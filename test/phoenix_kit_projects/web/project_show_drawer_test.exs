defmodule PhoenixKitProjects.Web.ProjectShowDrawerTest do
  @moduledoc """
  The project page hosts its own drawer (`:popup` embed mode): every form
  link opens `AssignmentFormLive` as a right-hand sheet over the plan, a
  save closes it and the list updates, a page link still navigates, and an
  edited form guards the sheet against a stray Esc/backdrop.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.Members
  alias PhoenixKitProjects.Projects
  alias PhoenixKitProjects.PubSub, as: ProjectsPubSub
  alias PhoenixKitProjects.Schemas.Assignment
  alias PhoenixKitProjects.Web.ProjectShowLive

  # The drawer's form mounts off-router and rebuilds identity from the
  # page's `current_user_uuid`, so the page scope must belong to a REAL
  # user (a synthetic uuid degrades the form to anonymous, which closes
  # itself for lack of permission — the exact production contract).
  setup %{conn: conn} do
    scope = fake_scope(user_uuid: embed_user_uuid!())
    conn = put_test_scope(conn, scope)
    project = fixture_project(%{"name" => "Drawer-#{System.unique_integer([:positive])}"})
    {:ok, conn: conn, project: project}
  end

  defp host(view, project), do: find_live_child(view, "project-popup-#{project.uuid}")

  # The click broadcasts `:opened` on the page's popup topic; the host
  # child picks it up on its own mailbox, so wait for the frame (and the
  # form LiveView it renders) instead of reading once.
  defp open_drawer(view, project, selector, text \\ nil) do
    view |> element(selector, text) |> render_click()
    host = host(view, project)
    {html, ref} = eventually(fn -> frame_ref(render(host)) end)
    frame_id = "embed-#{ref}-assignment_form_live"
    form = eventually(fn -> find_live_child(host, frame_id) end)
    {host, form, html}
  end

  defp frame_ref(html) do
    case Regex.run(~r/phx-value-frame-ref="(\d+)"/, html) do
      [_, ref] -> {html, ref}
      nil -> nil
    end
  end

  defp eventually(fun, tries \\ 50) do
    case fun.() do
      nil when tries > 0 ->
        Process.sleep(20)
        eventually(fun, tries - 1)

      nil ->
        flunk("condition never held")

      value ->
        value
    end
  end

  defp gone(host) do
    eventually(fn -> if render(host) =~ "<dialog", do: nil, else: true end)
  end

  test "the page is in popup mode and hosts its own drawer", %{conn: conn, project: p} do
    {:ok, view, html} = live(conn, "/en/admin/projects/#{p.uuid}")

    # The host is mounted, empty, as a drawer.
    assert host(view, p)
    refute render(host(view, p)) =~ "<dialog"
    # Form links are popup buttons; page links stay real links.
    assert html =~ ~s(phx-click="open_embed")
    assert html =~ ~s(href="/en/admin/projects/#{p.uuid}/files")
  end

  test "Add task opens the form in the drawer; saving closes it and the plan updates",
       %{conn: conn, project: p} do
    {:ok, view, _} = live(conn, "/en/admin/projects/#{p.uuid}")

    {host, form, html} =
      open_drawer(view, p, "button[phx-value-lv$='AssignmentFormLive']", "Add task")

    assert html =~ ~s(class="modal modal-end")
    assert render(form) =~ "Add task"

    # Create-new mode, title typed: the form reports dirty → the drawer
    # stops closing on Esc/backdrop.
    title = "Drawer task #{System.unique_integer([:positive])}"

    form
    |> form("#assignment-form",
      assignment: %{status: "todo"},
      task_mode: "new",
      task: %{title: title}
    )
    |> render_change()

    assert eventually(fn -> if render(host) =~ ~s(data-closeable="false"), do: true end)
    assert render(form) =~ "Discard your changes?"

    form
    |> form("#assignment-form",
      assignment: %{status: "todo"},
      task_mode: "new",
      task: %{title: title}
    )
    |> render_submit()

    # :saved with close: true popped the frame; the page re-read its plan.
    assert gone(host)

    assert title in Enum.map(
             Projects.list_assignments(p.uuid),
             &Assignment.label/1
           )

    assert render(view) =~ title
  end

  test "the drawer's form keeps the page's browser title", %{conn: conn, project: p} do
    {:ok, view, _} = live(conn, "/en/admin/projects/#{p.uuid}")

    {_host, form, _} =
      open_drawer(view, p, "button[phx-value-lv$='AssignmentFormLive']", "Add task")

    # The header inside the sheet still says what it is …
    assert render(form) =~ "Add task"
    # … but the nested LV carries no page_title (LiveView would apply it
    # to the tab), and the page's own title is untouched.
    assert :sys.get_state(form.pid).socket.assigns.page_title == nil
    assert :sys.get_state(form.pid).socket.assigns.heading == "Add task"
    assert :sys.get_state(view.pid).socket.assigns.page_title == p.name

    # The same form as a page of its own owns the tab.
    {:ok, page, _} = live(conn, "/en/admin/projects/#{p.uuid}/assignments/new")
    assert :sys.get_state(page.pid).socket.assigns.page_title == "Add task"
    assert :sys.get_state(page.pid).socket.assigns.heading == "Add task"
  end

  test "a tampered open_embed payload cannot name the user", %{conn: conn, project: p} do
    {:ok, view, _} = live(conn, "/en/admin/projects/#{p.uuid}")
    topic = :sys.get_state(view.pid).socket.assigns.embed_pubsub_topic
    ProjectsPubSub.subscribe(topic)

    forged = Ecto.UUID.generate()

    session =
      Jason.encode!(%{
        "live_action" => "new",
        "project_id" => p.uuid,
        "current_user_uuid" => forged,
        "pubsub_topic" => "elsewhere",
        "mode" => "navigate"
      })

    render_click(view, "open_embed", %{
      "lv" => "Elixir.PhoenixKitProjects.Web.AssignmentFormLive",
      "session" => session
    })

    assert_receive {:projects, :opened, %{session: emitted}}, 1_000
    refute Map.has_key?(emitted, "current_user_uuid")
    refute Map.has_key?(emitted, "pubsub_topic")
    refute Map.has_key?(emitted, "mode")
    assert emitted["project_id"] == p.uuid
  end

  test "Cancel in the drawer closes it without saving", %{conn: conn, project: p} do
    {:ok, view, _} = live(conn, "/en/admin/projects/#{p.uuid}")

    {host, form, _} =
      open_drawer(view, p, "button[phx-value-lv$='AssignmentFormLive']", "Add task")

    form |> element("button.btn[phx-click=cancel]") |> render_click()
    assert gone(host)
    assert Projects.list_assignments(p.uuid) == []
  end

  test "the Add a task row opens the sheet with the cursor in the title", %{
    conn: conn,
    project: p
  } do
    {:ok, view, _} = live(conn, "/en/admin/projects/#{p.uuid}")

    {_host, form, _} =
      open_drawer(view, p, "#quick-add button[phx-value-lv$='AssignmentFormLive']")

    html = render(form)
    assert html =~ ~s(name="task[title]")
    # The wrapper mounts focused and the title carries the Shift+Enter hook.
    assert html =~ ~s(id="new-task-title-0")
    assert html =~ ~s(phx-hook="PkShiftEnter")
    assert html =~ ~s(data-shift-enter-click="#assignment-add-next")
    assert html =~ ~s(id="assignment-add-next")
    assert html =~ "Shift+Enter adds and starts the next"
  end

  test "Add & next adds the task, keeps the sheet open on a fresh clean form",
       %{conn: conn, project: p} do
    {:ok, view, _} = live(conn, "/en/admin/projects/#{p.uuid}")

    {host, form, _} =
      open_drawer(view, p, "button[phx-value-lv$='AssignmentFormLive']", "Add task")

    first = "First #{System.unique_integer([:positive])}"

    form
    |> form("#assignment-form",
      assignment: %{status: "todo", description: "keep me out of the next one"},
      task_mode: "new",
      task: %{title: first}
    )
    |> render_change()

    assert eventually(fn -> if render(host) =~ ~s(data-closeable="false"), do: true end)

    # The "Add & next" submitter: LiveView sends its name/value with the submit.
    form
    |> form("#assignment-form",
      assignment: %{status: "todo", description: "keep me out of the next one"},
      task_mode: "new",
      task: %{title: first}
    )
    |> render_submit(%{"then" => "next"})

    # Created, and the page behind heard about it.
    assert first in Enum.map(Projects.list_assignments(p.uuid), &Assignment.label/1)
    assert eventually(fn -> if render(view) =~ first, do: true end)

    # Still open, reset, re-keyed and clean: Esc may close it again.
    html = render(form)
    assert html =~ ~s(id="new-task-title-1")
    refute html =~ "keep me out of the next one"
    refute :sys.get_state(form.pid).socket.assigns.dirty?
    assert eventually(fn -> if render(host) =~ ~s(data-closeable="true"), do: true end)

    # Plain Add on the fresh form closes the sheet.
    second = "Second #{System.unique_integer([:positive])}"

    form
    |> form("#assignment-form",
      assignment: %{status: "todo"},
      task_mode: "new",
      task: %{title: second}
    )
    |> render_submit()

    assert gone(host)
    assert second in Enum.map(Projects.list_assignments(p.uuid), &Assignment.label/1)
  end

  test "an embedded project page keeps the session's own mode", %{conn: conn, project: p} do
    # navigate (default) — plain links, no host of its own
    {:ok, u} =
      Auth.register_user(%{
        "email" => "embed-#{System.unique_integer([:positive])}@example.com",
        "password" => "EmbedPass123!"
      })

    {:ok, _} = Members.add_member(p, u.uuid, role: "manager")

    {:ok, _view, html} =
      live_isolated(conn, ProjectShowLive,
        session: %{"id" => p.uuid, "current_user_uuid" => u.uuid}
      )

    refute html =~ "project-popup-"
    assert html =~ ~s(href="/en/admin/projects/#{p.uuid}/assignments/new")
  end
end
