defmodule PhoenixKitProjects.Web.Api.Auth do
  @moduledoc """
  The API's bearer-token plug: `Authorization: Bearer pkp_…` →
  `PhoenixKitProjects.ApiKeys.authenticate/1` → the key, its project and the
  project's feature gates on the conn (`:pk_api_key`, `:pk_project`,
  `:pk_fx`), or one 401 for every refusal (missing, malformed, unknown,
  revoked, expired — a caller cannot tell them apart, on purpose). A key
  whose project is gone answers 401 too. A personal key whose person has
  left the project is a 403 `membership_ended` — that one the caller may
  know, it is their own membership.

  Then the key's rate limit (`Web.Api.RateLimit`): every authenticated
  response carries `x-ratelimit-limit` and `x-ratelimit-remaining`; a key
  over its window answers 429 `rate_limited` with `retry-after` (seconds)
  before any controller runs, so a refused call is never stored as an
  idempotent response.

  `last_used_at` is touched here, throttled by `ApiKeys.touch_last_used/1`.
  """

  @behaviour Plug

  import Plug.Conn

  alias PhoenixKitProjects.{ApiKeys, Features, Projects}
  alias PhoenixKitProjects.Web.Api.{Json, RateLimit}

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with {:ok, token} <- bearer(conn),
         {:ok, key} <- ApiKeys.authenticate(token),
         %{} = project <- Projects.get_project(key.project_uuid) || :no_project,
         {:ok, key} <- ApiKeys.resolve(key, project) do
      conn
      |> rate_limit(key)
      |> case do
        {:ok, conn} ->
          key = ApiKeys.touch_last_used(key)

          conn
          |> assign(:pk_api_key, key)
          |> assign(:pk_project, project)
          |> assign(:pk_fx, Features.gates(project))

        {:halt, conn} ->
          conn
      end
    else
      {:error, :membership_ended} ->
        conn
        |> Json.error(
          :forbidden,
          "membership_ended",
          "This key acts for a person who is no longer a member of the project."
        )
        |> halt()

      _ ->
        conn
        |> Json.error(
          :unauthorized,
          "unauthorized",
          "A valid project API key is required: Authorization: Bearer pkp_…"
        )
        |> halt()
    end
  end

  defp rate_limit(conn, key) do
    case RateLimit.hit(key) do
      :off ->
        {:ok, conn}

      {:allow, remaining} ->
        {:ok, conn |> limit_headers() |> put_resp_header("x-ratelimit-remaining", "#{remaining}")}

      {:deny, retry_after_ms} ->
        seconds = max(div(retry_after_ms + 999, 1000), 1)

        {:halt,
         conn
         |> limit_headers()
         |> put_resp_header("x-ratelimit-remaining", "0")
         |> put_resp_header("retry-after", "#{seconds}")
         |> Json.error(
           :too_many_requests,
           "rate_limited",
           "This key has used its #{RateLimit.describe()}; wait #{seconds}s and retry the same request.",
           %{retry_after_ms: retry_after_ms, retry_after_seconds: seconds}
         )
         |> halt()}
    end
  end

  defp limit_headers(conn) do
    case RateLimit.config() do
      %{limit: limit} -> put_resp_header(conn, "x-ratelimit-limit", "#{limit}")
      nil -> conn
    end
  end

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, String.trim(token)}
      ["bearer " <> token] -> {:ok, String.trim(token)}
      _ -> {:error, :missing}
    end
  end
end
