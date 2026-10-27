defmodule PhoenixKitProjects.Web.ProjectShowNextUpTest do
  @moduledoc """
  A new task is `waiting` (idle, nobody asked yet) until it is released —
  `todo`, shown as "can be started", which tells its people. Completing a
  task that others wait on asks first ("next up"): each task nothing would
  hold up is released on confirm unless it is kept idle, and a comment can
  be left for whoever does it. Nothing is written before the confirm.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.Projects

  setup %{conn: conn} do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "next-up-#{System.unique_integer([:positive])}@example.com",
        "password" => "ActorPass123!"
      })

    conn = put_test_scope(conn, fake_scope(user_uuid: user.uuid))

    project = fixture_project(%{"start_mode" => "immediate"})
    {:ok, _} = Projects.start_project(project)
    project = Projects.get_project!(project.uuid)

    consult = assignment!(project, "Consultation")
    measure = assignment!(project, "Measurement")
    render = assignment!(project, "3D render")
    {:ok, _} = Projects.add_dependency(measure.uuid, consult.uuid)
    {:ok, _} = Projects.add_dependency(render.uuid, consult.uuid)

    {:ok,
     conn: conn,
     project: project,
     consult: consult,
     measure: measure,
     render: render,
     actor_uuid: user.uuid}
  end

  # No status given: a new task's default.
  defp assignment!(project, title) do
    task = fixture_task(%{"title" => title})

    {:ok, a} =
      Projects.create_assignment(%{"project_uuid" => project.uuid, "task_uuid" => task.uuid})

    a
  end

  defp status(a), do: Projects.get_assignment(a.uuid).status
  defp next_up(project), do: "#project-next-up-#{project.uuid}"
  defp show(ctx), do: live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}")

  # The words a person reads: the text between tags (ids and attribute
  # values like `board-column-todo` are code, not copy).
  defp visible(html), do: Regex.replace(~r/<[^>]*>/, html, " ")

  test "a new task waits, and no screen says to do", ctx do
    assert status(ctx.consult) == "waiting"

    {:ok, view, html} = show(ctx)
    assert html =~ "waiting"
    refute visible(html) =~ ~r/to.?do/i

    board = render_click(view, "switch_tab", %{"tab" => "board"})
    assert board =~ "Waiting"
    assert board =~ "Can be started"
    refute visible(board) =~ ~r/to.?do/i
  end

  test "Can be started releases a waiting task; idle puts it back", ctx do
    {:ok, view, _html} = show(ctx)

    render_click(view, "make_ready", %{"uuid" => ctx.consult.uuid})
    assert status(ctx.consult) == "todo"
    assert_activity_logged("projects.assignment_made_ready", resource_uuid: ctx.consult.uuid)

    render_click(view, "make_idle", %{"uuid" => ctx.consult.uuid})
    assert status(ctx.consult) == "waiting"
  end

  test "completing a task that hands work on asks first and writes nothing", ctx do
    {:ok, view, _html} = show(ctx)

    render_click(view, "complete", %{"uuid" => ctx.consult.uuid})

    assert has_element?(view, next_up(ctx.project), "Measurement")
    assert has_element?(view, next_up(ctx.project), "3D render")
    assert has_element?(view, next_up(ctx.project), "Keep idle")
    assert status(ctx.consult) == "waiting"

    render_click(view, "next_up_close", %{})
    refute has_element?(view, next_up(ctx.project))
    assert status(ctx.consult) == "waiting"
    assert status(ctx.measure) == "waiting"
  end

  test "confirm completes the task and releases what it held up", ctx do
    {:ok, view, _html} = show(ctx)

    render_click(view, "complete", %{"uuid" => ctx.consult.uuid})
    render_submit(view, "next_up_confirm", %{"uuid" => ctx.consult.uuid})

    refute has_element?(view, next_up(ctx.project))
    assert status(ctx.consult) == "done"
    assert status(ctx.measure) == "todo"
    assert status(ctx.render) == "todo"

    assert_activity_logged("projects.assignment_completed",
      actor_uuid: ctx.actor_uuid,
      resource_uuid: ctx.consult.uuid
    )
  end

  test "Keep idle leaves a task waiting; pressed again it is released", ctx do
    {:ok, view, _html} = show(ctx)

    render_click(view, "complete", %{"uuid" => ctx.consult.uuid})
    render_click(view, "next_up_toggle_idle", %{"uuid" => ctx.render.uuid})
    render_click(view, "next_up_toggle_idle", %{"uuid" => ctx.measure.uuid})
    render_click(view, "next_up_toggle_idle", %{"uuid" => ctx.measure.uuid})

    render_submit(view, "next_up_confirm", %{"uuid" => ctx.consult.uuid})

    assert status(ctx.consult) == "done"
    assert status(ctx.measure) == "todo"
    assert status(ctx.render) == "waiting"
  end

  test "a released task kept idle goes back to waiting", ctx do
    {:ok, _} = Projects.update_assignment_status(ctx.render, %{status: "todo"})
    {:ok, view, _html} = show(ctx)

    render_click(view, "complete", %{"uuid" => ctx.consult.uuid})
    render_click(view, "next_up_toggle_idle", %{"uuid" => ctx.render.uuid})
    render_submit(view, "next_up_confirm", %{"uuid" => ctx.consult.uuid})

    assert status(ctx.render) == "waiting"
  end

  test "a completion that holds nothing up completes at once", ctx do
    {:ok, view, _html} = show(ctx)

    render_click(view, "complete", %{"uuid" => ctx.render.uuid})

    refute has_element?(view, next_up(ctx.project))
    assert status(ctx.render) == "done"
  end

  test "only the offered tasks can be toggled, and only the asked task confirmed", ctx do
    {:ok, view, _html} = show(ctx)

    render_click(view, "complete", %{"uuid" => ctx.consult.uuid})
    render_submit(view, "next_up_confirm", %{"uuid" => ctx.render.uuid})

    assert status(ctx.render) == "waiting"
    assert status(ctx.consult) == "waiting"
  end

  describe "with comments" do
    setup do
      :ok = PhoenixKitProjects.DataCase.with_comments_module()
    end

    test "comments are posted to each task's thread on confirm, not before", ctx do
      {:ok, view, _html} = show(ctx)

      render_click(view, "complete", %{"uuid" => ctx.consult.uuid})
      render_click(view, "next_up_toggle_idle", %{"uuid" => ctx.render.uuid})

      render_submit(view, "next_up_confirm", %{
        "uuid" => ctx.consult.uuid,
        "notes" => %{
          ctx.measure.uuid => "  Client is home after 17:00.  ",
          ctx.render.uuid => "Wait for the measurements first.",
          ctx.consult.uuid => "not offered"
        }
      })

      assert [comment] = PhoenixKitComments.list_comments("assignment", ctx.measure.uuid)
      assert comment.content == "Client is home after 17:00."
      assert comment.user_uuid == ctx.actor_uuid
      assert [_] = PhoenixKitComments.list_comments("assignment", ctx.render.uuid)
      assert PhoenixKitComments.list_comments("assignment", ctx.consult.uuid) == []
    end
  end
end
