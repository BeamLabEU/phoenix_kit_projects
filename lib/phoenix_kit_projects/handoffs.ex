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

  The project is read in two statements (its rows with their names, its
  dependencies) per write, however many rows the write moved
  (`statuses_changed/2`), and the rules run in memory; then one assignment
  read per person told. Nothing here raises into the writer: a change is
  never lost to a notice.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKit.RepoHelper
  alias PhoenixKitProjects.{Activity, Actor, Notices, People, Projects}
  alias PhoenixKitProjects.Schemas.{Assignment, Dependency, Project}

  @type change :: %{uuid: binary(), project_uuid: binary(), from: term(), to: term()}

  @doc """
  Reacts to one task's status change. `cause` is `:direct` (the caller logs
  the change itself) or `:auto` (tick rules, rollups: logged here).
  """
  @spec status_changed(change(), :direct | :auto) :: :ok
  def status_changed(change, cause), do: statuses_changed([change], cause)

  @doc """
  Reacts to the status changes one write made — a tick that moved a parent
  and ten subtasks is one call: the project is read once, and each person is
  told once, however many of the changes concern them.
  """
  @spec statuses_changed([change()], :direct | :auto) :: :ok
  def statuses_changed([], _cause), do: :ok

  def statuses_changed(changes, cause) when is_list(changes) do
    actor = Actor.get()

    changes
    |> Enum.group_by(& &1.project_uuid)
    |> Enum.each(fn {project_uuid, mine} ->
      shape = load(project_uuid)
      if cause == :auto, do: Enum.each(mine, &log_auto(&1, shape, actor))
      wake(mine, shape, actor)
      hold(mine, shape, actor)
    end)

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
    |> Enum.map(&{&1, %{}})
    |> tell("projects.assignment_ready", Actor.get())

    :ok
  rescue
    error ->
      Logger.warning("[Projects] start hand-off failed: #{inspect(error.__struct__)}")
      :ok
  catch
    :exit, _ -> :ok
  end

  # ── Your turn ───────────────────────────────────────────────────────

  defp wake(changes, shape, actor) do
    changes
    |> Enum.filter(&(&1.to == "done"))
    |> Enum.flat_map(fn %{uuid: uuid} ->
      after_label = label(shape, uuid)

      shape.dependents
      |> Map.get(uuid, [])
      |> Enum.flat_map(&[&1 | descendants(&1, shape)])
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
    end)
    |> Enum.uniq_by(fn {row, _} -> row.uuid end)
    |> tell("projects.assignment_ready", actor)
  end

  # ── On hold ─────────────────────────────────────────────────────────

  defp hold(changes, shape, actor) do
    changes
    |> Enum.filter(&(&1.from == "done" and &1.to != "done"))
    |> Enum.flat_map(fn %{uuid: uuid} ->
      after_label = label(shape, uuid)

      shape.dependents
      |> Map.get(uuid, [])
      |> Enum.flat_map(&[&1 | descendants(&1, shape)])
      |> Enum.map(&Map.get(shape.rows, &1))
      |> Enum.filter(&(&1 && &1.status == "in_progress"))
      |> Enum.map(&{&1, %{"after" => after_label}})
    end)
    |> Enum.uniq_by(fn {row, _} -> row.uuid end)
    |> tell("projects.assignment_on_hold", actor)
  end

  # One notice per person: the first of their rows (in the list's order) is
  # named, the rest are counted. The assignee lists are read per row — a
  # person is a key, a team or department one read each.
  defp tell(rows, action, actor) do
    rows
    |> Enum.flat_map(fn {row, meta} ->
      Enum.map(People.assignee_user_uuids(row), &{&1, row, meta})
    end)
    |> Enum.reject(fn {user_uuid, _, _} -> user_uuid == actor end)
    |> Enum.group_by(&elem(&1, 0), &{elem(&1, 1), elem(&1, 2)})
    |> Enum.each(fn {user_uuid, mine} ->
      [{first, meta} | rest] = Enum.sort_by(mine, fn {row, _} -> row.position end)
      meta = if rest == [], do: meta, else: Map.put(meta, "more", length(rest))

      case Projects.get_assignment(first.uuid) do
        %Assignment{} = a ->
          Notices.notify(action, a, actor_uuid: actor, recipients: [user_uuid], metadata: meta)

        _ ->
          :ok
      end
    end)
  end

  # ── Rows nobody logged ──────────────────────────────────────────────

  defp log_auto(%{uuid: uuid, project_uuid: project_uuid, from: from, to: to}, shape, actor) do
    Activity.log(auto_action(from, to),
      actor_uuid: actor,
      resource_type: "assignment",
      resource_uuid: uuid,
      metadata: %{
        "task" => label(shape, uuid),
        "project_uuid" => project_uuid,
        "auto" => true,
        "from" => from,
        "to" => to
      }
    )
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
        left_join: t in assoc(a, :task),
        left_join: cp in assoc(a, :child_project),
        where: a.project_uuid == ^project_uuid and a.review_status == "accepted",
        select: %{
          uuid: a.uuid,
          label: coalesce(t.title, cp.name),
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

  defp label(shape, uuid), do: get_in(shape.rows, [uuid, :label]) || ""
end
