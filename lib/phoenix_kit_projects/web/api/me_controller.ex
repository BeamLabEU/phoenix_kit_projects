defmodule PhoenixKitProjects.Web.Api.MeController do
  @moduledoc """
  `GET /me` — the agent's entry point: who the key is and whom it acts
  for, its HOME project (where a call without `project` acts) with what it
  may do there, and EVERY project it reaches with its access in each —
  per area none / read / write (V24) — so an agent never infers one
  project's rights from another's. An agent reads this first instead of
  probing endpoints for 403s.
  """

  use Phoenix.Controller, formats: [:json]

  alias PhoenixKitProjects.{ApiAccess, ApiKeys, Authz, Extensions}
  alias PhoenixKitProjects.Schemas.{ApiKey, Project}
  alias PhoenixKitProjects.Web.Api.{Assignee, Docs, Json}
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
      home_project: Json.project(project),
      # Kept for agents written before V24: the same as `home_project`.
      project: Json.project(project),
      projects: reachable(key),
      # Every gate of the task tracker (labels, dependencies, subprojects,
      # … included) — the guide names them and an agent reads them here.
      features: fx,
      extensions: Extensions.enabled_map(project.uuid),
      agent_policy: Project.agent_policy(project),
      allowed_actions: allowed,
      all_scopes: ApiKey.scopes(),
      docs: %{llms_txt: Docs.url("/llms.txt"), openapi: Docs.url("/openapi.json")}
    })
  end

  # Every project the key reaches: its key (what to pass as `project`), its
  # access per area, the role the key acts with there, and where that
  # access comes from (its own grant, or a parent's that covers it).
  defp reachable(key) do
    key
    |> ApiKeys.reachable()
    |> Enum.map(fn %{project: p, scopes: scopes, role: role, source: source} ->
      %{
        key: p.key,
        uuid: p.uuid,
        name: p.name,
        archived: not is_nil(p.archived_at),
        role: role,
        scopes: scopes,
        access: ApiAccess.grid(scopes),
        source:
          case source do
            :direct -> "direct"
            {:inherited, from} -> %{inherited_from: from}
          end
      }
    end)
  end

  # The person a personal key acts for; a shared agent has none.
  defp acting_for(%ApiKey{user_uuid: uuid} = key) when is_binary(uuid) do
    # `person_uuid`: their staff record, what `assignee: "me"` resolves to
    %{uuid: uuid, name: ApiKeyPanel.user_name(uuid), person_uuid: Assignee.person_uuid(key)}
  end

  defp acting_for(_key), do: nil
end
