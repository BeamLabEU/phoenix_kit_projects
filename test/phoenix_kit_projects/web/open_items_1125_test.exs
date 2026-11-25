defmodule PhoenixKitProjects.Web.OpenItems1125Test do
  @moduledoc """
  Three items left open by the 2026-11-25 reviews:

    * `GET /hours` sums tokens and cost over the projects the key may read
      usage in (one sub-project without it used to hide them for the whole
      answer), and names those projects;
    * the key's access to many projects is read in a fixed number of
      statements (`ApiKeys.access_map/2`), so `GET /tasks`, `/hours` and
      `/me` do not grow with the number of sub-projects;
    * a member of only a sub-project resolves that project's records in
      mentions (`ResourceLinks`), as its pages already let them.
  """

  use PhoenixKitProjects.LiveCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{ApiKeys, Ledger, Members, Projects, QueryCounter, ResourceLinks}
  alias PhoenixKitProjects.Test.Repo

  @base "/api/projects/v1"

  defp api(conn, token) do
    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("accept", "application/json")
  end

  defp user! do
    {:ok, user} =
      Auth.register_user(%{
        email: "open-#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    user
  end

  defp subprojects!(parent, n) do
    for i <- 1..n do
      {:ok, %{child_project: child}} =
        Projects.create_subproject(parent.uuid, %{
          "name" => "Child #{System.unique_integer([:positive])} #{i}"
        })

      child
    end
  end

  describe "GET /hours usage" do
    test "tokens and cost cover the projects the key may read usage in", %{conn: conn} do
      _owner = user!()
      project = fixture_project()
      [child] = subprojects!(project, 1)
      {:ok, key, token} = ApiKeys.create(project, %{"name" => "Reporter", "role" => "member"})

      # Time but not usage in the sub-project.
      {:ok, _} = ApiKeys.put_grant(key, child.uuid, %{"scopes" => ["time:read", "tasks:read"]})

      {:ok, _} =
        Ledger.record_ai(project.uuid, %{tokens: 900, cost_cents: 3, agent_uuid: key.uuid})

      {:ok, _} = Ledger.record_ai(child.uuid, %{tokens: 100, cost_cents: 1, agent_uuid: key.uuid})

      body = conn |> api(token) |> get("#{@base}/hours") |> json_response(200)

      assert body["totals"]["tokens"] == 900
      assert body["totals"]["cost_cents"] == 3
      assert body["usage_projects"] == [project.uuid]
    end

    test "with usage everywhere the totals are the whole tree's", %{conn: conn} do
      _owner = user!()
      project = fixture_project()
      [child] = subprojects!(project, 1)
      {:ok, key, token} = ApiKeys.create(project, %{"name" => "Reporter", "role" => "member"})

      {:ok, _} =
        Ledger.record_ai(project.uuid, %{tokens: 900, cost_cents: 3, agent_uuid: key.uuid})

      {:ok, _} = Ledger.record_ai(child.uuid, %{tokens: 100, cost_cents: 1, agent_uuid: key.uuid})

      body = conn |> api(token) |> get("#{@base}/hours") |> json_response(200)

      assert body["totals"]["tokens"] == 1000
      assert Enum.sort(body["usage_projects"]) == Enum.sort([project.uuid, child.uuid])
    end
  end

  describe "batched access" do
    test "access_map reads the same however many sub-projects there are" do
      _owner = user!()
      project = fixture_project()
      {:ok, key, _token} = ApiKeys.create(project, %{"name" => "Reader", "role" => "member"})

      few = subprojects!(project, 2)

      {map, small} =
        QueryCounter.count(fn -> ApiKeys.access_map(key, Enum.map(few, & &1.uuid)) end)

      assert Enum.all?(Map.values(map), &match?({:ok, _}, &1))

      many = few ++ subprojects!(project, 8)

      {map, large} =
        QueryCounter.count(fn -> ApiKeys.access_map(key, Enum.map(many, & &1.uuid)) end)

      assert map_size(map) == 10 and Enum.all?(Map.values(map), &match?({:ok, _}, &1))

      assert large <= small + 1, "#{small} statements for 2 sub-projects, #{large} for 10"
    end

    test "access_map agrees with access_for, a blocking grant included" do
      _owner = user!()
      project = fixture_project()
      [open, blocked] = subprojects!(project, 2)
      {:ok, key, _token} = ApiKeys.create(project, %{"name" => "Reader", "role" => "member"})
      {:ok, _} = ApiKeys.put_grant(key, blocked.uuid, %{"scopes" => []})
      other = fixture_project()

      uuids = [project.uuid, open.uuid, blocked.uuid, other.uuid, Ecto.UUID.generate()]
      map = ApiKeys.access_map(key, uuids)

      for uuid <- uuids do
        assert match?({:ok, _}, map[uuid]) == match?({:ok, _}, ApiKeys.access_for(key, uuid)),
               "disagree on #{uuid}"
      end

      assert {:error, :no_access} = map[blocked.uuid]
      assert {:ok, _} = map[open.uuid]
      assert {:error, :no_access} = map[other.uuid]
    end

    test "GET /tasks reads the same however many sub-project rows it lists", %{conn: conn} do
      _owner = user!()
      project = fixture_project()
      {:ok, _key, token} = ApiKeys.create(project, %{"name" => "Reader", "role" => "member"})
      subprojects!(project, 2)

      {_, small} =
        QueryCounter.count(fn ->
          conn |> api(token) |> get("#{@base}/tasks") |> json_response(200)
        end)

      subprojects!(project, 8)

      {body, large} =
        QueryCounter.count(fn ->
          conn |> api(token) |> get("#{@base}/tasks") |> json_response(200)
        end)

      assert length(body["tasks"]) == 10
      # A little slack for caching; one walk per row would add dozens.
      assert large <= small + 6, "#{small} statements for 2 sub-project rows, #{large} for 10"
    end
  end

  describe "mentions inside a sub-project" do
    setup do
      _owner = user!()
      parent = fixture_project()
      [child] = subprojects!(parent, 1)

      {:ok, %{assignment: row}} =
        Projects.create_task_with_assignment(
          child.uuid,
          %{"title" => "Inner task", "ad_hoc" => true},
          %{}
        )

      %{parent: parent, child: child, row: row}
    end

    defp member_scope(project) do
      user = user!()
      if project, do: {:ok, _} = Members.add_member(project, user.uuid, role: "member")
      fake_scope(user_uuid: user.uuid, email: user.email, permissions: ["projects"], roles: [])
    end

    test "a member of only the sub-project resolves its records", ctx do
      scope = member_scope(ctx.child)

      assert Enum.sort(
               ResourceLinks.visible_resource_uuids([ctx.child.uuid, ctx.row.uuid], scope: scope)
             ) ==
               Enum.sort([ctx.child.uuid, ctx.row.uuid])

      refute ResourceLinks.visible_resource_uuids([ctx.parent.uuid], scope: scope) == [
               ctx.parent.uuid
             ]

      assert ResourceLinks.search_resources("Inner", scope: scope) != []
    end

    test "a member of the parent resolves the sub-project's records too", ctx do
      scope = member_scope(ctx.parent)

      assert Enum.sort(
               ResourceLinks.visible_resource_uuids([ctx.child.uuid, ctx.row.uuid], scope: scope)
             ) ==
               Enum.sort([ctx.child.uuid, ctx.row.uuid])
    end

    test "an outsider resolves nothing", ctx do
      scope = member_scope(nil)

      assert ResourceLinks.visible_resource_uuids([ctx.parent.uuid, ctx.child.uuid, ctx.row.uuid],
               scope: scope
             ) == []

      assert ResourceLinks.search_resources("Inner", scope: scope) == []
    end

    # zai, 2026-11-25: the page's inherited view stops at a template
    # ancestor; mentions (and the lists) now stop there too.
    test "nothing at or under a template nested in the project resolves", ctx do
      scope = member_scope(ctx.parent)

      {:ok, %{child_project: deeper}} =
        Projects.create_subproject(ctx.child.uuid, %{"name" => "Below the template"})

      {1, _} =
        Repo.update_all(
          from(p in PhoenixKitProjects.Schemas.Project, where: p.uuid == ^ctx.child.uuid),
          set: [is_template: true]
        )

      assert ResourceLinks.visible_resource_uuids(
               [ctx.child.uuid, ctx.row.uuid, deeper.uuid],
               scope: scope
             ) == []

      refute PhoenixKitProjects.Authz.can?(scope, Projects.get_project(deeper.uuid), :view)
      assert PhoenixKitProjects.Authz.can?(scope, Projects.get_project(ctx.parent.uuid), :view)
    end
  end
end
