defmodule PhoenixKitProjects.Integration.QuickAddTest do
  @moduledoc """
  `Projects.create_task_with_assignment/3` and the quick-add composer's
  `quick_add_assignment/3` on top of it: one transaction, bottom position,
  broadcasts only after commit, one-off tasks invisible to the library.
  """

  use PhoenixKitProjects.DataCase, async: false

  alias PhoenixKitProjects.Projects
  alias PhoenixKitProjects.PubSub, as: ProjectsPubSub
  alias PhoenixKitProjects.Schemas.{Assignment, Task}

  defp project! do
    fixture_project(%{"name" => "QA #{System.unique_integer([:positive])}"})
  end

  describe "quick_add_assignment/3" do
    test "creates a one-off task and its assignment at the bottom of the plan" do
      p = project!()
      t = fixture_task(%{"title" => "Library #{System.unique_integer([:positive])}"})

      {:ok, first} =
        Projects.create_assignment(%{"project_uuid" => p.uuid, "task_uuid" => t.uuid})

      assert {:ok, %{task: task, assignment: a}} =
               Projects.quick_add_assignment(p.uuid, "  Call the client  ")

      assert %Task{ad_hoc: true, title: "Call the client"} = task
      assert %Assignment{project_uuid: project_uuid, task_uuid: task_uuid, status: "todo"} = a
      assert project_uuid == p.uuid
      assert task_uuid == task.uuid
      assert a.position == first.position + 1

      # Two more land in order, never on the same number.
      {:ok, %{assignment: b}} = Projects.quick_add_assignment(p.uuid, "Second")
      {:ok, %{assignment: c}} = Projects.quick_add_assignment(p.uuid, "Third")
      assert [a.position, b.position, c.position] == [a.position, a.position + 1, a.position + 2]

      assert Enum.map(Projects.list_assignments(p.uuid), & &1.uuid) == [
               first.uuid,
               a.uuid,
               b.uuid,
               c.uuid
             ]
    end

    test "a blank title is a task validation error and writes nothing" do
      p = project!()
      before_tasks = Projects.count_tasks(ad_hoc: :all)

      assert {:error, :task, %Ecto.Changeset{} = cs} =
               Projects.quick_add_assignment(p.uuid, "   ")

      assert "can't be blank" in errors_on(cs).title
      assert Projects.count_tasks(ad_hoc: :all) == before_tasks
      assert Projects.list_assignments(p.uuid) == []
    end

    test "an unknown project is refused before anything is written" do
      before_tasks = Projects.count_tasks(ad_hoc: :all)

      assert {:error, :project, :not_found} =
               Projects.quick_add_assignment(Ecto.UUID.generate(), "Orphan")

      assert Projects.count_tasks(ad_hoc: :all) == before_tasks
    end

    test "broadcasts task + assignment creation after commit" do
      p = project!()
      ProjectsPubSub.subscribe(ProjectsPubSub.topic_project(p.uuid))
      ProjectsPubSub.subscribe(ProjectsPubSub.topic_tasks())

      {:ok, %{task: task, assignment: a}} = Projects.quick_add_assignment(p.uuid, "Ping")

      assert_receive {:projects, :assignment_created, %{uuid: a_uuid, project_uuid: p_uuid}}
      assert a_uuid == a.uuid and p_uuid == p.uuid
      assert_receive {:projects, :task_created, %{uuid: t_uuid, title: "Ping"}}
      assert t_uuid == task.uuid
    end

    test "a failed add broadcasts nothing" do
      p = project!()
      ProjectsPubSub.subscribe(ProjectsPubSub.topic_project(p.uuid))
      ProjectsPubSub.subscribe(ProjectsPubSub.topic_tasks())

      assert {:error, :task, _} = Projects.quick_add_assignment(p.uuid, "")

      refute_receive {:projects, :assignment_created, _}, 50
      refute_receive {:projects, :task_created, _}, 50
    end
  end

  describe "one-off tasks and the library" do
    test "are excluded from the library list and count by default" do
      p = project!()
      lib = fixture_task(%{"title" => "Reusable #{System.unique_integer([:positive])}"})
      {:ok, %{task: adhoc}} = Projects.quick_add_assignment(p.uuid, "One-off")

      default_uuids = Projects.list_tasks() |> Enum.map(& &1.uuid)
      assert lib.uuid in default_uuids
      refute adhoc.uuid in default_uuids
      assert Projects.count_tasks() == length(default_uuids)

      only = Projects.list_tasks(ad_hoc: :only) |> Enum.map(& &1.uuid)
      assert only == [adhoc.uuid]
      assert Projects.count_tasks(ad_hoc: :only) == 1

      all = Projects.list_tasks(ad_hoc: :all) |> Enum.map(& &1.uuid)
      assert lib.uuid in all and adhoc.uuid in all
      assert Projects.count_tasks(ad_hoc: :all) == length(all)

      # Grouped library view rides on list_tasks/0 — same exclusion.
      groups = Projects.list_task_groups()
      group_uuids = Enum.map(groups.standalone, & &1.uuid)
      refute adhoc.uuid in group_uuids
    end

    test "the assignment behind a one-off task reads like any other" do
      p = project!()
      {:ok, %{assignment: a}} = Projects.quick_add_assignment(p.uuid, "Visible in the plan")
      [loaded] = Projects.list_assignments(p.uuid)
      assert loaded.uuid == a.uuid
      assert Assignment.label(loaded) == "Visible in the plan"
    end

    test "a one-off task can be promoted to the library" do
      p = project!()
      {:ok, %{task: adhoc}} = Projects.quick_add_assignment(p.uuid, "Promote me")
      {:ok, promoted} = Projects.update_task(adhoc, %{"ad_hoc" => false})
      assert promoted.ad_hoc == false
      assert promoted.uuid in Enum.map(Projects.list_tasks(), & &1.uuid)
    end
  end

  describe "create_task_with_assignment/3" do
    test "carries assignment attrs and rolls the task back when the assignment fails" do
      p = project!()
      before_tasks = Projects.count_tasks(ad_hoc: :all)

      assert {:error, :assignment, %Ecto.Changeset{}} =
               Projects.create_task_with_assignment(
                 p.uuid,
                 %{"title" => "Rolled back"},
                 %{"status" => "not-a-status"}
               )

      assert Projects.count_tasks(ad_hoc: :all) == before_tasks

      assert {:ok, %{task: task, assignment: a}} =
               Projects.create_task_with_assignment(
                 p.uuid,
                 %{
                   title: "Library-grade",
                   estimated_duration: 2,
                   estimated_duration_unit: "days"
                 },
                 %{description: "with details", priority: "high"}
               )

      assert task.ad_hoc == false
      assert a.description == "with details" and a.priority == "high"
    end
  end
end
