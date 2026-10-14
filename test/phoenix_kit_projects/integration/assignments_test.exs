defmodule PhoenixKitProjects.Integration.AssignmentsTest do
  @moduledoc """
  Integration tests for the assignment DB path. Covers:

    - mass-assignment guard on the form-facing changeset
    - server-trusted status transitions via `update_assignment_status/2`
    - PubSub broadcast fires after a successful update
    - `complete_assignment/2` / `reopen_assignment/1` sugar helpers
  """

  # Not async: these tests create projects whose keys come from their
  # names, and two sandboxed transactions inserting the same key wait on
  # each other at the key registry (chain V22) — a deadlock once each
  # creates a second one.
  use PhoenixKitProjects.DataCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.Projects
  alias PhoenixKitProjects.PubSub, as: ProjectsPubSub

  defp fixture!(context \\ %{}) do
    {:ok, project} =
      Projects.create_project(%{
        "name" => "Project #{System.unique_integer([:positive])}",
        "status" => "active",
        "start_mode" => "immediate"
      })

    {:ok, task} =
      Projects.create_task(%{
        "title" => "Task #{System.unique_integer([:positive])}",
        "estimated_duration" => 2,
        "estimated_duration_unit" => "hours"
      })

    {:ok, assignment} =
      Projects.create_assignment(%{
        "project_uuid" => project.uuid,
        "task_uuid" => task.uuid,
        "status" => "todo"
      })

    Map.merge(context, %{project: project, task: task, assignment: assignment})
  end

  # `Assignment.completed_by_uuid` FKs to `phoenix_kit_users(uuid)`,
  # so completion paths need a real user — a bare `UUIDv7.generate()`
  # raises `Ecto.ConstraintError` on the FK. Build a real user via the
  # public registration path and return its UUID.
  defp real_user_uuid! do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "actor-#{System.unique_integer([:positive])}@example.com",
        "password" => "ActorPass123!"
      })

    user.uuid
  end

  describe "mass-assignment guard" do
    test "create_assignment silently drops completed_by_uuid/completed_at from user input" do
      %{project: p, task: t} = fixture!()
      attacker_uuid = UUIDv7.generate()
      fake_time = DateTime.utc_now()

      {:ok, a} =
        Projects.create_assignment(%{
          "project_uuid" => p.uuid,
          "task_uuid" => t.uuid,
          "status" => "todo",
          "completed_by_uuid" => attacker_uuid,
          "completed_at" => fake_time
        })

      assert a.completed_by_uuid == nil
      assert a.completed_at == nil
    end

    test "update_assignment_form silently drops completed_by_uuid/completed_at from user input" do
      %{assignment: a} = fixture!()
      attacker_uuid = UUIDv7.generate()

      {:ok, updated} =
        Projects.update_assignment_form(a, %{
          "description" => "edited",
          "completed_by_uuid" => attacker_uuid,
          "completed_at" => DateTime.utc_now()
        })

      assert updated.description == "edited"
      assert updated.completed_by_uuid == nil
      assert updated.completed_at == nil
    end

    test "update_assignment_status DOES apply completed_by_uuid/completed_at" do
      %{assignment: a} = fixture!()
      actor = real_user_uuid!()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, updated} =
        Projects.update_assignment_status(a, %{
          status: "done",
          completed_by_uuid: actor,
          completed_at: now
        })

      assert updated.status == "done"
      assert updated.completed_by_uuid == actor
      assert updated.completed_at == now
    end
  end

  describe "complete_assignment/2 + reopen_assignment/1" do
    test "complete sets status and completion fields" do
      %{assignment: a} = fixture!()
      actor = real_user_uuid!()

      {:ok, done} = Projects.complete_assignment(a, actor)

      assert done.status == "done"
      assert done.completed_by_uuid == actor
      assert done.completed_at != nil
    end

    test "reopen clears completion fields" do
      %{assignment: a} = fixture!()
      {:ok, done} = Projects.complete_assignment(a, real_user_uuid!())

      {:ok, reopened} = Projects.reopen_assignment(done)

      assert reopened.status == "todo"
      assert reopened.completed_by_uuid == nil
      assert reopened.completed_at == nil
    end
  end

  describe "PubSub broadcast" do
    test "update fires :assignment_updated on topic_project" do
      %{project: p, assignment: a} = fixture!()
      ProjectsPubSub.subscribe(ProjectsPubSub.topic_project(p.uuid))

      {:ok, _} = Projects.update_assignment_form(a, %{"description" => "broadcast check"})

      assert_receive {:projects, :assignment_updated, %{uuid: uuid, project_uuid: pid}}, 500
      assert uuid == a.uuid
      assert pid == p.uuid
    end

    test "complete_assignment fires the same broadcast (sugar helper parity)" do
      %{project: p, assignment: a} = fixture!()
      ProjectsPubSub.subscribe(ProjectsPubSub.topic_project(p.uuid))

      {:ok, _} = Projects.complete_assignment(a, real_user_uuid!())

      assert_receive {:projects, :assignment_updated, %{uuid: uuid}}, 500
      assert uuid == a.uuid
    end
  end

  describe "progress_pct validation" do
    test "rejects values outside 0..100" do
      %{assignment: a} = fixture!()

      assert {:error, cs} = Projects.update_assignment_form(a, %{"progress_pct" => 150})
      assert %{progress_pct: [_ | _]} = errors_on(cs)

      assert {:error, cs2} = Projects.update_assignment_form(a, %{"progress_pct" => -5})
      assert %{progress_pct: [_ | _]} = errors_on(cs2)
    end
  end
end
