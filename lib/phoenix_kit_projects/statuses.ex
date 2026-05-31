defmodule PhoenixKitProjects.Statuses do
  @moduledoc """
  User-defined project **workflow statuses**, configured through the
  optional `phoenix_kit_entities` module and cemented locally when a
  project starts.

  Two layers:

  - **Catalog (entities).** A shared `project_status` entity (auto-seeded
    with a default vocabulary) and/or full custom per-project entities the
    user owns. Templates and not-yet-started projects read this catalog
    live, so edits to the vocabulary flow straight through.
  - **Cemented (local).** When a project starts, its chosen catalog
    statuses are snapshotted into `phoenix_kit_project_statuses`
    (`PhoenixKitProjects.Schemas.ProjectStatus`). The running project then
    uses its own frozen, independently-editable copy — later catalog edits
    don't touch it. Mirrors the module's template→instance philosophy.

  The selected status is addressed by its **slug** (`current_status_slug`
  on the project), a stable identity that resolves against the live
  catalog before start and the cemented local rows after.

  ## Optional dependency

  `phoenix_kit_entities` is optional. Every public function degrades
  gracefully when it's absent or disabled: reads return `[]`/`nil`,
  provisioning returns `{:error, :entities_not_available}`, and
  `cement_project_statuses/2` becomes a no-op. The guard scaffolding
  (`@compile {:no_warn_undefined, …}` + `safe_call/2` + `available?/0`)
  mirrors `PhoenixKitProjects.Translations`.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKit.Utils.Multilang
  alias PhoenixKitProjects.L10n
  alias PhoenixKitProjects.Schemas.{Project, ProjectStatus}

  @default_entity_base "project_statuses"
  @per_project_prefix "project_status_"
  @source_tag "phoenix_kit_projects"
  # Admin-chosen global default status entity (the "Shared default" a project
  # falls back to). Set on the projects Settings page; nothing auto-creates it.
  @default_status_setting "projects_default_status_entity_uuid"

  # The default vocabulary seeded into a freshly-created status entity.
  # Title-only for now — the label rides the built-in EntityData `title`
  # column and the order rides `position`. (Colour is still read/rendered
  # if a record carries a `color` data field, but we don't seed one.)
  # Seed vocabulary for a generated default status list. These titles are
  # written into entity_data `title` columns (user-owned, editable, and
  # translatable per-language in the entities admin) — they are NOT rendered
  # through `gettext/1`, so `mix gettext.extract` does not pick them up and
  # they ship in English. That is intentional: a generated list is a starting
  # point the admin localises in the entities UI, not a fixed UI string.
  @default_statuses [
    %{title: "Backlog", slug: "backlog", position: 1},
    %{title: "Planned", slug: "planned", position: 2},
    %{title: "In Progress", slug: "in-progress", position: 3},
    %{title: "Blocked", slug: "blocked", position: 4},
    %{title: "In Review", slug: "in-review", position: 5},
    %{title: "Done", slug: "done", position: 6}
  ]

  # No custom field definitions — a status is just its title (built-in).
  # Colour/other fields can be added later without a code change.
  @fields_definition []

  # `PhoenixKitEntities` is the optional plugin — hosts may not pull it in.
  @compile {:no_warn_undefined,
            [
              {PhoenixKitEntities, :enabled?, 0},
              {PhoenixKitEntities, :get_entity_by_name, 1},
              {PhoenixKitEntities, :create_entity, 2},
              {PhoenixKitEntities, :list_entities, 0},
              {PhoenixKitEntities, :list_entities, 1},
              {PhoenixKitEntities.EntityData, :create, 2},
              {PhoenixKitEntities.EntityData, :list_by_entity, 1}
            ]}

  @typedoc """
  A normalized status row, identical whether it came from the live catalog
  or a cemented local row. `uuid` is the source row's uuid (entity_data
  uuid pre-start, `phoenix_kit_project_statuses` uuid post-start); `slug`
  is the stable cross-boundary identity.
  """
  @type status :: %{
          uuid: String.t() | nil,
          label: String.t(),
          slug: String.t(),
          color: String.t() | nil,
          position: integer()
        }

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @doc "Base name for generated default status entities (`\"project_statuses\"`)."
  @spec default_entity_base() :: String.t()
  def default_entity_base, do: @default_entity_base

  @doc "The default seeded status vocabulary (for tests / inspection)."
  @spec default_statuses() :: [map()]
  def default_statuses, do: @default_statuses

  @doc """
  Is the entities-backed status feature usable right now? True when the
  optional `phoenix_kit_entities` plugin is loaded AND enabled at runtime.
  """
  @spec available?() :: boolean()
  def available? do
    Code.ensure_loaded?(PhoenixKitEntities) and
      safe_call(fn -> PhoenixKitEntities.enabled?() end, false)
  end

  # ── Catalog provisioning ─────────────────────────────────────────────

  @doc """
  Creates a **new** default status entity, seeded with the default
  vocabulary, and returns `{:ok, entity}` (or `{:error, :entities_not_available}`).

  Named `project_statuses`; if that's already taken it auto-increments —
  `project_statuses_2`, `project_statuses_3`, … — so generating a default
  again always produces a fresh, independent list rather than reusing the
  existing one.
  """
  @spec create_default_status_entity(keyword()) :: {:ok, struct()} | {:error, term()}
  def create_default_status_entity(opts \\ []) do
    if available?() do
      safe_call(
        fn ->
          {name, display} = next_available_status_name()
          create_and_seed(name, display, display, "shared", opts)
        end,
        {:error, :entities_not_available}
      )
    else
      {:error, :entities_not_available}
    end
  end

  # Finds the first free `project_statuses` / `project_statuses_<n>` name.
  defp next_available_status_name(n \\ 1) do
    {name, display} =
      if n == 1,
        do: {@default_entity_base, "Project Statuses"},
        else: {"#{@default_entity_base}_#{n}", "Project Statuses #{n}"}

    case PhoenixKitEntities.get_entity_by_name(name) do
      nil -> {name, display}
      _exists -> next_available_status_name(n + 1)
    end
  end

  @doc """
  Provisions a dedicated custom status entity for `project` (named
  `project_status_<uuid>`), seeds it with the defaults as a starting
  point, points the project's `status_entity_uuid` at it, and returns
  `{:ok, project}` with the updated project.

  This is the per-project opt-in. The user fully owns the resulting
  entity afterward (rename, restructure fields, edit statuses) in the
  entities admin. No-op-with-error when entities is unavailable.
  """
  @spec ensure_project_status_entity(Project.t(), keyword()) ::
          {:ok, Project.t()} | {:error, term()}
  def ensure_project_status_entity(%Project{} = project, opts \\ []) do
    name = per_project_entity_name(project)

    with true <- available?() || {:error, :entities_not_available},
         {:ok, entity} <-
           safe_call(
             fn ->
               case PhoenixKitEntities.get_entity_by_name(name) do
                 nil ->
                   create_and_seed(name, "Project Status", "Project Statuses", "project", opts)

                 entity ->
                   {:ok, entity}
               end
             end,
             {:error, :entities_not_available}
           ),
         {:ok, updated} <-
           PhoenixKitProjects.Projects.update_project(project, %{status_entity_uuid: entity.uuid}) do
      {:ok, updated}
    else
      {:error, _} = err -> err
      false -> {:error, :entities_not_available}
    end
  end

  @doc """
  Per-project custom status entity name: `project_status_<32 hex>` (the
  full project UUID with hyphens stripped — 47 chars, under the 50-char
  entity-name limit, and collision-free unlike a UUIDv7 prefix).
  """
  @spec per_project_entity_name(Project.t()) :: String.t()
  def per_project_entity_name(%Project{uuid: uuid}) when is_binary(uuid),
    do: @per_project_prefix <> String.replace(uuid, "-", "")

  # Creates the entity then seeds the default rows. Seeding failures are
  # logged but don't fail the provisioning (the entity exists; the user
  # can add statuses by hand).
  defp create_and_seed(name, display, display_plural, scope, opts) do
    attrs = %{
      name: name,
      display_name: display,
      display_name_plural: display_plural,
      description: "Workflow statuses for projects.",
      icon: "hero-flag",
      fields_definition: @fields_definition,
      settings: %{"source" => @source_tag, "scope" => scope}
    }

    attrs = maybe_put(attrs, :created_by_uuid, opts[:actor_uuid])

    case PhoenixKitEntities.create_entity(attrs, opts) do
      {:ok, entity} ->
        seed_defaults(entity, opts)
        {:ok, entity}

      {:error, _changeset} ->
        # Likely a name-uniqueness race — re-fetch and treat as success.
        case PhoenixKitEntities.get_entity_by_name(name) do
          nil -> {:error, :status_entity_create_failed}
          entity -> {:ok, entity}
        end
    end
  end

  defp seed_defaults(entity, opts) do
    Enum.each(@default_statuses, fn s ->
      PhoenixKitEntities.EntityData.create(
        %{
          entity_uuid: entity.uuid,
          title: s.title,
          slug: s.slug,
          position: s.position,
          status: "published"
        },
        opts
      )
    end)
  rescue
    e ->
      Logger.warning("[Projects.Statuses] seeding defaults failed: #{Exception.message(e)}")
      :ok
  end

  # ── Reading statuses ──────────────────────────────────────────────────

  @doc """
  The status list for a project — cemented local rows once it has started,
  otherwise the live catalog list it draws from. `[]` when entities is
  unavailable and the project hasn't started.
  """
  @spec statuses_for(Project.t()) :: [status()]
  def statuses_for(%Project{started_at: %DateTime{}} = project),
    do: list_project_statuses(project)

  def statuses_for(%Project{} = project) do
    case resolve_catalog_entity_uuid(project) do
      {:ok, entity_uuid} -> catalog_rows_at(entity_uuid, effective_status_lang(project))
      _ -> []
    end
  end

  @doc """
  Whether status titles display in the viewer's content locale for this
  project: the per-project override if set, else the global
  `projects_use_status_translations` setting (default `true`). Translations
  are always captured; this only gates display.
  """
  @spec use_status_translations?(Project.t()) :: boolean()
  def use_status_translations?(%Project{} = project),
    do: use_status_translations?(project, global_use_status_translations?())

  # Same, but with the global default pre-resolved — lets batch callers read
  # the `projects_use_status_translations` setting once for a whole list.
  @spec use_status_translations?(Project.t(), boolean()) :: boolean()
  def use_status_translations?(%Project{} = project, global_default) do
    case Project.status_translation_override(project) do
      override when is_boolean(override) -> override
      _ -> global_default
    end
  end

  @doc "The global default for status-title translation display (setting, default true)."
  @spec global_use_status_translations?() :: boolean()
  def global_use_status_translations? do
    safe_call(
      fn -> PhoenixKit.Settings.get_boolean_setting("projects_use_status_translations", true) end,
      true
    )
  end

  # The locale to resolve status titles to for this project — the content
  # locale when translation display is on, else `nil` (primary title).
  # Accepts a pre-resolved global default so batch callers (the list view)
  # read the `projects_use_status_translations` setting ONCE rather than
  # once per project.
  defp effective_status_lang(project, global_default \\ global_use_status_translations?()) do
    if use_status_translations?(project, global_default),
      do: L10n.current_content_lang(),
      else: nil
  end

  @doc """
  The currently-selected status for a project as a normalized map, or
  `nil` when unset / unresolvable (e.g. the slug points at a trashed
  catalog row, or entities is unavailable).
  """
  @spec current_status(Project.t()) :: status() | nil
  def current_status(%Project{current_status_slug: slug}) when slug in [nil, ""], do: nil

  def current_status(%Project{current_status_slug: slug} = project) do
    project |> statuses_for() |> Enum.find(&(&1.slug == slug))
  end

  @doc """
  Live catalog statuses for a given entity uuid (normalized). `[]` when
  entities is unavailable.
  """
  @spec list_catalog_statuses(String.t()) :: [status()]
  def list_catalog_statuses(entity_uuid) when is_binary(entity_uuid),
    # `catalog_rows_at/2 → fetch_catalog_rows/2` already guards on
    # `available?/0` (returning `[]` when entities is off), so no second check.
    do: catalog_rows_at(entity_uuid, L10n.current_content_lang())

  def list_catalog_statuses(_), do: []

  # Reads catalog records normalized, with each record's title resolved to
  # `lang` via the entities module's built-in `:lang` resolution (falls
  # back to the primary title when a record has no translation). `nil`
  # lang reads the raw primary title. `[]` when entities is unavailable.
  defp catalog_rows_at(entity_uuid, nil), do: fetch_catalog_rows(entity_uuid, [])

  defp catalog_rows_at(entity_uuid, lang) when is_binary(lang),
    do: fetch_catalog_rows(entity_uuid, lang: lang)

  defp fetch_catalog_rows(entity_uuid, opts) do
    if available?() do
      safe_call(
        fn ->
          entity_uuid
          |> PhoenixKitEntities.EntityData.list_by_entity(opts)
          |> Enum.map(&normalize_catalog_row/1)
        end,
        []
      )
    else
      []
    end
  end

  @doc """
  Statuses from the shared catalog entity if it already exists — does
  NOT provision it (unlike `resolve_catalog_entity_uuid/1`). Used by the
  list view's status filter, which shouldn't seed the entity as a side
  effect of rendering. `[]` when the shared entity hasn't been created
  yet or entities is unavailable.
  """
  @spec shared_catalog_statuses() :: [status()]
  def shared_catalog_statuses do
    case global_default_status_entity_uuid() do
      uuid when is_binary(uuid) -> list_catalog_statuses(uuid)
      _ -> []
    end
  end

  @doc """
  Entities selectable as a project's status source, grouped for a picker:
  `[{"Status lists", [{name, uuid}]}, {"Other entities", [{name, uuid}]}]`.
  Status-tagged catalogs (the shared entity + per-project opt-ins, marked
  `settings["source"] = "phoenix_kit_projects"`) come first; every other
  entity follows, since any entity's records can serve as statuses (record
  title = label). Empty groups are omitted. `[]` when entities is
  unavailable.
  """
  @spec list_status_source_entities() :: [{String.t(), [{String.t(), String.t()}]}]
  def list_status_source_entities do
    if available?() do
      safe_call(
        fn ->
          {tagged, others} =
            PhoenixKitEntities.list_entities()
            |> Enum.split_with(&status_tagged?/1)

          [
            {"Status lists", Enum.map(tagged, &{entity_label(&1), &1.uuid})},
            {"Other entities", Enum.map(others, &{entity_label(&1), &1.uuid})}
          ]
          |> Enum.reject(fn {_group, items} -> items == [] end)
        end,
        []
      )
    else
      []
    end
  end

  defp status_tagged?(%{settings: settings}) when is_map(settings),
    do: Map.get(settings, "source") == @source_tag

  defp status_tagged?(_), do: false

  defp entity_label(entity), do: Map.get(entity, :display_name) || Map.get(entity, :name)

  @doc """
  Points a project at `entity_uuid` as its status source (nil = the shared
  default). For an **already-started** project this re-cements immediately
  — the chosen entity's statuses are snapshotted into fresh local rows
  (replacing any existing cemented rows), per the "cement on selection"
  rule — so existing/running projects get a usable, frozen status set.
  Unstarted projects just record the choice and cement at start as usual.
  """
  @spec set_status_entity(Project.t(), String.t() | nil, keyword()) ::
          {:ok, Project.t()} | {:error, term()}
  def set_status_entity(%Project{} = project, entity_uuid, _opts \\ []) do
    entity_uuid = if entity_uuid in [nil, ""], do: nil, else: entity_uuid

    if started?(project) do
      # Repoint + re-cement + reconcile the selection in ONE transaction, so
      # a started project never ends up pointing at a new entity while its
      # local rows (or `current_status_slug`) still reflect the old one.
      repo().transaction(fn ->
        case update_status_entity(project, entity_uuid) do
          {:ok, updated} -> do_recement(updated)
          {:error, changeset} -> repo().rollback(changeset)
        end
      end)
    else
      update_status_entity(project, entity_uuid)
    end
  end

  defp update_status_entity(project, entity_uuid),
    do: PhoenixKitProjects.Projects.update_project(project, %{status_entity_uuid: entity_uuid})

  @doc """
  Updates a project (arbitrary form attrs) and, when a **started** project's
  status source changed, re-cements its local rows — all in one transaction.
  This is the atomic edit-form entry point: `update_project/2` followed by a
  separate re-cement would leave a failure window where the project points at
  a new entity with stale local rows. Returns the (possibly slug-reconciled)
  project. Unstarted projects just record the choice and cement at start.
  """
  @spec update_project_with_statuses(Project.t(), map()) ::
          {:ok, Project.t()} | {:error, term()}
  def update_project_with_statuses(%Project{} = project, attrs) do
    old_entity = project.status_entity_uuid

    repo().transaction(fn ->
      case PhoenixKitProjects.Projects.update_project(project, attrs) do
        {:ok, updated} ->
          if started?(updated) and updated.status_entity_uuid != old_entity,
            do: do_recement(updated),
            else: updated

        {:error, changeset} ->
          repo().rollback(changeset)
      end
    end)
  end

  @doc "True once a project has started (has a `started_at`)."
  @spec started?(Project.t()) :: boolean()
  def started?(%Project{started_at: %DateTime{}}), do: true
  def started?(_), do: false

  @doc """
  Clear + re-copy the chosen catalog into local rows, atomically. Used when
  a started project switches its status source (from the show-page picker).
  Existing local edits are intentionally discarded — the user chose a
  different list. Returns the (possibly slug-reconciled) project, or
  `{:error, changeset}` if the reconciling write fails. No-op (returns
  `{:ok, project}`) when entities is unavailable.
  """
  @spec recement_project_statuses(Project.t()) :: {:ok, Project.t()} | {:error, term()}
  def recement_project_statuses(%Project{} = project) do
    repo().transaction(fn -> do_recement(project) end)
  end

  # Clears local rows, re-copies the chosen catalog, then reconciles the
  # current selection. Runs inside the caller's transaction; raises/rolls
  # back on a write failure. Returns the (possibly updated) project.
  defp do_recement(%Project{uuid: uuid} = project) do
    repo().delete_all(from(s in ProjectStatus, where: s.project_uuid == ^uuid))
    slugs = do_cement(project)
    reconcile_current_status(project, slugs)
  end

  # After a re-cement the previously-selected status may no longer exist in
  # the new list — clear `current_status_slug` so the project doesn't keep a
  # dangling selection that silently renders as "no status".
  defp reconcile_current_status(%Project{current_status_slug: slug} = project, slugs)
       when is_binary(slug) and slug != "" do
    if slug in slugs do
      project
    else
      case project
           |> Project.current_status_changeset(%{current_status_slug: nil})
           |> repo().update() do
        {:ok, updated} -> updated
        {:error, changeset} -> repo().rollback(changeset)
      end
    end
  end

  defp reconcile_current_status(project, _slugs), do: project

  @doc "Cemented local status rows for a project, ordered by position."
  @spec list_project_statuses(Project.t()) :: [status()]
  def list_project_statuses(%Project{uuid: uuid} = project) do
    lang = effective_status_lang(project)

    ProjectStatus
    |> where([s], s.project_uuid == ^uuid)
    |> order_by([s], asc: s.position, asc: s.inserted_at, asc: s.uuid)
    |> repo().all()
    |> Enum.map(&normalize_local_row(&1, lang))
  end

  @doc """
  Resolves which catalog entity a project/template draws from: its own
  `status_entity_uuid` (per-project choice), else the **admin-chosen global
  default** (the `projects_default_status_entity_uuid` setting, picked on the
  projects Settings page). Returns `{:ok, uuid}` or `{:error, :no_status_entity}`
  when neither is set — nothing is auto-provisioned.
  """
  @spec resolve_catalog_entity_uuid(Project.t()) :: {:ok, String.t()} | {:error, term()}
  def resolve_catalog_entity_uuid(%Project{status_entity_uuid: uuid}) when is_binary(uuid),
    do: {:ok, uuid}

  def resolve_catalog_entity_uuid(%Project{}) do
    case global_default_status_entity_uuid() do
      uuid when is_binary(uuid) -> {:ok, uuid}
      _ -> {:error, :no_status_entity}
    end
  end

  @doc """
  The admin-chosen global default status entity uuid (the
  `projects_default_status_entity_uuid` setting), or `nil` when unset. This
  is what a project's "Shared default" resolves to. Set on the projects
  Settings page; nothing is auto-created.
  """
  @spec global_default_status_entity_uuid() :: String.t() | nil
  def global_default_status_entity_uuid do
    case safe_setting(@default_status_setting) do
      uuid when is_binary(uuid) and uuid != "" -> uuid
      _ -> nil
    end
  end

  @doc "Sets (or clears with `nil`) the global default status entity."
  @spec set_default_status_entity(String.t() | nil) :: term()
  def set_default_status_entity(uuid) do
    PhoenixKit.Settings.update_setting_with_module(
      @default_status_setting,
      uuid || "",
      "projects"
    )
  end

  defp safe_setting(key) do
    safe_call(fn -> PhoenixKit.Settings.get_setting(key) end, nil)
  end

  # ── Cementing (called from Projects.start_project/2) ──────────────────

  @doc """
  Snapshots a project's chosen catalog statuses into local
  `phoenix_kit_project_statuses` rows. Called inside `start_project/2`'s
  transaction. Idempotent: a no-op if the project already has cemented
  rows. A no-op (returns `:ok`) when entities is unavailable — a started
  project simply has no workflow statuses until the module is wired up.

  Runs inside the caller's transaction, so a raised error rolls the whole
  start back.
  """
  @spec cement_project_statuses(Project.t(), keyword()) :: :ok
  def cement_project_statuses(%Project{} = project, _opts \\ []) do
    cond do
      already_cemented?(project) -> :ok
      not available?() -> :ok
      true -> do_cement(project)
    end
  end

  defp already_cemented?(%Project{uuid: uuid}) do
    repo().exists?(from(s in ProjectStatus, where: s.project_uuid == ^uuid))
  end

  # Copies the chosen catalog's rows into local `phoenix_kit_project_statuses`
  # rows. Returns the list of cemented slugs (`[]` when there's no resolvable
  # entity) so callers can reconcile a project's current selection.
  defp do_cement(%Project{uuid: uuid} = project) do
    case resolve_catalog_entity_uuid(project) do
      {:ok, entity_uuid} ->
        # Cement the PRIMARY-language title as the canonical label, and
        # capture per-language title translations into the row's
        # `translations` JSONB so a started project stays localized
        # independent of the catalog.
        primary_rows = entity_uuid |> catalog_rows_at(nil) |> dedupe_slugs()
        primary_by_slug = Map.new(primary_rows, &{&1.slug, &1.label})
        translations_by_slug = capture_translations(entity_uuid, primary_by_slug)

        Enum.each(primary_rows, fn s ->
          %ProjectStatus{}
          |> ProjectStatus.changeset(%{
            project_uuid: uuid,
            label: s.label,
            slug: s.slug,
            position: s.position,
            data: if(s.color, do: %{"color" => s.color}, else: %{}),
            translations: Map.get(translations_by_slug, s.slug, %{}),
            source_entity_data_uuid: s.uuid
          })
          |> repo().insert!()
        end)

        Enum.map(primary_rows, & &1.slug)

      {:error, _} ->
        []
    end
  end

  # Builds `%{slug => %{lang => %{"label" => translated_title}}}` for every
  # enabled non-primary language, by reading the catalog resolved to each
  # language. Skips entries equal to the primary label (no real override).
  defp capture_translations(entity_uuid, primary_by_slug) do
    primary = primary_lang_code()

    enabled_lang_codes()
    |> Enum.reject(&(&1 == primary))
    |> Enum.reduce(%{}, fn lang, acc ->
      entity_uuid
      |> catalog_rows_at(lang)
      |> Enum.reduce(acc, fn row, inner ->
        primary_label = Map.get(primary_by_slug, row.slug)

        if is_binary(row.label) and row.label != "" and row.label != primary_label do
          Map.update(
            inner,
            row.slug,
            %{lang => %{"label" => row.label}},
            &Map.put(&1, lang, %{"label" => row.label})
          )
        else
          inner
        end
      end)
    end)
  end

  defp enabled_lang_codes do
    safe_call(
      fn ->
        Multilang.enabled_languages()
        |> Enum.map(&lang_code/1)
        |> Enum.reject(&is_nil/1)
      end,
      []
    )
  end

  defp primary_lang_code do
    safe_call(fn -> lang_code(Multilang.primary_language()) end, nil)
  end

  defp lang_code(code) when is_binary(code), do: code
  defp lang_code(%{code: code}), do: code
  defp lang_code(%{"code" => code}), do: code
  defp lang_code(_), do: nil

  # Guarantee unique slugs within the cemented set (the
  # (project_uuid, slug) unique index would otherwise reject a second row
  # whose label slugified to the same value). Suffixes collisions -2, -3…
  defp dedupe_slugs(statuses) do
    {rows, _seen} =
      Enum.map_reduce(statuses, MapSet.new(), fn s, seen ->
        slug = unique_slug(s.slug, seen)
        {%{s | slug: slug}, MapSet.put(seen, slug)}
      end)

    rows
  end

  defp unique_slug(slug, seen, suffix \\ 1) do
    candidate = if suffix == 1, do: slug, else: "#{slug}-#{suffix}"
    if MapSet.member?(seen, candidate), do: unique_slug(slug, seen, suffix + 1), else: candidate
  end

  # ── Setting the current status ────────────────────────────────────────

  @doc """
  Sets a project's current workflow status by slug (or clears it with
  `nil`). Validates the slug against the project's resolved status list
  before writing. Delegates the write to
  `PhoenixKitProjects.Projects.set_current_status_slug/2` so the single
  PubSub broadcast fires. Returns `{:ok, project}` or `{:error, reason}`.
  """
  @spec set_current_status(Project.t(), String.t() | nil, keyword()) ::
          {:ok, Project.t()} | {:error, term()}
  def set_current_status(project, slug, opts \\ [])

  def set_current_status(%Project{} = project, nil, _opts),
    do: PhoenixKitProjects.Projects.set_current_status_slug(project, nil)

  def set_current_status(%Project{} = project, slug, _opts) when is_binary(slug) do
    valid_slugs = project |> statuses_for() |> Enum.map(& &1.slug)

    if slug in valid_slugs do
      PhoenixKitProjects.Projects.set_current_status_slug(project, slug)
    else
      {:error, :invalid_status}
    end
  end

  # ── Local CRUD for post-start editing ─────────────────────────────────

  @doc "Adds a cemented status row to a started project."
  @spec add_project_status(Project.t(), map()) ::
          {:ok, ProjectStatus.t()} | {:error, Ecto.Changeset.t()}
  def add_project_status(%Project{uuid: uuid}, attrs) do
    position = attrs[:position] || attrs["position"] || next_local_position(uuid)

    %ProjectStatus{}
    |> ProjectStatus.changeset(
      attrs
      |> stringify()
      |> Map.merge(%{"project_uuid" => uuid, "position" => position})
    )
    |> repo().insert()
  end

  @doc "Updates a cemented status row."
  @spec update_project_status_row(ProjectStatus.t(), map()) ::
          {:ok, ProjectStatus.t()} | {:error, Ecto.Changeset.t()}
  def update_project_status_row(%ProjectStatus{} = row, attrs),
    do: row |> ProjectStatus.changeset(stringify(attrs)) |> repo().update()

  @doc "Deletes a cemented status row."
  @spec remove_project_status(ProjectStatus.t()) ::
          {:ok, ProjectStatus.t()} | {:error, Ecto.Changeset.t()}
  def remove_project_status(%ProjectStatus{} = row), do: repo().delete(row)

  @doc "Fetches a cemented status row by uuid, scoped to a project."
  @spec get_project_status(Project.t(), String.t()) :: ProjectStatus.t() | nil
  def get_project_status(%Project{uuid: project_uuid}, uuid) when is_binary(uuid) do
    repo().one(
      from(s in ProjectStatus, where: s.project_uuid == ^project_uuid and s.uuid == ^uuid)
    )
  end

  defp next_local_position(project_uuid) do
    case repo().one(
           from(s in ProjectStatus,
             where: s.project_uuid == ^project_uuid,
             select: max(s.position)
           )
         ) do
      nil -> 1
      n -> n + 1
    end
  end

  # ── Batched list-view enrichment ──────────────────────────────────────

  @doc """
  Batched current-status lookup for a list of projects. Returns
  `%{project_uuid => status() | nil}`. Groups started projects by a single
  local query and unstarted projects by their resolved catalog entity (one
  `list_by_entity` per distinct entity) to avoid an N+1. Empty map when
  entities is unavailable.
  """
  @spec statuses_for_projects([Project.t()]) :: %{optional(String.t()) => status() | nil}
  def statuses_for_projects(projects) when is_list(projects) do
    {started, unstarted} = Enum.split_with(projects, &match?(%DateTime{}, &1.started_at))

    %{}
    |> Map.merge(started_current_map(started))
    |> Map.merge(unstarted_current_map(unstarted))
  end

  defp started_current_map([]), do: %{}

  defp started_current_map(projects) do
    uuids = Enum.map(projects, & &1.uuid)

    rows_by_project =
      ProjectStatus
      |> where([s], s.project_uuid in ^uuids)
      |> repo().all()
      |> Enum.group_by(& &1.project_uuid)

    # Resolve the global translation-display default once for the whole list
    # instead of re-reading the setting per project.
    global_default = global_use_status_translations?()

    Map.new(projects, fn p ->
      row =
        rows_by_project
        |> Map.get(p.uuid, [])
        |> Enum.find(&(&1.slug == p.current_status_slug))

      {p.uuid, row && normalize_local_row(row, effective_status_lang(p, global_default))}
    end)
  end

  defp unstarted_current_map([]), do: %{}

  defp unstarted_current_map(projects) do
    if available?() do
      # Resolve each project's entity uuid (shared resolves once), then
      # batch one catalog read per distinct entity.
      shared_uuid = shared_entity_uuid_or_nil()

      by_entity =
        Enum.group_by(projects, fn p -> p.status_entity_uuid || shared_uuid end)

      catalog_index =
        for {entity_uuid, _} <- by_entity, is_binary(entity_uuid), into: %{} do
          {entity_uuid, index_by_slug(list_catalog_statuses(entity_uuid))}
        end

      Map.new(projects, fn p ->
        entity_uuid = p.status_entity_uuid || shared_uuid
        index = Map.get(catalog_index, entity_uuid, %{})
        {p.uuid, Map.get(index, p.current_status_slug)}
      end)
    else
      Map.new(projects, &{&1.uuid, nil})
    end
  end

  defp shared_entity_uuid_or_nil, do: global_default_status_entity_uuid()

  defp index_by_slug(statuses), do: Map.new(statuses, &{&1.slug, &1})

  # ── Reverse-reference count (host-registered) ─────────────────────────

  @doc """
  Counts projects/templates currently sourcing their status list from the
  given catalog entity. This is the callback a host registers via
  `config :phoenix_kit_entities, reverse_references: [{"project_status",
  &PhoenixKitProjects.Statuses.reverse_reference_count/1}]` to power the
  entities admin's "Used by N" hint. Started projects no longer reference
  the catalog (they're cemented), which is the intended semantics.
  """
  @spec reverse_reference_count(String.t()) :: non_neg_integer()
  def reverse_reference_count(entity_uuid) when is_binary(entity_uuid) do
    # Only count projects/templates that still draw from the catalog live.
    # A started project has cemented its own local copy and no longer
    # references the catalog (its `status_entity_uuid` lingers as
    # provenance), so it must be excluded to keep the "Used by N" hint honest.
    repo().one(
      from(p in Project,
        where: p.status_entity_uuid == ^entity_uuid and is_nil(p.started_at),
        select: count(p.uuid)
      )
    ) || 0
  end

  def reverse_reference_count(_), do: 0

  # ── Helpers ───────────────────────────────────────────────────────────

  defp normalize_catalog_row(row) do
    color = row.data && Map.get(row.data, "color")
    slug = row.slug || ProjectStatus.slugify(row.title || "")

    %{
      uuid: row.uuid,
      label: row.title,
      slug: slug,
      color: color,
      position: row.position || 0
    }
  end

  defp normalize_local_row(%ProjectStatus{} = row, lang) do
    %{
      uuid: row.uuid,
      label: ProjectStatus.localized_label(row, lang),
      slug: row.slug,
      color: ProjectStatus.color(row),
      position: row.position || 0
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp stringify(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  # Plugin-boundary fuse — see `PhoenixKitProjects.Translations.safe_ai_call/2`
  # for the rationale. Narrow `rescue` (missing/broken plugin), broad
  # `catch` (the plugin's own process tree can exit/throw arbitrarily).
  defp safe_call(fun, default) do
    fun.()
  rescue
    UndefinedFunctionError -> default
    FunctionClauseError -> default
    ArgumentError -> default
  catch
    :exit, _ -> default
    :throw, _ -> default
  end
end
