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

  The key's rate limit (`Web.Api.RateLimit`) comes right after the token
  is checked, before the account, grants and project are read: every
  authenticated response carries `x-ratelimit-limit` and
  `x-ratelimit-remaining`; a key over its window answers 429 `rate_limited`
  with `retry-after` (seconds) before any controller runs, so a refused call
  is never stored as an idempotent response and a flood of them costs the
  database almost nothing.

  `last_used_at` is touched here, throttled by `ApiKeys.touch_last_used/1`,
  and every authenticated call is counted per key, project and day once it
  is answered (`PhoenixKitProjects.ApiUsage.record/3`).
  """

  @behaviour Plug

  import Plug.Conn

  alias PhoenixKitProjects.{ApiKeys, ApiUsage, Features, Projects}
  alias PhoenixKitProjects.Schemas.ApiKey
  alias PhoenixKitProjects.Web.Api.{Json, RateLimit}

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with {:ok, token} <- bearer(conn),
         {:ok, key} <- ApiKeys.authenticate(token) do
      # The limit is taken before anything else is read about the key: a
      # key over its window costs the key lookup and one counter write, not
      # the account, grant and project reads a served call makes.
      # Switched off in Admin › Modules (an incident, a migration): the
      # admin pages close through core's mount gate, and the API with them
      # — a key must not go on writing tasks and time meanwhile.
      if PhoenixKitProjects.enabled?() do
        case rate_limit(conn, key) do
          {:ok, conn} -> refuse_nul(conn) || admit(conn, key)
          {:halt, conn} -> count_refused(conn, key)
        end
      else
        module_disabled(conn)
      end
    else
      _ -> unauthorized(conn)
    end
  end

  # Postgres refuses a NUL byte in `text` and `jsonb`: a title, note or
  # comment carrying one passed every validator and then raised in the
  # insert — a 500, and a retry that failed the same way. Refused here, for
  # every field of every call, as the field error it is.
  defp refuse_nul(conn) do
    case nul_field(conn.params, nil) do
      nil ->
        nil

      field ->
        why = "must not contain a NUL byte (\\u0000)"

        conn
        |> Json.error(
          :unprocessable_entity,
          "validation_failed",
          "#{field} #{why}.",
          %{field => [why]}
        )
        |> halt()
    end
  end

  defp nul_field(value, path) when is_binary(value),
    do: if(String.contains?(value, <<0>>), do: path || "request", else: nil)

  defp nul_field(%{} = map, path) when not is_struct(map) do
    Enum.find_value(map, fn {k, v} ->
      key = to_string(k)
      if String.contains?(key, <<0>>), do: path || "request", else: nul_field(v, join(path, key))
    end)
  end

  defp nul_field(list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.find_value(fn {v, i} -> nul_field(v, join(path, Integer.to_string(i))) end)
  end

  defp nul_field(_value, _path), do: nil

  defp join(nil, key), do: key
  defp join(path, key), do: path <> "." <> key

  defp module_disabled(conn) do
    conn
    |> Json.error(
      :service_unavailable,
      "module_disabled",
      "The Projects module is switched off on this site."
    )
    |> halt()
  end

  defp admit(conn, key) do
    PhoenixKitProjects.ApiKeys.reset_access_cache()

    with %{} = project <- home_project(key) || :no_project,
         {:ok, key, refused} <- home_view(key, project) do
      key = ApiKeys.touch_last_used(key)

      # A `#KEY-42` this request writes becomes a link only within the
      # key's reach (`RefText`, "Who is writing").
      # Only where it may read tasks: an interactions-only grant must
      # not turn `#ACME-12` into a link (and so confirm the task).
      PhoenixKitProjects.RefText.put_writer(
        {:reach, &PhoenixKitProjects.ApiKeys.allows?(key, &1, "tasks:read")}
      )

      Json.put_view(key)
      PhoenixKitProjects.Actor.put(ApiKey.accountable_uuid(key))
      PhoenixKitProjects.L10n.reset_viewer_zone()

      conn
      |> count_request(key, project)
      |> assign(:pk_api_key, key)
      |> assign(:pk_home_refused, refused)
      |> assign(:pk_project, project)
      |> assign(:pk_fx, Features.gates(project))
    else
      _ -> unauthorized(conn)
    end
  end

  defp unauthorized(conn) do
    conn
    |> Json.error(
      :unauthorized,
      "unauthorized",
      "A valid project API key is required: Authorization: Bearer pkp_…"
    )
    |> halt()
  end

  # Where a call without `project` acts: the key's home (V24) — its first
  # grant's project when the home was taken away.
  # A grant that gives no access (empty scopes) is not a home: the first
  # one that gives some is, else the first.
  defp home_project(key) do
    with nil <- key.project_uuid && Projects.get_project(key.project_uuid),
         [first | _] = grants <- ApiKeys.grants(key) do
      grant = Enum.find(grants, first, &(&1.scopes not in [nil, []]))
      Projects.get_project(grant.project_uuid)
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

  # Every authenticated call is counted once it is answered (`ApiUsage`,
  # the API keys page's charts): in the project it ended up acting in —
  # the home unless it named another — with its status, so refusals count
  # too.
  defp count_request(conn, key, home) do
    register_before_send(conn, fn conn ->
      project = conn.assigns[:pk_project] || home
      ApiUsage.record(key.uuid, project.uuid, conn.status || 200)
      conn
    end)
  end

  # A call over its rate limit is counted as the error it is, but it never
  # looked the home up (that is the point of limiting first): it goes
  # against the key's stored home, and is not counted for a key without one.
  defp count_refused(conn, key) do
    ApiUsage.record(key.uuid, key.project_uuid, conn.status || 429)
    conn
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
