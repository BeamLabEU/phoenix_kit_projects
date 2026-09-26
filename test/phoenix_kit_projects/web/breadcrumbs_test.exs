defmodule PhoenixKitProjects.Web.BreadcrumbsTest do
  @moduledoc """
  The admin header trail on every page of the module (`Web.Crumbs`):
  "Admin Panel / Projects / …" everywhere, subtab labels as crumbs, sub-pages
  as crumbs (not "Test · Files"), the sub-project parent chain, "Add task"
  under a project vs "New task" in the library, and an edit page as the
  record's trail plus the record, titled plainly "Edit" (core's
  admin-header-trail guide) — the record crumb links to its page, or is
  text when the list is its only page.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{Members, Projects}

  setup %{conn: conn} do
    scope = fake_scope()
    {:ok, conn: put_test_scope(conn, scope)}
  end

  # The trail as the test layout renders it: section / crumbs… / title.
  defp trail(html) do
    [crumbs_html] = Regex.run(~r/<div id="test-breadcrumb"[^>]*>.*?<\/div>/s, html)
    [_, title] = Regex.run(~r/data-page-title="([^"]*)"/, crumbs_html)
    section = Regex.run(~r/data-crumb-section="([^"]*)"/, crumbs_html)
    # A crumb with no path renders with no href (core renders it as text).
    crumbs = Regex.scan(~r/data-crumb="([^"]*)"(?: href="([^"]*)")?/, crumbs_html)

    %{
      section: section && Enum.at(section, 1),
      crumbs: Enum.map(crumbs, fn [_, label | rest] -> {label, List.first(rest)} end),
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

    # Edit: the project page's trail plus the project (linked), then "Edit".
    {:ok, _, html} = live(conn, "#{base}/edit")
    assert trail_labels(html) == ["Projects", "Test", "Edit"]
    assert {"Test", "/en/admin/projects/#{p.uuid}"} in trail(html).crumbs

    {:ok, _, html} = live(conn, "/en/admin/projects/new")
    assert trail_labels(html) == ["Projects", "New project"]

    t = fixture_task(%{"title" => "Measure"})
    {:ok, a} = Projects.create_assignment(%{"project_uuid" => p.uuid, "task_uuid" => t.uuid})
    # An assignment has no page of its own: its task is a text crumb.
    {:ok, _, html} = live(conn, "#{base}/assignments/#{a.uuid}/edit")
    assert trail_labels(html) == ["Projects", "Test", "Measure", "Edit"]
    assert {"Measure", nil} in trail(html).crumbs
    assert {"Test", "/en/admin/projects/#{p.uuid}"} in trail(html).crumbs
  end

  test "editing a sub-project row links the child's own page", %{conn: conn} do
    parent = fixture_project(%{"name" => "Parent"})

    {:ok, %{child_project: child, assignment: row}} =
      Projects.create_subproject(parent.uuid, %{"name" => "Child"})

    {:ok, _, html} = live(conn, "/en/admin/projects/#{parent.uuid}/assignments/#{row.uuid}/edit")
    assert trail_labels(html) == ["Projects", "Parent", "Child", "Edit"]
    assert {"Child", "/en/admin/projects/#{child.uuid}"} in trail(html).crumbs
  end

  test "the task library and templates", %{conn: conn} do
    {:ok, _, html} = live(conn, "/en/admin/projects/tasks/new")
    assert trail_labels(html) == ["Projects", "Tasks", "New task"]

    t = fixture_task(%{"title" => "Order fronts"})
    # The library is a task's only page, so the task crumb is text.
    {:ok, _, html} = live(conn, "/en/admin/projects/tasks/#{t.uuid}/edit")
    assert trail_labels(html) == ["Projects", "Tasks", "Order fronts", "Edit"]
    assert {"Order fronts", nil} in trail(html).crumbs

    tpl = fixture_template(%{"name" => "Kitchen template"})
    {:ok, _, html} = live(conn, "/en/admin/projects/templates/#{tpl.uuid}")
    assert trail_labels(html) == ["Projects", "Templates", "Kitchen template"]

    {:ok, _, html} = live(conn, "/en/admin/projects/templates/new")
    assert trail_labels(html) == ["Projects", "Templates", "New template"]

    # Edit: the template page's trail plus the template (linked), then "Edit".
    {:ok, _, html} = live(conn, "/en/admin/projects/templates/#{tpl.uuid}/edit")
    assert trail_labels(html) == ["Projects", "Templates", "Kitchen template", "Edit"]

    assert {"Kitchen template", "/en/admin/projects/templates/#{tpl.uuid}"} in trail(html).crumbs
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

  test "a member of the sub-project alone does not see the parents' names in the trail",
       %{conn: conn} do
    # The sweep (2026-09-05): the trail walked the parent chain with no
    # :view check, naming projects the reader had been refused.
    parent = fixture_project(%{"name" => "Secret parent"})
    {:ok, %{child_project: child}} = Projects.create_subproject(parent.uuid, %{"name" => "Mine"})

    {:ok, member} =
      Auth.register_user(%{
        "email" => "crumb-#{System.unique_integer([:positive])}@example.com",
        "password" => "ActorPass123!"
      })

    {:ok, _} = Members.add_member(child, member.uuid, role: "viewer")
    conn = put_test_scope(conn, fake_scope(user_uuid: member.uuid, permissions: ["projects"]))

    {:ok, _, html} = live(conn, "/en/admin/projects/#{child.uuid}")
    assert trail_labels(html) == ["Projects", "Mine"]
    refute html =~ "Secret parent"
  end
end
