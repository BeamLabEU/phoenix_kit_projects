defmodule PhoenixKitProjects.Web.ProjectShowNextUpTest do
  @moduledoc """
  A new task is `waiting` (idle, nobody asked yet) until it is released —
  `todo`, shown as "can be started", which tells its people. Completing a
  task that others wait on asks first ("next up"): each task nothing would
  hold up is released on confirm unless it is kept idle, and a comment can
  be left for whoever does it. Nothing is written before the confirm.
  """

  use PhoenixKitProjects.LiveCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.Projects
  alias PhoenixKitProjects.Test.Repo
  alias PhoenixKitStaff.Schemas.{Department, Person}

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

  test "a waiting task offers only Ready to start; a released one Start", ctx do
    {:ok, view, _html} = show(ctx)
    button = &"button[phx-click='#{&1}'][phx-value-uuid='#{ctx.consult.uuid}']"

    assert has_element?(view, button.("ask_ready"))
    refute has_element?(view, button.("complete"))
    refute has_element?(view, button.("start_task"))

    render_click(view, "make_ready", %{"uuid" => ctx.consult.uuid})

    refute has_element?(view, button.("ask_ready"))
    assert has_element?(view, button.("start_task"))
  end

  test "Ready to start opens the dialog for that task; nothing is written until confirm", ctx do
    {:ok, view, _html} = show(ctx)

    render_click(view, "ask_ready", %{"uuid" => ctx.consult.uuid})
    assert has_element?(view, next_up(ctx.project), "ready to start?")
    refute has_element?(view, next_up(ctx.project), "Keep idle")
    assert status(ctx.consult) == "waiting"

    render_click(view, "next_up_close", %{})
    assert status(ctx.consult) == "waiting"

    render_click(view, "ask_ready", %{"uuid" => ctx.consult.uuid})
    render_submit(view, "next_up_confirm", %{"uuid" => ctx.consult.uuid})
    assert status(ctx.consult) == "todo"
    assert_activity_logged("projects.assignment_made_ready", resource_uuid: ctx.consult.uuid)
  end

  describe "who is told" do
    setup ctx do
      dept = Repo.insert!(%Department{name: "Measurers #{System.unique_integer([:positive])}"})
      alice = person!(ctx.project, "Alice", dept)
      bob = person!(ctx.project, "Bob", dept)

      {:ok, measure} =
        Projects.update_assignment_form(ctx.measure, %{"assigned_department_uuid" => dept.uuid})

      %{alice: alice, bob: bob, dept: dept, measure: measure}
    end

    defp person!(project, name, dept) do
      {:ok, user} =
        Auth.register_user(%{
          "email" => "#{String.downcase(name)}-#{System.unique_integer([:positive])}@example.com",
          "password" => "ValidPassword123!",
          "first_name" => name
        })

      Repo.insert!(%Person{
        user_uuid: user.uuid,
        status: "active",
        name: name,
        primary_department_uuid: dept.uuid
      })

      {:ok, _} = PhoenixKitProjects.Members.add_member(project, user.uuid, role: "member")
      user.uuid
    end

    defp notices(action, user_uuid) do
      Repo.all(
        from(e in PhoenixKit.Activity.Entry,
          where: e.action == ^action and e.target_uuid == ^user_uuid
        )
      )
    end

    test "the dialog names the assignee and everyone the notice would reach", ctx do
      {:ok, view, _html} = show(ctx)

      html = render_click(view, "ask_ready", %{"uuid" => ctx.measure.uuid})

      assert html =~ ctx.dept.name
      assert html =~ "Send a notification to"
      assert has_element?(view, next_up(ctx.project), "Alice")
      assert has_element?(view, next_up(ctx.project), "Bob")
    end

    test "an unticked person is not told; the comment goes along with the notice", ctx do
      {:ok, view, _html} = show(ctx)

      render_click(view, "ask_ready", %{"uuid" => ctx.measure.uuid})

      render_click(view, "next_up_toggle_person", %{
        "uuid" => ctx.measure.uuid,
        "user" => ctx.bob
      })

      render_submit(view, "next_up_confirm", %{
        "uuid" => ctx.measure.uuid,
        "notes" => %{ctx.measure.uuid => "Client is home after 17:00."}
      })

      assert status(ctx.measure) == "todo"
      assert [notice] = notices("projects.assignment_ready", ctx.alice)
      assert notice.metadata["notification_text"] =~ "Client is home after 17:00."
      assert notices("projects.assignment_ready", ctx.bob) == []
    end

    test "only the task's own people can be unticked", ctx do
      {:ok, view, _html} = show(ctx)

      render_click(view, "ask_ready", %{"uuid" => ctx.measure.uuid})

      render_click(view, "next_up_toggle_person", %{
        "uuid" => ctx.measure.uuid,
        "user" => ctx.actor_uuid
      })

      render_submit(view, "next_up_confirm", %{"uuid" => ctx.measure.uuid})

      assert [_] = notices("projects.assignment_ready", ctx.alice)
      assert [_] = notices("projects.assignment_ready", ctx.bob)
    end

    test "with comments on, the comment is kept on the task without a second notice", ctx do
      :ok = PhoenixKitProjects.DataCase.with_comments_module()
      {:ok, view, _html} = show(ctx)

      render_click(view, "ask_ready", %{"uuid" => ctx.measure.uuid})

      render_submit(view, "next_up_confirm", %{
        "uuid" => ctx.measure.uuid,
        "notes" => %{ctx.measure.uuid => "Bring the long tape."}
      })

      assert [comment] = PhoenixKitComments.list_comments("assignment", ctx.measure.uuid)
      assert comment.content == "Bring the long tape."
      assert [_] = notices("projects.assignment_ready", ctx.alice)
      assert notices("projects.comment_added", ctx.alice) == []
    end
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
