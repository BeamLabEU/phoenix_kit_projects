defmodule PhoenixKitProjects.Web.BreadcrumbsTest do
  @moduledoc """
  The admin header trail on every page of the module (`Web.Crumbs`):
  "Admin Panel / Projects / …" everywhere, subtab labels as crumbs, sub-pages
  as crumbs (not "Test · Files"), the sub-project parent chain, "Add task"
  under a project vs "New task" in the library, "Edit <name>".
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKitProjects.Projects

  setup %{conn: conn} do
    scope = fake_scope()
    {:ok, conn: put_test_scope(conn, scope)}
  end

  # The trail as the test layout renders it: section / crumbs… / title.
  defp trail(html) do
    [crumbs_html] = Regex.run(~r/<div id="test-breadcrumb"[^>]*>.*?<\/div>/s, html)
    [_, title] = Regex.run(~r/data-page-title="([^"]*)"/, crumbs_html)
    section = Regex.run(~r/data-crumb-section="([^"]*)"/, crumbs_html)
    crumbs = Regex.scan(~r/data-crumb="([^"]*)" href="([^"]*)"/, crumbs_html)

    %{
      section: section && Enum.at(section, 1),
      crumbs: Enum.map(crumbs, fn [_, label, href] -> {label, href} end),
      title: title
    }
  end

  defp trail_labels(html) do
    %{section: s, crumbs: c, title: t} = trail(html)
    Enum.reject([s | Enum.map(c, &elem(&1, 0))] ++ [t], &is_nil/1)
  end

  test "lists, overview and settings", %{conn: conn} do
    {:ok, _, html} = live(conn, "/en/admin/projects")
    assert trail_labels(html) == ["Projects"]

    {:ok, _, html} = live(conn, "/en/admin/projects/tasks")
    assert trail_labels(html) == ["Projects", "Tasks"]

    {:ok, _, html} = live(conn, "/en/admin/projects/templates")
    assert trail_labels(html) == ["Projects", "Templates"]

    {:ok, _, html} = live(conn, "/en/admin/projects/overview")
    assert trail_labels(html) == ["Projects", "Overview"]
  end

  test "a project, its sub-pages and its forms", %{conn: conn} do
    p = fixture_project(%{"name" => "Test"})
    base = "/en/admin/projects/#{p.uuid}"

    {:ok, _, html} = live(conn, base)
    assert trail_labels(html) == ["Projects", "Test"]

    for {sub, leaf} <- [
          {"files", "Files"},
          {"members", "Members"},
          {"modules", "Modules"},
          {"activity", "Activity"}
        ] do
      {:ok, _, html} = live(conn, "#{base}/#{sub}")
      assert trail_labels(html) == ["Projects", "Test", leaf], sub
      # The project crumb links back to the project page.
      assert {"Test", "/en/admin/projects/#{p.uuid}"} in trail(html).crumbs
    end

    {:ok, _, html} = live(conn, "#{base}/assignments/new")
    assert trail_labels(html) == ["Projects", "Test", "Add task"]
    refute html =~ "Add task to"

    {:ok, _, html} = live(conn, "#{base}/edit")
    assert trail_labels(html) == ["Projects", "Edit Test"]

    {:ok, _, html} = live(conn, "/en/admin/projects/new")
    assert trail_labels(html) == ["Projects", "New project"]

    t = fixture_task(%{"title" => "Measure"})
    {:ok, a} = Projects.create_assignment(%{"project_uuid" => p.uuid, "task_uuid" => t.uuid})
    {:ok, _, html} = live(conn, "#{base}/assignments/#{a.uuid}/edit")
    assert trail_labels(html) == ["Projects", "Test", "Edit Measure"]
  end

  test "the task library and templates", %{conn: conn} do
    {:ok, _, html} = live(conn, "/en/admin/projects/tasks/new")
    assert trail_labels(html) == ["Projects", "Tasks", "New task"]

    t = fixture_task(%{"title" => "Order fronts"})
    {:ok, _, html} = live(conn, "/en/admin/projects/tasks/#{t.uuid}/edit")
    assert trail_labels(html) == ["Projects", "Tasks", "Edit Order fronts"]

    tpl = fixture_template(%{"name" => "Kitchen template"})
    {:ok, _, html} = live(conn, "/en/admin/projects/templates/#{tpl.uuid}")
    assert trail_labels(html) == ["Projects", "Templates", "Kitchen template"]

    {:ok, _, html} = live(conn, "/en/admin/projects/templates/new")
    assert trail_labels(html) == ["Projects", "Templates", "New template"]

    {:ok, _, html} = live(conn, "/en/admin/projects/templates/#{tpl.uuid}/edit")
    assert trail_labels(html) == ["Projects", "Templates", "Edit Kitchen template"]
  end

  test "a sub-project carries its parent chain", %{conn: conn} do
    parent = fixture_project(%{"name" => "Parent"})
    {:ok, %{child_project: child}} = Projects.create_subproject(parent.uuid, %{"name" => "Child"})

    {:ok, %{child_project: grandchild}} =
      Projects.create_subproject(child.uuid, %{"name" => "Grandchild"})

    assert Enum.map(Projects.parent_chain(grandchild.uuid), & &1.name) == ["Parent", "Child"]
    assert Projects.parent_chain(parent.uuid) == []

    {:ok, _, html} = live(conn, "/en/admin/projects/#{grandchild.uuid}")
    assert trail_labels(html) == ["Projects", "Parent", "Child", "Grandchild"]

    {:ok, _, html} = live(conn, "/en/admin/projects/#{grandchild.uuid}/assignments/new")
    assert trail_labels(html) == ["Projects", "Parent", "Child", "Grandchild", "Add task"]
  end
end
