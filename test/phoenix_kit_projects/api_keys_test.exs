defmodule PhoenixKitProjects.ApiKeysTest do
  @moduledoc "The credential lifecycle of a project API key (chain V17)."

  use PhoenixKitProjects.DataCase, async: false

  import Ecto.Query

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{ApiKeys, Authz, Members}
  alias PhoenixKitProjects.Schemas.ApiKey

  setup do
    {:ok, project: fixture_project()}
  end

  defp user_fixture do
    {:ok, user} =
      Auth.register_user(%{
        email: "keys-#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    user
  end

  describe "a personal key acts for a member" do
    test "its role is the person's current membership, capped by the key and by manager",
         %{project: project} do
      owner = user_fixture()
      {:ok, _} = Members.add_member(project, owner.uuid, role: "owner")

      {:ok, key, _} =
        ApiKeys.create(project, %{"name" => "Owner's AI", "user_uuid" => owner.uuid},
          actor_uuid: owner.uuid
        )

      assert ApiKey.kind(key) == :personal
      assert ApiKey.accountable_uuid(key) == owner.uuid
      # an owner's key acts as a manager, never as the owner
      assert {:ok, "manager"} = ApiKeys.effective_role(key, project)
      assert {:ok, %ApiKey{role: "manager"}} = ApiKeys.resolve(key, project)

      # demotion propagates at once; a viewer cap holds whatever the membership says
      {:ok, _} = Members.add_member(project, user_fixture().uuid, role: "owner")
      {:ok, _} = Members.change_role(project, owner.uuid, "viewer")
      assert {:ok, "viewer"} = ApiKeys.effective_role(key, project)

      {:ok, capped, _} =
        ApiKeys.create(project, %{
          "name" => "Read-only AI",
          "role" => "viewer",
          "user_uuid" => owner.uuid
        })

      {:ok, _} = Members.change_role(project, owner.uuid, "manager")
      assert {:ok, "viewer"} = ApiKeys.effective_role(capped, project)
      assert {:ok, "manager"} = ApiKeys.effective_role(key, project)

      # a shared key keeps its stored role and names its minter
      {:ok, shared, _} = ApiKeys.create(project, %{"name" => "CI", "role" => "member"})
      assert ApiKey.kind(shared) == :shared
      assert {:ok, "member"} = ApiKeys.effective_role(shared, project)
      assert ApiKey.accountable_uuid(shared) == nil
    end

    test "leaving the project ends the person's keys", %{project: project} do
      owner = user_fixture()
      member = user_fixture()
      {:ok, _} = Members.add_member(project, owner.uuid, role: "owner")
      {:ok, _} = Members.add_member(project, member.uuid, role: "member")

      {:ok, key, token} =
        ApiKeys.create(project, %{"name" => "Mine", "user_uuid" => member.uuid})

      {:ok, other, _} = ApiKeys.create(project, %{"name" => "Theirs", "user_uuid" => owner.uuid})
      assert [%ApiKey{uuid: uuid}] = ApiKeys.list_for_user(project.uuid, member.uuid)
      assert uuid == key.uuid

      {:ok, _} = Members.remove_member(project, member.uuid, actor_uuid: owner.uuid)

      assert ApiKeys.list_for_user(project.uuid, member.uuid) == []
      assert {:error, :revoked} = ApiKeys.authenticate(token)
      assert_activity_logged("projects.api_key_revoked", resource_uuid: project.uuid)
      assert ApiKeys.get(other.uuid).revoked_at == nil

      # a key that somehow outlives the membership is refused at resolve time
      assert {:error, :membership_ended} = ApiKeys.effective_role(key, project)
    end
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

  test "a pending reservation is never reclaimed by age: a live request keeps its key", %{
    project: project
  } do
    {:ok, key, _} = ApiKeys.create(project, %{"name" => "k"})
    parent = self()

    first =
      Task.async(fn ->
        ApiKeys.idempotent(key, "live-slow", fn ->
          send(parent, :reserved)

          receive do
            :finish -> {201, %{"owner" => "first"}}
          after
            5_000 -> raise "test timed out"
          end
        end)
      end)

    assert_receive :reserved, 1_000

    # ten minutes "pass": a slow database call or provider outlives any timeout,
    # so the clock must not hand the key to a second run of the same work
    PhoenixKit.RepoHelper.repo().update_all(
      from(i in PhoenixKitProjects.Schemas.ApiIdempotency,
        where: i.api_key_uuid == ^key.uuid and i.idempotency_key == "live-slow"
      ),
      set: [inserted_at: DateTime.add(DateTime.utc_now(), -600, :second)]
    )

    assert {:ok, 409, %{error: %{code: "in_progress"}}} =
             ApiKeys.idempotent(key, "live-slow", fn -> raise "must not run" end)

    send(first.pid, :finish)
    assert {:ok, 201, %{"owner" => "first"}} = Task.await(first)

    # the first request's answer is the one that is stored and replayed
    assert {:replay, 201, %{"owner" => "first"}} =
             ApiKeys.idempotent(key, "live-slow", fn -> raise "must replay" end)
  end

  describe "a personal key needs its person's live account" do
    test "a deactivated account's key is refused at resolve", %{project: project} do
      user = user_fixture()
      {:ok, _} = Members.add_member(project, user.uuid, role: "owner")
      {:ok, key, _} = ApiKeys.create(project, %{"name" => "Mine", "user_uuid" => user.uuid})
      assert {:ok, _} = ApiKeys.resolve(key, project)

      {:ok, _} =
        user |> Ecto.Changeset.change(is_active: false) |> PhoenixKit.RepoHelper.repo().update()

      assert {:error, :account_inactive} = ApiKeys.resolve(key, project)

      # a shared key has no account to check
      {:ok, shared, _} = ApiKeys.create(project, %{"name" => "CI"})
      assert {:ok, _} = ApiKeys.resolve(shared, project)
    end

    test "deleting the account revokes its keys on every project", %{project: project} do
      other = fixture_project()
      user = user_fixture()
      {:ok, _} = Members.add_member(project, user.uuid, role: "member")
      {:ok, a, token} = ApiKeys.create(project, %{"name" => "A", "user_uuid" => user.uuid})
      {:ok, b, _} = ApiKeys.create(other, %{"name" => "B", "user_uuid" => user.uuid})
      {:ok, shared, _} = ApiKeys.create(project, %{"name" => "CI"})

      :ok = Members.handle_user_deletion(user.uuid)

      assert {:error, :revoked} = ApiKeys.authenticate(token)
      assert %DateTime{} = ApiKeys.get(a.uuid).revoked_at
      assert %DateTime{} = ApiKeys.get(b.uuid).revoked_at
      assert ApiKeys.get(shared.uuid).revoked_at == nil
    end
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
