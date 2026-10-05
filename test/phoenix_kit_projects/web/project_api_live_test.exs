defmodule PhoenixKitProjects.Web.ProjectApiLiveTest do
  @moduledoc "\"Your API key\": every member's own keys, one click to mint, nobody else's shown."

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{ApiKeys, Members}
  alias PhoenixKitProjects.Schemas.ApiKey

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

  test "create my key, see it, rotate it; another person's key stays out of sight", %{
    conn: conn,
    project: project,
    user: user
  } do
    {:ok, other} =
      Auth.register_user(%{
        email: "other-#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    {:ok, _} = Members.add_member(project, other.uuid, role: "member")
    {:ok, _theirs, _} = ApiKeys.create(project, %{"name" => "Theirs", "user_uuid" => other.uuid})
    {:ok, _shared, _} = ApiKeys.create(project, %{"name" => "ANDI agent"})

    {:ok, view, html} = live(conn, "/en/admin/projects/#{project.uuid}/api")
    assert html =~ "Your API key"
    assert html =~ "Create my key"
    assert html =~ "/api/projects/v1/llms.txt"
    refute html =~ "Theirs"
    refute html =~ "ANDI agent"
    # an owner also gets the way to the whole list
    assert html =~ "All keys on this project"

    html = render_click(view, "create_my_key", %{})

    assert [%ApiKey{} = key] = ApiKeys.list_for_user(project.uuid, user.uuid)
    assert key.name == "Max Don's AI"
    assert key.role == "manager"
    assert key.created_by_uuid == user.uuid
    assert key.scopes == ApiKey.scopes()

    # the modal: the token once, the prompt naming the person
    assert html =~ "Key created — copy it now"
    assert html =~ "pkp_#{key.key_id}_"
    assert html =~ "You act for Max Don on this project"

    html = render_click(view, "dismiss_api_token", %{})
    refute html =~ "pkp_#{key.key_id}_"
    assert html =~ "ID pkp_#{key.key_id}"
    assert html =~ "owners&#39; keys act as managers"
    refute html =~ "Create my key"
    assert html =~ ~s(id="api-key-prompt-#{key.uuid}")

    html = render_click(view, "rotate_api_key", %{"uuid" => key.uuid})
    assert html =~ "Key rotated"
    rotated = ApiKeys.get(key.uuid)
    assert rotated.key_id != key.key_id
    assert html =~ "pkp_#{rotated.key_id}_"

    # revoking takes it off the page and brings the button back
    render_click(view, "dismiss_api_token", %{})
    html = render_click(view, "revoke_api_key", %{"uuid" => key.uuid})
    assert html =~ "Create my key"
    assert %DateTime{} = ApiKeys.get(key.uuid).revoked_at
  end

  test "a crafted event cannot touch someone else's key", %{conn: conn, project: project} do
    {:ok, other} =
      Auth.register_user(%{
        email: "other-#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    {:ok, _} = Members.add_member(project, other.uuid, role: "member")
    {:ok, theirs, _} = ApiKeys.create(project, %{"name" => "Theirs", "user_uuid" => other.uuid})

    {:ok, view, _} = live(conn, "/en/admin/projects/#{project.uuid}/api")
    html = render_click(view, "revoke_api_key", %{"uuid" => theirs.uuid})
    assert html =~ "Could not revoke the key."
    assert ApiKeys.get(theirs.uuid).revoked_at == nil
  end

  test "a site admin who is not a member can look but not mint", %{conn: conn} do
    project = fixture_project()
    admin = fake_scope()

    {:ok, view, html} =
      live(put_test_scope(conn, admin), "/en/admin/projects/#{project.uuid}/api")

    assert html =~ "not a member of this project"

    html = render_click(view, "create_my_key", %{})
    assert html =~ "Only a member of the project can have a key"
    assert ApiKeys.list_for_project(project.uuid) == []
  end
end
