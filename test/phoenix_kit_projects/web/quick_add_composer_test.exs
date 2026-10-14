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

  # Someone who may add tasks types them into the list: the row at the
  # foot adds a task in place (`outline_add_first`) instead of opening the
  # sheet — the sheet stays at the top as "Add task", for one with details.
  test "on the project page it adds a task in place", %{conn: conn, project: p} do
    {:ok, view, html} = live(conn, "/en/admin/projects/#{p.uuid}")

    assert html =~ ~s(phx-click="outline_add_first")
    refute html =~ ~s(id="quick-add")
    assert has_element?(view, "[data-id='add-task-sheet']")

    view |> element("button[phx-click='outline_add_first']") |> render_click()
    [a] = PhoenixKitProjects.Projects.list_assignments(p.uuid)
    # The new row's title takes the cursor, empty, to be typed into.
    assert render(view) =~ ~s(id="task-title-#{a.uuid}")
  end

  test "on a host page in navigate mode the sheet is a link to the add page",
       %{conn: conn, project: p} do
    {:ok, _view, html} =
      live_isolated(conn, ProjectShowLive,
        session: %{"id" => p.uuid, "current_user_uuid" => embed_user_uuid!()}
      )

    assert html =~
             ~s(href="#{PhoenixKitProjects.DataCase.admin_projects()}/#{p.uuid}/assignments/new")
  end

  test "is not offered on templates", %{conn: conn} do
    t = fixture_template(%{"name" => "Tmpl-#{System.unique_integer([:positive])}"})
    {:ok, _view, html} = live(conn, "/en/admin/projects/templates/#{t.uuid}")
    refute html =~ ~s(id="quick-add")
    refute html =~ ~s(phx-click="outline_add_first")
  end

  test "is hidden when the tasks feature is off", %{conn: conn, project: p} do
    {:ok, _} = Extensions.disable(p, "tasks")
    {:ok, _view, html} = live(conn, "/en/admin/projects/#{p.uuid}")
    refute html =~ ~s(id="quick-add")
    refute html =~ ~s(phx-click="outline_add_first")
  end
end
