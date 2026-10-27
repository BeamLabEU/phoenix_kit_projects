defmodule PhoenixKitProjects.Web.ProjectShowNextUpTest do
  @moduledoc """
  A to-do task reads as "waiting" while something it depends on is open
  and "can be started" once nothing is (derived, the stored status stays
  `todo`), and a completion that made tasks ready opens "next up": remove
  what is no longer needed, or leave a note for whoever does it.
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

  defp assignment!(project, title) do
    task = fixture_task(%{"title" => title})

    {:ok, a} =
      Projects.create_assignment(%{
        "project_uuid" => project.uuid,
        "task_uuid" => task.uuid,
        "status" => "todo"
      })

    a
  end

  defp next_up_selector(project), do: "#project-next-up-#{project.uuid}"

  test "to-do tasks read as waiting or can be started", %{conn: conn, project: project} do
    {:ok, _view, html} = live(conn, "/en/admin/projects/#{project.uuid}")

    assert html =~ "can be started"
    assert html =~ "waiting"
  end

  test "completing a task that hands work on asks first and writes nothing", ctx do
    {:ok, view, _html} = live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}")

    refute has_element?(view, next_up_selector(ctx.project))

    render_click(view, "complete", %{"uuid" => ctx.consult.uuid})

    assert has_element?(view, next_up_selector(ctx.project), "Measurement")
    assert has_element?(view, next_up_selector(ctx.project), "3D render")
    assert Projects.get_assignment(ctx.consult.uuid).status == "todo"

    # Cancel: still not done.
    render_click(view, "next_up_close", %{})
    refute has_element?(view, next_up_selector(ctx.project))
    assert Projects.get_assignment(ctx.consult.uuid).status == "todo"
  end

  test "confirm completes the task", ctx do
    {:ok, view, _html} = live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}")

    render_click(view, "complete", %{"uuid" => ctx.consult.uuid})
    render_submit(view, "next_up_confirm", %{"uuid" => ctx.consult.uuid})

    refute has_element?(view, next_up_selector(ctx.project))
    assert Projects.get_assignment(ctx.consult.uuid).status == "done"
    assert Projects.get_assignment(ctx.measure.uuid)
    assert Projects.get_assignment(ctx.render.uuid)

    assert_activity_logged("projects.assignment_completed",
      actor_uuid: ctx.actor_uuid,
      resource_uuid: ctx.consult.uuid
    )
  end

  test "a completion that readies nothing completes at once", ctx do
    {:ok, view, _html} = live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}")

    render_click(view, "complete", %{"uuid" => ctx.render.uuid})

    refute has_element?(view, next_up_selector(ctx.project))
    assert Projects.get_assignment(ctx.render.uuid).status == "done"
  end

  test "Not needed only marks the task; confirm removes it, Keep undoes it", ctx do
    {:ok, view, _html} = live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}")

    render_click(view, "complete", %{"uuid" => ctx.consult.uuid})
    render_click(view, "next_up_toggle_drop", %{"uuid" => ctx.render.uuid})
    render_click(view, "next_up_toggle_drop", %{"uuid" => ctx.measure.uuid})
    assert has_element?(view, next_up_selector(ctx.project), "will be removed")
    assert Projects.get_assignment(ctx.render.uuid)

    # Changed my mind about the measurement.
    render_click(view, "next_up_toggle_drop", %{"uuid" => ctx.measure.uuid})

    render_submit(view, "next_up_confirm", %{"uuid" => ctx.consult.uuid})

    assert Projects.get_assignment(ctx.render.uuid) == nil
    assert Projects.get_assignment(ctx.measure.uuid)
    assert Projects.get_assignment(ctx.consult.uuid).status == "done"
  end

  test "cancel after marking a task not needed removes nothing", ctx do
    {:ok, view, _html} = live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}")

    render_click(view, "complete", %{"uuid" => ctx.consult.uuid})
    render_click(view, "next_up_toggle_drop", %{"uuid" => ctx.render.uuid})
    render_click(view, "next_up_close", %{})

    assert Projects.get_assignment(ctx.render.uuid)
    assert Projects.get_assignment(ctx.consult.uuid).status == "todo"
  end

  test "only the offered tasks can be marked, and only the asked task confirmed", ctx do
    {:ok, view, _html} = live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}")

    render_click(view, "complete", %{"uuid" => ctx.consult.uuid})
    render_click(view, "next_up_toggle_drop", %{"uuid" => ctx.consult.uuid})
    refute has_element?(view, next_up_selector(ctx.project), "will be removed")

    render_submit(view, "next_up_confirm", %{"uuid" => ctx.render.uuid})
    assert Projects.get_assignment(ctx.render.uuid).status == "todo"
    assert Projects.get_assignment(ctx.consult.uuid).status == "todo"
  end

  describe "with comments" do
    setup do
      :ok = PhoenixKitProjects.DataCase.with_comments_module()
    end

    test "comments are posted to each task's thread on confirm, not before", ctx do
      {:ok, view, _html} = live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}")

      render_click(view, "complete", %{"uuid" => ctx.consult.uuid})
      render_click(view, "next_up_toggle_drop", %{"uuid" => ctx.render.uuid})

      render_submit(view, "next_up_confirm", %{
        "uuid" => ctx.consult.uuid,
        "notes" => %{
          ctx.measure.uuid => "  Client is home after 17:00.  ",
          ctx.render.uuid => "dropped, so never posted",
          ctx.consult.uuid => "not offered"
        }
      })

      assert [comment] = PhoenixKitComments.list_comments("assignment", ctx.measure.uuid)
      assert comment.content == "Client is home after 17:00."
      assert comment.user_uuid == ctx.actor_uuid
      assert PhoenixKitComments.list_comments("assignment", ctx.consult.uuid) == []
    end
  end
end
