defmodule PhoenixKitProjects.Web.ApiTest do
  @moduledoc """
  The JSON API (`/api/projects/v1`) driven through the test router, which
  mirrors `Web.Routes.generate/1`'s API scope: auth, the role floors, the
  scopes, the feature gates, every task call, the ledger appends with their
  idempotency, the project status, and the docs.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Mentions
  alias PhoenixKit.Mentions.Token
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{ApiKeys, Authz, Extensions, Features, Ledger, Projects, TaskNotes}
  alias PhoenixKitProjects.Test.Repo

  @base "/api/projects/v1"

  setup do
    project = fixture_project()
    task = fixture_task(%{"title" => "Wire the API"})

    {:ok, assignment} =
      Projects.create_assignment(%{
        "project_uuid" => project.uuid,
        "task_uuid" => task.uuid,
        "status" => "todo"
      })

    {:ok, key, token} = ApiKeys.create(project, %{"name" => "Claude runner", "role" => "member"})

    {:ok, project: project, assignment: assignment, key: key, token: token}
  end

  defp api(conn, token) do
    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("accept", "application/json")
    |> put_req_header("content-type", "application/json")
  end

  defp post_json(conn, path, body, headers \\ []) do
    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    post(conn, path, Jason.encode!(body))
  end

  defp patch_json(conn, path, body), do: patch(conn, path, Jason.encode!(body))

  defp idem, do: [{"idempotency-key", Ecto.UUID.generate()}]

  # ── Auth ────────────────────────────────────────────────────────

  test "no key, a wrong key and a revoked key all answer the same 401", %{
    conn: conn,
    key: key,
    token: token
  } do
    assert %{"error" => %{"code" => "unauthorized"}} =
             conn |> get("#{@base}/me") |> json_response(401)

    assert %{"error" => %{"code" => "unauthorized"}} =
             conn |> api("pkp_nope_nope") |> get("#{@base}/me") |> json_response(401)

    {:ok, _} = ApiKeys.revoke(key, [])

    assert %{"error" => %{"code" => "unauthorized"}} =
             conn |> api(token) |> get("#{@base}/me") |> json_response(401)
  end

  test "the docs need no key", %{conn: conn} do
    docs_conn = get(conn, "#{@base}/llms.txt")
    assert get_resp_header(docs_conn, "content-type") |> hd() =~ "text/markdown"
    md = response(docs_conn, 200)
    assert md =~ "# Projects API v1"
    assert md =~ "Idempotency-Key"
    assert md =~ "POST /tasks/{id}/usage"
    assert md =~ "cost_cents"

    spec = conn |> get("#{@base}/openapi.json") |> json_response(200)
    assert spec["openapi"] == "3.1.0"
    assert Map.has_key?(spec["paths"], "/tasks/{id}/transition")
    assert get_in(spec, ["paths", "/tasks/{id}/time", "post", "operationId"]) == "logTaskTime"
  end

  # ── /me ─────────────────────────────────────────────────────────

  test "/me says who the key is and what it may do", %{conn: conn, token: token, project: project} do
    body = conn |> api(token) |> get("#{@base}/me") |> json_response(200)

    assert body["key"]["name"] == "Claude runner"
    assert body["key"]["role"] == "member"
    assert "usage:write" in body["key"]["scopes"]
    assert body["project"]["uuid"] == project.uuid
    assert body["features"]["tasks"] == true
    assert "view" in body["allowed_actions"]
    assert "create_tasks" in body["allowed_actions"]
    refute "manage_members" in body["allowed_actions"]
    assert body["docs"]["llms_txt"] =~ "/api/projects/v1/llms.txt"
  end

  # ── Tasks ───────────────────────────────────────────────────────

  test "list, read, create, edit and move a task", %{conn: conn, token: token, assignment: a} do
    c = api(conn, token)

    %{"tasks" => [listed], "count" => 1} = c |> get("#{@base}/tasks") |> json_response(200)
    assert listed["uuid"] == a.uuid
    assert listed["title"] == "Wire the API"
    assert listed["status"] == "todo"
    assert listed["allowed_transitions"] == ["in_progress", "done"]
    assert listed["library_task"] == true

    %{"task" => one} = c |> get("#{@base}/tasks/#{a.uuid}") |> json_response(200)
    assert one["uuid"] == a.uuid

    # Create: a one-off task at the bottom, unstarted.
    %{"task" => created} =
      c
      |> post_json("#{@base}/tasks", %{
        title: "Write the tests",
        description: "cover every call",
        priority: "high",
        estimated_duration: 2,
        estimated_duration_unit: "hours"
      })
      |> json_response(201)

    assert created["status"] == "todo"
    assert created["priority"] == "high"
    assert created["description"] == "cover every call"
    assert created["library_task"] == false
    assert_activity_logged("projects.assignment_created", resource_uuid: created["uuid"])

    # Content edits land on the one-off task; a library task refuses them.
    %{"task" => edited} =
      c
      |> patch_json("#{@base}/tasks/#{created["uuid"]}", %{
        title: "Write the tests, all of them",
        progress_pct: 40
      })
      |> json_response(200)

    assert edited["title"] == "Write the tests, all of them"
    assert edited["progress_pct"] == 40

    assert %{"error" => %{"code" => "library_task"}} =
             c
             |> patch_json("#{@base}/tasks/#{a.uuid}", %{title: "renamed"})
             |> json_response(409)

    # Plan fields on a library task are fine.
    %{"task" => %{"priority" => "urgent"}} =
      c |> patch_json("#{@base}/tasks/#{a.uuid}", %{priority: "urgent"}) |> json_response(200)

    # Lifecycle: start, then done, then reopen; a bad move is a 409 with the list.
    %{"task" => %{"status" => "in_progress"}} =
      c |> post_json("#{@base}/tasks/#{a.uuid}/start", %{}) |> json_response(200)

    assert_activity_logged("projects.assignment_started", resource_uuid: a.uuid)

    assert %{
             "error" => %{
               "code" => "invalid_transition",
               "message" => "The task is in_progress; from there it can only go to done or todo.",
               "details" => %{"allowed_transitions" => allowed}
             }
           } =
             c |> post_json("#{@base}/tasks/#{a.uuid}/start", %{}) |> json_response(409)

    assert allowed == ["done", "todo"]

    %{"task" => %{"status" => "done", "completed_at" => completed}} =
      c
      |> post_json("#{@base}/tasks/#{a.uuid}/transition", %{status: "done"})
      |> json_response(200)

    assert is_binary(completed)

    %{"task" => %{"status" => "todo", "completed_at" => nil}} =
      c |> post_json("#{@base}/tasks/#{a.uuid}/reopen", %{}) |> json_response(200)

    assert %{"error" => %{"code" => "validation_failed"}} =
             c
             |> post_json("#{@base}/tasks/#{a.uuid}/transition", %{status: "paused"})
             |> json_response(422)

    assert %{"error" => %{"code" => "not_found"}} =
             c |> get("#{@base}/tasks/#{Ecto.UUID.generate()}") |> json_response(404)
  end

  test "a task of another project is not found", %{conn: conn, token: token} do
    other = fixture_project()

    {:ok, a} =
      Projects.create_assignment(%{
        "project_uuid" => other.uuid,
        "task_uuid" => fixture_task().uuid,
        "status" => "todo"
      })

    assert %{"error" => %{"code" => "not_found"}} =
             conn |> api(token) |> get("#{@base}/tasks/#{a.uuid}") |> json_response(404)
  end

  test "bad fields are 422 with the allowed values", %{conn: conn, token: token} do
    c = api(conn, token)

    assert %{"error" => %{"code" => "validation_failed", "details" => %{"priority" => list}}} =
             c
             |> post_json("#{@base}/tasks", %{title: "x", priority: "asap"})
             |> json_response(422)

    assert "urgent" in list

    assert %{"error" => %{"code" => "validation_failed", "details" => %{"title" => _}}} =
             c |> post_json("#{@base}/tasks", %{title: "   "}) |> json_response(422)
  end

  # ── Roles, scopes, features ─────────────────────────────────────

  test "a viewer key reads but may not create where the project keeps creation to managers", %{
    conn: conn,
    project: project
  } do
    # The default floors let anyone with access create tasks; this project
    # narrows creation to managers, the override the Modules page offers.
    {:ok, project} = Authz.set_overrides(project, %{"create_tasks" => "managers"})
    {:ok, _key, token} = ApiKeys.create(project, %{"name" => "watcher", "role" => "viewer"})
    c = api(conn, token)

    assert %{"tasks" => _} = c |> get("#{@base}/tasks") |> json_response(200)

    assert %{"error" => %{"code" => "forbidden", "details" => %{"action" => "create_tasks"}}} =
             c |> post_json("#{@base}/tasks", %{title: "nope"}) |> json_response(403)
  end

  test "a metering-only key may report usage but not touch tasks", %{
    conn: conn,
    project: project,
    assignment: a
  } do
    {:ok, _key, token} =
      ApiKeys.create(project, %{
        "name" => "meter",
        "role" => "member",
        "scopes" => ["usage:write", "time:write"]
      })

    c = api(conn, token)

    assert %{"error" => %{"code" => "scope_missing", "details" => %{"scope" => "tasks:read"}}} =
             c |> get("#{@base}/tasks") |> json_response(403)

    assert %{"entries" => [_]} =
             c
             |> post_json("#{@base}/tasks/#{a.uuid}/usage", %{tokens: 500}, idem())
             |> json_response(201)
  end

  test "a project with the ledger off refuses time and usage", %{
    conn: conn,
    project: project,
    token: token,
    assignment: a
  } do
    {:ok, project} = Features.set_flags(project, %{"ledger" => false}, [])
    assert Features.gates(project).ledger == false

    assert %{"error" => %{"code" => "feature_disabled", "details" => %{"feature" => "ledger"}}} =
             conn
             |> api(token)
             |> post_json("#{@base}/tasks/#{a.uuid}/time", %{minutes: 5}, idem())
             |> json_response(403)
  end

  # ── Ledger ──────────────────────────────────────────────────────

  test "time and usage are recorded as the key, never billable, and replay on the same idempotency key",
       %{conn: conn, token: token, key: key, project: project, assignment: a} do
    c = api(conn, token)

    assert %{"error" => %{"code" => "idempotency_key_required"}} =
             c |> post_json("#{@base}/tasks/#{a.uuid}/time", %{minutes: 12}) |> json_response(422)

    headers = idem()

    %{"entry" => %{"minutes" => 12, "task_uuid" => task_uuid}} =
      c
      |> post_json(
        "#{@base}/tasks/#{a.uuid}/time",
        %{minutes: 12, note: "tests", billable: true},
        headers
      )
      |> json_response(201)

    assert task_uuid == a.uuid

    # Same key, same answer, no second row.
    replay =
      c |> post_json("#{@base}/tasks/#{a.uuid}/time", %{minutes: 12, note: "tests"}, headers)

    assert json_response(replay, 201)["entry"]["minutes"] == 12
    assert get_resp_header(replay, "idempotent-replayed") == ["true"]

    [entry] = Ledger.list_entries(project.uuid)
    assert entry.actor_kind == "ai_agent"
    assert entry.actor_uuid == key.uuid
    assert entry.billable == false
    assert entry.source == "ai"
    assert entry.metadata["api_key_name"] == "Claude runner"

    %{"entries" => entries} =
      c
      |> post_json(
        "#{@base}/tasks/#{a.uuid}/usage",
        %{tokens: 1800, cost_cents: 3, model: "claude-haiku-4-5"},
        idem()
      )
      |> json_response(201)

    assert Enum.map(entries, & &1["kind"]) |> Enum.sort() == ["cost", "tokens"]

    %{"entries" => [_]} =
      c |> post_json("#{@base}/usage", %{tokens: 200}, idem()) |> json_response(201)

    %{"entry" => _} = c |> post_json("#{@base}/time", %{minutes: 3}, idem()) |> json_response(201)

    totals = Ledger.totals_for_project(project.uuid)
    assert totals.ai_minutes == 15.0
    assert totals.time_minutes == 0.0
    assert totals.billable_minutes == 0.0
    assert totals.tokens == 2000.0
    assert totals.cost_cents == 3.0

    assert %{"error" => %{"code" => "validation_failed"}} =
             c |> post_json("#{@base}/usage", %{tokens: 0}, idem()) |> json_response(422)

    assert %{"error" => %{"code" => "validation_failed", "details" => %{"minutes" => _}}} =
             c |> post_json("#{@base}/time", %{minutes: 1.5}, idem()) |> json_response(422)
  end

  test "occurred_at dates a batch-reported entry; a bad or future one is 422", %{
    conn: conn,
    token: token,
    project: project,
    assignment: a
  } do
    c = api(conn, token)

    %{"entry" => %{"occurred_at" => "2026-10-04T09:15:00Z", "recorded_at" => recorded_at}} =
      c
      |> post_json(
        "#{@base}/tasks/#{a.uuid}/time",
        %{minutes: 4, occurred_at: "2026-10-04T11:15:00+02:00"},
        idem()
      )
      |> json_response(201)

    assert recorded_at != "2026-10-04T09:15:00Z"

    %{"entries" => [%{"occurred_at" => "2026-10-04T09:20:00Z"}]} =
      c
      |> post_json("#{@base}/usage", %{tokens: 50, occurred_at: "2026-10-04T09:20:00Z"}, idem())
      |> json_response(201)

    # Without it the entry carries only its receipt time.
    %{"entry" => %{"occurred_at" => nil}} =
      c |> post_json("#{@base}/time", %{minutes: 1}, idem()) |> json_response(201)

    assert project.uuid
           |> Ledger.list_entries()
           |> Enum.map(& &1.ended_at)
           |> Enum.sort()
           |> Enum.map(&(&1 && DateTime.to_iso8601(&1))) ==
             [nil, "2026-10-04T09:15:00Z", "2026-10-04T09:20:00Z"]

    for bad <- ["yesterday", 17, "2026-10-04"] do
      assert %{"error" => %{"code" => "validation_failed", "details" => %{"occurred_at" => _}}} =
               c
               |> post_json("#{@base}/time", %{minutes: 1, occurred_at: bad}, idem())
               |> json_response(422)
    end

    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()

    assert %{"error" => %{"details" => %{"occurred_at" => ["must not be in the future"]}}} =
             c
             |> post_json("#{@base}/usage", %{tokens: 1, occurred_at: future}, idem())
             |> json_response(422)
  end

  test "a # link in a created or edited description is indexed as a backlink", %{
    conn: conn,
    token: token,
    assignment: a
  } do
    c = api(conn, token)

    {:ok, token_text} =
      Token.to_string(:resource, "project_task", a.uuid, "Wire the API")

    %{"task" => %{"uuid" => created}} =
      c
      |> post_json("#{@base}/tasks", %{
        title: "Follow-up",
        description: "Came out of #{token_text}"
      })
      |> json_response(201)

    assert [%{source_type: "project_task", source_uuid: ^created}] =
             Mentions.list_backlinks("project_task", a.uuid)

    # Editing the link out of the text takes the backlink with it.
    assert c
           |> patch_json("#{@base}/tasks/#{created}", %{description: "plain"})
           |> json_response(200)

    assert Mentions.list_backlinks("project_task", a.uuid) == []
  end

  # ── Notes ───────────────────────────────────────────────────────

  describe "task notes" do
    setup %{project: project} do
      {:ok, _} = Settings.update_setting("comments_enabled", "true")
      on_exit(fn -> Settings.update_setting("comments_enabled", "false") end)

      {:ok, user} =
        Auth.register_user(%{
          email: "minter-#{System.unique_integer([:positive])}@example.com",
          password: "ValidPassword123!"
        })

      # A key with a person behind it: notes are written as that person.
      {:ok, key, token} =
        ApiKeys.create(project, %{"name" => "Runner", "role" => "member"}, actor_uuid: user.uuid)

      {:ok, minter: user, key: key, token: token}
    end

    test "a note with usage lands with its ledger rows; the task answers with what to read first",
         %{conn: conn, token: token, key: key, assignment: a} do
      c = api(conn, token)
      path = "#{@base}/tasks/#{a.uuid}/notes"

      assert %{"error" => %{"code" => "idempotency_key_required"}} =
               c |> post_json(path, %{summary: "x"}) |> json_response(422)

      assert %{"error" => %{"code" => "validation_failed", "details" => %{"summary" => _}}} =
               c |> post_json(path, %{content: "long"}, idem()) |> json_response(422)

      assert %{"error" => %{"details" => %{"refs" => _}}} =
               c
               |> post_json(path, %{summary: "s", refs: [%{type: "Bad Type", id: "1"}]}, idem())
               |> json_response(422)

      headers = idem()

      body = %{
        summary: "Batch import works; tests green",
        outcome: "done",
        content: "## What I did\nSwitched to the batch API.",
        next_steps: "Deploy to dev",
        refs: [
          %{type: "commit", id: "a1b2c3d", url: "https://example.com/c/a1b2c3d"},
          %{type: "pr", id: "42"}
        ],
        usage: %{tokens: 18_422, cost_cents: 7, minutes: 12, model: "m"}
      }

      %{"note" => note, "entries" => entries} =
        c |> post_json(path, body, headers) |> json_response(201)

      assert note["kind"] == "agent_note"
      assert note["author"] == "Runner"
      assert note["summary"] == "Batch import works; tests green"
      assert note["outcome"] == "done"
      assert length(note["refs"]) == 2
      assert note["usage"]["tokens"] == 18_422
      assert length(note["usage"]["entries"]) == 3
      assert Enum.sort(Enum.map(entries, & &1["kind"])) == ["cost", "time", "tokens"]

      # Replay: same note, no second set of rows.
      replay = c |> post_json(path, body, headers)
      assert json_response(replay, 201)["note"]["uuid"] == note["uuid"]
      assert get_resp_header(replay, "idempotent-replayed") == ["true"]

      [entry | _] = Ledger.list_entries(a.project_uuid)
      assert entry.actor_kind == "ai_agent"
      assert entry.actor_uuid == key.uuid
      assert entry.metadata["note_uuid"] == note["uuid"]
      assert length(Ledger.list_entries(a.project_uuid)) == 3

      %{"task" => task} = c |> get("#{@base}/tasks/#{a.uuid}") |> json_response(200)
      assert task["totals"] == %{"minutes" => 12.0, "tokens" => 18_422.0, "cost_cents" => 7.0}
      assert task["direction"] == nil
      assert task["last_outcome"] == "done"

      assert task["display_summary"] == %{
               "text" => "Batch import works; tests green",
               "source" => "agent"
             }

      assert task["notes_url"] =~ "/tasks/#{a.uuid}/notes"

      %{"notes" => [listed], "count" => 1, "latest_agent_note" => %{"uuid" => latest}} =
        c |> get(path) |> json_response(200)

      assert listed["uuid"] == note["uuid"] and latest == note["uuid"]

      # A person changes the direction (only people can): the task now leads with it.
      {:ok, fields} =
        TaskNotes.validate(
          %{"summary" => "No — keep the old parser"},
          "redirect"
        )

      {:ok, _} =
        TaskNotes.create(a, fields,
          user_uuid: key.created_by_uuid,
          kind: "redirect"
        )

      %{"task" => task} = c |> get("#{@base}/tasks/#{a.uuid}") |> json_response(200)
      assert task["direction"]["summary"] == "No — keep the old parser"
      assert task["display_summary"]["source"] == "redirect"
      assert %{"direction" => %{"kind" => "redirect"}} = c |> get(path) |> json_response(200)
    end

    test "usage on a note needs the usage scope; a key with nobody behind it cannot write notes",
         %{conn: conn, project: project, assignment: a, minter: user} do
      {:ok, _, narrow} =
        ApiKeys.create(project, %{"name" => "Narrow", "scopes" => ["tasks:read", "tasks:write"]},
          actor_uuid: user.uuid
        )

      path = "#{@base}/tasks/#{a.uuid}/notes"

      assert %{"error" => %{"code" => "scope_missing"}} =
               conn
               |> api(narrow)
               |> post_json(path, %{summary: "s", usage: %{tokens: 1}}, idem())
               |> json_response(403)

      assert %{"note" => _} =
               conn
               |> api(narrow)
               |> post_json(path, %{summary: "s"}, idem())
               |> json_response(201)

      {:ok, _, orphan} = ApiKeys.create(project, %{"name" => "Orphan"})

      assert %{"error" => %{"code" => "forbidden"}} =
               conn
               |> api(orphan)
               |> post_json(path, %{summary: "s"}, idem())
               |> json_response(403)

      {:ok, _} = Settings.update_setting("comments_enabled", "false")

      assert %{"error" => %{"code" => "feature_disabled", "details" => %{"feature" => "notes"}}} =
               conn |> api(narrow) |> get(path) |> json_response(403)
    end
  end

  # ── Rate limit ──────────────────────────────────────────────────

  test "a key over its window answers 429 with Retry-After; the limit is per key",
       %{conn: conn, token: token, project: project} do
    previous = Application.get_env(:phoenix_kit_projects, :api_rate_limit)
    Application.put_env(:phoenix_kit_projects, :api_rate_limit, limit: 3, window_ms: 60_000)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit_projects, :api_rate_limit, previous),
        else: Application.delete_env(:phoenix_kit_projects, :api_rate_limit)
    end)

    c = api(conn, token)

    remaining =
      for _ <- 1..3 do
        resp = get(c, "#{@base}/me")
        assert json_response(resp, 200)
        assert get_resp_header(resp, "x-ratelimit-limit") == ["3"]
        resp |> get_resp_header("x-ratelimit-remaining") |> hd()
      end

    assert remaining == ["2", "1", "0"]

    denied = get(c, "#{@base}/me")

    assert %{"error" => %{"code" => "rate_limited", "details" => %{"retry_after_seconds" => s}}} =
             json_response(denied, 429)

    assert s >= 1
    assert get_resp_header(denied, "retry-after") == ["#{s}"]
    assert get_resp_header(denied, "x-ratelimit-remaining") == ["0"]

    # The docs tell the agent the live figure, and the limit is per key: a
    # second key of the same project is untouched.
    assert conn |> get("#{@base}/llms.txt") |> response(200) =~ "3 calls per 60 seconds"

    {:ok, _, other} = ApiKeys.create(project, %{"name" => "other"})
    assert conn |> api(other) |> get("#{@base}/me") |> json_response(200)
  end

  # ── Project ─────────────────────────────────────────────────────

  test "the project's workflow status is set from the available slugs", %{
    conn: conn,
    token: token,
    project: project
  } do
    c = api(conn, token)

    %{"project" => %{"available_workflow_statuses" => statuses}} =
      c |> get("#{@base}/project") |> json_response(200)

    case statuses do
      [%{"slug" => slug} | _] ->
        %{"project" => %{"workflow_status" => ^slug}} =
          c |> post_json("#{@base}/project/status", %{status: slug}) |> json_response(200)

      [] ->
        # No status catalogue in this env: the call still refuses an unknown slug properly.
        assert %{"error" => %{"code" => _}} =
                 c
                 |> post_json("#{@base}/project/status", %{status: "nope"})
                 |> json_response(422)
    end

    assert Projects.get_project(project.uuid)
  end

  # ── Keys ────────────────────────────────────────────────────────

  test "rotation keeps the key and ends the old token; expiry ends it too", %{
    conn: conn,
    key: key,
    token: token
  } do
    {:ok, rotated, new_token} = ApiKeys.rotate(key, [])
    assert rotated.uuid == key.uuid
    refute new_token == token

    assert conn |> api(token) |> get("#{@base}/me") |> json_response(401)
    assert conn |> api(new_token) |> get("#{@base}/me") |> json_response(200)

    past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

    {:ok, _} =
      rotated |> Ecto.Changeset.change(expires_at: past) |> Repo.update()

    assert conn |> api(new_token) |> get("#{@base}/me") |> json_response(401)
  end

  test "a key's tasks extension gate: tasks off means 403 feature_disabled", %{
    conn: conn,
    token: token,
    project: project
  } do
    {:ok, _} = Extensions.disable(project, "tasks")

    assert %{"error" => %{"code" => "feature_disabled", "details" => %{"feature" => "tasks"}}} =
             conn |> api(token) |> get("#{@base}/tasks") |> json_response(403)
  end
end
