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

  describe "each area stays its own (review 2026-10-16)" do
    test "/hours leaves out a sub-project the key cannot read time in", %{
      token: token,
      key: key,
      home: home
    } do
      {:ok, %{child_project: child}} = Projects.create_subproject(home.uuid, %{"name" => "Kid"})
      {:ok, _} = PhoenixKitProjects.Ledger.log_time(home.uuid, 30)
      {:ok, _} = PhoenixKitProjects.Ledger.log_time(child.uuid, 600)

      minutes = fn ->
        api(build_conn(), token)
        |> get("#{@base}/hours")
        |> json_response(200)
        |> get_in(["totals", "minutes"])
      end

      assert minutes.() == 630
      {:ok, _} = ApiKeys.put_grant(key, child.uuid, %{"scopes" => []})
      assert minutes.() == 30
    end

    test "tasks:read alone shows no time, usage or notes on a task", %{
      token: token,
      key: key,
      home: home
    } do
      t = task(home, "Quiet")
      {:ok, _} = PhoenixKitProjects.Ledger.log_time(home.uuid, 45, assignment_uuid: t.uuid)
      {:ok, _} = ApiKeys.put_grant(key, home.uuid, %{"scopes" => ["tasks:read"]})

      %{"task" => one} =
        api(build_conn(), token) |> get("#{@base}/tasks/#{t.uuid}") |> json_response(200)

      refute Map.has_key?(one["totals"] || %{}, "minutes")
      refute Map.has_key?(one["totals"] || %{}, "tokens")
      assert one["latest_agent_note"] == nil

      %{"tasks" => [row]} =
        api(build_conn(), token) |> get("#{@base}/tasks") |> json_response(200)

      refute Map.has_key?(row["totals"] || %{}, "minutes")

      assert %{"project_notes" => [], "events" => []} =
               api(build_conn(), token) |> get("#{@base}/briefing") |> json_response(200)

      {:ok, _} = ApiKeys.put_grant(key, home.uuid, %{"scopes" => ["tasks:read", "time:read"]})

      %{"task" => one} =
        api(build_conn(), token) |> get("#{@base}/tasks/#{t.uuid}") |> json_response(200)

      assert one["totals"]["minutes"] == 45
    end

    test "a sub-project the key cannot reach is not listed on its parent", %{
      token: token,
      key: key,
      home: home
    } do
      {:ok, %{child_project: child}} =
        Projects.create_subproject(home.uuid, %{"name" => "Hidden kid"})

      subs = fn ->
        api(build_conn(), token)
        |> get("#{@base}/project")
        |> json_response(200)
        |> get_in(["project", "subprojects"])
      end

      assert [_] = subs.()
      {:ok, _} = ApiKeys.put_grant(key, child.uuid, %{"scopes" => []})
      assert [] = subs.()
    end

    test "a home the key can no longer use does not block its other projects", %{
      token: token,
      key: key,
      home: home,
      other: other
    } do
      {:ok, _} = ApiKeys.put_grant(key, other.uuid, %{"scopes" => grid("read")})
      {:ok, _} = ApiKeys.put_grant(key, home.uuid, %{"scopes" => []})
      task(other, "Still here")

      assert %{"tasks" => [_]} =
               api(build_conn(), token)
               |> get("#{@base}/tasks?project=#{other.key}")
               |> json_response(200)

      assert %{"error" => %{"code" => "no_access"}} =
               api(build_conn(), token) |> get("#{@base}/tasks") |> json_response(403)

      assert %{"home_refused" => "no_access", "projects" => [_ | _]} =
               api(build_conn(), token) |> get("#{@base}/me") |> json_response(200)

      assert {:error, :no_grant} = ApiKeys.set_home(key, home.uuid)
    end

    test "no grant reaches a template", %{key: key} do
      template =
        fixture_project(%{
          "name" => "Tpl #{System.unique_integer([:positive])}",
          "is_template" => true
        })

      {:ok, _} = ApiKeys.put_grant(key, template.uuid, %{"scopes" => grid("full")})
      assert {:error, :no_access} = ApiKeys.access_for(key, template.uuid)
    end

    test "time:read alone lists time entries, not tokens or cost; /hours sums usage only where every project allows it",
         %{token: token, key: key, home: home} do
      {:ok, %{child_project: child}} = Projects.create_subproject(home.uuid, %{"name" => "Kid"})
      {:ok, _} = PhoenixKitProjects.Ledger.log_time(home.uuid, 30)
      {:ok, _} = PhoenixKitProjects.Ledger.record_ai(home.uuid, %{tokens: 1000, cost_cents: 5})
      {:ok, _} = PhoenixKitProjects.Ledger.record_ai(child.uuid, %{tokens: 99, cost_cents: 1})

      {:ok, _} =
        ApiKeys.put_grant(key, home.uuid, %{"scopes" => ["time:read", "project:read"]})

      %{"entries" => entries} =
        api(build_conn(), token) |> get("#{@base}/entries") |> json_response(200)

      assert Enum.map(entries, & &1["kind"]) == ["time"]

      {:ok, _} = ApiKeys.put_grant(key, home.uuid, %{"scopes" => ["time:read", "usage:read"]})
      {:ok, _} = ApiKeys.put_grant(key, child.uuid, %{"scopes" => ["time:read"]})

      totals =
        api(build_conn(), token)
        |> get("#{@base}/hours")
        |> json_response(200)
        |> Map.get("totals")

      refute Map.has_key?(totals, "tokens")

      :ok = ApiKeys.delete_grant(key, child.uuid)

      totals =
        api(build_conn(), token)
        |> get("#{@base}/hours")
        |> json_response(200)
        |> Map.get("totals")

      assert totals["tokens"] == 1099
    end

    test "a sub-project the key cannot reach has no row in its parent's task list", %{
      token: token,
      key: key,
      home: home
    } do
      {:ok, %{child_project: child}} =
        Projects.create_subproject(home.uuid, %{"name" => "Secret"})

      {:ok, _} = ApiKeys.put_grant(key, child.uuid, %{"scopes" => []})

      %{"tasks" => rows} =
        api(build_conn(), token) |> get("#{@base}/tasks") |> json_response(200)

      refute Enum.any?(rows, &(&1["child_project_uuid"] == child.uuid))
    end

    test "a project move offers only keys whose grant actually reaches the project", %{
      key: key,
      home: home
    } do
      {:ok, %{child_project: child}} =
        Projects.create_subproject(home.uuid, %{"name" => "Moving"})

      scope = fake_scope()

      assert Enum.any?(
               PhoenixKitProjects.ProjectMove.preview(child, scope).keys,
               &(&1.uuid == key.uuid)
             )

      {:ok, _} =
        ApiKeys.put_grant(key, home.uuid, %{"scopes" => grid("full"), "inherit" => false})

      refute Enum.any?(
               PhoenixKitProjects.ProjectMove.preview(child, scope).keys,
               &(&1.uuid == key.uuid)
             )
    end

    test "a malformed project names no project", %{token: token} do
      assert api(build_conn(), token)
             |> post_json("#{@base}/tasks", %{"title" => "x", "project" => %{"a" => 1}})
             |> json_response(404)
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
    test "five keys or fewer: no filters, revoked last; more: filters, revoked hidden until asked",
         %{conn: conn, other: other} do
      max = user("filters")
      {:ok, _} = Members.add_member(other, max.uuid, role: "member")
      conn = put_test_scope(conn, fake_scope(user_uuid: max.uuid, permissions: ["projects"]))

      make = fn name ->
        {:ok, key, _} =
          ApiKeys.create(other, %{"name" => name, "user_uuid" => max.uuid}, actor_uuid: max.uuid)

        key
      end

      old = make.("Old one")
      {:ok, _} = ApiKeys.revoke(old, [])
      for n <- 1..3, do: make.("Key #{n}")

      {:ok, view, html} = live(conn, "/en/admin/projects/api-keys")
      refute has_element?(view, "#api-key-filters")
      # revoked sorts after the active ones
      [first | _] = Regex.scan(~r/id="api-key-([0-9a-f-]{36})"/, html) |> Enum.map(&List.last/1)
      refute first == old.uuid

      for n <- 4..6, do: make.("Key #{n}")

      {:ok, view, _html} = live(conn, "/en/admin/projects/api-keys")
      assert has_element?(view, "#api-key-filters")
      refute has_element?(view, "#api-key-#{old.uuid}")
      # only the filters that tell these keys apart: all personal, one project
      assert has_element?(view, "#api-key-filter-form select[name='status']")
      refute has_element?(view, "#api-key-filter-form select[name='kind']")
      refute has_element?(view, "#api-key-filter-form select[name='project']")

      view |> form("#api-key-filter-form", %{"status" => "revoked"}) |> render_change()
      assert_patch(view, "/en/admin/projects/api-keys?status=revoked")
      assert has_element?(view, "#api-key-#{old.uuid}")
      assert render(view) =~ "1 of 7 keys"

      view |> form("#api-key-filter-form", %{"status" => "all"}) |> render_change()
      assert has_element?(view, "#api-key-#{old.uuid}")

      {:ok, view, _html} = live(conn, "/en/admin/projects/api-keys?status=all&q=key 4")
      assert render(view) =~ "1 of 7 keys"
    end

    test "a change to a key's access says it was saved", %{conn: conn, other: other} do
      max = user("feedback")
      {:ok, _} = Members.add_member(other, max.uuid, role: "member")
      conn = put_test_scope(conn, fake_scope(user_uuid: max.uuid, permissions: ["projects"]))

      {:ok, key, _} =
        ApiKeys.create(other, %{"name" => "Helper", "user_uuid" => max.uuid},
          actor_uuid: max.uuid
        )

      {:ok, view, _} = live(conn, "/en/admin/projects/api-keys")

      html =
        view
        |> form("#preset-#{key.uuid}-#{other.uuid}", preset: "read")
        |> render_change()

      assert html =~ "Saved: Helper in"
      assert html =~ "Read only"
    end

    test "an administrator sees everyone's keys at once", %{conn: conn, key: key} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, html} = live(conn, "/en/admin/projects/api-keys")

      assert has_element?(view, "#api-key-#{key.uuid}")
      refute html =~ "Show everyone"
    end

    test "a project's owner manages only that project's row of someone else's key", %{
      conn: conn,
      other: other,
      stranger: stranger
    } do
      owner = user("owner")
      ada = user("ada")
      {:ok, _} = Members.add_member(other, owner.uuid, role: "owner")
      for p <- [other, stranger], do: {:ok, _} = Members.add_member(p, ada.uuid, role: "member")

      {:ok, key, _} =
        ApiKeys.create(stranger, %{"name" => "Ada's AI", "user_uuid" => ada.uuid},
          actor_uuid: ada.uuid
        )

      {:ok, _} = ApiKeys.put_grant(key, other.uuid, %{"scopes" => grid("full")})

      conn = put_test_scope(conn, fake_scope(user_uuid: owner.uuid, permissions: ["projects"]))
      {:ok, view, _html} = live(conn, "/en/admin/projects/api-keys")

      # the owner's project, not Ada's other one; no rotate or revoke
      assert has_element?(view, "#grant-#{key.uuid}-#{other.uuid}")
      refute has_element?(view, "#grant-#{key.uuid}-#{stranger.uuid}")
      refute has_element?(view, "#api-key-#{key.uuid} button[phx-click='revoke']")

      view
      |> form("#preset-#{key.uuid}-#{other.uuid}", preset: "read")
      |> render_change()

      assert {:ok, %{scopes: scopes}} = ApiKeys.access_for(key, other.uuid)
      refute "tasks:write" in scopes

      # a forged change to the row they do not own is ignored
      render_change(view, "set_preset", %{
        "key" => key.uuid,
        "project" => stranger.uuid,
        "preset" => "none"
      })

      assert {:ok, _} = ApiKeys.access_for(key, stranger.uuid)
      render_click(view, "revoke", %{"key" => key.uuid})
      assert is_nil(ApiKeys.get(key.uuid).revoked_at)
    end

    test "on Usage, an owner sees someone else's key only in their own project", %{
      conn: conn,
      other: other,
      stranger: stranger
    } do
      owner = user("usage-owner")
      ada = user("usage-ada")
      {:ok, _} = Members.add_member(other, owner.uuid, role: "owner")
      for p <- [other, stranger], do: {:ok, _} = Members.add_member(p, ada.uuid, role: "member")

      {:ok, key, _} =
        ApiKeys.create(stranger, %{"name" => "Ada's AI", "user_uuid" => ada.uuid},
          actor_uuid: ada.uuid
        )

      {:ok, _} = ApiKeys.put_grant(key, other.uuid, %{"scopes" => grid("full")})
      for _ <- 1..3, do: PhoenixKitProjects.ApiUsage.record(key.uuid, other.uuid, 200)
      for _ <- 1..40, do: PhoenixKitProjects.ApiUsage.record(key.uuid, stranger.uuid, 200)

      conn = put_test_scope(conn, fake_scope(user_uuid: owner.uuid, permissions: ["projects"]))
      {:ok, view, _html} = live(conn, "/en/admin/projects/api-keys/usage")

      assert has_element?(view, "#usage-by-key", "3 requests")
      refute render(view) =~ "43 requests"
      refute render(view) =~ "40 requests"
    end

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

    test "a project picked in Add a project survives a change on another row; Default shows only with two",
         %{conn: conn, other: other} do
      max = user("draft")
      third = fixture_project(%{"name" => "Third #{System.unique_integer([:positive])}"})
      for p <- [other, third], do: {:ok, _} = Members.add_member(p, max.uuid, role: "member")
      conn = put_test_scope(conn, fake_scope(user_uuid: max.uuid, permissions: ["projects"]))

      {:ok, key, _} =
        ApiKeys.create(other, %{"name" => "Agent", "user_uuid" => max.uuid}, actor_uuid: max.uuid)

      {:ok, view, html} = live(conn, "/en/admin/projects/api-keys")
      refute html =~ "Make default"

      view
      |> form("#grant-add-#{key.uuid}", grant: %{project: third.uuid, preset: "read"})
      |> render_change()

      html =
        view
        |> form("#preset-#{key.uuid}-#{other.uuid}", preset: "read")
        |> render_change()

      assert {:ok, %{scopes: scopes}} = ApiKeys.access_for(key, other.uuid)
      refute "tasks:write" in scopes

      assert html =~
               ~r/<option[^>]*selected[^>]*value="#{third.uuid}"|<option[^>]*value="#{third.uuid}"[^>]*selected/

      view |> form("#grant-add-#{key.uuid}") |> render_submit()
      assert render(view) =~ "Set as default"
    end
  end
end
