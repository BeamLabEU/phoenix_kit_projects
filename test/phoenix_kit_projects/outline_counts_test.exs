defmodule PhoenixKitProjects.OutlineCountsTest do
  @moduledoc """
  What a project counts once tasks can sit under tasks (chain V23): the
  rows with nothing under them, everywhere a project measures its work —
  the summaries, the tree summary, the workload counts, the template
  count — plus the places a subtask travels: a clone keeps the nesting, a
  task cannot depend on its own branch, the schedule nests a subtask in
  its parent, the Hours page reads a parent as own + below, and a held
  task is off the portal.
  """

  use PhoenixKitProjects.DataCase, async: false

  alias PhoenixKit.RepoHelper
  alias PhoenixKitProjects.{Hours, Ledger, Projects, ScheduleLayout}
  alias PhoenixKitProjects.Schemas.Assignment

  # `parent_uuid` is not castable: a subtask is placed through
  # `Outline.move/3`, as every real path places one.
  defp task(project, title, attrs \\ %{}) do
    {parent, attrs} = Map.pop(attrs, "parent_uuid")

    {:ok, %{assignment: a}} =
      Projects.create_task_with_assignment(
        project.uuid,
        %{"title" => title, "ad_hoc" => true},
        attrs
      )

    if parent do
      {:ok, a} = PhoenixKitProjects.Outline.move(a, parent, :last)
      a
    else
      a
    end
  end

  defp set(%Assignment{} = a, changes) do
    {:ok, a} = a |> Ecto.Changeset.change(changes) |> RepoHelper.repo().update()
    a
  end

  # Parent (todo) with two subtasks (one done), and one plain task (todo):
  # three leaves, one of them done.
  defp outline(name \\ "Outline") do
    project = fixture_project(%{"name" => "#{name} #{System.unique_integer([:positive])}"})
    parent = task(project, "Parent")

    done =
      task(project, "Sub done", %{"parent_uuid" => parent.uuid})
      |> set(status: "done", progress_pct: 100)

    open = task(project, "Sub open", %{"parent_uuid" => parent.uuid})
    plain = task(project, "Plain")
    %{project: project, parent: parent, done: done, open: open, plain: plain}
  end

  describe "counts count leaves" do
    test "project_summary/1 leaves the parent out of total and progress" do
      %{project: project} = outline()
      summary = Projects.project_summary(project)

      assert summary.total == 3
      assert summary.done == 1
      assert summary.progress_pct == 33
    end

    test "project_tree_summary/1 counts the three leaves" do
      %{project: project} = outline()
      node = Projects.project_tree_summary(project)

      assert node.task_total == 3
      assert node.task_done == 1
      assert node.task_waiting == 2
      assert node.progress_pct == 33
    end

    test "assignment_counts_for_projects/1 and assignment_status_counts/0 skip the parent" do
      before = Projects.assignment_status_counts()
      %{project: project} = outline()

      assert Projects.assignment_counts_for_projects([project.uuid]) == %{project.uuid => 3}

      now = Projects.assignment_status_counts()
      assert Map.get(now, "waiting", 0) - Map.get(before, "waiting", 0) == 2
      assert Map.get(now, "done", 0) - Map.get(before, "done", 0) == 1
    end

    test "a held subtask makes its parent a leaf again" do
      %{project: project, done: done, open: open} = outline()
      set(done, review_status: "removed")
      set(open, review_status: "removed")

      # Parent + plain.
      assert Projects.project_summary(project).total == 2
    end
  end

  describe "available_dependencies/2" do
    test "never offers the task's own branch" do
      %{project: project, parent: parent, done: done, open: open, plain: plain} = outline()

      offered =
        project.uuid |> Projects.available_dependencies(parent.uuid) |> Enum.map(& &1.uuid)

      assert offered == [plain.uuid]

      offered = project.uuid |> Projects.available_dependencies(open.uuid) |> Enum.map(& &1.uuid)
      assert Enum.sort(offered) == Enum.sort([done.uuid, plain.uuid])
    end
  end

  describe "cloning a template" do
    test "a subtask of the template is a subtask of the copy" do
      template =
        fixture_project(%{
          "name" => "Tpl #{System.unique_integer([:positive])}",
          "is_template" => "true"
        })

      parent = task(template, "Parent")
      _sub = task(template, "Sub", %{"parent_uuid" => parent.uuid})

      {:ok, copy} =
        Projects.create_project_from_template(template.uuid, %{
          "name" => "Copy #{System.unique_integer([:positive])}"
        })

      rows = Projects.list_assignments(copy.uuid)
      by_title = Map.new(rows, &{&1.task.title, &1})

      assert by_title["Parent"].parent_uuid == nil
      assert by_title["Sub"].parent_uuid == by_title["Parent"].uuid
    end
  end

  describe "ScheduleLayout.tree/1" do
    test "a subtask hangs off its parent task and the parent spans it" do
      %{project: project, parent: parent, open: open} = outline()
      {items, layout} = ScheduleLayout.tree(Projects.get_project!(project.uuid))
      by_uuid = Map.new(items, &{&1.uuid, &1})

      assert by_uuid[open.uuid].parent_uuid == parent.uuid
      assert by_uuid[parent.uuid].parent_uuid == nil

      span = layout[parent.uuid]
      sub = layout[open.uuid]
      assert NaiveDateTime.compare(span.start, sub.start) in [:lt, :eq]
      assert NaiveDateTime.compare(span.end, sub.end) in [:gt, :eq]
    end

    test "own_bar?/2: a subtask has a calendar bar only with a date of its own" do
      %{project: project, open: open} = outline()
      project = Projects.get_project!(project.uuid)

      {items, _} = ScheduleLayout.tree(project)
      refute ScheduleLayout.own_bar?(Enum.find(items, &(&1.uuid == open.uuid)), project)

      set(open, end_date: ~D[2026-11-02])
      {items, _} = ScheduleLayout.tree(project)
      assert ScheduleLayout.own_bar?(Enum.find(items, &(&1.uuid == open.uuid)), project)
    end
  end

  describe "hours" do
    test "Ledger.totals_for_branches/1 gives a parent its own time plus what is under it" do
      %{project: project, parent: parent, open: open, plain: plain} = outline()
      {:ok, _} = Ledger.log_time(project.uuid, 30, assignment_uuid: parent.uuid)
      {:ok, _} = Ledger.log_time(project.uuid, 45, assignment_uuid: open.uuid)

      totals = project.uuid |> Projects.list_assignments() |> Ledger.totals_for_branches()

      assert totals[parent.uuid].minutes == 75.0
      assert totals[parent.uuid].own.minutes == 30.0
      assert totals[open.uuid].minutes == 45.0
      assert totals[plain.uuid].minutes == 0.0
    end

    test "Hours.summary/2 lists a parent with nothing of its own for the time under it" do
      %{project: project, parent: parent, open: open} = outline()
      {:ok, _} = Ledger.log_time(project.uuid, 45, assignment_uuid: open.uuid)

      summary = Hours.summary(Hours.filters(project_uuids: [project.uuid]))
      rows = Map.new(summary.by_task, &{&1.task.uuid, &1})

      assert rows[open.uuid].minutes == 45.0
      assert rows[open.uuid].below_minutes == 0.0
      assert rows[parent.uuid].minutes == 0.0
      assert rows[parent.uuid].below_minutes == 45.0
      assert rows[parent.uuid].entries == 0
    end

    test "a subtask is named with the task it sits under in the pickers" do
      %{project: project, open: open} = outline()

      assert Hours.task_option(open.uuid).title == "Parent / Sub open"

      assert %{title: "Parent / Sub open"} =
               Enum.find(Hours.task_options([project.uuid], nil), &(&1.uuid == open.uuid))

      {found, _more?} = Hours.search_tasks([project.uuid], "Sub open", 10)
      assert [%{title: "Parent / Sub open"}] = found
    end
  end

  describe "Assignment.label_under/3" do
    test "a top-level task is just its label; a subtask without its parent loaded too" do
      %{project: project, parent: parent, open: open} = outline()
      rows = Map.new(Projects.list_assignments(project.uuid), &{&1.uuid, &1})

      assert Assignment.label_under(rows[parent.uuid]) == "Parent"

      assert Assignment.label_under(rows[open.uuid], nil, rows[parent.uuid]) ==
               "Parent / Sub open"

      assert Assignment.label_under(%{rows[open.uuid] | parent: %Ecto.Association.NotLoaded{}}) ==
               "Sub open"
    end
  end
end
