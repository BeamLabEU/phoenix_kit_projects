defmodule PhoenixKitProjects.Web.ProjectMembersLiveTest do
  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.Members

  setup %{conn: conn} do
    PhoenixKitProjects.Extensions.Registry.refresh()
    conn = put_test_scope(conn, fake_scope())
    project = fixture_project()

    {:ok, user} =
      Auth.register_user(%{
        email: "lv-member-#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    {:ok, conn: conn, project: project, user: user}
  end

  defp path(project), do: "/en/admin/projects/list/#{project.uuid}/members"

  test "renders the empty state", %{conn: conn, project: project} do
    {:ok, _view, html} = live(conn, path(project))
    assert html =~ "Members"
    assert html =~ "No members yet"
  end

  test "adds a member by email; row appears with the role", %{
    conn: conn,
    project: project,
    user: user
  } do
    {:ok, view, _} = live(conn, path(project))

    html =
      render_submit(view, "add_member", %{"email" => user.email, "role" => "manager"})

    assert html =~ user.email
    assert Members.role_of(project, user.uuid) == :manager
  end

  test "unknown email flashes without creating anything", %{conn: conn, project: project} do
    {:ok, view, _} = live(conn, path(project))

    html =
      render_submit(view, "add_member", %{"email" => "ghost@example.com", "role" => "member"})

    assert html =~ "No account with that email address."
    assert Members.list_members(project.uuid) == []
  end

  test "the last owner cannot be demoted from the UI", %{
    conn: conn,
    project: project,
    user: user
  } do
    {:ok, _} = Members.add_member(project, user.uuid, role: "owner")
    {:ok, view, _} = live(conn, path(project))

    html = render_change(view, "change_role", %{"user" => user.uuid, "role" => "viewer"})
    assert html =~ "at least one owner"
    assert Members.role_of(project, user.uuid) == :owner
  end

  test "an invalid role param collapses to member, never crashes", %{
    conn: conn,
    project: project,
    user: user
  } do
    {:ok, view, _} = live(conn, path(project))

    render_submit(view, "add_member", %{"email" => user.email, "role" => "superadmin"})
    assert Members.role_of(project, user.uuid) == :member
  end

  test "a scope without the projects permission is bounced", %{project: project} do
    conn =
      Phoenix.ConnTest.build_conn()
      |> put_test_scope(fake_scope(permissions: []))

    {:error, {:live_redirect, %{to: to}}} = live(conn, path(project))
    assert to =~ "/admin/projects"
  end

  test "templates bounce", %{conn: conn} do
    template = fixture_template()
    {:error, {:live_redirect, %{to: _}}} = live(conn, path(template))
  end
end
