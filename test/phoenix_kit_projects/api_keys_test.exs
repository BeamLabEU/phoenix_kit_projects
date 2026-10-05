defmodule PhoenixKitProjects.ApiKeysTest do
  @moduledoc "The credential lifecycle of a project API key (chain V17)."

  use PhoenixKitProjects.DataCase, async: false

  alias PhoenixKitProjects.{ApiKeys, Authz}
  alias PhoenixKitProjects.Schemas.ApiKey

  setup do
    {:ok, project: fixture_project()}
  end

  test "create, authenticate, list, revoke", %{project: project} do
    assert {:ok, key, token} =
             ApiKeys.create(project, %{"name" => "  Claude  ", "role" => "manager"})

    assert key.name == "Claude"
    assert key.role == "manager"
    assert key.scopes == ApiKey.scopes()
    assert String.starts_with?(token, "pkp_#{key.key_id}_")
    refute String.contains?(key.secret_hash, String.replace(token, "pkp_#{key.key_id}_", ""))
    assert_activity_logged("projects.api_key_created", resource_uuid: project.uuid)

    assert {:ok, found} = ApiKeys.authenticate(token)
    assert found.uuid == key.uuid

    assert {:error, :malformed} = ApiKeys.authenticate("nope")
    assert {:error, :malformed} = ApiKeys.authenticate(nil)
    assert {:error, :unknown} = ApiKeys.authenticate("pkp_#{key.key_id}_wrongsecret")
    assert {:error, :unknown} = ApiKeys.authenticate("pkp_unknownid_whatever")

    assert [%ApiKey{uuid: uuid}] = ApiKeys.list_for_project(project.uuid)
    assert uuid == key.uuid
    assert ApiKeys.get_for_project(project.uuid, key.uuid).uuid == key.uuid
    assert ApiKeys.get_for_project(fixture_project().uuid, key.uuid) == nil

    assert {:ok, revoked} = ApiKeys.revoke(key, [])
    assert %DateTime{} = revoked.revoked_at
    assert {:error, :revoked} = ApiKeys.authenticate(token)
    assert {:error, :revoked} = ApiKeys.rotate(revoked, [])
    assert_activity_logged("projects.api_key_revoked", resource_uuid: project.uuid)
  end

  test "the role and scopes are validated; owner is never a key's role", %{project: project} do
    assert {:error, cs} = ApiKeys.create(project, %{"name" => "x", "role" => "owner"})
    assert %{role: _} = errors_on(cs)

    assert {:error, cs} =
             ApiKeys.create(project, %{"name" => "x", "scopes" => ["tasks:read", "everything"]})

    assert %{scopes: _} = errors_on(cs)

    assert {:error, cs} = ApiKeys.create(project, %{"name" => "x", "scopes" => []})
    assert %{scopes: _} = errors_on(cs)

    assert {:error, cs} = ApiKeys.create(project, %{"name" => ""})
    assert %{name: _} = errors_on(cs)
  end

  test "a key's role is its own: the floors answer from it alone", %{project: project} do
    assert Authz.can_role?(project, "viewer", :view)
    # The default floors let anyone with access create tasks …
    assert Authz.can_role?(project, "viewer", :create_tasks)
    # … and a project's own override is honoured, like it is for people.
    {:ok, narrowed} = Authz.set_overrides(project, %{"create_tasks" => "managers"})
    refute Authz.can_role?(narrowed, "viewer", :create_tasks)
    refute Authz.can_role?(narrowed, "member", :create_tasks)
    assert Authz.can_role?(narrowed, "manager", :create_tasks)
    refute Authz.can_role?(project, "member", :manage_members)
    assert Authz.can_role?(project, :manager, :edit_tasks)
    refute Authz.can_role?(project, "owner-ish", :view)
    refute Authz.can_role?(nil, "manager", :view)
  end

  test "idempotency stores the first answer and replays it", %{project: project} do
    {:ok, key, _token} = ApiKeys.create(project, %{"name" => "k"})
    counter = :counters.new(1, [])

    fun = fn ->
      :counters.add(counter, 1, 1)
      {201, %{"n" => :counters.get(counter, 1)}}
    end

    assert {:ok, 201, %{"n" => 1}} = ApiKeys.idempotent(key, "abc", fun)
    assert {:replay, 201, %{"n" => 1}} = ApiKeys.idempotent(key, "abc", fun)
    assert {:ok, 201, %{"n" => 2}} = ApiKeys.idempotent(key, "def", fun)
    assert {:ok, 201, %{"n" => 3}} = ApiKeys.idempotent(key, nil, fun)

    # Another key with the same header is its own series.
    {:ok, other, _} = ApiKeys.create(project, %{"name" => "k2"})
    assert {:ok, 201, %{"n" => 4}} = ApiKeys.idempotent(other, "abc", fun)
  end

  test "last_used_at moves at most once a minute", %{project: project} do
    {:ok, key, _} = ApiKeys.create(project, %{"name" => "k"})
    assert key.last_used_at == nil

    touched = ApiKeys.touch_last_used(key)
    assert %DateTime{} = touched.last_used_at

    again = ApiKeys.touch_last_used(touched)
    assert again.last_used_at == touched.last_used_at
  end
end
