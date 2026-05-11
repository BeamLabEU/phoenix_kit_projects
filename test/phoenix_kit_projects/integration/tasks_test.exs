defmodule PhoenixKitProjects.Integration.TasksTest do
  @moduledoc """
  Smoke test for the integration test infrastructure: exercises the
  Task-library branch of the `Projects` context against a real PostgreSQL
  database (no cross-module deps on staff tables).
  """

  use PhoenixKitProjects.DataCase, async: true

  alias PhoenixKitProjects.Projects

  describe "task library CRUD" do
    test "create → get → update → delete round-trip" do
      assert {:ok, task} =
               Projects.create_task(%{
                 "title" => "Smoke test task",
                 "description" => "From integration tests",
                 "estimated_duration" => 2,
                 "estimated_duration_unit" => "hours"
               })

      assert task.title == "Smoke test task"
      assert task.estimated_duration_unit == "hours"

      assert reloaded = Projects.get_task(task.uuid)
      assert reloaded.uuid == task.uuid

      assert {:ok, updated} = Projects.update_task(reloaded, %{"estimated_duration" => 4})
      assert updated.estimated_duration == 4

      assert {:ok, _} = Projects.delete_task(updated)
      assert Projects.get_task(updated.uuid) == nil
    end

    test "title is required" do
      assert {:error, cs} = Projects.create_task(%{"title" => ""})
      assert %{title: [_ | _]} = errors_on(cs)
    end

    test "duplicate titles are allowed (V112 dropped the case-insensitive unique index)" do
      shared = "Shared #{System.unique_integer([:positive])}"
      {:ok, a} = Projects.create_task(%{"title" => shared})
      {:ok, b} = Projects.create_task(%{"title" => String.downcase(shared)})

      assert a.uuid != b.uuid
      assert String.downcase(a.title) == String.downcase(b.title)
    end
  end

  describe "template task dependencies" do
    test "adds and removes dependency between two tasks" do
      {:ok, a} = Projects.create_task(%{"title" => "Task A"})
      {:ok, b} = Projects.create_task(%{"title" => "Task B"})

      assert {:ok, _} = Projects.add_task_dependency(b.uuid, a.uuid)
      assert [dep] = Projects.list_task_dependencies(b.uuid)
      assert dep.depends_on_task_uuid == a.uuid

      assert {:ok, _} = Projects.remove_task_dependency(b.uuid, a.uuid)
      assert Projects.list_task_dependencies(b.uuid) == []
    end
  end
end
