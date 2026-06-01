defmodule PhoenixKitProjects.Web.ProjectShowSubprojectsTest do
  @moduledoc """
  LiveView smoke coverage for the sub-project UI on `ProjectShowLive` (V126):
  the row renders, the add-modal creates one, expand reveals the child's tasks,
  and remove tears it down. Complements the context-level
  `Integration.SubprojectsTest` by exercising the actual HEEx branch at runtime.
  """

  use PhoenixKitProjects.LiveCase, async: false

  import Phoenix.LiveViewTest

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.Projects

  setup %{conn: conn} do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "sp-actor-#{System.unique_integer([:positive])}@example.com",
        "password" => "ActorPass123!"
      })

    conn = put_test_scope(conn, fake_scope(user_uuid: user.uuid))
    {:ok, conn: conn}
  end

  defp path(project), do: "/en/admin/projects/list/#{project.uuid}"

  test "an existing sub-project renders as a row with the child name + badge", %{conn: conn} do
    parent = fixture_project()

    {:ok, %{child_project: child}} =
      Projects.create_subproject(parent.uuid, %{"name" => "Phase One"})

    {:ok, _view, html} = live(conn, path(parent))

    assert html =~ "Phase One"
    assert html =~ "Sub-project"
    refute html =~ child.uuid <> "/edit"
  end

  test "Add sub-project links to the shared add form in sub-project mode", %{conn: conn} do
    parent = fixture_project()
    {:ok, _view, html} = live(conn, path(parent))

    # The button is now a link to AssignmentFormLive's add page in sub-project
    # mode (same page tasks use), not a bespoke modal.
    assert html =~ "Add sub-project"
    assert html =~ "assignments/new?kind=subproject"
  end

  test "the add form in sub-project mode creates a sub-project", %{conn: conn} do
    parent = fixture_project()

    {:ok, view, _html} =
      live(conn, "/en/admin/projects/list/#{parent.uuid}/assignments/new?kind=subproject")

    html =
      view
      |> form("#subproject-form", %{"subproject" => %{"name" => "Design"}})
      |> render_submit()

    # Navigates back to the project on success.
    assert {:error, {:live_redirect, %{to: to}}} = html
    assert to =~ "/list/#{parent.uuid}"

    assert Enum.any?(Projects.list_assignments(parent.uuid), &(&1.child_project_uuid != nil))
  end

  test "expanding a sub-project reveals its (empty) task panel", %{conn: conn} do
    parent = fixture_project()
    {:ok, %{assignment: link}} = Projects.create_subproject(parent.uuid, %{"name" => "Buildout"})

    {:ok, view, _html} = live(conn, path(parent))

    html =
      view
      |> element(~s([phx-click="toggle_subproject"][phx-value-uuid="#{link.uuid}"]))
      |> render_click()

    assert html =~ "No tasks in this sub-project yet."
  end

  test "expanding a sub-project renders its child tasks' dependency badges", %{conn: conn} do
    parent = fixture_project()

    {:ok, %{child_project: child, assignment: link}} =
      Projects.create_subproject(parent.uuid, %{"name" => "Buildout"})

    task_a = fixture_task(%{"title" => "Pour foundation"})
    task_b = fixture_task(%{"title" => "Frame walls"})

    {:ok, a} =
      Projects.create_assignment(%{
        "project_uuid" => child.uuid,
        "task_uuid" => task_a.uuid,
        "status" => "todo"
      })

    {:ok, b} =
      Projects.create_assignment(%{
        "project_uuid" => child.uuid,
        "task_uuid" => task_b.uuid,
        "status" => "todo"
      })

    {:ok, _} = Projects.add_dependency(b.uuid, a.uuid)

    {:ok, view, _html} = live(conn, path(parent))

    html =
      view
      |> element(~s([phx-click="toggle_subproject"][phx-value-uuid="#{link.uuid}"]))
      |> render_click()

    # The dependency lives on the CHILD project, so its deps must be loaded into
    # `deps_by_assignment` (was parent-only) for the inset badge to render.
    assert html =~ "Frame walls"
    assert html =~ "depends on:"
    assert html =~ "Pour foundation"
  end

  test "removing a sub-project row deletes the child and drops the row", %{conn: conn} do
    parent = fixture_project()

    {:ok, %{child_project: child, assignment: link}} =
      Projects.create_subproject(parent.uuid, %{"name" => "Doomed"})

    {:ok, view, _html} = live(conn, path(parent))

    html =
      view
      |> element(~s([phx-click="remove_assignment"][phx-value-uuid="#{link.uuid}"]))
      |> render_click()

    assert html =~ "Task removed."
    refute html =~ "Doomed"
    assert is_nil(Projects.get_project(child.uuid))
  end
end
