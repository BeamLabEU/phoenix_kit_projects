defmodule PhoenixKitProjects.Web.ProjectModulesLiveTest do
  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKitProjects.Extensions
  alias PhoenixKitProjects.Extensions.Registry
  alias PhoenixKitProjects.Features

  setup %{conn: conn} do
    Registry.refresh()
    scope = fake_scope()
    conn = put_test_scope(conn, scope)
    project = fixture_project()
    {:ok, conn: conn, project: project, scope: scope}
  end

  test "renders the panel: built-in tasks toggle, flags, presets", %{conn: conn, project: project} do
    {:ok, _view, html} = live(conn, "/en/admin/projects/list/#{project.uuid}/modules")

    assert html =~ "Modules &amp; features"
    assert html =~ "Tasks"
    assert html =~ "Workflow statuses"
    assert html =~ "Simple to-do list"
  end

  test "toggle_ext flips the tasks extension off and back", %{conn: conn, project: project} do
    {:ok, view, _html} = live(conn, "/en/admin/projects/list/#{project.uuid}/modules")

    assert Extensions.enabled?(project, "tasks")

    view |> element("input[phx-value-key='tasks'][phx-click='toggle_ext']") |> render_click()
    refute Extensions.enabled?(project, "tasks")

    view |> element("input[phx-value-key='tasks'][phx-click='toggle_ext']") |> render_click()
    assert Extensions.enabled?(project, "tasks")
  end

  test "toggle_flag writes an explicit value", %{conn: conn, project: project} do
    {:ok, view, _html} = live(conn, "/en/admin/projects/list/#{project.uuid}/modules")

    assert Features.on?(project, "assignees")
    view |> element("input[phx-value-key='assignees'][phx-click='toggle_flag']") |> render_click()
    refute Features.on?(project.uuid, "assignees")
  end

  test "dependency matrix disables dependents and explains", %{conn: conn, project: project} do
    {:ok, _} = Features.set_flags(project, %{"scheduling" => false})

    {:ok, _view, html} = live(conn, "/en/admin/projects/list/#{project.uuid}/modules")

    # view_timeline's toggle is disabled with the explanation visible.
    assert html =~ "Requires:"

    assert [_ | _] =
             Regex.scan(
               ~r/<input[^>]*phx-value-key="view_timeline"[^>]*disabled[^>]*>|<input[^>]*disabled[^>]*phx-value-key="view_timeline"[^>]*>/,
               html
             )
  end

  test "apply_preset simple flips the feature set", %{conn: conn, project: project} do
    {:ok, view, _html} = live(conn, "/en/admin/projects/list/#{project.uuid}/modules")

    view |> element("button[phx-value-key='simple'][phx-click='apply_preset']") |> render_click()

    refute Features.on?(project.uuid, "assignees")
    refute Features.on?(project.uuid, "view_calendar")
  end

  test "a scope without the projects permission is bounced", %{project: project} do
    conn =
      Phoenix.ConnTest.build_conn()
      |> put_test_scope(fake_scope(permissions: []))

    {:error, {:live_redirect, %{to: to}}} =
      live(conn, "/en/admin/projects/list/#{project.uuid}/modules")

    assert to =~ "/admin/projects"
  end

  test "unknown project bounces with a flash", %{conn: conn} do
    {:error, {:live_redirect, %{to: to}}} =
      live(conn, "/en/admin/projects/list/#{Ecto.UUID.generate()}/modules")

    assert to =~ "/admin/projects"
  end
end
