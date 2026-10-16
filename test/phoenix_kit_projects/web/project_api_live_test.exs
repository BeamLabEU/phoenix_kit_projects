defmodule PhoenixKitProjects.Web.ProjectApiLiveTest do
  @moduledoc "\"Your API key\": a read-only view of the viewer's own keys reaching the project; nobody else's shown."

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{ApiKeys, Members}

  setup %{conn: conn} do
    {:ok, user} =
      Auth.register_user(%{
        email: "me-#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!",
        first_name: "Max",
        last_name: "Don"
      })

    project = fixture_project()
    {:ok, _} = Members.add_member(project, user.uuid, role: "owner")

    # a plain member, not a site admin: the page is for everyone
    scope = fake_scope(user_uuid: user.uuid, email: user.email, permissions: ["projects"])
    {:ok, conn: put_test_scope(conn, scope), project: project, user: user}
  end

  test "my own key shows with its access here; another person's and a shared key stay out of sight",
       %{conn: conn, project: project, user: user} do
    {:ok, other} =
      Auth.register_user(%{
        email: "other-#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    {:ok, _} = Members.add_member(project, other.uuid, role: "member")
    {:ok, _theirs, _} = ApiKeys.create(project, %{"name" => "Theirs", "user_uuid" => other.uuid})
    {:ok, _shared, _} = ApiKeys.create(project, %{"name" => "ANDI agent"})

    {:ok, _view, html} = live(conn, "/en/admin/projects/#{project.uuid}/api")
    assert html =~ "Your API key"
    assert html =~ "None of your keys reach this project"
    assert html =~ "/api/projects/v1/llms.txt"
    refute html =~ "Theirs"
    refute html =~ "ANDI agent"
    # an owner also gets the way to the whole list
    assert html =~ "All keys reaching this project"

    {:ok, mine, _} = ApiKeys.create(project, %{"name" => "My AI", "user_uuid" => user.uuid})

    {:ok, _view, html} = live(conn, "/en/admin/projects/#{project.uuid}/api")
    assert html =~ ~s(id="my-key-#{mine.uuid}")
    assert html =~ "My AI"
    assert html =~ "ID pkp_#{mine.key_id}"
    assert html =~ "Access here"
    assert html =~ "set on this project"
    assert html =~ ~s(id="api-key-prompt-#{mine.uuid}")
    refute html =~ "Theirs"

    # the links out, and nothing to mint, rotate or revoke here
    assert html =~ "Manage your API keys"
    assert html =~ "New key for this project"
    assert html =~ "/admin/projects/api-keys?project=#{project.uuid}"
    refute html =~ "rotate_api_key"
    refute html =~ "revoke_api_key"
    refute html =~ "create_my_key"
  end

  test "a key granted on a parent shows as inherited on the sub-project", %{
    conn: conn,
    user: user
  } do
    parent = fixture_project()
    {:ok, _} = Members.add_member(parent, user.uuid, role: "owner")
    child = fixture_project()
    {:ok, _} = PhoenixKitProjects.Projects.link_subproject(parent.uuid, child.uuid)
    {:ok, _} = Members.add_member(child, user.uuid, role: "owner")
    {:ok, key, _} = ApiKeys.create(parent, %{"name" => "Parent AI", "user_uuid" => user.uuid})

    {:ok, _view, html} = live(conn, "/en/admin/projects/#{child.uuid}/api")
    assert html =~ ~s(id="my-key-#{key.uuid}")
    assert html =~ "from #{parent.name}"
  end

  test "a site admin who is not a member sees no keys and no way to mint here", %{conn: conn} do
    project = fixture_project()
    admin = fake_scope()

    {:ok, _view, html} =
      live(put_test_scope(conn, admin), "/en/admin/projects/#{project.uuid}/api")

    assert html =~ "None of your keys reach this project"
    refute html =~ "create_my_key"
  end
end
