defmodule PhoenixKitProjects.Web.Api.Auth do
  @moduledoc """
  The API's bearer-token plug: `Authorization: Bearer pkp_…` →
  `PhoenixKitProjects.ApiKeys.authenticate/1` → the key, its project and the
  project's feature gates on the conn (`:pk_api_key`, `:pk_project`,
  `:pk_fx`), or one 401 for every refusal (missing, malformed, unknown,
  revoked, expired — a caller cannot tell them apart, on purpose). A key
  with no project left answers 401 too. A key that can no longer use its
  home (no access there, or its person left it) still authenticates: a
  call naming another project is checked there, and one that stays home
  is a 403 `no_access` / `membership_ended` (`Json.require_scope/2`), which
  the caller may know — it is their own key.

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
         %{} = project <- home_project(key) || :no_project,
         {:ok, key, refused} <- home_view(key, project) do
      conn
      |> rate_limit(key)
      |> case do
        {:ok, conn} ->
          key = ApiKeys.touch_last_used(key)

          # A `#KEY-42` this request writes becomes a link only within the
          # key's reach (`RefText`, "Who is writing").
          # Only where it may read tasks: an interactions-only grant must
          # not turn `#ANDI-12` into a link (and so confirm the task).
          PhoenixKitProjects.RefText.put_writer(
            {:reach, &PhoenixKitProjects.ApiKeys.allows?(key, &1, "tasks:read")}
          )

          Json.put_view(key)

          conn
          |> assign(:pk_api_key, key)
          |> assign(:pk_home_refused, refused)
          |> assign(:pk_project, project)
          |> assign(:pk_fx, Features.gates(project))

        {:halt, conn} ->
          conn
      end
    else
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

  # Where a call without `project` acts: the key's home (V24) — its first
  # grant's project when the home was taken away.
  defp home_project(key) do
    with nil <- key.project_uuid && Projects.get_project(key.project_uuid),
         [first | _] <- ApiKeys.grants(key) do
      Projects.get_project(first.project_uuid)
    else
      [] -> nil
      project -> project
    end
  end

  # The key as it stands at home. A home it can no longer use (an empty
  # grant there, a membership that ended) does not stop the key: a call
  # naming another project is rescoped there and checked on its own, and
  # one that stays home is refused with this reason (`Json.require_scope/2`).
  defp home_view(key, project) do
    case ApiKeys.resolve(key, project) do
      {:ok, key} ->
        {:ok, key, nil}

      {:error, reason} when reason in [:no_access, :membership_ended] ->
        {:ok, %{key | scopes: [], role: "viewer"}, reason}

      error ->
        error
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
