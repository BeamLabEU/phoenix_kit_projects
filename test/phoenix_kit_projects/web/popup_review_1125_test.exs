defmodule PhoenixKitProjects.Web.PopupReview1125Test do
  @moduledoc """
  The 2026-11-25 focused review of the task popup (`PopupHostLive` +
  `PkpDrawerUrl`, kimi): a covered view of a deleted task leaves the stack;
  a task of another project opened from the address gets no step buttons
  the page under it cannot run.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{Members, Projects}
  alias PhoenixKitProjects.PubSub, as: ProjectsPubSub
  alias PhoenixKitProjects.Schemas.Assignment
  alias PhoenixKitProjects.Web.ProjectShowLive

  setup %{conn: conn} do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "popup-review-#{System.unique_integer([:positive])}@example.com",
        "password" => "PopupReview123!"
      })

    project = fixture_project(%{"start_mode" => "immediate"})
    {:ok, _} = Members.add_member(project, user.uuid, role: "member")

    {:ok, a} =
      Projects.create_assignment(%{
        "project_uuid" => project.uuid,
        "task_uuid" => fixture_task().uuid,
        "status" => "todo"
      })

    a = Projects.get_assignment(a.uuid)

    {:ok,
     conn: put_test_scope(conn, fake_scope(user_uuid: user.uuid)),
     user: user,
     project: project,
     a: a}
  end

  defp host(ctx, extra \\ %{"url_param" => "task"}) do
    topic = "popup-review-#{System.unique_integer([:positive])}"

    {:ok, view, _html} =
      live_isolated(ctx.conn, PhoenixKitProjects.Web.PopupHostLive,
        session:
          Map.merge(
            %{
              "pubsub_topic" => topic,
              "placement" => "center",
              "current_user_uuid" => ctx.user.uuid,
              "root_view" => %{
                "lv" => "Elixir.PhoenixKitProjects.Web.ProjectShowLive",
                "session" => %{"id" => ctx.project.uuid}
              }
            },
            extra
          )
      )

    {view, topic}
  end

  defp open_view(view, topic, assignment) do
    ProjectsPubSub.broadcast_embed(topic, :opened, %{
      lv: PhoenixKitProjects.Web.AssignmentViewLive,
      session:
        ProjectShowLive.view_session(%{
          project_uuid: assignment.project_uuid,
          uuid: assignment.uuid
        }),
      frame_ref: nil
    })

    _ = render(view)
  end

  defp stack(view), do: :sys.get_state(view.pid).socket.assigns.modal_stack

  defp other_assignment(project, status \\ "todo") do
    {:ok, a} =
      Projects.create_assignment(%{
        "project_uuid" => project.uuid,
        "task_uuid" => fixture_task().uuid,
        "status" => status
      })

    Projects.get_assignment(a.uuid)
  end

  # The frame's child LV (the task view), found by its frame ref.
  defp child_view(view, frame_ref) do
    find_live_child(view, "embed-#{frame_ref}-assignment_view_live")
  end

  # The root_view child (the project page), by the host topic's suffix.
  defp root_view(view, topic) do
    suffix =
      :crypto.hash(:sha256, topic)
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 12)

    find_live_child(view, "embed-root-project_show_live-#{suffix}")
  end

  defp eventually(fun, tries \\ 60) do
    case fun.() do
      nil when tries > 0 ->
        Process.sleep(25)
        eventually(fun, tries - 1)

      nil ->
        flunk("condition never held")

      value ->
        value
    end
  end

  test "a covered task view whose task is deleted leaves the stack", ctx do
    {view, topic} = host(ctx)
    open_view(view, topic, ctx.a)
    [%{frame_ref: a_ref}] = stack(view)

    # A second task's view stacked on top (the address-bar path).
    b = other_assignment(ctx.project)
    render_hook(view, "pkp_url_task", %{"task" => Assignment.row_ref(b)})
    assert [%{frame_ref: ^a_ref}, _] = stack(view)

    # The covered view is alive and subscribed: prove it processes a
    # project broadcast (a rename reloads it) before we delete.
    child = child_view(view, a_ref)
    assert render(child) =~ Assignment.label(ctx.a)

    # Another session deletes the COVERED task.
    {:ok, _} = Projects.delete_assignment(ctx.a)

    # Give the covered view every chance to react, then read the stack.
    Process.sleep(300)
    _ = render(view)
    refs = Enum.map(stack(view), & &1.frame_ref)

    assert a_ref not in refs,
           "the covered frame of the deleted task must leave the stack " <>
             "(the :deleted handler's own invariant), got #{inspect(refs)}"
  end

  test "control: the TOP task view whose task is deleted closes", ctx do
    {view, topic} = host(ctx)
    open_view(view, topic, ctx.a)
    assert [%{frame_ref: _}] = stack(view)

    {:ok, _} = Projects.delete_assignment(ctx.a)

    eventually(fn -> if stack(view) == [], do: true end)
  end

  test "a task of ANOTHER project opened via ?task= gets no step buttons the page cannot run",
       ctx do
    other = fixture_project(%{"start_mode" => "immediate"})
    {:ok, _} = Members.add_member(other, ctx.user.uuid, role: "manager")
    q = other_assignment(other)

    {view, _topic} = host(ctx)
    render_hook(view, "pkp_url_task", %{"task" => Assignment.row_ref(q)})
    [%{frame_ref: ref}] = stack(view)

    # No status menu that hands its steps to the page under the drawer.
    refute render(child_view(view, ref)) =~ "view-status-pop-#{q.uuid}"
  end

  test "control: a step on the page's OWN task via ?task= runs", ctx do
    {view, topic} = host(ctx)
    render_hook(view, "pkp_url_task", %{"task" => Assignment.row_ref(ctx.a)})
    [%{frame_ref: ref}] = stack(view)
    child = child_view(view, ref)
    assert render(child) =~ "view-status-pop-#{ctx.a.uuid}"

    child
    |> element("#view-status-#{ctx.a.uuid}-done")
    |> render_click()

    # The drawer closes and the page's "next up" dialog takes over.
    eventually(fn -> if stack(view) == [], do: true end)

    eventually(fn ->
      if render(view) =~ "project-next-up-#{ctx.project.uuid}", do: true
    end)

    # Confirming it completes the task.
    view
    |> root_view(topic)
    |> form("#next-up-form-#{ctx.project.uuid}")
    |> render_submit()

    assert Projects.get_assignment(ctx.a.uuid).status == "done"
  end

  test "with two task views stacked, closing the top shows the lower task in the address", ctx do
    {view, topic} = host(ctx)
    open_view(view, topic, ctx.a)

    b = other_assignment(ctx.project)
    render_hook(view, "pkp_url_task", %{"task" => Assignment.row_ref(b)})
    assert [%{frame_ref: _}, %{frame_ref: b_ref}] = stack(view)

    render_click(view, "close_top_modal", %{"frame-ref" => to_string(b_ref)})

    assert [%{frame_ref: _}] = stack(view)

    assert has_element?(
             view,
             ~s([phx-hook="PkpDrawerUrl"][data-task="#{Assignment.row_ref(ctx.a)}"])
           )
  end

  test "Back with two task views stacked closes the whole task drawer", ctx do
    {view, topic} = host(ctx)
    open_view(view, topic, ctx.a)

    b = other_assignment(ctx.project)
    render_hook(view, "pkp_url_task", %{"task" => Assignment.row_ref(b)})
    assert length(stack(view)) == 2

    render_hook(view, "pkp_url_task", %{"task" => ""})
    assert stack(view) == []
  end
end
