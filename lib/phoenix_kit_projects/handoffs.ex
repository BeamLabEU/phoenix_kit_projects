defmodule PhoenixKitProjects.Handoffs do
  @moduledoc """
  What a task's status change means for the people around it.

  Every path that changes a task's status already announces it in one of two
  places — `Projects` (a status written directly: the page, the form, the API,
  a sub-project's rollup) and `Outline` (the rows the tick rules move) — and
  both call `status_changed/2` after the write. Here:

    * **A row nobody logged gets its history line.** The tick rules and the
      rollups move rows no caller logged (`cause: :auto`): they are written
      as `auto` activity, attributed to whoever's change set them off.
    * **"Your turn"** (`projects.assignment_ready`). A task is *ready* when it
      is still to do, every task it depends on is done, and so is everything
      every task above it depends on. When a task is done, the tasks that
      wait on it — and the subtasks under those — that became ready tell
      their assignee. Never inferred from the list's order: a dependency is
      the only "after" there is (the panel, 2026-10-25). Work already in
      progress that was waiting on it (put on hold by a reopen, or started
      early) is told it can go on (`"resume"`).
    * **"On hold"** (`projects.assignment_on_hold`). A done task reopened
      while something that waits on it is in progress tells that assignee.

  `project_started/1` tells the assignees of the tasks that are ready when a
  project starts — one notice per person, naming the first and counting the
  rest.

  The project is read in two statements (its rows, its dependencies) and the
  rules run in memory. Nothing here raises into the writer: a change is never
  lost to a notice.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKit.RepoHelper
  alias PhoenixKitProjects.{Activity, Actor, Notices, People, Projects}
  alias PhoenixKitProjects.Schemas.{Assignment, Dependency, Project}

  @doc """
  Reacts to one task's status change. `cause` is `:direct` (the caller logs
  the change itself) or `:auto` (tick rules, rollups: logged here).
  """
  @spec status_changed(
          %{uuid: binary(), project_uuid: binary(), from: term(), to: term()},
          :direct | :auto
        ) :: :ok
  def status_changed(%{uuid: uuid, project_uuid: project_uuid, from: from, to: to}, cause) do
    actor = Actor.get()

    if cause == :auto, do: log_auto(uuid, from, to, actor)

    cond do
      to == "done" -> wake_after(uuid, project_uuid, actor)
      from == "done" -> hold_after(uuid, project_uuid, actor)
      true -> :ok
    end

    :ok
  rescue
    error ->
      Logger.warning("[Projects] hand-off failed: #{inspect(error.__struct__)}")
      :ok
  catch
    :exit, _ -> :ok
  end

  @doc "Tells the assignees of the tasks ready when `project` starts."
  @spec project_started(Project.t()) :: :ok
  def project_started(%Project{is_template: true}), do: :ok

  def project_started(%Project{} = project) do
    shape = load(project.uuid)

    shape.rows
    |> Map.values()
    |> Enum.filter(&ready?(&1, shape))
    |> Enum.sort_by(& &1.position)
    |> Enum.flat_map(fn row -> Enum.map(People.assignee_user_uuids(row), &{&1, row}) end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.each(fn {user_uuid, [first | rest]} ->
      notify_ready(first.uuid, [user_uuid], Actor.get(), %{"more" => length(rest)})
    end)

    :ok
  rescue
    error ->
      Logger.warning("[Projects] start hand-off failed: #{inspect(error.__struct__)}")
      :ok
  catch
    :exit, _ -> :ok
  end

  # ── Your turn ───────────────────────────────────────────────────────

  defp wake_after(uuid, project_uuid, actor) do
    shape = load(project_uuid)
    waiting = Map.get(shape.dependents, uuid, [])

    after_label = label_of(uuid)

    woken =
      waiting
      |> Enum.flat_map(&[&1 | descendants(&1, shape)])
      |> Enum.uniq()
      |> Enum.map(&Map.get(shape.rows, &1))
      |> Enum.flat_map(fn
        nil ->
          []

        row ->
          cond do
            ready?(row, shape) ->
              [{row, %{"after" => after_label}}]

            # Work already under way that was waiting on this — on hold since
            # it was reopened, or started early: it can go on now.
            row.status == "in_progress" and clear?(row.uuid, shape, 0) ->
              [{row, %{"after" => after_label, "resume" => true}}]

            true ->
              []
          end
      end)

    # One notice per person per change: a container that became ready with
    # three subtasks of the same person is one line naming the first.
    woken
    |> Enum.flat_map(fn {row, meta} ->
      Enum.map(People.assignee_user_uuids(row), &{&1, row, meta})
    end)
    |> Enum.group_by(&elem(&1, 0), &{elem(&1, 1), elem(&1, 2)})
    |> Enum.each(fn {user_uuid, rows} ->
      [{first, meta} | rest] = Enum.sort_by(rows, fn {row, _} -> row.position end)
      meta = if rest == [], do: meta, else: Map.put(meta, "more", length(rest))
      notify_ready(first.uuid, [user_uuid], actor, meta)
    end)
  end

  defp notify_ready(uuid, recipients, actor, meta) do
    case Projects.get_assignment(uuid) do
      %Assignment{} = a ->
        Notices.notify("projects.assignment_ready", a,
          actor_uuid: actor,
          recipients: recipients,
          metadata: meta
        )

      _ ->
        :ok
    end
  end

  # ── On hold ─────────────────────────────────────────────────────────

  defp hold_after(uuid, project_uuid, actor) do
    shape = load(project_uuid)
    after_label = label_of(uuid)

    shape.dependents
    |> Map.get(uuid, [])
    |> Enum.flat_map(&[&1 | descendants(&1, shape)])
    |> Enum.uniq()
    |> Enum.map(&Map.get(shape.rows, &1))
    |> Enum.filter(&(&1 && &1.status == "in_progress"))
    |> Enum.each(fn row ->
      case People.assignee_user_uuids(row) do
        [] ->
          :ok

        recipients ->
          case Projects.get_assignment(row.uuid) do
            %Assignment{} = a ->
              Notices.notify("projects.assignment_on_hold", a,
                actor_uuid: actor,
                recipients: recipients,
                metadata: %{"after" => after_label}
              )

            _ ->
              :ok
          end
      end
    end)
  end

  # ── Rows nobody logged ──────────────────────────────────────────────

  defp log_auto(uuid, from, to, actor) do
    case Projects.get_assignment(uuid) do
      %Assignment{} = a ->
        Activity.log(auto_action(from, to),
          actor_uuid: actor,
          resource_type: "assignment",
          resource_uuid: a.uuid,
          metadata: %{
            "task" => Notices.subject_label(a),
            "project_uuid" => a.project_uuid,
            "auto" => true,
            "from" => from,
            "to" => to
          }
        )

      _ ->
        :ok
    end
  end

  defp auto_action(_from, "done"), do: "projects.assignment_completed"
  defp auto_action("done", _to), do: "projects.assignment_reopened"
  defp auto_action(_from, "in_progress"), do: "projects.assignment_started"
  defp auto_action(_from, _to), do: "projects.assignment_reopened"

  # ── The project's shape ─────────────────────────────────────────────

  @doc false
  # Every accepted row of the project and its dependencies, in two reads:
  # `rows` by uuid, `deps` (a row → what it waits on), `dependents` (a row →
  # what waits on it), `children` (a row → the rows directly under it).
  def load(project_uuid) do
    rows =
      from(a in Assignment,
        where: a.project_uuid == ^project_uuid and a.review_status == "accepted",
        select: %{
          uuid: a.uuid,
          parent_uuid: a.parent_uuid,
          status: a.status,
          position: a.position,
          assigned_person_uuid: a.assigned_person_uuid,
          assigned_team_uuid: a.assigned_team_uuid,
          assigned_department_uuid: a.assigned_department_uuid
        }
      )
      |> RepoHelper.repo().all()
      |> Map.new(&{&1.uuid, &1})

    pairs =
      from(d in Dependency,
        join: a in Assignment,
        on: a.uuid == d.assignment_uuid,
        where: a.project_uuid == ^project_uuid,
        select: {d.assignment_uuid, d.depends_on_uuid}
      )
      |> RepoHelper.repo().all()

    %{
      rows: rows,
      deps: Enum.group_by(pairs, &elem(&1, 0), &elem(&1, 1)),
      dependents: Enum.group_by(pairs, &elem(&1, 1), &elem(&1, 0)),
      children:
        rows
        |> Map.values()
        |> Enum.reject(&is_nil(&1.parent_uuid))
        |> Enum.group_by(& &1.parent_uuid, & &1.uuid)
    }
  end

  @doc false
  # Still to do, and nothing it — or any task above it — waits on is open.
  def ready?(%{status: "todo"} = row, shape), do: clear?(row.uuid, shape, 0)
  def ready?(_row, _shape), do: false

  defp clear?(nil, _shape, _depth), do: true
  defp clear?(_uuid, _shape, depth) when depth > 100, do: false

  defp clear?(uuid, shape, depth) do
    met? =
      shape.deps
      |> Map.get(uuid, [])
      |> Enum.all?(fn dep ->
        case Map.get(shape.rows, dep) do
          %{status: "done"} -> true
          # A dependency held out of the list no longer holds anything up.
          nil -> true
          _ -> false
        end
      end)

    met? and clear?(get_in(shape.rows, [uuid, :parent_uuid]), shape, depth + 1)
  end

  defp descendants(uuid, shape) do
    shape.children
    |> Map.get(uuid, [])
    |> Enum.flat_map(&[&1 | descendants(&1, shape)])
  end

  defp label_of(uuid) do
    case Projects.get_assignment(uuid) do
      %Assignment{} = a -> Notices.subject_label(a)
      _ -> ""
    end
  end
end
