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
  alias PhoenixKitProjects.{Activity, Actor, Notices, Outline, People, Projects}
  alias PhoenixKitProjects.Schemas.{Assignment, Dependency, Project}

  @type change :: %{uuid: binary(), project_uuid: binary(), from: term(), to: term()}

  @batch :projects_handoff_batch
  @overrides :projects_handoff_overrides

  # Deeper than any real outline; a guard against a cycle the database
  # trigger should already make impossible.
  @max_depth 100

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
    tagged = Enum.map(changes, &{&1, cause})

    case Process.get(@batch) do
      buffered when is_list(buffered) -> Process.put(@batch, buffered ++ tagged)
      _ -> run(tagged)
    end

    :ok
  end

  @doc """
  Runs `fun` as one write: the status changes announced inside it — the
  caller's own and the rows the tick rules moved with it, which announce
  first — are reacted to together when it returns, so a person told about
  the subtask and its parent is told once. Nested calls join the outer one;
  an exception drops what was collected.
  """
  @spec batch((-> result)) :: result when result: term()
  def batch(fun) when is_function(fun, 0) do
    if is_list(Process.get(@batch)) do
      fun.()
    else
      Process.put(@batch, [])

      result =
        try do
          fun.()
        rescue
          error ->
            Process.delete(@batch)
            reraise error, __STACKTRACE__
        catch
          kind, reason ->
            Process.delete(@batch)
            :erlang.raise(kind, reason, __STACKTRACE__)
        end

      run(Process.delete(@batch) || [])
      result
    end
  end

  @doc """
  Runs `fun` with per-task choices for the notices it causes, keyed by the
  task's uuid: `:only` — the people (user uuids) who may be told about that
  task, the rest left out (nil: everyone it would tell); `:note` — words
  that ride along in the notice ("the client is home after 17:00"). What
  the project page's "next up" dialog sets: who to tell, and what.
  """
  @spec with_overrides(%{binary() => map()}, (-> result)) :: result when result: term()
  def with_overrides(overrides, fun) when is_map(overrides) and is_function(fun, 0) do
    previous = Process.get(@overrides)
    Process.put(@overrides, overrides)

    try do
      fun.()
    after
      if previous, do: Process.put(@overrides, previous), else: Process.delete(@overrides)
    end
  end

  @doc """
  Drops what the current `batch/1` collected — for a caller whose writes
  rolled back inside the batch (nobody is told of a change that did not
  happen). Outside a batch it does nothing.
  """
  @spec discard() :: :ok
  def discard do
    if is_list(Process.get(@batch)), do: Process.put(@batch, [])
    :ok
  end

  defp run([]), do: :ok

  defp run(tagged) do
    actor = Actor.get()

    tagged
    |> Enum.group_by(fn {change, _cause} -> change.project_uuid end)
    |> Enum.each(fn {project_uuid, pairs} ->
      shape = load(project_uuid)

      pairs
      |> Enum.filter(&match?({_, :auto}, &1))
      |> Enum.each(fn {change, _} -> log_auto(change, shape, actor) end)

      mine = Enum.map(pairs, &elem(&1, 0))
      wake(mine, shape, actor)
      hold(mine, shape, actor)

      # The rows above exist now: the project's History reloads with them
      # (the status broadcast went out before they were written).
      PhoenixKitProjects.PubSub.broadcast_to_project(project_uuid, :history_changed, %{
        project_uuid: project_uuid
      })
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

  @doc """
  The not-started tasks of `project_uuid` (waiting, or already released)
  that nothing would hold up once `uuid` is done — read before the write,
  so the project page can ask first ("next up"): release each one or keep
  it idle, and nobody is told of a completion that was a slip. Completing
  a task ticks its open subtasks, and closing a parent's last open subtask
  closes the parent while the project lets it (`Outline.parent_auto?/1`),
  so both are counted done here. In the list's order. Never raises: an
  empty list on a failure.
  """
  @spec would_ready(binary(), binary()) :: [map()]
  def would_ready(project_uuid, uuid) do
    shape = load(project_uuid)
    below = [uuid | descendants(uuid, shape)]

    above =
      if Outline.parent_auto?(project_uuid),
        do: closed_above(uuid, shape, below, 0),
        else: []

    closed = below ++ above
    after_shape = Enum.reduce(closed, shape, &put_in(&2, [:rows, &1, :status], "done"))

    closed
    |> Enum.flat_map(&waiting_on(&1, after_shape))
    |> Enum.reject(&(&1.uuid in closed))
    |> Enum.filter(&(&1.status in ["waiting", "todo"] and clear?(&1.uuid, after_shape, 0)))
    |> Enum.uniq_by(& &1.uuid)
    |> Enum.sort_by(& &1.position)
  rescue
    error ->
      Logger.warning("[Projects] next-up read failed: #{inspect(error.__struct__)}")
      []
  catch
    :exit, _ -> []
  end

  # The parents that close with `uuid`: each whose every other subtask is
  # already done (or closing), climbing while that holds.
  defp closed_above(_uuid, _shape, _closing, depth) when depth > @max_depth, do: []

  defp closed_above(uuid, shape, closing, depth) do
    with parent when is_binary(parent) <- get_in(shape.rows, [uuid, :parent_uuid]),
         %{status: status} when status != "done" <- Map.get(shape.rows, parent),
         true <-
           shape.children
           |> Map.get(parent, [])
           |> Enum.all?(&(&1 in closing or get_in(shape.rows, [&1, :status]) == "done")) do
      [parent | closed_above(parent, shape, [parent | closing], depth + 1)]
    else
      _ -> []
    end
  end

  # The rows that wait on `uuid`, and the subtasks under them.
  defp waiting_on(uuid, shape) do
    shape.dependents
    |> Map.get(uuid, [])
    |> Enum.flat_map(&[&1 | descendants(&1, shape)])
    |> Enum.map(&Map.get(shape.rows, &1))
    |> Enum.reject(&is_nil/1)
  end

  defp wake(changes, shape, actor) do
    changes
    |> Enum.filter(&(&1.to == "done"))
    |> Enum.flat_map(fn %{uuid: uuid} ->
      after_label = label(shape, uuid)

      uuid
      |> waiting_on(shape)
      |> Enum.flat_map(fn row ->
        cond do
          ready?(row, shape) ->
            [{row, %{"after" => after_label, "after_uuid" => uuid}}]

          # Work already under way that was waiting on this — on hold since
          # it was reopened, or started early: it can go on now.
          row.status == "in_progress" and clear?(row.uuid, shape, 0) ->
            [{row, %{"after" => after_label, "after_uuid" => uuid, "resume" => true}}]

          true ->
            []
        end
      end)
    end)
    |> Kernel.++(released(changes, shape))
    |> Enum.uniq_by(fn {row, _} -> row.uuid end)
    |> tell("projects.assignment_ready", actor)
  end

  # A waiting task released ("ready to start") tells its people it is their
  # turn — someone decided it can go, whatever is still open before it —
  # named after what it waited on: the task done in the same write first
  # (the "next up" confirm), else any done one. A task waiting stays
  # silent: idle means nobody is asked yet.
  defp released(changes, shape) do
    done_now = for %{to: "done", uuid: uuid} <- changes, do: uuid

    for %{from: "waiting", to: "todo", uuid: uuid} <- changes,
        %{} = row <- [Map.get(shape.rows, uuid)] do
      deps = Map.get(shape.deps, uuid, [])

      case Enum.find(deps, &(&1 in done_now)) ||
             Enum.find(deps, &(get_in(shape.rows, [&1, :status]) == "done")) do
        nil -> {row, %{}}
        dep -> {row, %{"after" => label(shape, dep), "after_uuid" => dep}}
      end
    end
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
      |> Enum.map(&{&1, %{"after" => after_label, "after_uuid" => uuid}})
    end)
    |> Enum.uniq_by(fn {row, _} -> row.uuid end)
    |> tell("projects.assignment_on_hold", actor)
  end

  # One notice per person and kind ("your turn" apart from "go on"): the
  # first of their rows (in the list's order) is named, the rest are
  # counted. The assignee lists are read per row — a person is a key, a team
  # or department one read each.
  defp tell(rows, action, actor) do
    overrides = Process.get(@overrides) || %{}

    rows
    |> Enum.flat_map(fn {row, meta} ->
      {people, meta} = overridden(People.assignee_user_uuids(row), meta, overrides[row.uuid])
      Enum.map(people, &{&1, row, meta})
    end)
    |> Enum.reject(fn {user_uuid, _, _} -> user_uuid == actor end)
    |> Enum.group_by(&{elem(&1, 0), elem(&1, 2)["resume"] == true}, &{elem(&1, 1), elem(&1, 2)})
    |> Enum.each(fn {{user_uuid, _resume?}, mine} ->
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

  # The page's choices for one task (`with_overrides/2`): only the people
  # it ticked, and its note in the notice.
  defp overridden(people, meta, nil), do: {people, meta}

  defp overridden(people, meta, %{} = o) do
    people = if is_list(o[:only]), do: Enum.filter(people, &(&1 in o[:only])), else: people

    meta =
      case o[:note] do
        note when is_binary(note) and note != "" -> Map.put(meta, "note", note)
        _ -> meta
      end

    {people, meta}
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

  @typedoc "A project's rows and dependencies, as `load/1` reads them."
  @type shape :: %{
          rows: %{binary() => map()},
          deps: %{binary() => [binary()]},
          dependents: %{binary() => [binary()]},
          children: %{binary() => [binary()]}
        }

  @doc false
  # Every accepted row of the project and its dependencies, in two reads:
  # `rows` by uuid, `deps` (a row → what it waits on), `dependents` (a row →
  # what waits on it), `children` (a row → the rows directly under it).
  @spec load(binary()) :: shape()
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
  @spec ready?(map(), shape()) :: boolean()
  def ready?(%{status: "todo"} = row, shape), do: clear?(row.uuid, shape, 0)
  def ready?(_row, _shape), do: false

  defp clear?(nil, _shape, _depth), do: true
  defp clear?(_uuid, _shape, depth) when depth > @max_depth, do: false

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
