defmodule PhoenixKitProjects.Web.ProjectMembersLiveTest do
  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Roles
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

  describe "group access (indirect grants)" do
    alias PhoenixKitProjects.{Authz, Grants, Projects}

    test "granting a site role gives its holders the role, and says who it reaches", %{
      conn: conn,
      project: project,
      user: user
    } do
      {:ok, role} =
        Roles.create_role(%{
          name: "UiContractor-#{System.unique_integer([:positive])}"
        })

      {:ok, _} = Roles.assign_role(user, role.name)
      refute Authz.can?(user.uuid, project, :view)

      {:ok, view, html} = live(conn, path(project))
      assert html =~ "Groups with access"

      html =
        render_submit(view, "add_grant", %{"subject" => "role:#{role.uuid}", "role" => "viewer"})

      assert html =~ role.name
      # Blast radius, including the part people forget.
      assert html =~ "1 person now"
      assert html =~ "anyone added later"

      assert Authz.effective_role(project, user.uuid) == :viewer
      # A viewer participates by default; the container stays the owner's.
      assert Authz.can?(user.uuid, project, :create_tasks)
      refute Authz.can?(user.uuid, project, :manage_members)
    end

    test "revoking removes the access", %{conn: conn, project: project, user: user} do
      {:ok, role} =
        Roles.create_role(%{
          name: "UiRevoke-#{System.unique_integer([:positive])}"
        })

      {:ok, _} = Roles.assign_role(user, role.name)
      {:ok, grant} = Grants.grant(project, "role", role.uuid, "viewer")
      assert Authz.can?(user.uuid, project, :view)

      {:ok, view, _} = live(conn, path(project))
      render_click(view, "revoke_grant", %{"uuid" => grant.uuid})

      refute Authz.can?(user.uuid, project, :view)
    end

    test "a grant uuid from ANOTHER project can't be revoked through this page", %{
      conn: conn,
      project: project,
      user: user
    } do
      other = fixture_project(%{"name" => "Other-#{System.unique_integer([:positive])}"})

      {:ok, role} =
        Roles.create_role(%{
          name: "UiCross-#{System.unique_integer([:positive])}"
        })

      {:ok, _} = Roles.assign_role(user, role.name)
      {:ok, foreign} = Grants.grant(other, "role", role.uuid, "viewer")

      {:ok, view, _} = live(conn, path(project))
      render_click(view, "revoke_grant", %{"uuid" => foreign.uuid})

      # Untouched — the handler scopes the uuid to the project on screen.
      assert Authz.can?(user.uuid, other, :view)
      assert length(Grants.list_grants(other.uuid)) == 1
    end

    test "a malformed subject is refused rather than stored", %{conn: conn, project: project} do
      {:ok, view, _} = live(conn, path(project))

      render_submit(view, "add_grant", %{
        "subject" => "wizard:#{Ecto.UUID.generate()}",
        "role" => "viewer"
      })

      render_submit(view, "add_grant", %{"subject" => "", "role" => "viewer"})

      assert Grants.list_grants(project.uuid) == []
    end

    test "a grant whose subject was deleted is labelled, not hidden", %{
      conn: conn,
      project: project
    } do
      {:ok, _} = Grants.grant(project, "team", Ecto.UUID.generate(), "viewer")

      {:ok, _view, html} = live(conn, path(project))
      assert html =~ "(deleted group)"
    end

    test "the project's own page still lists it for a group-granted viewer", %{
      project: project,
      user: user
    } do
      {:ok, role} =
        Roles.create_role(%{
          name: "UiList-#{System.unique_integer([:positive])}"
        })

      {:ok, _} = Roles.assign_role(user, role.name)
      {:ok, _} = Grants.grant(project, "role", role.uuid, "viewer")

      scope = fake_scope(user_uuid: user.uuid, permissions: ["projects"])
      names = Projects.list_projects_for(scope) |> Enum.map(& &1.name)
      assert project.name in names
    end
  end
end
