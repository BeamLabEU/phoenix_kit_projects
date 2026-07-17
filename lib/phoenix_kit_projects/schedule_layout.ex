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

  @type span :: %{start: NaiveDateTime.t(), end: NaiveDateTime.t()}

  # Guards against pathological/corrupt nesting when flattening the tree.
  @max_subproject_depth 32

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
  """
  @spec tree(Project.t()) :: {[item()], %{String.t() => span()}}
  def tree(%Project{} = project) do
    items = collect_items(project, nil, 0)

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

    {items, layout}
  end

  # The anchor for the sequential walk: the real start when running, the
  # planned start when scheduled, else "now" so an unstarted project still
  # previews.
  @spec schedule_anchor(Project.t()) :: DateTime.t()
  defp schedule_anchor(%Project{started_at: %DateTime{} = at}), do: at
  defp schedule_anchor(%Project{scheduled_start_date: %DateTime{} = at}), do: at
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
  # `@max_subproject_depth` guards against pathological/corrupt nesting.
  defp collect_items(project, parent_uuid, depth) do
    project.uuid
    |> Projects.list_assignments()
    |> Enum.flat_map(fn a ->
      item = %{
        uuid: a.uuid,
        assignment: a,
        project: project,
        parent_uuid: parent_uuid,
        position: a.position
      }

      children =
        if subproject_with_children?(a, depth),
          do: collect_items(a.child_project, a.uuid, depth + 1),
          else: []

      [item | children]
    end)
  end

  defp subproject_with_children?(%Assignment{} = a, depth) do
    Assignment.subproject?(a) and not is_nil(a.child_project) and depth < @max_subproject_depth
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
