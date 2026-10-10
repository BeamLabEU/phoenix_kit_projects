defmodule PhoenixKitProjects.Web.ApiHoursTest do
  @moduledoc """
  `GET /hours` — logged time summed for a period over the API: the totals,
  the three groupings, the period and worker filters, sub-projects within
  reach, and the gates it shares with `GET /entries`.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{ApiKeys, Features, Ledger, Projects}

  @base "/api/projects/v1"

  setup do
    project = fixture_project()

    {:ok, user} =
      Auth.register_user(%{
        email: "hours-api-#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    {:ok, key, token} =
      ApiKeys.create(project, %{"name" => "Reporter", "role" => "member"}, actor_uuid: user.uuid)

    {:ok, project: project, user: user, key: key, token: token}
  end

  defp api(conn, token) do
    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("accept", "application/json")
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

  test "totals and people by default, with an agent's time apart", ctx do
    %{conn: conn, project: project, user: user, key: key, token: token} = ctx
    {:ok, _} = Ledger.log_time(project.uuid, 60, actor_uuid: user.uuid, billable: true)

    {:ok, _} =
      Ledger.log_time(project.uuid, 20,
        actor_kind: "ai_agent",
        actor_uuid: key.uuid,
        source: "ai",
        metadata: %{"api_key_name" => key.name}
      )

    {:ok, _} = Ledger.record_ai(project.uuid, %{tokens: 900, cost_cents: 3, agent_uuid: key.uuid})

    body = conn |> api(token) |> get("#{@base}/hours") |> json_response(200)

    assert body["project_uuid"] == project.uuid
    assert body["group_by"] == "person"
    assert body["include_subprojects"] == true
    assert body["period"] == %{"from" => nil, "to" => nil}

    assert %{
             "minutes" => 60,
             "billable_minutes" => 60,
             "ai_minutes" => 20,
             "tokens" => 900,
             "cost_cents" => 3,
             "entries" => 1,
             "people" => 1
           } = body["totals"]

    assert [person, agent] = body["groups"]
    assert person["worker"]["key"] == "user:#{user.uuid}"
    assert person["minutes"] == 60 and person["billable_minutes"] == 60 and person["entries"] == 1

    assert agent["worker"] == %{
             "key" => "ai_agent:#{key.uuid}",
             "kind" => "ai_agent",
             "uuid" => key.uuid,
             "name" => "Reporter"
           }
  end

  test "group_by task and day, a period, a worker and billable", ctx do
    %{conn: conn, project: project, user: user, token: token} = ctx
    cut = task(project, "Cut the panels")

    {:ok, _} =
      Ledger.log_time(project.uuid, 90,
        actor_uuid: user.uuid,
        assignment_uuid: cut.uuid,
        ended_at: ~U[2026-10-05 10:00:00Z],
        billable: true
      )

    {:ok, _} = Ledger.log_time(project.uuid, 30, ended_at: ~U[2026-10-06 23:30:00Z])
    {:ok, _} = Ledger.log_time(project.uuid, 15, ended_at: ~U[2026-09-01 10:00:00Z])
    c = api(conn, token)

    by_task =
      c |> get("#{@base}/hours?group_by=task&from=2026-10-01&to=2026-10-06") |> json_response(200)

    assert by_task["totals"]["minutes"] == 120

    assert by_task["period"] == %{
             "from" => "2026-10-01T00:00:00Z",
             "to" => "2026-10-07T00:00:00Z"
           }

    assert [
             %{"task_uuid" => task_uuid, "title" => "Cut the panels", "minutes" => 90},
             %{"task_uuid" => nil, "title" => nil, "minutes" => 30}
           ] = by_task["groups"]

    assert task_uuid == cut.uuid

    by_day = c |> get("#{@base}/hours?group_by=day&from=2026-10-01") |> json_response(200)

    assert [
             %{"date" => "2026-10-05", "minutes" => 90, "by_worker" => by},
             %{"date" => "2026-10-06"}
           ] = by_day["groups"]

    assert by == %{"user:#{user.uuid}" => 90}

    # an instant as `to` is excluded
    upto = c |> get("#{@base}/hours?to=2026-10-05T10:00:00Z") |> json_response(200)
    assert upto["totals"]["minutes"] == 15

    mine = c |> get("#{@base}/hours?worker=user:#{user.uuid}") |> json_response(200)
    assert mine["totals"]["minutes"] == 90

    assert (c |> get("#{@base}/hours?billable=true") |> json_response(200))["totals"]["minutes"] ==
             90

    assert (c |> get("#{@base}/hours?billable=false") |> json_response(200))["totals"]["minutes"] ==
             45
  end

  test "covers the sub-projects within reach, or only the project", ctx do
    %{conn: conn, project: project, token: token} = ctx

    {:ok, %{child_project: child}} =
      Projects.create_subproject(project.uuid, %{"name" => "Child"})

    other = fixture_project()
    {:ok, _} = Ledger.log_time(project.uuid, 60)
    {:ok, _} = Ledger.log_time(child.uuid, 30)
    {:ok, _} = Ledger.log_time(other.uuid, 500)
    c = api(conn, token)

    assert (c |> get("#{@base}/hours") |> json_response(200))["totals"]["minutes"] == 90

    alone = c |> get("#{@base}/hours?include_subprojects=false") |> json_response(200)
    assert alone["totals"]["minutes"] == 60 and alone["include_subprojects"] == false

    in_child = c |> get("#{@base}/hours?project=#{child.uuid}") |> json_response(200)
    assert in_child["project_uuid"] == child.uuid and in_child["totals"]["minutes"] == 30

    assert c |> get("#{@base}/hours?project=#{other.uuid}") |> json_response(404)
  end

  test "refuses what it cannot read, with the field named", %{conn: conn, token: token} do
    c = api(conn, token)

    for {query, field} <- [
          {"from=yesterday", "from"},
          {"to=2026-13-40", "to"},
          {"group_by=project", "group_by"},
          {"billable=maybe", "billable"},
          {"include_subprojects=x", "include_subprojects"},
          {"worker=user:nope", "worker"},
          {"worker=robot:#{Ecto.UUID.generate()}", "worker"}
        ] do
      body = c |> get("#{@base}/hours?#{query}") |> json_response(422)
      assert body["error"]["code"] == "validation_failed"
      assert Map.has_key?(body["error"]["details"], field), query
    end
  end

  test "needs the read scope, the ledger and a token", ctx do
    %{conn: conn, project: project, user: user, token: token} = ctx

    {:ok, _key, write_only} =
      ApiKeys.create(
        project,
        %{"name" => "Meter", "role" => "member", "scopes" => ["time:write"]},
        actor_uuid: user.uuid
      )

    assert (conn
            |> api(write_only)
            |> get("#{@base}/hours")
            |> json_response(403))["error"]["code"] ==
             "scope_missing"

    assert conn
           |> put_req_header("accept", "application/json")
           |> get("#{@base}/hours")
           |> json_response(401)

    {:ok, _} = Features.set_flags(project, %{"ledger" => false})
    assert conn |> api(token) |> get("#{@base}/hours") |> json_response(403)
  end

  test "is in the generated docs", %{conn: conn} do
    text = conn |> get("#{@base}/llms.txt") |> response(200)
    assert text =~ "/hours"

    spec =
      conn
      |> put_req_header("accept", "application/json")
      |> get("#{@base}/openapi.json")
      |> json_response(200)

    assert get_in(spec, ["paths", "/hours", "get", "operationId"]) == "getHours"
  end
end
