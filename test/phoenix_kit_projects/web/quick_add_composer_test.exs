defmodule PhoenixKitProjects.Web.QuickAddComposerTest do
  @moduledoc """
  The Todoist-style composer at the foot of a project's task list
  (`Components.QuickAddComposer` + the `quick_add_*` events on
  `ProjectShowLive`).
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias Ecto.Adapters.SQL
  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{Authz, Extensions, Members, Projects}
  alias PhoenixKitProjects.Schemas.Assignment
  alias PhoenixKitProjects.Test.Repo, as: TestRepo

  setup %{conn: conn} do
    scope = fake_scope()
    conn = put_test_scope(conn, scope)
    project = fixture_project(%{"name" => "Composer-#{System.unique_integer([:positive])}"})
    {:ok, conn: conn, project: project, actor_uuid: scope.user.uuid}
  end

  defp open(view),
    do: view |> element("#quick-add button[phx-click=quick_add_open]") |> render_click()

  defp submit(view, title),
    do: view |> form("#quick-add-form", %{"title" => title}) |> render_submit()

  test "starts closed as a dashed add-row, opens into a focused input", %{conn: conn, project: p} do
    {:ok, view, html} = live(conn, "/en/admin/projects/#{p.uuid}")

    assert html =~ "Add a task"
    refute html =~ "quick-add-form"

    html = open(view)
    assert html =~ ~s(id="quick-add-form")
    # A fresh element with a mount-time focus, and a Tab-reachable escape hatch.
    assert html =~ ~s(id="quick-add-title-1")
    assert html =~ "phx-mounted"
    assert html =~ "More options"
  end

  test "Enter adds a one-off task at the bottom and keeps the composer open, empty",
       %{conn: conn, project: p, actor_uuid: actor_uuid} do
    lib = fixture_task(%{"title" => "From the library"})
    {:ok, _} = Projects.create_assignment(%{"project_uuid" => p.uuid, "task_uuid" => lib.uuid})

    {:ok, view, _} = live(conn, "/en/admin/projects/#{p.uuid}")
    open(view)

    html = submit(view, "Order the worktop")

    # The row is there in the SAME reply (no wait for our own broadcast) …
    assert html =~ "Order the worktop"
    # … the input was re-created empty (seq bumped) and the form stayed open.
    assert html =~ ~s(id="quick-add-title-2")
    refute html =~ ~s(value="Order the worktop")
    assert html =~ ~s(id="quick-add-form")

    html = submit(view, "Fit the sink")
    assert html =~ ~s(id="quick-add-title-3")

    titles =
      p.uuid
      |> Projects.list_assignments()
      |> Enum.map(&Assignment.label/1)

    assert titles == ["From the library", "Order the worktop", "Fit the sink"]

    # One-off: out of the library, but a real assignment with an audit line.
    refute "Order the worktop" in Enum.map(Projects.list_tasks(), & &1.title)
    assert "Order the worktop" in Enum.map(Projects.list_tasks(ad_hoc: :only), & &1.title)

    # Two adds, two audit lines (one per task), both marked as quick-adds.
    %{rows: rows} =
      SQL.query!(
        TestRepo,
        "SELECT metadata FROM phoenix_kit_activities WHERE action = 'projects.assignment_created' AND actor_uuid = $1",
        [Ecto.UUID.dump!(actor_uuid)]
      )

    assert rows |> Enum.map(fn [m] -> {m["new_task"], m["quick_add"]} end) |> Enum.sort() ==
             [{"Fit the sink", true}, {"Order the worktop", true}]
  end

  test "a blank title keeps the composer open with an inline error and adds nothing",
       %{conn: conn, project: p} do
    {:ok, view, _} = live(conn, "/en/admin/projects/#{p.uuid}")
    open(view)

    html = submit(view, "   ")
    assert html =~ "Give the task a title."
    assert html =~ ~s(id="quick-add-title-1")
    assert Projects.list_assignments(p.uuid) == []
  end

  test "Esc and the close button both close it; the draft is dropped", %{conn: conn, project: p} do
    {:ok, view, _} = live(conn, "/en/admin/projects/#{p.uuid}")
    open(view)

    view |> form("#quick-add-form", %{"title" => "half typed"}) |> render_change()
    html = view |> element("#quick-add-title-1") |> render_keydown(%{"key" => "Escape"})
    refute html =~ "quick-add-form"
    assert html =~ "Add a task"

    html = open(view)
    refute html =~ "half typed"
    html = view |> element("#quick-add button[phx-click=quick_add_close]") |> render_click()
    refute html =~ "quick-add-form"
  end

  test "More options carries the draft into the full form without creating anything",
       %{conn: conn, project: p} do
    {:ok, view, _} = live(conn, "/en/admin/projects/#{p.uuid}")
    open(view)
    html = view |> form("#quick-add-form", %{"title" => "Needs a duration"}) |> render_change()

    assert html =~ "title=Needs+a+duration"
    assert Projects.list_assignments(p.uuid) == []

    {:ok, _form, form_html} =
      live(conn, "/en/admin/projects/#{p.uuid}/assignments/new?title=Needs+a+duration")

    assert form_html =~ ~s(value="Needs a duration")
    assert form_html =~ ~s(name="task_mode" value="new")
  end

  test "is not offered on templates", %{conn: conn} do
    t = fixture_template(%{"name" => "Tmpl-#{System.unique_integer([:positive])}"})
    {:ok, _view, html} = live(conn, "/en/admin/projects/templates/#{t.uuid}")
    refute html =~ ~s(id="quick-add")
  end

  test "is hidden and refused when the tasks feature is off", %{conn: conn, project: p} do
    {:ok, _} = Extensions.disable(p, "tasks")
    {:ok, view, html} = live(conn, "/en/admin/projects/#{p.uuid}")

    refute html =~ ~s(id="quick-add")
    html = render_click(view, "quick_add_task", %{"title" => "Forged"})
    assert html =~ "turned off for this project"
    assert Projects.list_assignments(p.uuid) == []
  end

  test "a member below the project's create_tasks floor is refused", %{project: p} do
    # Floors are open by default (a viewer may add work); the project
    # tightens this one to managers, exactly like the full add page honours.
    {:ok, p} = Authz.set_overrides(p, %{"create_tasks" => "managers"})

    {:ok, u} =
      Auth.register_user(%{
        "email" => "viewer-#{System.unique_integer([:positive])}@example.com",
        "password" => "ViewerPass123!"
      })

    {:ok, _} = Members.add_member(p, u.uuid, role: "viewer")

    conn =
      put_test_scope(
        Phoenix.ConnTest.build_conn(),
        fake_scope(user_uuid: u.uuid, email: u.email, roles: ["User"], permissions: ["projects"])
      )

    {:ok, view, _html} = live(conn, "/en/admin/projects/#{p.uuid}")

    html = render_click(view, "quick_add_task", %{"title" => "Not mine to add"})
    assert html =~ "permission"
    assert Projects.list_assignments(p.uuid) == []
  end
end
