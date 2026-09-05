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

  describe "legacy list/… addresses" do
    alias PhoenixKitProjects.Web.ListRedirectLive

    test "the bare list path redirects to the landing", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/en/admin/projects"}}} =
               live(conn, "/en/admin/projects/list")
    end

    test "every nested legacy path redirects to the same path without the segment",
         %{conn: conn} do
      p = fixture_project(%{"name" => "Legacy-#{System.unique_integer([:positive])}"})

      for {from, to} <- [
            {"/en/admin/projects/list/new", "/en/admin/projects/new"},
            {"/en/admin/projects/list/#{p.uuid}", "/en/admin/projects/#{p.uuid}"},
            {"/en/admin/projects/list/#{p.uuid}/board", "/en/admin/projects/#{p.uuid}/board"},
            {"/en/admin/projects/list/#{p.uuid}/assignments/new?title=Hi",
             "/en/admin/projects/#{p.uuid}/assignments/new?title=Hi"}
          ] do
        assert {:error, {:redirect, %{to: ^to}}} = live(conn, from), from
      end
    end

    test "strip_list_segment/1 touches only the first projects/list pair" do
      assert ListRedirectLive.strip_list_segment("https://x/phoenix_kit/en/admin/projects/list") ==
               "/phoenix_kit/en/admin/projects"

      assert ListRedirectLive.strip_list_segment("/admin/projects/list/abc/files?x=1") ==
               "/admin/projects/abc/files?x=1"

      # A project literally named "list" deeper in the path is not a segment pair.
      assert ListRedirectLive.strip_list_segment("/admin/projects/abc/list") ==
               "/admin/projects/abc/list"

      assert ListRedirectLive.strip_list_segment("/admin/projects/listing") ==
               "/admin/projects/listing"
    end

    test "the new project pages answer at their new addresses", %{conn: conn} do
      p = fixture_project(%{"name" => "Moved-#{System.unique_integer([:positive])}"})
      {:ok, _view, html} = live(conn, "/en/admin/projects/#{p.uuid}")
      assert html =~ p.name
      {:ok, _view, html} = live(conn, "/en/admin/projects/new")
      assert html =~ "New project" or html =~ "Create"
    end
  end

  describe "admin tabs" do
    defp tab(id) do
      Enum.find(PhoenixKitProjects.admin_tabs(), &(&1.id == id)) ||
        flunk("no tab #{inspect(id)}")
    end

    test "parent and Projects subtab land on the list; the Overview is the last subtab" do
      assert {PhoenixKitProjects.Web.ProjectsLive, :index} = tab(:admin_projects).live_view
      assert {PhoenixKitProjects.Web.ProjectsLive, :index} = tab(:admin_projects_list).live_view
      assert tab(:admin_projects_list).path == "projects"

      overview = tab(:admin_projects_overview)
      assert overview.path == "projects/overview"
      assert {PhoenixKitProjects.Web.OverviewLive, :index} = overview.live_view

      visible =
        PhoenixKitProjects.admin_tabs()
        |> Enum.filter(&(&1.parent == :admin_projects and &1.visible != false))
        |> Enum.sort_by(& &1.priority)
        |> Enum.map(& &1.id)

      assert List.last(visible) == :admin_projects_overview
      assert hd(visible) == :admin_projects_list

      legacy = tab(:admin_projects_list_legacy)
      assert legacy.visible == false
      assert legacy.match == :exact
      assert {PhoenixKitProjects.Web.ListRedirectLive, :index} = legacy.live_view
      assert tab(:admin_projects_list_legacy_glob).path == "projects/list/*rest"

      # Route order is declaration order: the literal siblings and the legacy
      # redirects must be emitted before `projects/:id` could swallow them,
      # and `projects/new` before `projects/:id`.
      paths = Enum.map(PhoenixKitProjects.admin_tabs(), & &1.path)
      idx = fn p -> Enum.find_index(paths, &(&1 == p)) end
      id_at = idx.("projects/:id")

      for p <-
            ~w(projects/tasks projects/templates projects/overview projects/list projects/list/*rest projects/new) do
        assert idx.(p) < id_at, "#{p} must be declared before projects/:id"
      end
    end

    test "the Projects subtab is lit on the landing and on project pages only" do
      t = Tab.resolve_path(tab(:admin_projects_list), :admin)

      assert Tab.matches_path?(t, "/admin/projects")
      assert Tab.matches_path?(t, "/en/admin/projects/")
      assert Tab.matches_path?(t, "/admin/projects/new")
      assert Tab.matches_path?(t, "/admin/projects/0199-abc")
      assert Tab.matches_path?(t, "/admin/projects/0199-abc/gantt?tab=x")
      assert Tab.matches_path?(t, "/admin/projects/0199-abc/assignments/new")

      refute Tab.matches_path?(t, "/admin/projects/tasks")
      refute Tab.matches_path?(t, "/admin/projects/tasks/new")
      refute Tab.matches_path?(t, "/admin/projects/overview")
      refute Tab.matches_path?(t, "/admin/projects/templates/0199-abc")
      refute Tab.matches_path?(t, "/admin/projectsx")
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
