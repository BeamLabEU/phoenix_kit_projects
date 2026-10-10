defmodule PhoenixKitProjects.Web.MoveProjectLiveTest do
  @moduledoc """
  The "Move…" dialog (`Components.MoveProject`) on the project page and on
  the projects list.
  """

  use PhoenixKitProjects.LiveCase, async: false

  import Phoenix.LiveViewTest

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{Members, Projects}

  setup %{conn: conn} do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "mover-#{System.unique_integer([:positive])}@example.com",
        "password" => "ActorPass123!"
      })

    {:ok, conn: put_test_scope(conn, fake_scope(user_uuid: user.uuid)), user: user}
  end

  defp child!(parent, name) do
    {:ok, %{child_project: child}} = Projects.create_subproject(parent.uuid, %{"name" => name})
    child
  end

  test "a sub-project's own menu moves it out, taking the parent's members", ctx do
    parent = fixture_project(%{"name" => "Parent Co"})
    child = child!(parent, "Editor")
    {:ok, _} = Members.add_member(parent.uuid, ctx.user.uuid, role: "owner")

    {:ok, view, html} = live(ctx.conn, "/en/admin/projects/#{child.uuid}")
    assert html =~ "Move…"

    html = render_click(view, "move_project_open", %{"uuid" => child.uuid})
    assert html =~ "Make it its own project"
    assert html =~ "Now a sub-project of"
    assert html =~ "Parent Co"
    assert html =~ "1 member"

    assert {:error, {:live_redirect, %{to: to}}} =
             view
             |> form("#move-project-form-#{child.uuid}", %{"place" => "top", "members" => "true"})
             |> render_submit()

    assert to =~ child.uuid
    assert Projects.subproject_link(child.uuid) == nil
    assert Members.role_of(child.uuid, ctx.user.uuid) == :owner
    assert_activity_logged("projects.project_moved", resource_uuid: child.uuid)
  end

  test "the parent's row offers Move out and the row goes", ctx do
    parent = fixture_project()
    child = child!(parent, "Phase One")

    {:ok, view, html} = live(ctx.conn, "/en/admin/projects/#{parent.uuid}")
    assert html =~ "Move out…"
    refute html =~ "Make standalone"

    render_click(view, "move_project_open", %{"uuid" => child.uuid})

    html =
      view
      |> form("#move-project-form-#{child.uuid}", %{"place" => "top"})
      |> render_submit()

    assert html =~ "is now its own project"
    assert Projects.child_projects(parent.uuid) == []
  end

  test "the list nests a project under another; no place chosen is an error", ctx do
    a = fixture_project(%{"name" => "Alpha Move"})
    b = fixture_project(%{"name" => "Beta Move"})

    {:ok, view, _html} = live(ctx.conn, "/en/admin/projects")
    html = render_click(view, "move_project_open", %{"uuid" => a.uuid})
    assert html =~ "Put it under another project"
    refute html =~ "Make it its own project"

    html = view |> form("#move-project-form-#{a.uuid}", %{}) |> render_submit()
    assert html =~ "Choose where the project goes."

    view
    |> form("#move-project-form-#{a.uuid}", %{"place" => "under"})
    |> render_change()

    html =
      view
      |> form("#move-project-form-#{a.uuid}", %{"place" => "under", "parent" => b.uuid})
      |> render_submit()

    assert html =~ "is now under"
    assert [%{uuid: parent_uuid}] = Projects.parent_chain(a.uuid)
    assert parent_uuid == b.uuid
  end

  test "a viewer who may not change the project's settings gets no dialog", ctx do
    project = fixture_project()
    child = child!(project, "Locked")
    {:ok, _} = Members.add_member(child.uuid, ctx.user.uuid, role: "viewer")

    conn =
      put_test_scope(ctx.conn, fake_scope(user_uuid: ctx.user.uuid, permissions: ["projects"]))

    {:ok, view, _html} = live(conn, "/en/admin/projects/#{child.uuid}")
    html = render_click(view, "move_project_open", %{"uuid" => child.uuid})

    refute html =~ "Make it its own project"
    assert Projects.subproject_link(child.uuid)
  end
end
