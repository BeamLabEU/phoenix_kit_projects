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

  @doc """
  Provisions a custom status entity seeded with the given `{title, slug}`
  rows (in order), WITHOUT registering it as the global default. Lets a test
  build a status list with slugs that differ from the default vocabulary —
  e.g. to exercise switching a started project onto a list that lacks its
  current selection. Returns the entity.
  """
  def seed_custom_status_entity!(rows, opts \\ []) when is_list(rows) do
    enable_entities!()
    actor_uuid = ensure_actor!()
    name = "custom_statuses_#{System.unique_integer([:positive])}"

    {:ok, entity} =
      PhoenixKitEntities.create_entity(
        %{
          name: name,
          display_name: "Custom Statuses",
          display_name_plural: "Custom Statuses",
          description: "Test statuses.",
          fields_definition: [],
          settings: %{"source" => "phoenix_kit_projects", "scope" => "shared"},
          created_by_uuid: actor_uuid
        },
        Keyword.put_new(opts, :actor_uuid, actor_uuid)
      )

    rows
    |> Enum.with_index(1)
    |> Enum.each(fn {{title, slug}, position} ->
      {:ok, _} =
        PhoenixKitEntities.EntityData.create(
          %{
            entity_uuid: entity.uuid,
            title: title,
            slug: slug,
            position: position,
            status: "published"
          },
          opts
        )
    end)

    entity
  end
end
