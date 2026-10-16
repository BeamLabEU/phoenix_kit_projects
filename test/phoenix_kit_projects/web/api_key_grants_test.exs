defmodule PhoenixKitProjects.Web.ApiKeyGrantsTest do
  @moduledoc """
  API keys across projects (chain V24): a key's access is per project, per
  area (none / read / write), the nearest grant up a project's tree
  decides, and every request is checked against the project it acts on —
  never against the key's home.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{ApiAccess, ApiKeys, Members, Projects}

  @base "/api/projects/v1"

  defp user(name) do
    {:ok, u} =
      Auth.register_user(%{
        email: "#{name}-#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    u
  end

  defp api(conn, token) do
    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("accept", "application/json")
    |> put_req_header("content-type", "application/json")
  end

  defp post_json(conn, path, body, headers \\ []) do
    Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    |> post(path, Jason.encode!(body))
  end

  defp patch_json(conn, path, body), do: patch(conn, path, Jason.encode!(body))

  defp grid(preset) do
    {_k, _l, grid} = Enum.find(ApiAccess.presets(), fn {k, _l, _g} -> k == preset end)
    ApiAccess.scopes(grid)
  end

  defp task(project, title) do
    {:ok, %{assignment: a}} =
      Projects.create_task_with_assignment(
        project.uuid,
        %{"title" => title, "ad_hoc" => true},
        %{}
      )

    a
  end

  # A shared manager key homed on `home` with full access there, plus
  # whatever grants the test adds.
  setup do
    home = fixture_project(%{"name" => "Home #{System.unique_integer([:positive])}"})
    other = fixture_project(%{"name" => "Other #{System.unique_integer([:positive])}"})
    stranger = fixture_project(%{"name" => "Stranger #{System.unique_integer([:positive])}"})
    minter = user("minter")

    {:ok, key, token} =
      ApiKeys.create(home, %{"name" => "Agent", "role" => "manager"}, actor_uuid: minter.uuid)

    {:ok, home: home, other: other, stranger: stranger, key: key, token: token}
  end

  describe "the grant rules" do
    test "a new key has one grant: its project, at full", %{home: home, key: key} do
      assert [g] = ApiKeys.grants(key)
      assert g.project_uuid == home.uuid
      assert Enum.sort(g.scopes) == Enum.sort(grid("full"))
      assert {:ok, %{role: "manager"}} = ApiKeys.access_for(key, home.uuid)
    end

    test "the nearest grant decides; a sub-project inherits unless told not to, or set to no access",
         %{home: home, key: key} do
      {:ok, %{child_project: child}} = Projects.create_subproject(home.uuid, %{"name" => "Child"})
      assert {:ok, _} = ApiKeys.access_for(key, child.uuid)

      {:ok, _} = ApiKeys.put_grant(key, child.uuid, %{"scopes" => []})
      assert {:error, :no_access} = ApiKeys.access_for(key, child.uuid)

      {:ok, _} = ApiKeys.put_grant(key, child.uuid, %{"scopes" => grid("read")})
      assert {:ok, %{scopes: scopes}} = ApiKeys.access_for(key, child.uuid)
      refute "tasks:write" in scopes

      :ok = ApiKeys.delete_grant(key, child.uuid)

      {:ok, _} =
        ApiKeys.put_grant(key, home.uuid, %{"scopes" => grid("full"), "inherit" => false})

      assert {:error, :no_access} = ApiKeys.access_for(key, child.uuid)
      assert {:ok, _} = ApiKeys.access_for(key, home.uuid)
    end

    test "a personal key's grant follows its person's role there; leaving takes only that project",
         %{home: home, other: other} do
      max = user("max")
      {:ok, _} = Members.add_member(home, max.uuid, role: "member")
      {:ok, _} = Members.add_member(other, max.uuid, role: "viewer")

      {:ok, key, _token} =
        ApiKeys.create(home, %{"name" => "Max's AI", "user_uuid" => max.uuid},
          actor_uuid: max.uuid
        )

      {:ok, _} = ApiKeys.put_grant(key, other.uuid, %{"scopes" => grid("full")})

      assert {:ok, %{role: "member"}} = ApiKeys.access_for(key, home.uuid)
      assert {:ok, %{role: "viewer"}} = ApiKeys.access_for(key, other.uuid)

      {:ok, _} = Members.remove_member(other, max.uuid)
      assert {:error, _} = ApiKeys.access_for(key, other.uuid)
      assert {:ok, _} = ApiKeys.access_for(key, home.uuid)
      assert is_nil(ApiKeys.get(key.uuid).revoked_at)
    end

    test "deleting the home project keeps the key and its other grants", %{
      home: home,
      other: other,
      key: key
    } do
      {:ok, _} = ApiKeys.put_grant(key, other.uuid, %{"scopes" => grid("read")})
      {:ok, _} = Projects.delete_project(home)

      assert %{} = ApiKeys.get(key.uuid)
      assert [%{project_uuid: uuid}] = ApiKeys.grants(key)
      assert uuid == other.uuid
    end
  end

  describe "the API, per project" do
    test "a read-only project: reads work, writes are refused there, and home is untouched",
         %{conn: conn, token: token, key: key, other: other} do
      {:ok, _} = ApiKeys.put_grant(key, other.uuid, %{"scopes" => grid("read")})
      t = task(other, "Their task")
      c = api(conn, token)

      assert %{"tasks" => [_]} =
               c |> get("#{@base}/tasks?project=#{other.uuid}") |> json_response(200)

      assert %{"task" => _} = c |> get("#{@base}/tasks/#{t.uuid}") |> json_response(200)

      assert %{"error" => %{"code" => "scope_missing"}} =
               c
               |> post_json("#{@base}/tasks?project=#{other.uuid}", %{"title" => "Sneak"})
               |> json_response(403)

      assert %{"error" => %{"code" => "scope_missing"}} =
               c
               |> patch_json("#{@base}/tasks/#{t.uuid}", %{"title" => "Renamed"})
               |> json_response(403)

      assert %{"error" => %{"code" => "scope_missing"}} =
               c |> post_json("#{@base}/tasks/#{t.uuid}/complete", %{}) |> json_response(403)

      assert %{"task" => _} =
               c |> post_json("#{@base}/tasks", %{"title" => "Mine"}) |> json_response(201)
    end

    test "a right only the target project grants still works (the project is chosen first)",
         %{conn: conn, token: token, key: key, home: home, other: other} do
      {:ok, _} =
        ApiKeys.put_grant(key, home.uuid, %{"scopes" => grid("none") ++ ["project:read"]})

      {:ok, _} = ApiKeys.put_grant(key, other.uuid, %{"scopes" => grid("read")})
      task(other, "Visible")

      assert %{"tasks" => [_]} =
               api(conn, token)
               |> get("#{@base}/tasks?project=#{other.key}")
               |> json_response(200)
    end

    test "a project the key has no grant on is not there", %{
      conn: conn,
      token: token,
      stranger: stranger
    } do
      t = task(stranger, "Hidden")
      c = api(conn, token)

      assert c |> get("#{@base}/tasks?project=#{stranger.uuid}") |> json_response(404)
      assert c |> get("#{@base}/tasks/#{t.uuid}") |> json_response(404)
    end

    test "/me lists every project the key reaches with its access per area",
         %{conn: conn, token: token, key: key, home: home, other: other} do
      {:ok, _} = ApiKeys.put_grant(key, other.uuid, %{"scopes" => ["comments:read"]})

      %{"home_project" => %{"uuid" => home_uuid}, "projects" => projects} =
        api(conn, token) |> get("#{@base}/me") |> json_response(200)

      assert home_uuid == home.uuid
      by = Map.new(projects, &{&1["uuid"], &1})
      assert by[home.uuid]["access"]["tasks"] == "write"
      assert by[other.uuid]["access"]["comments"] == "read"
      assert by[other.uuid]["access"]["tasks"] == "none"
    end

    test "the same Idempotency-Key on two projects is two requests",
         %{conn: conn, token: token, key: key, other: other} do
      {:ok, _} = ApiKeys.put_grant(key, other.uuid, %{"scopes" => grid("full")})
      c = api(conn, token)
      headers = [{"idempotency-key", "same-one"}]

      %{"task" => a} =
        c |> post_json("#{@base}/tasks", %{"title" => "Home task"}, headers) |> json_response(201)

      %{"task" => b} =
        api(build_conn(), token)
        |> post_json("#{@base}/tasks?project=#{other.uuid}", %{"title" => "Other task"}, headers)
        |> json_response(201)

      refute a["uuid"] == b["uuid"]
    end
  end

  describe "comments" do
    setup do
      {:ok, _} = PhoenixKit.Settings.update_setting("comments_enabled", "true")
      on_exit(fn -> PhoenixKit.Settings.update_setting("comments_enabled", "false") end)
      :ok
    end

    test "a key reads and posts a task's discussion with the comments area", %{
      conn: conn,
      token: token,
      home: home,
      key: key
    } do
      t = task(home, "Discussed")
      c = api(conn, token)

      %{"comment" => posted} =
        c
        |> post_json("#{@base}/tasks/#{t.uuid}/comments", %{"content" => "Looks done"}, [
          {"idempotency-key", "c1"}
        ])
        |> json_response(201)

      assert posted["content"] == "Looks done"

      %{"comments" => [read]} =
        api(build_conn(), token) |> get("#{@base}/tasks/#{t.uuid}/comments") |> json_response(200)

      assert read["uuid"] == posted["uuid"]

      {:ok, _} =
        ApiKeys.put_grant(key, home.uuid, %{"scopes" => grid("full") -- ["comments:write"]})

      assert %{"error" => %{"code" => "scope_missing"}} =
               api(build_conn(), token)
               |> post_json("#{@base}/tasks/#{t.uuid}/comments", %{"content" => "No"}, [
                 {"idempotency-key", "c2"}
               ])
               |> json_response(403)
    end
  end

  describe "the API keys page" do
    test "a person makes a key, gives it a second project read-only, and takes it away", %{
      conn: conn,
      other: other
    } do
      max = user("page")
      {:ok, _} = Members.add_member(other, max.uuid, role: "member")
      conn = put_test_scope(conn, fake_scope(user_uuid: max.uuid, permissions: ["projects"]))
      start = fixture_project(%{"name" => "Start #{System.unique_integer([:positive])}"})
      {:ok, _} = Members.add_member(start, max.uuid, role: "member")

      {:ok, view, html} = live(conn, "/en/admin/projects/api-keys?project=#{start.uuid}")
      assert html =~ "API keys"

      view
      |> form("#api-key-new", key: %{name: "Max's AI", project: start.uuid, preset: "full"})
      |> render_submit()

      assert render(view) =~ "copy it now"
      [key] = ApiKeys.list_mine(max.uuid)
      assert key.user_uuid == max.uuid

      view
      |> form("#grant-add-#{key.uuid}", grant: %{project: other.uuid, preset: "read"})
      |> render_submit()

      assert {:ok, %{scopes: scopes}} = ApiKeys.access_for(key, other.uuid)
      refute "tasks:write" in scopes

      view
      |> element("button[phx-click='remove_grant'][phx-value-project='#{other.uuid}']")
      |> render_click()

      assert {:error, _} = ApiKeys.access_for(key, other.uuid)
    end
  end
end
