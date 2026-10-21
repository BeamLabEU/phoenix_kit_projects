defmodule PhoenixKitProjects.Web.ApiRateLimitTest do
  @moduledoc """
  A key over its rate limit is refused before anything else is read about
  it: the limit is taken straight after the token is checked, so a flood of
  refused calls costs the key lookup and one counter write — not the
  account, grant and project reads a served call makes.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKitProjects.{ApiKeys, ApiUsage, QueryCounter}

  @base "/api/projects/v1"

  setup do
    previous = Application.get_env(:phoenix_kit_projects, :api_rate_limit)
    Application.put_env(:phoenix_kit_projects, :api_rate_limit, limit: 2, window_ms: 60_000)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit_projects, :api_rate_limit, previous),
        else: Application.delete_env(:phoenix_kit_projects, :api_rate_limit)
    end)

    project = fixture_project()
    {:ok, key, token} = ApiKeys.create(project, %{"name" => "Limited", "role" => "member"})

    {:ok, project: project, key: key, token: token}
  end

  defp api(token) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("accept", "application/json")
  end

  test "the call over the limit is a 429 with retry-after, counted as an error",
       %{token: token, key: key, project: project} do
    assert %{"project" => _} = api(token) |> get("#{@base}/me") |> json_response(200)

    conn = api(token) |> get("#{@base}/me")
    assert json_response(conn, 200)
    assert get_resp_header(conn, "x-ratelimit-remaining") == ["0"]

    conn = api(token) |> get("#{@base}/me")
    assert %{"error" => %{"code" => "rate_limited"}} = json_response(conn, 429)
    assert [_] = get_resp_header(conn, "retry-after")

    assert [row] = ApiUsage.rows([key.uuid])
    assert row.project == project.uuid
    assert %{requests: 3, errors: 1} = row
  end

  test "a refused call reads far less than a served one", %{token: token} do
    {_, served} = QueryCounter.count(fn -> api(token) |> get("#{@base}/me") end)
    api(token) |> get("#{@base}/me")

    {conn, refused} = QueryCounter.count(fn -> api(token) |> get("#{@base}/me") end)

    assert conn.status == 429
    # the key lookup and the counter write
    assert refused <= 3
    assert refused < served
  end
end
