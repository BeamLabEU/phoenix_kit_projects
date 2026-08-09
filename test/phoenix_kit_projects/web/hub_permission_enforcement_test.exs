defmodule PhoenixKitProjects.Web.HubPermissionEnforcementTest do
  @moduledoc """
  The project's "who can do what" floors have to bind on the hub, not just
  in the form that sets them.

  Before this, every mutating event on the show page went through a gate
  that asked only "is this feature enabled for the project" and never "may
  this person do it" — so the permission matrix was a decoration, and
  archiving (owner-only and deliberately not overridable) had no check at
  all. These tests pin the enforcement, including the case that makes a
  blanket deny wrong: the person a task is assigned to may still move it.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{Authz, Members, Projects}
  alias PhoenixKitStaff.Staff

  setup %{conn: conn} do
    PhoenixKitProjects.Extensions.Registry.refresh()

    # Registered for real: completing a task stamps completed_by_uuid,
    # which FKs to the users table.
    {:ok, owner_user} =
      Auth.register_user(%{
        "email" => "owner-#{System.unique_integer([:positive])}@example.com",
        "password" => "ActorPass123!"
      })

    owner = fake_scope(user_uuid: owner_user.uuid)
    project = fixture_project(%{"start_mode" => "immediate"})
    task = fixture_task()

    {:ok, assignment} =
      Projects.create_assignment(%{
        "project_uuid" => project.uuid,
        "task_uuid" => task.uuid,
        "status" => "todo"
      })

    # A plain module-reacher: holds "projects" but NOT projects.admin_all,
    # so nothing here passes on the site-admin override. Registered for
    # real because project_members carries a user FK.
    {:ok, viewer_user} =
      Auth.register_user(%{
        "email" => "viewer-#{System.unique_integer([:positive])}@example.com",
        "password" => "ActorPass123!"
      })

    viewer = fake_scope(user_uuid: viewer_user.uuid, permissions: ["projects"])
    {:ok, _} = Members.add_member(project, viewer_user.uuid, role: "viewer")

    {:ok,
     conn: conn,
     owner: owner,
     viewer: viewer,
     project: project,
     assignment: assignment,
     task: task}
  end

  defp show_path(project), do: "/en/admin/projects/list/#{project.uuid}"

  describe "work floors bind on the hub" do
    test "a viewer cannot complete a task when the floor says managers", ctx do
      {:ok, project} = Authz.set_overrides(ctx.project, %{"update_status" => "managers"})

      {:ok, lv, _} =
        ctx.conn |> put_test_scope(ctx.viewer) |> live(show_path(project))

      render_click(lv, "complete", %{"uuid" => ctx.assignment.uuid})

      assert Projects.get_assignment(ctx.assignment.uuid).status == "todo",
             "a viewer completed a task the floor reserved for managers"
    end

    test "the same event succeeds for the owner — the deny isn't blanket", ctx do
      {:ok, project} = Authz.set_overrides(ctx.project, %{"update_status" => "managers"})

      {:ok, lv, _} =
        ctx.conn |> put_test_scope(ctx.owner) |> live(show_path(project))

      render_click(lv, "complete", %{"uuid" => ctx.assignment.uuid})

      assert Projects.get_assignment(ctx.assignment.uuid).status == "done"
    end

    test "a viewer cannot archive — owner-only and never overridable", ctx do
      {:ok, lv, _} =
        ctx.conn |> put_test_scope(ctx.viewer) |> live(show_path(ctx.project))

      render_click(lv, "archive_project", %{})

      refute Projects.get_project(ctx.project.uuid).archived_at,
             "a viewer archived the project"
    end

    test "a viewer cannot remove a task when the floor says managers", ctx do
      {:ok, project} = Authz.set_overrides(ctx.project, %{"delete_tasks" => "managers"})

      {:ok, lv, _} =
        ctx.conn |> put_test_scope(ctx.viewer) |> live(show_path(project))

      render_click(lv, "remove_assignment", %{"uuid" => ctx.assignment.uuid})

      assert Projects.get_assignment(ctx.assignment.uuid),
             "a viewer deleted a task the floor reserved for managers"
    end
  end

  describe "the assignee exception survives the gate" do
    test "the assignee moves their own task despite a managers-only floor", ctx do
      # The interceptor resolves the task and passes it to can?/5 — without
      # that record the relationship grant can't fire and this person, who
      # the work was handed to, would be locked out of their own task.
      n = System.unique_integer([:positive])

      # A REAL auth user: create_person requires the link, and the
      # relationship grant resolves through person.user_uuid.
      {:ok, user} =
        Auth.register_user(%{
          "email" => "assignee-#{n}@example.com",
          "password" => "ActorPass123!"
        })

      {:ok, person} =
        Staff.create_person(%{
          "user_uuid" => user.uuid,
          "name" => "Anna Assignee",
          "employment_type" => "full_time"
        })

      {:ok, assignment} =
        Projects.create_assignment(%{
          "project_uuid" => ctx.project.uuid,
          "task_uuid" => fixture_task().uuid,
          "status" => "todo",
          "assigned_person_uuid" => person.uuid
        })

      {:ok, project} = Authz.set_overrides(ctx.project, %{"update_status" => "managers"})

      # No project role at all — the ONLY thing that lets them act is
      # being the assignee.
      assignee_scope = fake_scope(user_uuid: user.uuid, permissions: ["projects"])
      {:ok, _} = Members.add_member(project, user.uuid, role: "viewer")

      {:ok, lv, _} =
        ctx.conn |> put_test_scope(assignee_scope) |> live(show_path(project))

      render_click(lv, "complete", %{"uuid" => assignment.uuid})

      assert Projects.get_assignment(assignment.uuid).status == "done",
             "the assignee was blocked from their own task"
    end
  end
end
