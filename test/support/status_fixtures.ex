defmodule PhoenixKitProjects.StatusFixtures do
  @moduledoc """
  Test helpers for the entities-backed workflow-status feature.

  Toggling the `entities_enabled` setting flips
  `PhoenixKitProjects.Statuses.available?/0`. Because the setting lives in
  a process-wide ETS cache (not the sandbox), any test file using these
  helpers must be `async: false` (see workspace memory on Settings + ETS).
  """

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.Statuses

  @doc "Enables the entities module so `Statuses.available?/0` returns true."
  def enable_entities! do
    Settings.update_setting("entities_enabled", "true")
  end

  @doc "Disables the entities module (the graceful-degradation state)."
  def disable_entities! do
    Settings.update_setting("entities_enabled", "false")
  end

  @doc """
  Ensures at least one user exists and returns its uuid. Entities'
  `create_entity/2` requires a `created_by_uuid` and auto-fills it from
  the first admin/user — production always has one, the test sandbox
  doesn't, so seed one explicitly.
  """
  def ensure_actor! do
    case Auth.get_first_user_uuid() do
      nil ->
        {:ok, user} =
          Auth.register_user(%{
            email: "status-actor-#{System.unique_integer([:positive])}@example.com",
            password: "ValidPassword123!"
          })

        user.uuid

      uuid ->
        uuid
    end
  end

  @doc """
  Enables entities, ensures an actor exists, provisions the shared
  `project_status` entity with its default vocabulary, AND registers it as
  the global default status entity (so a project's "Shared default"
  resolves to it). Returns the entity.
  """
  def seed_shared_status_entity!(opts \\ []) do
    enable_entities!()
    actor_uuid = ensure_actor!()

    {:ok, entity} =
      Statuses.create_default_status_entity(Keyword.put_new(opts, :actor_uuid, actor_uuid))

    Statuses.set_default_status_entity(entity.uuid)
    entity
  end
end
