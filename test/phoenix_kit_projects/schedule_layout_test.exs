defmodule PhoenixKitProjects.ScheduleLayoutTest do
  @moduledoc """
  Direct pins for the shared durations→dates walk. Both the Timeline and
  Calendar tabs render from `tree/1`, so its contract — flattened tree
  order, sequential spans from the schedule anchor, uuid-keyed layout —
  was previously only pinned transitively through those LVs' tests.
  """
  use PhoenixKitProjects.DataCase, async: false

  alias PhoenixKitProjects.{Projects, ScheduleLayout}
  alias PhoenixKitProjects.Schemas.{Assignment, Project}

  defp sl_task(attrs) do
    {:ok, task} =
      Projects.create_task(
        Map.merge(
          %{
            "title" => "SL task #{System.unique_integer([:positive])}",
            "estimated_duration" => 4,
            "estimated_duration_unit" => "hours"
          },
          attrs
        )
      )

    task
  end

  defp started_project(attrs \\ %{}) do
    {:ok, project} =
      Projects.create_project(
        Map.merge(
          %{
            "name" => "SL project #{System.unique_integer([:positive])}",
            # Calendar-hours (weekends counted) so a 4h estimate spans exactly
            # 4 wall-clock hours — weekday mode stretches working hours over
            # calendar time and would make the pins rate-dependent.
            "counts_weekends" => "true",
            "start_mode" => "immediate",
            "started_at" =>
              DateTime.new!(Date.utc_today(), ~T[08:00:00], "Etc/UTC")
              |> DateTime.truncate(:second)
          },
          attrs
        )
      )

    project
  end

  test "tree/1 lays tasks out sequentially from the project's start, in position order" do
    project = started_project()
    t1 = sl_task(%{"title" => "First (4h)"})
    t2 = sl_task(%{"title" => "Second (4h)"})

    {:ok, a1} =
      Projects.create_assignment(%{"project_uuid" => project.uuid, "task_uuid" => t1.uuid})

    {:ok, a2} =
      Projects.create_assignment(%{"project_uuid" => project.uuid, "task_uuid" => t2.uuid})

    {items, layout} = project.uuid |> Projects.get_project!() |> ScheduleLayout.tree()

    assert Enum.map(items, & &1.uuid) == [a1.uuid, a2.uuid]
    assert %{start: s1, end: e1} = layout[a1.uuid]
    assert %{start: s2, end: e2} = layout[a2.uuid]

    # Anchor = started_at; each task starts where the previous ends.
    assert s1 == project.started_at |> DateTime.to_naive()
    assert NaiveDateTime.diff(e1, s1, :hour) == 4
    assert s2 == e1
    assert NaiveDateTime.diff(e2, s2, :hour) == 4
  end

  test "tree/1 flattens a sub-project inline and its span covers the child's walk" do
    parent = started_project()
    child = started_project(%{"name" => "SL child #{System.unique_integer([:positive])}"})

    t = sl_task(%{"title" => "Child chore", "estimated_duration" => 8})

    {:ok, child_a} =
      Projects.create_assignment(%{"project_uuid" => child.uuid, "task_uuid" => t.uuid})

    {:ok, %{assignment: link}} = Projects.link_subproject(parent.uuid, child.uuid)

    {items, layout} = parent.uuid |> Projects.get_project!() |> ScheduleLayout.tree()

    # Link row immediately followed by its descendant; the descendant belongs
    # to the CHILD project.
    assert [%{uuid: link_uuid, parent_uuid: nil}, %{uuid: leaf_uuid, parent_uuid: leaf_parent}] =
             items

    assert link_uuid == link.uuid
    assert leaf_uuid == child_a.uuid
    assert leaf_parent == link.uuid
    assert Enum.at(items, 1).project.uuid == child.uuid

    # The container's span covers its child's.
    assert NaiveDateTime.compare(layout[link.uuid].start, layout[child_a.uuid].start) != :gt
    assert NaiveDateTime.compare(layout[link.uuid].end, layout[child_a.uuid].end) != :lt
  end

  test "task_counts_weekends?/2 prefers the assignment override, falls back to the project" do
    project = %Project{counts_weekends: true}

    assert ScheduleLayout.task_counts_weekends?(%Assignment{counts_weekends: nil}, project)
    refute ScheduleLayout.task_counts_weekends?(%Assignment{counts_weekends: false}, project)

    refute ScheduleLayout.task_counts_weekends?(
             %Assignment{counts_weekends: nil},
             %Project{counts_weekends: false}
           )
  end

  test "assignment_hours/2 prefers the assignment's duration, falling back to the task's" do
    project = %Project{counts_weekends: true}

    task = %PhoenixKitProjects.Schemas.Task{
      estimated_duration: 2,
      estimated_duration_unit: "days"
    }

    own = %Assignment{estimated_duration: 3, estimated_duration_unit: "hours", task: task}
    assert ScheduleLayout.assignment_hours(own, project) == 3.0

    inherited = %Assignment{estimated_duration: nil, task: task}
    assert ScheduleLayout.assignment_hours(inherited, project) == 48.0

    bare = %Assignment{estimated_duration: nil, task: nil}
    assert ScheduleLayout.assignment_hours(bare, project) == 0.0
  end
end
