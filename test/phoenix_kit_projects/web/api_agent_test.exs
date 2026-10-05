defmodule PhoenixKitProjects.Web.ApiAgentTest do
  @moduledoc """
  What the first agent on the API asked for (2026-10-05): an ongoing
  project that never completes on its own, provenance and claims, wording
  protection, deletion and ledger corrections under the project's agent
  policy, checklists, waiting / origin / labels on a task, polling by
  `updated_since`, project-level notes and the briefing.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{ApiKeys, Features, Labels, Ledger, Projects}
  alias PhoenixKitProjects.Schemas.Project

  @base "/api/projects/v1"

  setup do
    {:ok, _} = Settings.update_setting("comments_enabled", "true")
    on_exit(fn -> Settings.update_setting("comments_enabled", "false") end)

    project = fixture_project()

    {:ok, user} =
      Auth.register_user(%{
        email: "agent-#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    {:ok, key, token} =
      ApiKeys.create(project, %{"name" => "Agent A", "role" => "manager"}, actor_uuid: user.uuid)

    {:ok, key_b, token_b} =
      ApiKeys.create(project, %{"name" => "Agent B", "role" => "member"}, actor_uuid: user.uuid)

    {:ok, project: project, key: key, token: token, key_b: key_b, token_b: token_b}
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

  defp set_policy(project, policy) do
    settings = Map.put(project.settings || %{}, "agents", policy)
    {:ok, p} = Projects.update_project(project, %{"settings" => settings})
    p
  end

  test "an ongoing project is all caught up, never completed; a sub-project copies the mode", %{
    conn: conn,
    project: project,
    token: token
  } do
    {:ok, project} =
      Projects.update_project(project, %{"settings" => %{"completion" => "manual"}})

    assert Project.ongoing?(project)
    c = api(conn, token)

    %{"task" => t} =
      c |> post_json("#{@base}/tasks", %{"title" => "Only one"}, idem()) |> json_response(201)

    assert %{"task" => %{"status" => "done"}} =
             c
             |> post_json("#{@base}/tasks/#{t["uuid"]}/complete", %{}, idem())
             |> json_response(200)

    %{"project" => p} = c |> get("#{@base}/project") |> json_response(200)
    assert p["completion"] == "manual"
    assert p["caught_up"] == true
    assert p["completed_at"] == nil

    # the child copies the parent's mode, and can be told otherwise
    %{"project" => child} =
      c |> post_json("#{@base}/subprojects", %{"name" => "Ongoing child"}) |> json_response(201)

    assert child["completion"] == "manual"

    %{"project" => finite} =
      c
      |> post_json("#{@base}/subprojects", %{"name" => "Finite child", "completion" => "auto"})
      |> json_response(201)

    assert finite["completion"] == "auto"

    # the finite child completes itself; the ongoing parent stays open and the row shows caught up
    %{"task" => ct} =
      c
      |> post_json(
        "#{@base}/tasks",
        %{"title" => "In the finite child", "project" => finite["uuid"]},
        idem()
      )
      |> json_response(201)

    c |> post_json("#{@base}/tasks/#{ct["uuid"]}/complete", %{}, idem()) |> json_response(200)
    assert Projects.get_project(finite["uuid"]).completed_at != nil
    assert Projects.get_project(project.uuid).completed_at == nil

    # the ongoing child's row is open (no tasks yet), so the parent is no longer caught up
    assert %{"project" => %{"caught_up" => false, "completed_at" => nil}, "subprojects" => [_, _]} =
             c |> get("#{@base}/briefing") |> json_response(200)
  end

  test "provenance, claims and wording protection follow the project's policy", %{
    conn: conn,
    project: project,
    key: key,
    token: token,
    key_b: key_b,
    token_b: token_b
  } do
    a = api(conn, token)
    b = api(conn, token_b)

    %{"task" => t} =
      a
      |> post_json("#{@base}/tasks", %{"title" => "Mine", "description" => "by A"}, idem())
      |> json_response(201)

    assert t["created_by"]["key"] == key.uuid

    me = a |> get("#{@base}/me") |> json_response(200)
    assert me["agent_policy"]["take_started_task"] == false

    # A starts it; B may not take it over
    %{"task" => started} =
      a |> post_json("#{@base}/tasks/#{t["uuid"]}/start", %{}, idem()) |> json_response(200)

    assert started["started_by"]["key"] == key.uuid

    # B may not move A's in-progress task at all — not reopen it, not finish it
    assert %{
             "error" => %{
               "code" => "already_started",
               "details" => %{"started_by" => %{"key" => k}}
             }
           } =
             b
             |> post_json("#{@base}/tasks/#{t["uuid"]}/reopen", %{}, idem())
             |> json_response(409)

    assert k == key.uuid

    assert %{"error" => %{"code" => "already_started"}} =
             b
             |> post_json("#{@base}/tasks/#{t["uuid"]}/complete", %{}, idem())
             |> json_response(409)

    # A puts it back; B still may not start it
    a |> post_json("#{@base}/tasks/#{t["uuid"]}/reopen", %{}, idem()) |> json_response(200)

    assert %{"error" => %{"code" => "already_started"}} =
             b
             |> post_json("#{@base}/tasks/#{t["uuid"]}/start", %{}, idem())
             |> json_response(409)

    # B may not reword A's task, may set its own fields
    assert %{"error" => %{"code" => "foreign_text"}} =
             b
             |> patch_json("#{@base}/tasks/#{t["uuid"]}", %{"title" => "Theirs"})
             |> json_response(403)

    assert %{"task" => %{"waiting_on" => "the client"}} =
             b
             |> patch_json("#{@base}/tasks/#{t["uuid"]}", %{"waiting_on" => "the client"})
             |> json_response(200)

    # a person rewords A's task in the form: the words are theirs now, A may not reword
    {:ok, _} =
      Projects.stamp_assignment(Projects.get_assignment(t["uuid"]), %{words_by_key_uuid: nil})

    assert %{"error" => %{"code" => "foreign_text"}} =
             a
             |> patch_json("#{@base}/tasks/#{t["uuid"]}", %{"title" => "Mine again"})
             |> json_response(403)

    # the project opens both
    project = set_policy(project, %{"take_started_task" => true, "edit_foreign_text" => true})
    assert Project.agent_policy(project)["take_started_task"] == true

    assert %{"task" => %{"started_by" => %{"key" => kb}}} =
             b
             |> post_json("#{@base}/tasks/#{t["uuid"]}/start", %{}, idem())
             |> json_response(200)

    assert kb == key_b.uuid

    assert %{"task" => %{"title" => "Theirs"}} =
             b
             |> patch_json("#{@base}/tasks/#{t["uuid"]}", %{"title" => "Theirs"})
             |> json_response(200)
  end

  test "deletion is a policy: none, own, any", %{
    conn: conn,
    project: project,
    token: token,
    token_b: token_b
  } do
    a = api(conn, token)
    b = api(conn, token_b)

    %{"task" => t} =
      a |> post_json("#{@base}/tasks", %{"title" => "Doomed"}, idem()) |> json_response(201)

    assert %{"error" => %{"code" => "delete_not_allowed"}} =
             a |> delete("#{@base}/tasks/#{t["uuid"]}") |> json_response(403)

    project = set_policy(project, %{"delete_tasks" => "own"})

    assert %{"error" => %{"code" => "delete_not_allowed"}} =
             b |> delete("#{@base}/tasks/#{t["uuid"]}") |> json_response(403)

    assert %{"deleted" => _} = a |> delete("#{@base}/tasks/#{t["uuid"]}") |> json_response(200)
    assert Projects.get_assignment(t["uuid"]) == nil

    _ = set_policy(project, %{"delete_tasks" => "any"})

    %{"task" => t2} =
      a |> post_json("#{@base}/tasks", %{"title" => "Doomed too"}, idem()) |> json_response(201)

    assert %{"deleted" => _} = b |> delete("#{@base}/tasks/#{t2["uuid"]}") |> json_response(200)
  end

  test "checklist, origin, labels, position and updated_since", %{
    conn: conn,
    project: project,
    token: token
  } do
    c = api(conn, token)
    {:ok, _} = Features.set_flags(project, %{"labels" => true})

    %{"task" => first} =
      c |> post_json("#{@base}/tasks", %{"title" => "First"}, idem()) |> json_response(201)

    %{"task" => t} =
      c
      |> post_json(
        "#{@base}/tasks",
        %{
          "title" => "Relayed",
          "origin" => "client",
          "labels" => ["Furniture", "Urgent"],
          "position" => "top",
          "checklist" => [%{"text" => "Rooms dropdown"}, %{"text" => "CIX set", "done" => true}]
        },
        idem()
      )
      |> json_response(201)

    assert t["origin"] == "client"
    assert Enum.sort(t["labels"]) == ["Furniture", "Urgent"]
    assert t["checklist"] == %{"done" => 1, "total" => 2}
    assert t["position"] < first["position"]
    assert [%{name: _}, %{name: _}] = Labels.list_for_project(project.uuid)

    %{"task" => detail} = c |> get("#{@base}/tasks/#{t["uuid"]}") |> json_response(200)
    [open_item, done_item] = detail["checklist_items"]
    assert open_item["done"] == false
    assert done_item["done"] == true and is_binary(done_item["done_at"])

    %{"task" => ticked} =
      c
      |> patch_json("#{@base}/tasks/#{t["uuid"]}/checklist/#{open_item["id"]}", %{"done" => true})
      |> json_response(200)

    assert ticked["checklist"] == %{"done" => 2, "total" => 2}

    assert %{"error" => %{"code" => "not_found"}} =
             c
             |> patch_json("#{@base}/tasks/#{t["uuid"]}/checklist/nope", %{"done" => true})
             |> json_response(404)

    # labels by name again: existing reused, one new
    %{"task" => relabelled} =
      c
      |> patch_json("#{@base}/tasks/#{t["uuid"]}", %{"labels" => ["furniture", "Later"]})
      |> json_response(200)

    assert Enum.sort(relabelled["labels"]) == ["Furniture", "Later"]
    assert length(Labels.list_for_project(project.uuid)) == 3

    # updated_since: only what moved after the moment
    %{"now" => now} = c |> get("#{@base}/tasks") |> json_response(200)
    Process.sleep(1100)

    c
    |> patch_json("#{@base}/tasks/#{first["uuid"]}", %{"waiting_on" => "boss"})
    |> json_response(200)

    %{"tasks" => moved} = c |> get("#{@base}/tasks?updated_since=#{now}") |> json_response(200)
    assert Enum.map(moved, & &1["uuid"]) == [first["uuid"]]
  end

  test "project notes and the briefing", %{conn: conn, project: project, token: token} do
    c = api(conn, token)

    %{"task" => t} =
      c
      |> post_json("#{@base}/tasks", %{"title" => "Open one", "waiting_on" => "client"}, idem())
      |> json_response(201)

    %{"task" => _} =
      c |> post_json("#{@base}/tasks", %{"title" => "Done one"}, idem()) |> json_response(201)

    assert %{"note" => note, "entries" => [_ | _]} =
             c
             |> post_json(
               "#{@base}/notes",
               %{
                 "summary" => "Rooms dropdown answered",
                 "outcome" => "done",
                 "usage" => %{"tokens" => 500}
               },
               idem()
             )
             |> json_response(201)

    assert note["kind"] == "agent_note"
    assert Ledger.totals_for_project(project.uuid).tokens == 500.0

    %{"notes" => [one], "count" => 1} = c |> get("#{@base}/notes") |> json_response(200)
    assert one["summary"] == "Rooms dropdown answered"

    later = DateTime.utc_now() |> DateTime.add(60) |> DateTime.to_iso8601()

    %{"notes" => [], "count" => 0} =
      c |> get("#{@base}/notes?since=#{later}") |> json_response(200)

    c
    |> post_json(
      "#{@base}/tasks/#{t["uuid"]}/notes",
      %{"summary" => "Waiting on the CIX set", "outcome" => "blocked"},
      idem()
    )
    |> json_response(201)

    b = c |> get("#{@base}/briefing") |> json_response(200)
    assert b["project"]["completion"] == "auto"
    assert b["open_total"] == 2
    assert b["truncated"] == false
    assert [%{"summary" => "Rooms dropdown answered"}] = b["project_notes"]
    open = Enum.find(b["tasks"], &(&1["uuid"] == t["uuid"]))
    assert open["waiting_on"] == "client"
    assert open["last_outcome"] == "blocked"
    assert open["latest_agent_note"]["summary"] == "Waiting on the CIX set"

    %{"tasks" => [_], "truncated" => true} =
      c |> get("#{@base}/briefing?limit=1") |> json_response(200)

    # the agent's own in-progress task comes first, its latest note is the resume pointer, done today is a tail
    c |> post_json("#{@base}/tasks/#{t["uuid"]}/start", %{}, idem()) |> json_response(200)

    %{"task" => other} =
      c
      |> post_json("#{@base}/tasks", %{"title" => "Third", "priority" => "urgent"}, idem())
      |> json_response(201)

    c |> post_json("#{@base}/tasks/#{other["uuid"]}/complete", %{}, idem()) |> json_response(200)

    b2 = c |> get("#{@base}/briefing") |> json_response(200)
    assert hd(b2["tasks"])["uuid"] == t["uuid"]
    assert b2["counts"]["mine"] == 1
    assert b2["resume"]["task_uuid"] == t["uuid"]
    assert b2["resume"]["summary"] == "Waiting on the CIX set"
    assert [%{"uuid" => done_uuid}] = b2["done_today"]
    assert done_uuid == other["uuid"]
  end

  defmodule FakeInteractions do
    @moduledoc false
    def resource, do: "interactions"
    def scopes, do: %{read: "interactions:read", write: "interactions:write"}
    def action, do: :log_interaction

    def list(_ctx, params),
      do: {:ok, %{interactions: [%{uuid: "i-1", subject: "Call", since: params["since"]}]}}

    def get(_ctx, "01a10000-0000-7000-8000-000000000001"),
      do:
        {:ok,
         %{
           interaction: %{uuid: "01a10000-0000-7000-8000-000000000001", subject: "Kickoff | call"}
         }}

    def get(_ctx, _), do: {:error, {404, "not_found", "No such interaction.", nil}}
  end

  defmodule FakeClient do
    @moduledoc false
    def phoenix_kit_project_extensions do
      [
        %{
          key: "crm_client",
          name: "Client",
          description: "A test client extension",
          permission_actions: [:view, :log_interaction],
          api: PhoenixKitProjects.Web.ApiAgentTest.FakeInteractions
        }
      ]
    end
  end

  test "entries can be read back, with the estimate flag and who recorded them", %{
    conn: conn,
    token: token,
    key: key
  } do
    c = api(conn, token)

    %{"task" => t} =
      c |> post_json("#{@base}/tasks", %{"title" => "Costly"}, idem()) |> json_response(201)

    %{"entries" => [e | _]} =
      c
      |> post_json(
        "#{@base}/tasks/#{t["uuid"]}/usage",
        %{"tokens" => 800, "model" => "claude", "estimated" => true},
        idem()
      )
      |> json_response(201)

    assert e["estimated"] == true
    assert e["model"] == "claude"
    assert e["actor"] == %{"kind" => "ai_agent", "uuid" => key.uuid}

    %{"entries" => on_task, "task_uuid" => _} =
      c |> get("#{@base}/tasks/#{t["uuid"]}/entries") |> json_response(200)

    assert Enum.map(on_task, & &1["uuid"]) == [e["uuid"]]

    %{"entries" => all, "truncated" => false, "limit" => 200} =
      c |> get("#{@base}/entries") |> json_response(200)

    assert e["uuid"] in Enum.map(all, & &1["uuid"])

    c |> post_json("#{@base}/usage", %{"tokens" => 5}, idem()) |> json_response(201)

    %{"entries" => [_], "truncated" => true} =
      c |> get("#{@base}/entries?limit=1") |> json_response(200)

    # a note's usage keeps the flag too, and its entries are whole numbers
    %{"note" => note, "entries" => [ne | _]} =
      c
      |> post_json(
        "#{@base}/tasks/#{t["uuid"]}/notes",
        %{"summary" => "Guessed", "usage" => %{"tokens" => 10, "estimated" => true}},
        idem()
      )
      |> json_response(201)

    assert note["usage"]["estimated"] == true
    assert ne["amount"] === 10
    assert ne["estimated"] == true

    me = c |> get("#{@base}/me") |> json_response(200)
    assert Map.has_key?(me["features"], "labels")
  end

  test "a task links to a client interaction with a mention token; the briefing carries the client",
       %{
         conn: conn,
         project: project,
         token: token
       } do
    previous = Application.get_env(:phoenix_kit_projects, :extension_providers, [])
    Application.put_env(:phoenix_kit_projects, :extension_providers, [FakeClient | previous])
    PhoenixKitProjects.Extensions.Registry.refresh()

    on_exit(fn ->
      Application.put_env(:phoenix_kit_projects, :extension_providers, previous)
      PhoenixKitProjects.Extensions.Registry.refresh()
    end)

    {:ok, _} = PhoenixKitProjects.Extensions.enable(project, "crm_client")
    c = api(conn, token)
    uuid = "01a10000-0000-7000-8000-000000000001"

    %{"task" => t} =
      c
      |> post_json("#{@base}/tasks", %{"title" => "From the call", "interaction" => uuid}, idem())
      |> json_response(201)

    assert t["interactions"] == [uuid]

    assert Projects.get_assignment(t["uuid"]).task.description =~
             "#[crm_interaction:#{uuid}|Kickoff   call]"

    # linking again is a no-op; an unknown interaction is a 404
    %{"task" => again} =
      c
      |> patch_json("#{@base}/tasks/#{t["uuid"]}", %{"interaction" => uuid})
      |> json_response(200)

    assert again["interactions"] == [uuid]

    # a rewrite of the description does not unlink: the join is the truth and the token comes back
    %{"task" => rewritten} =
      c
      |> patch_json("#{@base}/tasks/#{t["uuid"]}", %{"description" => "Rewritten"})
      |> json_response(200)

    assert rewritten["interactions"] == [uuid]

    assert Projects.get_assignment(t["uuid"]).task.description =~
             "Rewritten\n#[crm_interaction:#{uuid}|"

    # the explicit link and unlink calls
    %{"task" => unlinked} =
      c |> delete("#{@base}/tasks/#{t["uuid"]}/interactions/#{uuid}") |> json_response(200)

    assert unlinked["interactions"] == []

    %{"task" => relinked} =
      c
      |> post_json("#{@base}/tasks/#{t["uuid"]}/interactions/#{uuid}", %{})
      |> json_response(200)

    assert relinked["interactions"] == [uuid]

    assert %{"error" => %{"code" => "not_found"}} =
             c
             |> patch_json("#{@base}/tasks/#{t["uuid"]}", %{"interaction" => Ecto.UUID.generate()})
             |> json_response(404)

    # the client lines need the interactions scope: a key minted now carries it
    {:ok, _, reader} = ApiKeys.create(project, %{"name" => "Client reader"})
    b = conn |> api(reader) |> get("#{@base}/briefing") |> json_response(200)
    assert [%{"subject" => "Call"}] = b["client"]["interactions"]
    assert b["events"] == []
  end

  test "planned events are readable once the extension is on", %{
    conn: conn,
    project: project,
    token: token
  } do
    c = api(conn, token)

    assert %{"error" => %{"code" => "feature_disabled"}} =
             c |> get("#{@base}/events") |> json_response(403)

    {:ok, _} = PhoenixKitProjects.Extensions.enable(project, "events")

    {:ok, event} =
      PhoenixKitProjects.ProjectEvents.create(project, %{
        title: "Review with the client",
        starts_at: DateTime.add(DateTime.utc_now(), 3600),
        all_day: false
      })

    %{"events" => [%{"uuid" => uuid, "title" => "Review with the client"}], "count" => 1} =
      c |> get("#{@base}/events") |> json_response(200)

    assert uuid == event.uuid

    assert %{"event" => %{"uuid" => ^uuid}} =
             c |> get("#{@base}/events/#{uuid}") |> json_response(200)

    assert %{"error" => %{"code" => "not_found"}} =
             c |> get("#{@base}/events/#{Ecto.UUID.generate()}") |> json_response(404)

    # the briefing lists what is coming up
    %{"events" => [%{"uuid" => ^uuid}]} = c |> get("#{@base}/briefing") |> json_response(200)
  end

  test "ledger corrections: own entries under the policy, any for a manager key", %{
    conn: conn,
    project: project,
    token: token,
    token_b: token_b,
    key_b: key_b
  } do
    a = api(conn, token)
    b = api(conn, token_b)

    %{"entry" => e} =
      b |> post_json("#{@base}/time", %{"minutes" => 90}, idem()) |> json_response(201)

    assert %{"entry" => %{"amount" => 9}} =
             b
             |> patch_json("#{@base}/entries/#{e["uuid"]}", %{"minutes" => 9})
             |> json_response(200)

    _ = set_policy(project, %{"amend_own_ledger" => false})

    assert %{"error" => %{"code" => "amend_not_allowed"}} =
             b
             |> patch_json("#{@base}/entries/#{e["uuid"]}", %{"minutes" => 10})
             |> json_response(403)

    # the manager key corrects anyone's
    assert %{"deleted" => _} = a |> delete("#{@base}/entries/#{e["uuid"]}") |> json_response(200)
    assert Ledger.get_entry(e["uuid"]) == nil
    assert key_b.role == "member"

    assert %{"error" => %{"code" => "not_found"}} =
             a |> delete("#{@base}/entries/#{Ecto.UUID.generate()}") |> json_response(404)

    # a tokens entry takes `amount`; a billable row is never erased over the API
    %{"entries" => [tok | _]} =
      b
      |> post_json("#{@base}/usage", %{"tokens" => 900, "estimated" => true}, idem())
      |> json_response(201)

    _ = set_policy(project, %{"amend_own_ledger" => true})

    assert %{"entry" => %{"amount" => 450}} =
             b
             |> patch_json("#{@base}/entries/#{tok["uuid"]}", %{"amount" => 450})
             |> json_response(200)

    {:ok, billable} =
      Ledger.log_time(project.uuid, 30,
        billable: true,
        actor_kind: "user",
        actor_uuid: Ecto.UUID.generate()
      )

    assert %{"error" => %{"code" => "billable_entry"}} =
             a |> delete("#{@base}/entries/#{billable.uuid}") |> json_response(403)
  end
end
