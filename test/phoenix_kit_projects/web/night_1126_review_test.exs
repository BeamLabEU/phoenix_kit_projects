defmodule PhoenixKitProjects.Web.Night1126ReviewTest do
  @moduledoc """
  The panel's night review of PR #66 (codex, 2026-11-26), each case a
  defect it found and that was then fixed: `ApiKeys.access_map/2` with a
  malformed uuid, a personal key's grants read per grant on `GET /me`, the
  briefing's latest notes read per row, a `#` search with a project context
  reaching past a template, mention visibility ignoring the role the viewer
  switched to, and a crafted zone event crashing the project form.
  """
  use PhoenixKitProjects.LiveCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Users.{Auth, RolePermission, Roles}
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitProjects.{ApiKeys, Authz, Members, Projects, QueryCounter, ResourceLinks}
  alias PhoenixKitProjects.Schemas.Project
  alias PhoenixKitProjects.Test.Repo

  defp register_user! do
    {:ok, user} =
      Auth.register_user(%{
        email: "pr66-#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    user
  end

  defp child!(parent, name) do
    {:ok, %{child_project: child}} = Projects.create_subproject(parent.uuid, %{"name" => name})
    child
  end

  test "a bad lookup does not change valid answers across a grant tree" do
    root = fixture_project()
    leaf = child!(root, "Inherited reader")

    [stop, below_stop, empty, below_empty, ended, below_ended] =
      Enum.scan(1..6, root, fn depth, parent -> child!(parent, "Depth #{depth}") end)

    user = register_user!()
    {:ok, _} = Members.add_member(root, user.uuid, role: "owner")
    {:ok, _} = Members.add_member(stop, user.uuid, role: "manager")
    {:ok, shared, _} = ApiKeys.create(root, %{"name" => "Shared", "role" => "manager"})

    {:ok, personal, _} =
      ApiKeys.create(root, %{"name" => "Personal", "role" => "manager", "user_uuid" => user.uuid})

    keys = [%{shared | project_uuid: nil}, personal]

    for key <- keys do
      {:ok, _} =
        ApiKeys.put_grant(key, stop.uuid, %{
          "scopes" => ["tasks:read"],
          "role" => "viewer",
          "inherit" => false
        })

      {:ok, _} = ApiKeys.put_grant(key, empty.uuid, %{"scopes" => []})
      {:ok, _} = ApiKeys.put_grant(key, ended.uuid, %{"scopes" => ["tasks:read"]})
    end

    uuids =
      Enum.map([root, leaf, stop, below_stop, empty, below_empty, ended, below_ended], & &1.uuid)

    for key <- keys do
      batch = ApiKeys.access_map(key, uuids)
      assert batch == Map.new(uuids, &{&1, ApiKeys.access_for(key, &1)})
      assert {:ok, %{role: "manager"}} = batch[leaf.uuid]
      assert {:ok, %{role: "viewer"}} = batch[stop.uuid]

      for denied <- [below_stop, empty, below_empty] do
        assert batch[denied.uuid] == {:error, :no_access}
      end

      if key.user_uuid do
        assert batch[ended.uuid] == {:error, :membership_ended}
        assert batch[below_ended.uuid] == {:error, :membership_ended}
      else
        assert {:ok, _} = batch[below_ended.uuid]
      end
    end

    for key <- keys do
      single = ApiKeys.access_for(key, leaf.uuid)
      assert ApiKeys.access_map(key, uuids ++ ["not-a-uuid"])[leaf.uuid] == single
    end
  end

  test "listing personal grants does not add membership queries per grant" do
    user = register_user!()

    projects = for _ <- 1..8, do: fixture_project()
    [home | others] = projects
    {:ok, key, _} = ApiKeys.create(home, %{"name" => "Personal", "user_uuid" => user.uuid})

    for project <- projects do
      {:ok, _} = Members.add_member(project, user.uuid, role: "member")
    end

    child!(home, "Home child")

    {:ok, _} =
      ApiKeys.put_grant(key, home.uuid, %{"scopes" => ["tasks:read"], "inherit" => true})

    {few, few_reads} = QueryCounter.count(fn -> ApiKeys.reachable(key) end)
    assert length(few) == 2

    for project <- others do
      child!(project, "Child")

      {:ok, _} =
        ApiKeys.put_grant(key, project.uuid, %{"scopes" => ["tasks:read"], "inherit" => true})
    end

    {many, many_reads} = QueryCounter.count(fn -> ApiKeys.reachable(key) end)
    assert length(many) == 16
    assert many_reads <= few_reads + 1, "#{few_reads} queries for 1 grant, #{many_reads} for 8"
  end

  test "briefing does not add note lookups for each shown subproject" do
    {:ok, _} = PhoenixKit.Settings.update_setting("comments_enabled", "true")
    root = fixture_project()
    {:ok, _key, token} = ApiKeys.create(root, %{"name" => "Briefing reader"})

    child!(root, "First")
    child!(root, "Second")

    request = fn ->
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("accept", "application/json")
      |> get("/api/projects/v1/briefing")
      |> json_response(200)
    end

    {few, few_reads} = QueryCounter.count(request)
    assert length(few["tasks"]) == 2

    for index <- 3..8, do: child!(root, "Child #{index}")

    {many, many_reads} = QueryCounter.count(request)
    assert length(many["tasks"]) == 8
    assert many_reads <= few_reads + 1, "#{few_reads} queries for 2 rows, #{many_reads} for 8"
  end

  test "task list does not refetch missing inline files per row" do
    root = fixture_project()
    {:ok, _key, token} = ApiKeys.create(root, %{"name" => "Task reader"})
    description = "![missing](pkfile:#{Ecto.UUID.generate()})"

    add_task = fn i ->
      {:ok, _} =
        Projects.create_task_with_assignment(
          root.uuid,
          %{"title" => "Task #{i}", "ad_hoc" => true},
          %{"description" => description}
        )
    end

    request = fn ->
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("accept", "application/json")
      |> get("/api/projects/v1/tasks")
      |> json_response(200)
    end

    Enum.each(1..2, add_task)
    {few, few_reads} = QueryCounter.count(request)
    assert length(few["tasks"]) == 2
    assert Enum.all?(few["tasks"], &(&1["description"] == description))

    Enum.each(3..8, add_task)
    {many, many_reads} = QueryCounter.count(request)
    assert length(many["tasks"]) == 8
    assert many_reads <= few_reads + 1, "#{few_reads} queries for 2 rows, #{many_reads} for 8"
  end

  test "contextual mentions honor the template boundary" do
    user = register_user!()
    root = fixture_project()
    {:ok, _} = Members.add_member(root, user.uuid, role: "member")

    scope =
      fake_scope(user_uuid: user.uuid, email: user.email, permissions: ["projects"], roles: [])

    {:ok, %{child_project: middle}} =
      Projects.create_subproject(root.uuid, %{"name" => "Middle"})

    {:ok, %{child_project: hidden}} =
      Projects.create_subproject(middle.uuid, %{"name" => "Hiddenneedle"})

    {1, _} =
      Repo.update_all(from(p in Project, where: p.uuid == ^middle.uuid),
        set: [is_template: true]
      )

    refute Authz.can?(scope, hidden, :view)
    assert ResourceLinks.visible_resource_uuids([hidden.uuid], scope: scope) == []
    assert ResourceLinks.search_resources("Hiddenneedle", scope: scope) == []

    assert ResourceLinks.search_resources("Hiddenneedle",
             scope: scope,
             context: %{"project" => root.uuid}
           ) == []
  end

  test "everyone-project mentions use the supplied session role" do
    {:ok, _} = PhoenixKit.Settings.update_boolean_setting("role_switcher_enabled", true)
    project = fixture_project(%{"settings" => %{"visibility" => "everyone"}})

    results =
      for default_has_access <- [true, false] do
        user = register_user!()
        n = System.unique_integer([:positive])
        {:ok, first} = Roles.create_role(%{"name" => "First-#{n}"})
        {:ok, second} = Roles.create_role(%{"name" => "Second-#{n}"})
        {:ok, _} = Roles.assign_role(user, first.name)
        {:ok, _} = Roles.assign_role(user, second.name)
        grants_access = if default_has_access, do: first, else: second
        Repo.insert!(%RolePermission{role_uuid: grants_access.uuid, module_key: "projects"})

        scope = Scope.for_user(%{user | active_role_uuid: second.uuid})
        assert Authz.can?(scope, project, :view) == !default_has_access
        assert Authz.can?(user.uuid, project, :view) == default_has_access

        ResourceLinks.visible_resource_uuids([project.uuid], scope: scope)
      end

    assert results == [[], [project.uuid]]
  end

  test "project form ignores a zone hook event with a missing zone", %{conn: conn} do
    conn = put_test_scope(conn, fake_scope())
    {:ok, view, _html} = live(conn, "/en/admin/projects/new")
    assert is_binary(render_hook(view, "pkp_zone", %{}))
  end
end
