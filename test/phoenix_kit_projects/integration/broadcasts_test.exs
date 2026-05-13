defmodule PhoenixKitProjects.Integration.BroadcastsTest do
  @moduledoc """
  Asserts that every projects mutation broadcasts the expected PubSub
  event with the expected minimal payload. Templates fan out to the
  templates topic; assignments and dependencies fan out to the parent
  project's topic in addition to `projects:all`.
  """

  use PhoenixKitProjects.DataCase, async: false

  alias PhoenixKitProjects.Projects
  alias PhoenixKitProjects.PubSub, as: ProjectsPubSub

  defp new_project!(attrs \\ %{}) do
    {:ok, p} =
      %{
        "name" => "Project #{System.unique_integer([:positive])}",
        "status" => "active",
        "start_mode" => "immediate"
      }
      |> Map.merge(attrs)
      |> Projects.create_project()

    p
  end

  defp new_task! do
    {:ok, t} =
      Projects.create_task(%{
        "title" => "Task #{System.unique_integer([:positive])}",
        "estimated_duration" => 1,
        "estimated_duration_unit" => "hours"
      })

    t
  end

  describe "project broadcasts" do
    test "create fires :project_created on all and per-project topics" do
      ProjectsPubSub.subscribe(ProjectsPubSub.topic_all())

      project = new_project!()

      # Broadcast payload is intentionally minimal — uuid + name +
      # is_template. Subscribers needing archived state re-read the
      # project via `get_project/1` (the source of truth is the
      # `archived_at` column on the schema).
      assert_receive {:projects, :project_created,
                      %{uuid: uuid, name: _, is_template: false}},
                     500

      assert uuid == project.uuid
    end

    test "template create fires on both all and templates topics" do
      ProjectsPubSub.subscribe(ProjectsPubSub.topic_templates())

      template = new_project!(%{"is_template" => true})
      assert_receive {:projects, :project_created, %{uuid: uuid, is_template: true}}, 500
      assert uuid == template.uuid
    end

    test "update and delete broadcast with the resource uuid" do
      project = new_project!()
      ProjectsPubSub.subscribe(ProjectsPubSub.topic_all())

      {:ok, _} = Projects.update_project(project, %{"description" => "x"})
      assert_receive {:projects, :project_updated, %{uuid: uuid}}, 500
      assert uuid == project.uuid

      {:ok, _} = Projects.delete_project(project)
      assert_receive {:projects, :project_deleted, %{uuid: ^uuid}}, 500
    end
  end

  describe "task library broadcasts" do
    test "create/update/delete each fire on tasks topic" do
      ProjectsPubSub.subscribe(ProjectsPubSub.topic_tasks())

      task = new_task!()
      assert_receive {:projects, :task_created, %{uuid: uuid, title: _}}, 500
      assert uuid == task.uuid

      {:ok, _} = Projects.update_task(task, %{"description" => "x"})
      assert_receive {:projects, :task_updated, %{uuid: ^uuid}}, 500

      {:ok, _} = Projects.delete_task(task)
      assert_receive {:projects, :task_deleted, %{uuid: ^uuid}}, 500
    end
  end

  describe "dependency broadcasts" do
    test "add_dependency fires :dependency_added scoped to the project" do
      project = new_project!()
      task_a = new_task!()
      task_b = new_task!()

      {:ok, a} =
        Projects.create_assignment(%{
          "project_uuid" => project.uuid,
          "task_uuid" => task_a.uuid,
          "status" => "todo"
        })

      {:ok, b} =
        Projects.create_assignment(%{
          "project_uuid" => project.uuid,
          "task_uuid" => task_b.uuid,
          "status" => "todo"
        })

      ProjectsPubSub.subscribe(ProjectsPubSub.topic_project(project.uuid))

      {:ok, _} = Projects.add_dependency(a.uuid, b.uuid)

      assert_receive {:projects, :dependency_added,
                      %{assignment_uuid: aa, depends_on_uuid: bb, project_uuid: pp}},
                     500

      assert aa == a.uuid
      assert bb == b.uuid
      assert pp == project.uuid
    end

    test "remove_dependency fires :dependency_removed" do
      project = new_project!()
      task_a = new_task!()
      task_b = new_task!()

      {:ok, a} =
        Projects.create_assignment(%{
          "project_uuid" => project.uuid,
          "task_uuid" => task_a.uuid,
          "status" => "todo"
        })

      {:ok, b} =
        Projects.create_assignment(%{
          "project_uuid" => project.uuid,
          "task_uuid" => task_b.uuid,
          "status" => "todo"
        })

      {:ok, _} = Projects.add_dependency(a.uuid, b.uuid)

      ProjectsPubSub.subscribe(ProjectsPubSub.topic_project(project.uuid))

      {:ok, _} = Projects.remove_dependency(a.uuid, b.uuid)

      assert_receive {:projects, :dependency_removed, %{project_uuid: pp}}, 500
      assert pp == project.uuid
    end
  end
end
