defmodule PhoenixKitProjects.ScheduleLayout do
  @moduledoc """
  The shared durations→dates schedule walk behind the project show page's
  Timeline (gantt) and Calendar tabs.

  Flattens a project's assignment tree (sub-project descendants included) and
  lays every item out sequentially from the project's schedule anchor via
  `PhoenixLiveGantt.Layout.sequential/2` — each task starts where the previous
  one ends, honoring the task's effective weekday/weekend rule through
  `Project.eta_from/3`. Both tabs render from this one walk so they can never
  disagree about which dates a task occupies.

  The walk is hour-precise (`NaiveDateTime` spans in UTC, matching the
  project's stored `started_at`) and zoom/display-independent; consumers decide
  how to render the spans (bars on a date axis, all-day calendar chips, …).
  """

  alias PhoenixKitProjects.Projects
  alias PhoenixKitProjects.Schemas.{Assignment, Project}
  alias PhoenixKitProjects.Schemas.Task, as: TaskSchema

  @typedoc """
  One flattened schedule item: the assignment, its owning project (a
  sub-project descendant belongs to the CHILD project), and its
  linking-assignment parent (`nil` at top level).
  """
  @type item :: %{
          uuid: String.t(),
          assignment: Assignment.t(),
          project: Project.t(),
          parent_uuid: String.t() | nil,
          position: integer() | nil
        }

  @typedoc """
  A scheduled span. `pinned` is there only for a task that carries its own
  dates (`start_date` / `end_date`): the calendar days it occupies,
  inclusive — a consumer drawing whole days in a viewer's timezone uses
  those rather than converting the instants.
  """
  @type span :: %{
          required(:start) => NaiveDateTime.t(),
          required(:end) => NaiveDateTime.t(),
          optional(:pinned) => {Date.t(), Date.t()}
        }

  @doc """
  Flattens `project`'s assignment tree and computes each item's scheduled
  span. Returns `{items, layout}`: `items` in flattened tree order (each
  sub-project parent immediately followed by its descendants), `layout` a
  map of item uuid → `%{start: NaiveDateTime, end: NaiveDateTime}`.

  Tasks are laid out in the order the user gave them (drag `position`) — a
  manual order that violates a dependency is rendered honestly by the
  consumers, not reordered here. A sub-project's span covers its children's
  walk, so top-level spans stay correct even when a consumer only renders
  the top level.

  A task with its own dates sits on them instead of where the walk put it
  (both dates: that range; only a start: its computed length from that day,
  one day at least; only an end: that one day). The rest of the walk is
  not moved by it - the order still says what follows what - and a
  sub-project's span is widened to cover a pinned task inside it.
  """
  @spec tree(Project.t()) :: {[item()], %{String.t() => span()}}
  def tree(%Project{} = project) do
    [result] = trees([project])
    result
  end

  @doc """
  `tree/1` for a list of projects, batched: the whole forest's assignments
  come from one `Projects.assignments_by_project/1` read (one query per
  depth level) instead of one `list_assignments/1` per node — the shape a
  dashboard widget wants on a refresh tick. Results in input order.
  """
  @spec trees([Project.t()]) :: [{[item()], %{String.t() => span()}}]
  def trees(projects) when is_list(projects) do
    by_project = Projects.assignments_by_project(Enum.map(projects, & &1.uuid))
    Enum.map(projects, &tree_from(&1, by_project))
  end

  defp tree_from(%Project{} = project, by_project) do
    items = collect_items(project, nil, 0, by_project, %{})

    layout =
      PhoenixLiveGantt.Layout.sequential(items,
        start: DateTime.to_naive(schedule_anchor(project)),
        id: & &1.uuid,
        parent_id: & &1.parent_uuid,
        order: & &1.position,
        duration: fn it -> assignment_hours(it.assignment, it.project) end,
        advance: &advance_through_calendar/3,
        # No artificial minimum — reflect the real schedule. A task spans
        # exactly its duration; consumers decide how a zero-length span shows
        # (the gantt collapses it to a milestone, the calendar keeps its day).
        min_span: {:second, 0}
      )

    {items, pin_dates(items, layout)}
  end

  # Puts every task that carries its own dates on them, then widens each
  # ancestor's span to cover it.
  defp pin_dates(items, layout) do
    by_uuid = Map.new(items, &{&1.uuid, &1})

    Enum.reduce(items, layout, fn it, acc ->
      case pinned_span(it.assignment, Map.get(acc, it.uuid)) do
        nil -> acc
        span -> acc |> Map.put(it.uuid, span) |> widen_ancestors(it.parent_uuid, span, by_uuid)
      end
    end)
  end

  defp pinned_span(%Assignment{child_project_uuid: child}, _span) when not is_nil(child), do: nil
  defp pinned_span(%Assignment{start_date: nil, end_date: nil}, _span), do: nil
  defp pinned_span(_a, nil), do: nil

  defp pinned_span(%Assignment{start_date: %Date{} = from, end_date: %Date{} = to}, _span),
    do: day_span(from, to)

  defp pinned_span(%Assignment{start_date: %Date{} = from, end_date: nil}, span) do
    days = span.end |> NaiveDateTime.diff(span.start, :second) |> Kernel./(86_400) |> ceil()
    day_span(from, Date.add(from, max(days, 1) - 1))
  end

  defp pinned_span(%Assignment{start_date: nil, end_date: %Date{} = to}, _span),
    do: day_span(to, to)

  defp day_span(%Date{} = from, %Date{} = to) do
    to = if Date.compare(to, from) == :lt, do: from, else: to

    %{
      start: NaiveDateTime.new!(from, ~T[00:00:00]),
      end: NaiveDateTime.new!(Date.add(to, 1), ~T[00:00:00]),
      pinned: {from, to}
    }
  end

  defp widen_ancestors(layout, nil, _span, _by_uuid), do: layout

  defp widen_ancestors(layout, parent_uuid, span, by_uuid) do
    case {Map.get(layout, parent_uuid), Map.get(by_uuid, parent_uuid)} do
      {%{start: s, end: e} = parent, %{parent_uuid: up}} ->
        wide = %{
          parent
          | start: Enum.min([s, span.start], NaiveDateTime),
            end: Enum.max([e, span.end], NaiveDateTime)
        }

        layout |> Map.put(parent_uuid, wide) |> widen_ancestors(up, wide, by_uuid)

      _ ->
        layout
    end
  end

  # The anchor for the sequential walk: the real start when running, the
  # planned start when scheduled, else "now" so an unstarted project still
  # previews.
  @spec schedule_anchor(Project.t()) :: DateTime.t()
  defp schedule_anchor(%Project{started_at: %DateTime{} = at}), do: at
  defp schedule_anchor(%Project{scheduled_start_date: %DateTime{} = at}), do: at

  # Ongoing work with no start (made before it started itself) is under
  # way since it was made; "now" would move its tasks on every refresh.
  defp schedule_anchor(%Project{inserted_at: %DateTime{} = made} = project) do
    if Project.ongoing?(project), do: made, else: DateTime.utc_now()
  end

  defp schedule_anchor(_), do: DateTime.utc_now()

  @doc """
  Whether an assignment counts weekends — its own override, falling back to
  the project's setting.
  """
  @spec task_counts_weekends?(Assignment.t(), Project.t()) :: boolean()
  def task_counts_weekends?(a, project) do
    case a.counts_weekends do
      nil -> project.counts_weekends
      val -> val
    end
  end

  @doc """
  The estimated hours for an assignment: its own duration override if set,
  otherwise the underlying task's duration (nil-safe). Weekends are honored
  per `task_counts_weekends?/2`.
  """
  @spec assignment_hours(Assignment.t(), Project.t()) :: number()
  def assignment_hours(a, project) do
    weekends? = task_counts_weekends?(a, project)

    if a.estimated_duration && a.estimated_duration_unit do
      TaskSchema.to_hours(a.estimated_duration, a.estimated_duration_unit, weekends?)
    else
      task = a.task

      TaskSchema.to_hours(
        task && task.estimated_duration,
        task && task.estimated_duration_unit,
        weekends?
      )
    end
  end

  # Flattens the project tree into layout items, each carrying its owning
  # project and its linking-assignment parent (nil at top level). Sub-project
  # descendants ALWAYS appear so consumers can render or aggregate them;
  # `Projects.max_subproject_depth/0` guards against pathological/corrupt nesting.
  # `path` is the set of projects on the way down to here (a plain map —
  # dialyzer's opaqueness false positive on a literal MapSet): a link back to
  # one of them is a cycle in bad data, and descending would hand the
  # layout the same item uuid twice with a parent chain that loops — the
  # sequential walk then never terminates. Skipped, like the tree summary.
  defp collect_items(project, parent_uuid, depth, by_project, path) do
    path = Map.put(path, project.uuid, true)

    by_project
    |> Map.get(project.uuid, [])
    |> Enum.flat_map(fn a ->
      item = %{
        uuid: a.uuid,
        assignment: a,
        project: project,
        parent_uuid: parent_uuid,
        position: a.position
      }

      children =
        if subproject_with_children?(a, depth, path),
          do: collect_items(a.child_project, a.uuid, depth + 1, by_project, path),
          else: []

      [item | children]
    end)
  end

  # A child at the loader's depth cap is not collected — its assignments
  # were never read, so it would show as an empty container (codex,
  # 2026-09-05). Same convention as `Projects.project_tree_summaries/1`.
  defp subproject_with_children?(%Assignment{} = a, depth, path) do
    Assignment.subproject?(a) and not is_nil(a.child_project) and
      depth + 1 < Projects.max_subproject_depth() and
      not Map.has_key?(path, a.child_project_uuid)
  end

  # `PhoenixLiveGantt.Layout` `:advance` callback — move `cursor` forward by
  # `hours` honoring the assignment's effective weekday/weekend rule. The
  # cursor is a `Date` or `NaiveDateTime`; the result keeps that type so the
  # layout positions it at the right resolution.
  defp advance_through_calendar(cursor, hours, %{assignment: a, project: project}) do
    cal_project = %{project | counts_weekends: task_counts_weekends?(a, project)}

    case Project.eta_from(cal_project, to_utc_dt(cursor), hours) do
      %DateTime{} = ended -> from_utc_dt(ended, cursor)
      _ -> cursor
    end
  end

  defp to_utc_dt(%Date{} = d), do: DateTime.new!(d, ~T[00:00:00], "Etc/UTC")
  defp to_utc_dt(%NaiveDateTime{} = t), do: DateTime.from_naive!(t, "Etc/UTC")

  defp from_utc_dt(dt, %Date{}), do: DateTime.to_date(dt)
  defp from_utc_dt(dt, %NaiveDateTime{}), do: DateTime.to_naive(dt)
end
