defmodule PhoenixKitProjects.Web.Api.MeController do
  @moduledoc """
  `GET /me` — the agent's entry point: who the key is, what it may do on
  this project, which features are on, and where the docs are. An agent
  reads this first instead of probing endpoints for 403s.
  """

  use Phoenix.Controller, formats: [:json]

  alias PhoenixKitProjects.{ApiKeys, Authz}
  alias PhoenixKitProjects.Schemas.ApiKey
  alias PhoenixKitProjects.Web.Api.{Docs, Json}

  def show(conn, _params) do
    %{pk_api_key: key, pk_project: project, pk_fx: fx} = conn.assigns

    allowed =
      Authz.actions()
      |> Enum.filter(&Authz.can_role?(project, key.role, &1))
      |> Enum.map(&Atom.to_string/1)

    json(conn, %{
      key: %{
        uuid: key.uuid,
        name: key.name,
        role: key.role,
        scopes: key.scopes,
        key_id: ApiKeys.display_prefix(key),
        expires_at: key.expires_at
      },
      project: Json.project(project),
      features: %{
        tasks: Map.get(fx, :tasks, false),
        ledger: Map.get(fx, :ledger, false),
        statuses: Map.get(fx, :statuses, false),
        estimates: Map.get(fx, :estimates, false),
        priorities: Map.get(fx, :priorities, false),
        progress: Map.get(fx, :progress, false)
      },
      allowed_actions: allowed,
      all_scopes: ApiKey.scopes(),
      docs: %{llms_txt: Docs.url("/llms.txt"), openapi: Docs.url("/openapi.json")}
    })
  end
end
