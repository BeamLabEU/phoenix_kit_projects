defmodule PhoenixKitProjects.Web.SubprojectLinkScopeTest do
  @moduledoc """
  "Nest an existing project" offers, and accepts, only projects the viewer
  can see. The picker listed every project on the site, and the save took
  any uuid the client sent — a private project could be listed by name and
  nested under one the viewer could edit.
  """
  use PhoenixKitProjects.LiveCase, async: false

  import Phoenix.LiveViewTest

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{Members, Projects}

  setup %{conn: conn} do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "link-scope-#{System.unique_integer([:positive])}@example.com",
        "password" => "ActorPass123!"
      })

    parent = fixture_project(%{"name" => "Parent #{System.unique_integer([:positive])}"})
    visible = fixture_project(%{"name" => "Visible #{System.unique_integer([:positive])}"})
    hidden = fixture_project(%{"name" => "Hidden #{System.unique_integer([:positive])}"})

    {:ok, _} = Members.add_member(parent, user.uuid, role: "owner")
    {:ok, _} = Members.add_member(visible, user.uuid, role: "viewer")

    member = fake_scope(user_uuid: user.uuid, permissions: ["projects"], roles: [])

    {:ok,
     conn: put_test_scope(conn, member),
     member: member,
     user: user,
     parent: parent,
     visible: visible,
     hidden: hidden}
  end

  defp names(projects), do: Enum.map(projects, & &1.name)

  test "the picker lists only what the viewer can see; a site admin sees everything", ctx do
    offered = names(Projects.available_projects_to_link(ctx.parent, ctx.member))
    assert ctx.visible.name in offered
    refute ctx.hidden.name in offered

    admin = fake_scope(user_uuid: ctx.user.uuid)
    offered = names(Projects.available_projects_to_link(ctx.parent, admin))
    assert ctx.hidden.name in offered
  end

  test "a submit naming a project the viewer cannot see is refused, nothing nested", ctx do
    {:ok, view, html} =
      live(ctx.conn, "/en/admin/projects/#{ctx.parent.uuid}/assignments/new?kind=subproject")

    refute html =~ ctx.hidden.name

    render_submit(view, "save_subproject", %{"link_child_uuid" => ctx.hidden.uuid})

    assert render(view) =~ "be nested here."

    refute Enum.any?(
             Projects.list_assignments(ctx.parent.uuid),
             &(&1.child_project_uuid == ctx.hidden.uuid)
           )
  end

  test "templates stay a shared library: template nesting is not narrowed", ctx do
    parent = fixture_project(%{"is_template" => "true", "name" => "T-parent"})
    other = fixture_project(%{"is_template" => "true", "name" => "T-child"})

    assert other.name in names(Projects.available_projects_to_link(parent, ctx.member))
  end
end
