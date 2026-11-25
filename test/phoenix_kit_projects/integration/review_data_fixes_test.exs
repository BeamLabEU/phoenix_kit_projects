defmodule PhoenixKitProjects.Integration.ReviewDataFixesTest do
  @moduledoc """
  The data-layer findings of the 2026-11-24 review panel (codex, vibe,
  kimi), each pinned by the case that broke it. Races that need two real
  connections at once (the dependency lock, the depth re-check, the review
  decision, the rollup) cannot be driven through the sandbox; what can be
  driven sequentially is driven here.
  """

  use PhoenixKitProjects.DataCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{Members, Outline, Projects, TaskConversion}
  alias PhoenixKitProjects.Schemas.Task

  defp user_fixture do
    {:ok, user} =
      Auth.register_user(%{
        email: "review-#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    user
  end

  describe "deleting a task from the library" do
    test "refuses when a sub-project sits under a row using it, and leaves the link" do
      p = fixture_project(%{"start_mode" => "immediate"})
      {:ok, %{assignment: root, task: task}} = Projects.quick_add_assignment(p.uuid, "Root")

      {:ok, %{child_project: child, assignment: link}} =
        Projects.create_subproject(p.uuid, %{"name" => "Review child", "key" => unique_key()})

      {:ok, _} = Outline.move(link, root.uuid)

      assert {:error, :subproject_below} = Projects.delete_task(task)
      assert Projects.get_project(child.uuid)
      assert Projects.subproject_link(child.uuid)
      assert Projects.get_assignment(root.uuid)
    end

    test "takes every row using it with its branch, one-off subtasks' tasks too" do
      p = fixture_project(%{"start_mode" => "immediate"})
      task = fixture_task()

      {:ok, row} =
        Projects.create_assignment(%{
          "project_uuid" => p.uuid,
          "task_uuid" => task.uuid,
          "status" => "todo"
        })

      {:ok, %{assignment: sub, task: sub_task}} = Projects.quick_add_assignment(p.uuid, "Sub")
      {:ok, _} = Outline.move(sub, row.uuid)

      assert {:ok, _} = Projects.delete_task(task)
      refute Projects.get_task(task.uuid)
      refute Projects.get_assignment(row.uuid)
      refute Projects.get_assignment(sub.uuid)
      refute Repo.get(Task, sub_task.uuid), "the subtask's one-off task stayed behind"
    end
  end

  test "reopening a stale in-progress snapshot clears the completion stamps" do
    p = fixture_project()
    {:ok, %{assignment: row}} = Projects.quick_add_assignment(p.uuid, "Review")
    {:ok, started} = Projects.update_assignment_status(row, %{status: "in_progress"})
    {:ok, _} = Projects.complete_assignment(started, nil)

    # `started` is the struct read before someone else completed the task.
    {:ok, _} = Projects.reopen_assignment(started)

    final = Projects.get_assignment(started.uuid)
    assert final.status == "todo"
    assert is_nil(final.completed_at)
  end

  test "converting a task drops the dependencies that would cross projects" do
    p = fixture_project(%{"start_mode" => "immediate"})
    {:ok, %{assignment: outside}} = Projects.quick_add_assignment(p.uuid, "Outside")
    {:ok, %{assignment: root}} = Projects.quick_add_assignment(p.uuid, "Root")
    {:ok, %{assignment: child}} = Projects.quick_add_assignment(p.uuid, "Child")
    {:ok, %{assignment: sibling}} = Projects.quick_add_assignment(p.uuid, "Sibling")
    {:ok, _} = Outline.move(child, root.uuid)
    {:ok, _} = Outline.move(sibling, root.uuid)
    {:ok, _} = Projects.add_dependency(outside.uuid, child.uuid)
    {:ok, _} = Projects.add_dependency(sibling.uuid, child.uuid)

    {:ok, %{project: subproject}} = TaskConversion.to_subproject(root)

    assert Projects.get_assignment(child.uuid).project_uuid == subproject.uuid
    assert Projects.list_dependencies(outside.uuid) == []
    # An edge among the rows that moved together moves with them.
    assert [_] = Projects.list_dependencies(sibling.uuid)
  end

  test "deleting a project deletes its one-off tasks" do
    {:ok, project} = Projects.create_project(%{"name" => "Review scratch", "key" => unique_key()})
    {:ok, %{assignment: assignment}} = Projects.quick_add_assignment(project.uuid, "One-off")

    assert {:ok, _} = Projects.delete_project(project)
    assert Projects.get_task(assignment.task_uuid) == nil
  end

  test "a delete that expected other rows under the task deletes nothing" do
    p = fixture_project(%{"start_mode" => "immediate"})
    {:ok, %{assignment: root}} = Projects.quick_add_assignment(p.uuid, "Root")
    {:ok, %{assignment: sub}} = Projects.quick_add_assignment(p.uuid, "Moved under meanwhile")
    {:ok, _} = Outline.move(sub, root.uuid)

    # The API checked the task when nothing was under it.
    assert {:error, :branch_changed} =
             Projects.delete_assignment(Projects.get_assignment(root.uuid), expect_below: [])

    assert Projects.get_assignment(root.uuid)
    assert Projects.get_assignment(sub.uuid)

    assert {:ok, _} =
             Projects.delete_assignment(Projects.get_assignment(root.uuid),
               expect_below: [sub.uuid]
             )

    refute Projects.get_assignment(sub.uuid)
  end

  test "a submission decided once stays decided" do
    p = fixture_project()
    task = fixture_task()

    {:ok, pending} =
      Projects.create_assignment(
        %{"project_uuid" => p.uuid, "task_uuid" => task.uuid, "status" => "todo"},
        review: :pending
      )

    assert {:ok, %{review_status: "accepted"}} =
             Projects.review_assignment(pending.uuid, :accepted)

    assert {:ok, %{review_status: "accepted"}} =
             Projects.review_assignment(pending.uuid, :rejected)

    assert Projects.get_assignment(pending.uuid).review_status == "accepted"
  end

  test "a library reorder leaves one-off tasks where they are" do
    p = fixture_project()
    {:ok, %{task: one_off}} = Projects.quick_add_assignment(p.uuid, "One-off")
    before = Repo.get(Task, one_off.uuid).position
    library = fixture_task()

    assert :ok = Projects.reorder_tasks([one_off.uuid, library.uuid])
    assert Repo.get(Task, one_off.uuid).position == before
    assert Repo.get(Task, library.uuid).position == 2

    # The one-off lens names its half (administrators only, on the page).
    assert :ok = Projects.reorder_tasks([one_off.uuid], ad_hoc: :only)
    assert Repo.get(Task, one_off.uuid).position == 1
  end

  test "whoever creates a sub-project gets its owner seat" do
    p = fixture_project(%{"start_mode" => "immediate"})
    user = user_fixture()

    {:ok, %{child_project: child}} =
      Projects.create_subproject(
        p.uuid,
        %{"name" => "Mine", "key" => unique_key()},
        actor_uuid: user.uuid
      )

    assert Members.role_of(child, user.uuid) == :owner

    # Without an actor nothing changes.
    {:ok, %{child_project: other}} =
      Projects.create_subproject(p.uuid, %{"name" => "Nobody's", "key" => unique_key()})

    assert Members.role_of(other, user.uuid) == nil
  end

  test "a dependency still refuses a cycle, under the project lock" do
    p = fixture_project()
    {:ok, %{assignment: a}} = Projects.quick_add_assignment(p.uuid, "A")
    {:ok, %{assignment: b}} = Projects.quick_add_assignment(p.uuid, "B")

    assert {:ok, _} = Projects.add_dependency(a.uuid, b.uuid)
    assert {:error, cs} = Projects.add_dependency(b.uuid, a.uuid)
    assert "would create a dependency cycle" in errors_on(cs).depends_on_uuid
  end

  test "a reopen from a stale todo copy reopens the done row and clears its stamps" do
    project = fixture_project()

    {:ok, a} =
      Projects.create_assignment(%{
        "project_uuid" => project.uuid,
        "task_uuid" => fixture_task().uuid,
        "status" => "todo"
      })

    a = Projects.get_assignment(a.uuid)

    {:ok, _} =
      Projects.update_assignment_status(a, %{
        "status" => "done",
        "completed_at" => DateTime.utc_now()
      })

    # The caller still holds the `todo` copy: no status change on it, yet it
    # names the reopen. The row was done; it must end todo with no stamps,
    # never done without a completion time.
    {:ok, _} =
      Projects.update_assignment_status(a, %{
        "status" => "todo",
        "completed_at" => nil,
        "completed_by_uuid" => nil
      })

    fresh = Projects.get_assignment(a.uuid)
    assert fresh.status == "todo"
    assert is_nil(fresh.completed_at)
  end
end
