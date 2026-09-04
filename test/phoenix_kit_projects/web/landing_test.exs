defmodule PhoenixKitProjects.Web.LandingTest do
  @moduledoc """
  The module's landing page is the project LIST (2026-09): the parent tab
  and the `Projects` subtab both render `ProjectsLive` at the base path,
  the old bare `…/list` address redirects there, and the subtab's matcher
  is lit on the landing and on project pages only.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Dashboard.Tab

  setup %{conn: conn} do
    scope = fake_scope()
    {:ok, conn: put_test_scope(conn, scope)}
  end

  test "the base path renders the project list, not the old dashboard", %{conn: conn} do
    p = fixture_project(%{"name" => "Landing-#{System.unique_integer([:positive])}"})
    {:ok, _view, html} = live(conn, "/en/admin/projects")

    assert html =~ p.name
    # Overview-only furniture must be gone from the landing.
    refute html =~ "Tasks calendar"
  end

  test "the legacy bare list path redirects to the landing", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/en/admin/projects"}}} =
             live(conn, "/en/admin/projects/list")
  end

  describe "admin tabs" do
    defp tab(id) do
      Enum.find(PhoenixKitProjects.admin_tabs(), &(&1.id == id)) ||
        flunk("no tab #{inspect(id)}")
    end

    test "parent and Projects subtab land on the list; no Overview tab" do
      assert {PhoenixKitProjects.Web.ProjectsLive, :index} = tab(:admin_projects).live_view
      assert {PhoenixKitProjects.Web.ProjectsLive, :index} = tab(:admin_projects_list).live_view
      assert tab(:admin_projects_list).path == "projects"
      refute Enum.any?(PhoenixKitProjects.admin_tabs(), &(&1.id == :admin_projects_overview))

      legacy = tab(:admin_projects_list_legacy)
      assert legacy.visible == false
      assert legacy.match == :exact
      assert {PhoenixKitProjects.Web.ListRedirectLive, :index} = legacy.live_view
    end

    test "the Projects subtab is lit on the landing and on project pages only" do
      t = Tab.resolve_path(tab(:admin_projects_list), :admin)

      assert Tab.matches_path?(t, "/admin/projects")
      assert Tab.matches_path?(t, "/en/admin/projects/")
      assert Tab.matches_path?(t, "/admin/projects/list")
      assert Tab.matches_path?(t, "/admin/projects/list/0199-abc")
      assert Tab.matches_path?(t, "/admin/projects/list/0199-abc/gantt?tab=x")

      refute Tab.matches_path?(t, "/admin/projects/tasks")
      refute Tab.matches_path?(t, "/admin/projects/templates/0199-abc")
      refute Tab.matches_path?(t, "/admin/projectsx")
      refute Tab.matches_path?(t, "/admin/projects/listing")
    end

    test "Tasks and Templates subtabs stay their own" do
      tasks = Tab.resolve_path(tab(:admin_projects_tasks), :admin)
      templates = Tab.resolve_path(tab(:admin_projects_templates), :admin)

      refute Tab.matches_path?(tasks, "/admin/projects")
      refute Tab.matches_path?(templates, "/admin/projects")
      assert Tab.matches_path?(tasks, "/admin/projects/tasks/new")
      assert Tab.matches_path?(templates, "/admin/projects/templates")
    end
  end
end
