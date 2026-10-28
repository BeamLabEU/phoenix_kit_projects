defmodule PhoenixKitProjects.Web.OptionalReasonAndCueTest do
  @moduledoc """
  Reopening asks why, but the reason is optional: a reopen without one is
  still a reopen. And the task form's cued sections (History, Discussion,
  AI notes) can be opened without taking the form down.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.Projects

  setup %{conn: conn} do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "reason-#{System.unique_integer([:positive])}@example.com",
        "password" => "ReasonPass123!"
      })

    conn = put_test_scope(conn, fake_scope(user_uuid: user.uuid))
    project = fixture_project(%{"start_mode" => "immediate"})
    task = fixture_task(%{"title" => "Take kitchen measurements"})

    {:ok, a} =
      Projects.create_assignment(%{
        "project_uuid" => project.uuid,
        "task_uuid" => task.uuid,
        "status" => "done"
      })

    {:ok, conn: conn, project: project, a: a}
  end

  test "the reopen dialog does not require a reason, and reopens without one", ctx do
    {:ok, view, _html} = live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}")

    html = render_click(view, "ask_reopen", %{"uuid" => ctx.a.uuid})
    [textarea] = Regex.run(~r/<textarea[^>]*name="reason"[^>]*>/, html)
    refute textarea =~ "required"

    render_submit(view, "reopen", %{"uuid" => ctx.a.uuid, "reason" => ""})
    assert Projects.get_assignment(ctx.a.uuid).status == "todo"
  end

  test "opening a cued section of the task form does not crash it", ctx do
    {:ok, view, _html} =
      live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}/assignments/#{ctx.a.uuid}/edit")

    render_click(view, "pk_cue_seen", %{"region" => "assignment-history-#{ctx.a.uuid}"})
    assert render(view) =~ "Take kitchen measurements"
  end
end
