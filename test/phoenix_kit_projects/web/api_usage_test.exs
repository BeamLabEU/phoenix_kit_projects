defmodule PhoenixKitProjects.Web.ApiUsageTest do
  @moduledoc """
  Usage per API key (chain V25): every authenticated call is counted per
  key, project and day, with its failures and refusals; the AI time,
  tokens and cost a key reports are summed beside them; the API keys page
  draws both.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{ApiKeys, ApiUsage, Members}

  @base "/api/projects/v1"

  setup do
    home = fixture_project(%{"name" => "Home #{System.unique_integer([:positive])}"})
    other = fixture_project(%{"name" => "Other #{System.unique_integer([:positive])}"})

    {:ok, user} =
      Auth.register_user(%{
        email: "usage-#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    {:ok, _} = Members.add_member(home, user.uuid, role: "manager")

    {:ok, key, token} =
      ApiKeys.create(home, %{"name" => "Counter", "user_uuid" => user.uuid},
        actor_uuid: user.uuid
      )

    {:ok, home: home, other: other, key: key, token: token, user: user}
  end

  defp api(token) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("accept", "application/json")
    |> put_req_header("content-type", "application/json")
  end

  test "calls are counted per project with their failures; reported usage sits beside them",
       %{token: token, key: key, home: home, other: other} do
    api(token) |> get("#{@base}/me") |> json_response(200)
    api(token) |> get("#{@base}/tasks") |> json_response(200)
    # a project the key cannot reach: a 404 at home
    api(token) |> get("#{@base}/tasks?project=#{other.uuid}") |> json_response(404)

    api(token)
    |> put_req_header("idempotency-key", "u1")
    |> post("#{@base}/usage", Jason.encode!(%{tokens: 1500, cost_cents: 4}))
    |> json_response(201)

    # a refusal: the key's access no longer covers tasks there
    {:ok, _} = ApiKeys.put_grant(key, home.uuid, %{"scopes" => ["project:read"]})
    api(token) |> get("#{@base}/tasks") |> json_response(403)

    [row] = ApiUsage.rows([key.uuid])
    assert row.project == home.uuid
    assert row.day == Date.utc_today()
    assert %{requests: 5, errors: 2, denied: 1} = row
    assert row.tokens == 1500.0
    assert row.cost_cents == 4.0

    days = ApiUsage.days([row], :requests)
    assert length(days) == 30
    assert List.last(days).parts == [{home.uuid, 5}]
  end

  test "the page shows the figures and switches what the charts draw",
       %{conn: conn, token: token, key: key, user: user} do
    api(token) |> get("#{@base}/me") |> json_response(200)

    conn = put_test_scope(conn, fake_scope(user_uuid: user.uuid, permissions: ["projects"]))
    {:ok, view, html} = live(conn, "/en/admin/projects/api-keys")

    assert html =~ "api-usage-summary"
    assert has_element?(view, "#usage-#{key.uuid}")
    assert has_element?(view, "#usage-chart-#{key.uuid}")

    html = view |> element("button[phx-value-metric='tokens']") |> render_click()
    assert html =~ "None of this in the last 30 days."
  end

  test "a key nobody has used says so", %{conn: conn, key: key, user: user} do
    conn = put_test_scope(conn, fake_scope(user_uuid: user.uuid, permissions: ["projects"]))
    {:ok, view, html} = live(conn, "/en/admin/projects/api-keys")
    assert html =~ "No use in the last 30 days."
    refute has_element?(view, "#usage-#{key.uuid}")
  end
end
