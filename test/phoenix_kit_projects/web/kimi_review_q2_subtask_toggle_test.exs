defmodule PhoenixKitProjects.Web.KimiReviewQ2SubtaskToggleTest do
  @moduledoc """
  Review probe (night 2026-11-25, Q2): `AssignmentFormLive`'s
  `subtask_toggle` event, second clause, has no `live_action` guard and
  writes immediately. In `:new` mode `socket.assigns.assignment` is a
  fresh `%Assignment{uuid: nil}`, so the clause's
  `%Assignment{parent_uuid: p} when p == parent.uuid` matches ANY
  top-level task of ANY project, and the only permission asked is
  `:update_status` on the FORM's project — never on the target task's
  project. A member of project A who may not even view project B can
  complete/reopen B's top-level tasks.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{Members, Projects}

  setup %{conn: conn} do
    PhoenixKitProjects.Extensions.Registry.refresh()

    {:ok, user} =
      Auth.register_user(%{
        "email" => "kimi-q2-#{System.unique_integer([:positive])}@example.com",
        "password" => "ActorPass123!"
      })

    # A plain module-reacher: holds "projects", no admin_all.
    scope = fake_scope(user_uuid: user.uuid, permissions: ["projects"])

    project_a = fixture_project(%{"start_mode" => "immediate"})
    {:ok, _} = Members.add_member(project_a, user.uuid, role: "member")

    # Project B is private; the user is NOT a member and holds no seat.
    project_b = fixture_project(%{"start_mode" => "immediate"})
    task_b = fixture_task()

    {:ok, foreign} =
      Projects.create_assignment(%{
        "project_uuid" => project_b.uuid,
        "task_uuid" => task_b.uuid,
        "status" => "todo"
      })

    # Sanity: the user really has no rights on B.
    refute PhoenixKitProjects.Authz.can?(scope, project_b, :view)
    refute PhoenixKitProjects.Authz.can?(scope, project_b, :update_status)

    conn = put_test_scope(conn, scope)

    {:ok, conn: conn, project_a: project_a, project_b: project_b, foreign: foreign}
  end

  test "subtask_toggle in :new mode cannot complete another project's task", ctx do
    {:ok, lv, _html} =
      live(ctx.conn, "/en/admin/projects/#{ctx.project_a.uuid}/assignments/new")

    # Crafted event: the uuid of a top-level task in a project the viewer
    # has no seat on. The :new form renders no such row; the handler must
    # refuse it anyway.
    render_click(lv, "subtask_toggle", %{"uuid" => ctx.foreign.uuid})

    assert Projects.get_assignment(ctx.foreign.uuid).status == "todo",
           "subtask_toggle completed a task in a project the viewer has no rights on"
  end

  test "subtask_toggle in :new mode cannot reopen another project's done task", ctx do
    {:ok, done} = Projects.complete_assignment(ctx.foreign, nil)
    assert done.status == "done"

    {:ok, lv, _html} =
      live(ctx.conn, "/en/admin/projects/#{ctx.project_a.uuid}/assignments/new")

    render_click(lv, "subtask_toggle", %{"uuid" => ctx.foreign.uuid})

    assert Projects.get_assignment(ctx.foreign.uuid).status == "done",
           "subtask_toggle reopened a task in a project the viewer has no rights on"
  end
end
