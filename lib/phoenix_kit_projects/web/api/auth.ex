defmodule PhoenixKitProjects.Web.Api.Auth do
  @moduledoc """
  The API's bearer-token plug: `Authorization: Bearer pkp_…` →
  `PhoenixKitProjects.ApiKeys.authenticate/1` → the key, its project and the
  project's feature gates on the conn (`:pk_api_key`, `:pk_project`,
  `:pk_fx`), or one 401 for every refusal (missing, malformed, unknown,
  revoked, expired — a caller cannot tell them apart, on purpose). A key
  whose project is gone answers 401 too.

  `last_used_at` is touched here, throttled by `ApiKeys.touch_last_used/1`.
  """

  @behaviour Plug

  import Plug.Conn

  alias PhoenixKitProjects.{ApiKeys, Features, Projects}
  alias PhoenixKitProjects.Web.Api.Json

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with {:ok, token} <- bearer(conn),
         {:ok, key} <- ApiKeys.authenticate(token),
         %{} = project <- Projects.get_project(key.project_uuid) || :no_project do
      key = ApiKeys.touch_last_used(key)

      conn
      |> assign(:pk_api_key, key)
      |> assign(:pk_project, project)
      |> assign(:pk_fx, Features.gates(project))
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

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, String.trim(token)}
      ["bearer " <> token] -> {:ok, String.trim(token)}
      _ -> {:error, :missing}
    end
  end
end
