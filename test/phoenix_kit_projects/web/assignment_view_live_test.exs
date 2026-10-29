defmodule PhoenixKitProjects.Web.AssignmentViewLiveTest do
  @moduledoc """
  A task's view (`AssignmentViewLive`): what it is, its connections in
  words, its subtasks and details; "Edit" swaps the drawer to the form and
  the form's "Back to task" swaps back (`PopupHostLive`'s `:swap`); the
  next step is asked of the project page under the drawer (`:intent`).
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{Authz, Projects}
  alias PhoenixKitProjects.PubSub, as: ProjectsPubSub
  alias PhoenixKitProjects.Web.{AssignmentFormLive, AssignmentViewLive, PopupHostLive}

  setup %{conn: conn} do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "view-#{System.unique_integer([:positive])}@example.com",
        "password" => "ViewPass123!"
      })

    conn = put_test_scope(conn, fake_scope(user_uuid: user.uuid))
    project = fixture_project(%{"start_mode" => "immediate"})

    task = fn title, extra ->
      t = fixture_task(%{"title" => title})

      {:ok, a} =
        Projects.create_assignment(
          Map.merge(%{"project_uuid" => project.uuid, "task_uuid" => t.uuid}, extra)
        )

      a
    end

    consult = task.("Talk to the client", %{"status" => "done"})
    measure = task.("Take kitchen measurements", %{"description" => "Bring the long tape."})
    model = task.("Create 3D model", %{})
    {:ok, _} = Projects.add_dependency(measure.uuid, consult.uuid)
    {:ok, _} = Projects.add_dependency(model.uuid, measure.uuid)

    {:ok,
     conn: conn, user: user, project: project, consult: consult, measure: measure, model: model}
  end

  defp topic, do: "task-view-test-#{System.unique_integer([:positive])}"

  # An off-router mount has no scope of its own: the session names the
  # viewer, a member of the project.
  defp emit_session(ctx, task, extra \\ %{}) do
    {:ok, _} = PhoenixKitProjects.Members.add_member(ctx.project, ctx.user.uuid, role: "member")

    Map.merge(
      %{
        "project_id" => ctx.project.uuid,
        "id" => task.uuid,
        "current_user_uuid" => ctx.user.uuid,
        "mode" => "emit",
        "pubsub_topic" => ctx.topic,
        "frame_ref" => 7
      },
      extra
    )
  end

  describe "its page" do
    test "shows the task, its connections both ways and its details", ctx do
      {:ok, _view, html} =
        live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}/assignments/#{ctx.measure.uuid}")

      assert html =~ "Take kitchen measurements"
      assert html =~ "Bring the long tape."
      assert html =~ "Waits on"
      assert html =~ "Talk to the client"
      assert html =~ "Unlocks"
      assert html =~ "Create 3D model"
      assert html =~ "Unassigned"
      refute html =~ "None"
      # On its own page the next step takes you to the project to run it.
      assert html =~ "Ready to start"
    end

    test "a task of another project is not found", ctx do
      other = fixture_project()

      assert {:error, {:live_redirect, _}} =
               live(ctx.conn, "/en/admin/projects/#{other.uuid}/assignments/#{ctx.measure.uuid}")
    end
  end

  describe "in a drawer" do
    setup ctx do
      topic = topic()
      ProjectsPubSub.subscribe(topic)
      %{topic: topic}
    end

    test "Edit swaps the drawer to the form, marked as opened from the view", ctx do
      ctx = Map.put(ctx, :topic, ctx.topic)

      {:ok, view, _html} =
        live_isolated(ctx.conn, AssignmentViewLive, session: emit_session(ctx, ctx.measure))

      render_click(view, "edit", %{})

      assert_receive {:projects, :swap,
                      %{frame_ref: 7, lv: AssignmentFormLive, session: %{"from_view" => "1"} = s}}

      assert s["id"] == ctx.measure.uuid
    end

    test "a connection opens that task's view, with the way back", ctx do
      {:ok, view, _html} =
        live_isolated(ctx.conn, AssignmentViewLive, session: emit_session(ctx, ctx.measure))

      render_click(view, "open_task", %{"uuid" => ctx.model.uuid})

      assert_receive {:projects, :swap, %{lv: AssignmentViewLive, session: s}}
      assert s["id"] == ctx.model.uuid
      assert s["back_to"] == ctx.measure.uuid
    end

    test "the next step is asked of the page, and the view steps aside", ctx do
      {:ok, view, _html} =
        live_isolated(ctx.conn, AssignmentViewLive, session: emit_session(ctx, ctx.measure))

      render_click(view, "step", %{"step" => "ask_ready"})

      uuid = ctx.measure.uuid
      assert_receive {:projects, :intent, %{event: "ask_ready", uuid: ^uuid}}
      assert_receive {:projects, :closed, %{frame_ref: 7}}
    end

    test "someone who may read but not edit gets the view without Edit or the step", ctx do
      {:ok, _} =
        Authz.set_overrides(ctx.project, %{
          "edit_tasks" => "managers",
          "update_status" => "managers"
        })

      # A second user (the first one registered is the site's Owner, who
      # may do anything) and a bare connection: the session's member is
      # the only identity.
      {:ok, member} =
        Auth.register_user(%{
          "email" => "view-member-#{System.unique_integer([:positive])}@example.com",
          "password" => "ViewPass123!"
        })

      {:ok, view, html} =
        live_isolated(Phoenix.ConnTest.build_conn(), AssignmentViewLive,
          session: emit_session(%{ctx | user: member}, ctx.measure)
        )

      assert html =~ "Take kitchen measurements"
      refute html =~ "Ready to start"
      refute has_element?(view, ~s(button[phx-click="edit"]))

      render_click(view, "edit", %{})
      refute_receive {:projects, :swap, _}, 100
    end
  end

  describe "the form opened from the view" do
    setup ctx do
      topic = topic()
      ProjectsPubSub.subscribe(topic)
      %{topic: topic}
    end

    test "says Back to task, and leaving it swaps back to the view", ctx do
      session = emit_session(ctx, ctx.measure, %{"live_action" => "edit", "from_view" => "1"})
      {:ok, view, html} = live_isolated(ctx.conn, AssignmentFormLive, session: session)

      assert html =~ "Back to task"

      render_click(view, "close_form", %{})

      assert_receive {:projects, :swap, %{frame_ref: 7, lv: AssignmentViewLive, session: s}}
      assert s["id"] == ctx.measure.uuid
    end

    test "opened on its own it still closes", ctx do
      session = emit_session(ctx, ctx.measure, %{"live_action" => "edit"})
      {:ok, view, _html} = live_isolated(ctx.conn, AssignmentFormLive, session: session)

      # The drawer has its own ✕; the form draws none of its own there, and
      # its button at the bottom says Close (not "Done", the status's name).
      refute has_element?(view, ~s(button[aria-label="Close"]))
      assert has_element?(view, ~s(button[phx-click="close_form"]), "Close")

      render_click(view, "close_form", %{})
      assert_receive {:projects, :closed, %{frame_ref: 7}}
    end
  end

  describe "the drawer" do
    test ":swap replaces the top frame in place", ctx do
      topic = topic()

      {:ok, view, _html} =
        live_isolated(ctx.conn, PopupHostLive, session: %{"pubsub_topic" => topic})

      ProjectsPubSub.broadcast_embed(topic, :opened, %{
        lv: PhoenixKitProjects.Web.OverviewLive,
        session: %{},
        frame_ref: nil
      })

      [ref] = Regex.run(~r/phx-value-frame-ref="(\d+)"/, render(view), capture: :all_but_first)

      ProjectsPubSub.broadcast_embed(topic, :swap, %{
        frame_ref: String.to_integer(ref),
        lv: AssignmentViewLive,
        session: %{"project_id" => ctx.project.uuid, "id" => ctx.measure.uuid}
      })

      html = render(view)
      assert length(Regex.scan(~r/phx-hook="PkDialog"/, html)) == 1
    end

    test ":swap from a frame that is not on top is ignored", ctx do
      topic = topic()

      {:ok, view, _html} =
        live_isolated(ctx.conn, PopupHostLive, session: %{"pubsub_topic" => topic})

      ProjectsPubSub.broadcast_embed(topic, :swap, %{
        frame_ref: 999,
        lv: AssignmentViewLive,
        session: %{"project_id" => ctx.project.uuid, "id" => ctx.measure.uuid}
      })

      refute render(view) =~ "<dialog"
    end
  end

  describe "the project page" do
    test "the title opens the view, and a step asked by the view opens its dialog", ctx do
      {:ok, view, html} = live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}")

      assert html =~ "AssignmentViewLive"

      send(view.pid, {:projects, :intent, %{event: "ask_ready", uuid: ctx.measure.uuid}})
      assert render(view) =~ "ready to start?"
    end

    test "a step the page does not own is ignored", ctx do
      {:ok, view, _html} = live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}")

      send(view.pid, {:projects, :intent, %{event: "remove_assignment", uuid: ctx.measure.uuid}})
      _ = render(view)
      assert Projects.get_assignment(ctx.measure.uuid)
    end
  end
end
