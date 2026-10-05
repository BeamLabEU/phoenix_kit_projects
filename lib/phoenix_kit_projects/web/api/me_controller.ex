defmodule PhoenixKitProjects.Web.Api.MeController do
  @moduledoc """
  `GET /me` — the agent's entry point: who the key is and whom it acts
  for, what it may do on this project (the role it acts with right now),
  which features are on, and where the docs are. An agent reads this
  first instead of probing endpoints for 403s.
  """

  use Phoenix.Controller, formats: [:json]

  alias PhoenixKitProjects.{ApiKeys, Authz, Extensions}
  alias PhoenixKitProjects.Schemas.{ApiKey, Project}
  alias PhoenixKitProjects.Web.Api.{Docs, Json}
  alias PhoenixKitProjects.Web.ApiKeyPanel

  def show(conn, _params) do
    %{pk_api_key: key, pk_project: project, pk_fx: fx} = conn.assigns

    # This module's actions plus what the extension API providers ask for
    # (the CRM's `log_interaction`), so /me says the whole truth.
    allowed =
      (Authz.actions() ++ Enum.map(Extensions.api_providers(), & &1.module.action()))
      |> Enum.uniq()
      |> Enum.filter(&Authz.can_role?(project, key.role, &1))
      |> Enum.map(&Atom.to_string/1)

    json(conn, %{
      key: %{
        uuid: key.uuid,
        name: key.name,
        kind: ApiKey.kind(key),
        role: key.role,
        scopes: key.scopes,
        key_id: ApiKeys.display_prefix(key),
        expires_at: key.expires_at
      },
      acting_for: acting_for(key),
      project: Json.project(project),
      features: %{
        tasks: Map.get(fx, :tasks, false),
        ledger: Map.get(fx, :ledger, false),
        statuses: Map.get(fx, :statuses, false),
        estimates: Map.get(fx, :estimates, false),
        priorities: Map.get(fx, :priorities, false),
        progress: Map.get(fx, :progress, false)
      },
      extensions: Extensions.enabled_map(project.uuid),
      agent_policy: Project.agent_policy(project),
      allowed_actions: allowed,
      all_scopes: ApiKey.scopes(),
      docs: %{llms_txt: Docs.url("/llms.txt"), openapi: Docs.url("/openapi.json")}
    })
  end

  # The person a personal key acts for; a shared agent has none.
  defp acting_for(%ApiKey{user_uuid: uuid}) when is_binary(uuid) do
    %{uuid: uuid, name: ApiKeyPanel.user_name(uuid)}
  end

  defp acting_for(_key), do: nil
end
