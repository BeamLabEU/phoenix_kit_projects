defmodule PhoenixKitProjects.Web.ApiReview48Test do
  @moduledoc """
  Regressions from the post-merge review of PR #48 (Sonnet's review): what
  the API refuses instead of crashing on, what an amendment keeps, which
  scope a correction needs, and the claim / sub-project / portal edges.
  """

  use PhoenixKitProjects.LiveCase, async: false

  import Ecto.Query

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{ApiKeys, Ledger, Projects}
  alias PhoenixKitProjects.Schemas.{Assignment, WorkEntry}
  alias PhoenixKitProjects.Test.Repo
  alias PhoenixKitProjects.Web.Api.Docs

  @base "/api/projects/v1"

  setup do
    {:ok, _} = Settings.update_setting("comments_enabled", "true")
    on_exit(fn -> Settings.update_setting("comments_enabled", "false") end)

    project = fixture_project()

    {:ok, user} =
      Auth.register_user(%{
        email: "r48-#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    {:ok, key, token} =
      ApiKeys.create(project, %{"name" => "Agent", "role" => "manager"}, actor_uuid: user.uuid)

    {:ok, project: project, key: key, token: token}
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

  defp new_task(c, attrs \\ %{}) do
    %{"task" => t} =
      c
      |> post_json("#{@base}/tasks", Map.merge(%{"title" => "A task"}, attrs), idem())
      |> json_response(201)

    t
  end

  describe "amending an entry" do
    test "keeps the occurred_at an API entry was reported with", %{conn: conn, token: token} do
      c = api(conn, token)
      t = new_task(c)
      at = "2026-03-01T10:00:00Z"

      %{"entry" => e} =
        c
        |> post_json(
          "#{@base}/tasks/#{t["uuid"]}/time",
          %{"minutes" => 30, "occurred_at" => at},
          idem()
        )
        |> json_response(201)

      assert %{"entry" => amended} =
               c
               |> patch_json("#{@base}/entries/#{e["uuid"]}", %{"minutes" => 45})
               |> json_response(200)

      assert amended["amount"] == 45
      assert amended["occurred_at"] =~ "2026-03-01T10:00:00"
    end

    test "needs the scope its row was written under", %{conn: conn, project: project} do
      {:ok, _, usage_token} =
        ApiKeys.create(project, %{
          "name" => "meter",
          "role" => "manager",
          "scopes" => ["usage:write", "tasks:read"]
        })

      {:ok, _, time_token} =
        ApiKeys.create(project, %{
          "name" => "timer",
          "role" => "manager",
          "scopes" => ["time:write", "tasks:read"]
        })

      {:ok, tokens_row} =
        %WorkEntry{}
        |> WorkEntry.changeset(%{
          project_uuid: project.uuid,
          kind: "tokens",
          amount: 900,
          actor_kind: "ai_agent",
          actor_uuid: Ecto.UUID.generate()
        })
        |> Repo.insert()

      {:ok, time_row} =
        Ledger.log_time(project.uuid, 20,
          actor_kind: "ai_agent",
          actor_uuid: Ecto.UUID.generate()
        )

      # time:write alone cannot touch a tokens row, usage:write alone not a time row
      assert %{"error" => %{"code" => "scope_missing"}} =
               conn
               |> api(time_token)
               |> patch_json("#{@base}/entries/#{tokens_row.uuid}", %{"amount" => 5})
               |> json_response(403)

      assert %{"error" => %{"code" => "scope_missing"}} =
               conn
               |> api(usage_token)
               |> patch_json("#{@base}/entries/#{time_row.uuid}", %{"minutes" => 5})
               |> json_response(403)

      assert %{"entry" => %{"amount" => 5}} =
               conn
               |> api(usage_token)
               |> patch_json("#{@base}/entries/#{tokens_row.uuid}", %{"amount" => 5})
               |> json_response(200)
    end
  end

  describe "figures past the column are a 422, never a 500" do
    test "minutes, tokens, cost and an amendment", %{conn: conn, token: token} do
      c = api(conn, token)
      t = new_task(c)

      for {path, body} <- [
            {"/tasks/#{t["uuid"]}/time", %{"minutes" => 10_000_000_000}},
            {"/time", %{"minutes" => 1_000_001}},
            {"/tasks/#{t["uuid"]}/usage", %{"tokens" => 100_000_000_000}},
            {"/usage", %{"cost_cents" => 100_000_000_000}}
          ] do
        assert %{"error" => %{"code" => "validation_failed"}} =
                 c |> post_json("#{@base}#{path}", body, idem()) |> json_response(422)
      end

      %{"entry" => e} =
        c
        |> post_json("#{@base}/tasks/#{t["uuid"]}/time", %{"minutes" => 10}, idem())
        |> json_response(201)

      assert %{"error" => %{"code" => "validation_failed"}} =
               c
               |> patch_json("#{@base}/entries/#{e["uuid"]}", %{"minutes" => 10_000_000_000})
               |> json_response(422)
    end

    test "a note's usage", %{conn: conn, token: token} do
      c = api(conn, token)
      t = new_task(c)

      assert %{"error" => %{"code" => "validation_failed"}} =
               c
               |> post_json(
                 "#{@base}/tasks/#{t["uuid"]}/notes",
                 %{"summary" => "s", "usage" => %{"tokens" => 100_000_000_000}},
                 idem()
               )
               |> json_response(422)
    end

    test "a task's estimated_duration and position", %{conn: conn, token: token} do
      c = api(conn, token)

      for body <- [
            %{"title" => "x", "estimated_duration" => 9_999_999_999},
            %{"title" => "x", "position" => 3_000_000_000}
          ] do
        assert %{"error" => %{"code" => "validation_failed"}} =
                 c |> post_json("#{@base}/tasks", body, idem()) |> json_response(422)
      end
    end
  end

  test "a note's refs of the wrong type are a 422 naming the field", %{conn: conn, token: token} do
    c = api(conn, token)
    t = new_task(c)

    for refs <- [
          [%{"type" => %{}, "id" => "1"}],
          [%{"type" => "commit", "id" => %{"a" => 1}}],
          [%{"type" => ["x"], "id" => 1}]
        ] do
      assert %{"error" => %{"code" => "validation_failed", "details" => %{"refs" => [_]}}} =
               c
               |> post_json(
                 "#{@base}/tasks/#{t["uuid"]}/notes",
                 %{"summary" => "s", "refs" => refs},
                 idem()
               )
               |> json_response(422)
    end

    # a whole-number id is fine: it is read as its text
    assert %{"note" => _} =
             c
             |> post_json(
               "#{@base}/tasks/#{t["uuid"]}/notes",
               %{"summary" => "s", "refs" => [%{"type" => "issue", "id" => 42}]},
               idem()
             )
             |> json_response(201)
  end

  describe "tasks" do
    test "a sub-project's row is neither moved nor edited here", %{
      conn: conn,
      project: project,
      token: token
    } do
      c = api(conn, token)
      {:ok, %{assignment: row}} = Projects.create_subproject(project.uuid, %{"name" => "Child"})

      assert %{"error" => %{"code" => "subproject"}} =
               c
               |> post_json("#{@base}/tasks/#{row.uuid}/complete", %{}, idem())
               |> json_response(409)

      assert %{"error" => %{"code" => "subproject"}} =
               c
               |> patch_json("#{@base}/tasks/#{row.uuid}", %{"progress_pct" => 50})
               |> json_response(409)

      assert Projects.get_assignment(row.uuid).status != "done"
    end

    test "a reworded description reaches the copy the form kept on the assignment", %{
      conn: conn,
      project: project,
      token: token
    } do
      c = api(conn, token)

      {:ok, _} =
        Projects.update_project(project, %{
          "settings" => %{"agents" => %{"edit_foreign_text" => true}}
        })

      {:ok, %{assignment: a}} =
        Projects.create_task_with_assignment(
          project.uuid,
          %{"title" => "From the form", "description" => "old", "ad_hoc" => true},
          %{"description" => "old"}
        )

      assert %{"task" => %{"description" => "new"}} =
               c
               |> patch_json("#{@base}/tasks/#{a.uuid}", %{"description" => "new"})
               |> json_response(200)

      assert %{"task" => %{"description" => "new"}} =
               c |> get("#{@base}/tasks/#{a.uuid}") |> json_response(200)
    end

    test "a PATCH that fails validation changes nothing", %{conn: conn, token: token} do
      c = api(conn, token)
      t = new_task(c, %{"title" => "Before"})

      assert %{"error" => %{"code" => "validation_failed"}} =
               c
               |> patch_json("#{@base}/tasks/#{t["uuid"]}", %{
                 "title" => "After",
                 "waiting_on" => String.duplicate("w", 201)
               })
               |> json_response(422)

      assert %{"task" => %{"title" => "Before"}} =
               c |> get("#{@base}/tasks/#{t["uuid"]}") |> json_response(200)
    end

    test "a PATCH the assignment changeset refuses (51 checklist items) changes nothing", %{
      conn: conn,
      token: token
    } do
      c = api(conn, token)
      t = new_task(c, %{"title" => "Before"})
      items = for n <- 1..51, do: %{"text" => "item #{n}"}

      assert %{"error" => %{"code" => "validation_failed"}} =
               c
               |> patch_json("#{@base}/tasks/#{t["uuid"]}", %{
                 "title" => "After",
                 "checklist" => items
               })
               |> json_response(422)

      assert %{"task" => %{"title" => "Before"}} =
               c |> get("#{@base}/tasks/#{t["uuid"]}") |> json_response(200)
    end

    test "a duration longer than any task is a 422; a huge rollup is clamped, not lost", %{
      conn: conn,
      project: project,
      token: token
    } do
      c = api(conn, token)

      {:ok, %{child_project: child}} =
        Projects.create_subproject(project.uuid, %{"name" => "Child"})

      assert %{"error" => %{"code" => "validation_failed"}} =
               c
               |> post_json(
                 "#{@base}/tasks",
                 %{
                   "title" => "Huge",
                   "project" => child.uuid,
                   "estimated_duration" => 1_000_000_000,
                   "estimated_duration_unit" => "hours"
                 },
                 idem()
               )
               |> json_response(422)

      # a figure that got past the API (the form, an import) still cannot break the parent's row
      t = new_task(c, %{"title" => "Odd", "project" => child.uuid})

      {1, _} =
        Repo.update_all(
          from(a in Assignment, where: a.uuid == ^t["uuid"]),
          set: [estimated_duration: 1_000_000_000, estimated_duration_unit: "hours"]
        )

      assert %{"task" => %{"status" => "in_progress"}} =
               c
               |> post_json("#{@base}/tasks/#{t["uuid"]}/start", %{}, idem())
               |> json_response(200)

      assert [row] = Projects.list_assignments(project.uuid)
      assert row.estimated_duration == 2_147_483_647
      assert row.status == "in_progress"
    end

    test "a portal submission still in review is not reachable by its uuid", %{
      conn: conn,
      project: project,
      token: token
    } do
      c = api(conn, token)
      t = new_task(c)

      {:ok, _} =
        Projects.get_assignment(t["uuid"])
        |> Ecto.Changeset.change(review_status: "pending", source: "portal")
        |> Repo.update()

      assert %{"error" => %{"code" => "not_found"}} =
               c |> get("#{@base}/tasks/#{t["uuid"]}") |> json_response(404)

      assert %{"error" => %{"code" => "not_found"}} =
               c
               |> post_json("#{@base}/tasks/#{t["uuid"]}/complete", %{}, idem())
               |> json_response(404)

      assert %Assignment{review_status: "pending"} = Projects.get_assignment(t["uuid"])
      _ = project
    end
  end

  describe "the generated contract" do
    test "names the scope a correction needs by the entry's kind" do
      for id <- ["amendEntry", "removeEntry"] do
        endpoint = Enum.find(Docs.endpoints(), &(&1.id == id))
        assert endpoint.scope =~ "time:write"
        assert endpoint.scope =~ "usage:write"
      end

      assert Docs.llms_txt() =~ "usage:write for a tokens or cost entry"
    end
  end
end
