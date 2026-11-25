defmodule PhoenixKitProjects.Web.SubprojectAccessTest do
  @moduledoc """
  A sub-project is read by whoever can read a project above it (Max,
  2026-11-25): the parent's page already shows its tasks in the inset, and
  its Open link led to "Project not found". Only `:view` is inherited —
  editing still follows the sub-project's own roles.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{Authz, Members, Projects}

  setup do
    # The first account of a fresh database is the Owner: someone else.
    _owner = embed_user_uuid!()

    {:ok, user} =
      Auth.register_user(%{
        "email" => "sub-access-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    parent = fixture_project(%{"name" => "Parent"})
    {:ok, %{child_project: child}} = Projects.create_subproject(parent.uuid, %{"name" => "Child"})

    {:ok, %{child_project: grandchild}} =
      Projects.create_subproject(child.uuid, %{"name" => "Grandchild"})

    scope = fake_scope(user_uuid: user.uuid, permissions: ["projects"], roles: [])
    %{user: user, scope: scope, parent: parent, child: child, grandchild: grandchild}
  end

  test "a member of the parent may view the sub-projects below it, not edit them", ctx do
    {:ok, _} = Members.add_member(ctx.parent, ctx.user.uuid, role: "manager")

    assert Authz.can?(ctx.scope, ctx.child, :view)
    assert Authz.can?(ctx.scope, ctx.grandchild, :view)
    refute Authz.can?(ctx.scope, ctx.child, :edit_tasks)
    refute Authz.can?(ctx.scope, ctx.child, :delete_project)
  end

  test "someone with no seat above the sub-project gets nothing", ctx do
    refute Authz.can?(ctx.scope, ctx.child, :view)
    refute Authz.can?(ctx.scope, ctx.grandchild, :view)
  end

  test "a member of the sub-project only does not see its parent", ctx do
    {:ok, _} = Members.add_member(ctx.child, ctx.user.uuid, role: "member")

    assert Authz.can?(ctx.scope, ctx.child, :view)
    assert Authz.can?(ctx.scope, ctx.grandchild, :view)
    refute Authz.can?(ctx.scope, ctx.parent, :view)
  end

  test "the sub-project's page opens for a parent's member", %{conn: conn} = ctx do
    {:ok, _} = Members.add_member(ctx.parent, ctx.user.uuid, role: "member")
    conn = put_test_scope(conn, ctx.scope)

    assert {:ok, _view, html} = live(conn, "/en/admin/projects/#{ctx.child.uuid}")
    assert html =~ "Child"
  end

  test "the listing with sub-projects includes the nested ones for a parent's member", ctx do
    {:ok, _} = Members.add_member(ctx.parent, ctx.user.uuid, role: "member")
    _other = fixture_project(%{"name" => "Elsewhere"})

    names =
      [viewer: ctx.user.uuid, include_subprojects: true]
      |> Projects.list_projects()
      |> Enum.map(& &1.name)
      |> Enum.sort()

    # "Elsewhere" exists but is nobody's here: never listed.
    assert names == ["Child", "Grandchild", "Parent"]
  end

  test "nothing is inherited through a template", ctx do
    {:ok, _} = Members.add_member(ctx.parent, ctx.user.uuid, role: "member")
    {:ok, _} = Projects.update_project(ctx.parent, %{"is_template" => true})

    refute Authz.can?(ctx.scope, Projects.get_project(ctx.child.uuid), :view)
  end

  test "nothing is inherited past a template in the middle", ctx do
    {:ok, _} = Members.add_member(ctx.parent, ctx.user.uuid, role: "member")
    {:ok, _} = Projects.update_project(ctx.child, %{"is_template" => true})

    refute Authz.can?(ctx.scope, ctx.child.uuid, :view)
    refute Authz.can?(ctx.scope, Projects.get_project(ctx.grandchild.uuid), :view)

    assert Enum.map(
             Projects.list_projects(viewer: ctx.user.uuid, include_subprojects: true),
             & &1.uuid
           ) ==
             [ctx.parent.uuid]
  end
end
