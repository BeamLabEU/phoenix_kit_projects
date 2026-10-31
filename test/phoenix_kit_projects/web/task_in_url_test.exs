defmodule PhoenixKitProjects.Web.TaskInUrlTest do
  @moduledoc """
  Item 21: the task open in a drawer is in the page's address (`?task=`),
  so a reload or a link opens it again and Back closes it (`PopupHostLive`
  + the `PkpDrawerUrl` hook) — in an embed only when the host names the
  parameter (`"url_param"`, Max 2026-10-31: off by default); and the
  language comes from the URL, never from a `"locale"` left in the
  browser's session.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{Members, Projects}
  alias PhoenixKitProjects.PubSub, as: ProjectsPubSub
  alias PhoenixKitProjects.Schemas.Assignment
  alias PhoenixKitProjects.Web.Helpers, as: WebHelpers
  alias PhoenixKitProjects.Web.ProjectShowLive

  setup %{conn: conn} do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "task-url-#{System.unique_integer([:positive])}@example.com",
        "password" => "TaskUrlPass123!"
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
    topic = "task-url-#{System.unique_integer([:positive])}"

    {:ok, view, _html} =
      live_isolated(ctx.conn, PhoenixKitProjects.Web.PopupHostLive,
        session:
          Map.merge(
            %{
              "pubsub_topic" => topic,
              "placement" => "end",
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

  defp open_view(ctx, topic) do
    ProjectsPubSub.broadcast_embed(topic, :opened, %{
      lv: PhoenixKitProjects.Web.AssignmentViewLive,
      session: ProjectShowLive.view_session(%{project_uuid: ctx.project.uuid, uuid: ctx.a.uuid}),
      frame_ref: nil
    })
  end

  describe "an embed that names no parameter (the default)" do
    test "no address hook, and a forged address event opens nothing", ctx do
      {view, topic} = host(ctx, %{})
      refute has_element?(view, ~s([phx-hook="PkpDrawerUrl"]))

      open_view(ctx, topic)
      assert render(view) =~ "<dialog"
      refute has_element?(view, ~s([phx-hook="PkpDrawerUrl"]))

      # Nothing is read from the address either.
      render_hook(view, "pkp_url_task", %{"task" => ""})
      assert render(view) =~ "<dialog"
    end

    test "an address ref is not read", ctx do
      {view, _topic} = host(ctx, %{})
      render_hook(view, "pkp_url_task", %{"task" => Assignment.row_ref(ctx.a)})
      refute render(view) =~ "<dialog"
    end

    test "a name that is not a plain parameter name is off", ctx do
      {view, _topic} = host(ctx, %{"url_param" => "task\"><script>"})
      refute has_element?(view, ~s([phx-hook="PkpDrawerUrl"]))
    end
  end

  test "the host picks the parameter's name", ctx do
    {view, topic} = host(ctx, %{"url_param" => "pk_task"})
    assert has_element?(view, ~s([phx-hook="PkpDrawerUrl"][data-param="pk_task"]))

    open_view(ctx, topic)
    ref = Assignment.row_ref(ctx.a)
    assert has_element?(view, ~s([phx-hook="PkpDrawerUrl"][data-task="#{ref}"]))
  end

  test "the project's own page keeps ?task=", ctx do
    {:ok, view, _html} = live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}")
    assert has_element?(view, ~s([phx-hook="PkpDrawerUrl"][data-param="task"]))
  end

  test "opening a task's view puts its ref in the address hook", ctx do
    {view, topic} = host(ctx)
    ref = Assignment.row_ref(ctx.a)
    assert has_element?(view, ~s([phx-hook="PkpDrawerUrl"][data-task=""]))

    ProjectsPubSub.broadcast_embed(topic, :opened, %{
      lv: PhoenixKitProjects.Web.AssignmentViewLive,
      session:
        ProjectShowLive.view_session(%{
          project_uuid: ctx.project.uuid,
          uuid: ctx.a.uuid
        }),
      frame_ref: nil
    })

    assert has_element?(view, ~s([phx-hook="PkpDrawerUrl"][data-task="#{ref}"]))

    # Back over the entry: the task's frame closes.
    render_hook(view, "pkp_url_task", %{"task" => ""})
    assert has_element?(view, ~s([phx-hook="PkpDrawerUrl"][data-task=""]))
    refute render(view) =~ "<dialog"
  end

  test "a ?task= in the address when the page loads opens that task", ctx do
    {view, _topic} = host(ctx)
    ref = Assignment.row_ref(ctx.a)

    render_hook(view, "pkp_url_task", %{"task" => ref})
    assert has_element?(view, ~s([phx-hook="PkpDrawerUrl"][data-task="#{ref}"]))
    assert render(view) =~ "<dialog"

    # Already open: asking again opens nothing more.
    render_hook(view, "pkp_url_task", %{"task" => ref})
    assert length(Regex.scan(~r/<dialog/, render(view))) == 1

    # Something that is no task opens nothing.
    render_hook(view, "pkp_url_task", %{"task" => "NOPE-999"})
    assert length(Regex.scan(~r/<dialog/, render(view))) == 1
  end

  # A link may name the task by uuid (the Hours page's do) while the open
  # frame shows its KEY-n: the page opened it already, the hook asking with
  # the uuid must not stack the same task a second time.
  test "a task already open is not opened again when the address names it by uuid", ctx do
    {view, _topic} = host(ctx)
    ref = Assignment.row_ref(ctx.a)
    assert is_binary(ref) and ref != ctx.a.uuid

    render_hook(view, "pkp_url_task", %{"task" => ref})
    render_hook(view, "pkp_url_task", %{"task" => ctx.a.uuid})
    assert length(Regex.scan(~r/<dialog/, render(view))) == 1
  end

  test "a new task's form is not a task in the address", ctx do
    {view, topic} = host(ctx)

    ProjectsPubSub.broadcast_embed(topic, :opened, %{
      lv: PhoenixKitProjects.Web.AssignmentFormLive,
      session: %{"live_action" => "new", "project_id" => ctx.project.uuid},
      frame_ref: nil
    })

    assert render(view) =~ "<dialog"
    assert has_element?(view, ~s([phx-hook="PkpDrawerUrl"][data-task=""]))
  end

  test "the project page's tab address keeps the drawer's task", ctx do
    {:ok, _view, html} = live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}")
    assert html =~ ~s(phx-hook="PkpUrlMirror")
    refute html =~ ~s(phx-hook="PkUrlMirror")
  end

  describe "the language is the URL's" do
    test "a session's locale never replaces one the page already has" do
      Gettext.put_locale(PhoenixKitWeb.Gettext, "et")
      WebHelpers.maybe_put_locale(%{"locale" => "ru"})
      assert Gettext.get_locale(PhoenixKitWeb.Gettext) == "et"
    end

    test "an embed's own process takes the locale its host passed" do
      task =
        Task.async(fn ->
          WebHelpers.maybe_put_locale(%{"locale" => "et"})
          Gettext.get_locale(PhoenixKitWeb.Gettext)
        end)

      assert Task.await(task) == "et"
    end
  end
end
