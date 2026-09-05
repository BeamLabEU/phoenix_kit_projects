defmodule PhoenixKitProjects.Web.QuickAddComposerTest do
  @moduledoc """
  The "Add a task" row at the foot of a project's task list
  (`Components.QuickAddComposer`): the second way into the add-task
  sheet. The keyboard loop inside the sheet (Enter / Shift+Enter / Esc)
  is covered in `project_show_drawer_test.exs`.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKitProjects.Extensions
  alias PhoenixKitProjects.Web.ProjectShowLive

  setup %{conn: conn} do
    scope = fake_scope()
    conn = put_test_scope(conn, scope)
    project = fixture_project(%{"name" => "Composer-#{System.unique_integer([:positive])}"})
    {:ok, conn: conn, project: project}
  end

  test "on the project page it is a popup button into the add-task sheet",
       %{conn: conn, project: p} do
    {:ok, _view, html} = live(conn, "/en/admin/projects/#{p.uuid}")

    [row] = Regex.run(~r/<div id="quick-add".*?<\/div>/s, html)
    assert row =~ "Add a task"
    assert row =~ ~s(phx-click="open_embed")
    assert row =~ ~s(phx-value-lv="Elixir.PhoenixKitProjects.Web.AssignmentFormLive")
    assert row =~ "&quot;live_action&quot;:&quot;new&quot;"
    refute row =~ "<form"
  end

  test "on a host page in navigate mode it is a link to the add page", %{conn: conn, project: p} do
    {:ok, _view, html} =
      live_isolated(conn, ProjectShowLive,
        session: %{"id" => p.uuid, "current_user_uuid" => embed_user_uuid!()}
      )

    [row] = Regex.run(~r/<div id="quick-add".*?<\/div>/s, html)
    assert row =~ ~s(href="/en/admin/projects/#{p.uuid}/assignments/new")
  end

  test "is not offered on templates", %{conn: conn} do
    t = fixture_template(%{"name" => "Tmpl-#{System.unique_integer([:positive])}"})
    {:ok, _view, html} = live(conn, "/en/admin/projects/templates/#{t.uuid}")
    refute html =~ ~s(id="quick-add")
  end

  test "is hidden when the tasks feature is off", %{conn: conn, project: p} do
    {:ok, _} = Extensions.disable(p, "tasks")
    {:ok, _view, html} = live(conn, "/en/admin/projects/#{p.uuid}")
    refute html =~ ~s(id="quick-add")
  end
end
