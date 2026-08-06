defmodule PhoenixKitProjects.Features do
  @moduledoc """
  Per-project feature flags — Level 2 of the hub's granularity model
  (Level 1 is extension enablement in `PhoenixKitProjects.Extensions`).

  Every flag belongs to an extension: the built-in Tasks extension declares
  the pre-hub feature set (assignees, estimates, statuses, …) and providers
  declare their own via `feature_flags` on their descriptor — one channel,
  no special-cased built-ins.

  ## Resolution (frozen semantics — panel amendment #6)

  `on?(project, key)` is true iff ALL of:

    1. the flag exists in the catalog (unknown keys are fail-closed false);
    2. the flag's OWNING extension is effectively enabled for the project
       (`Extensions.enabled?/2`);
    3. every flag in `requires` resolves on (recursive, cycle-guarded) —
       the GitLab-style dependency rule: `view_timeline` requires
       `scheduling`, `scheduling` requires `estimates`;
    4. the project's explicit value — `settings["features"][key]` — when
       present; otherwise the flag's declared `default`.

  **Absence semantics are frozen**: a missing settings key ALWAYS means
  "inherit the flag's catalog default", never a latent choice. Presets and
  the Modules panel write explicit booleans; pre-hub projects have no keys
  and every pre-hub flag defaults true — behavior-preserving with no
  backfill migration.

  ## Presets

  Named flag bundles applied at creation (or any time before a team relies
  on the current shape): `"simple"` (a todo list — everything off but the
  list), `"standard"` (the pre-hub defaults), `"full"` (everything on).
  `apply_preset/3` writes the bundle as EXPLICIT values. The site default
  for new projects is the `projects_default_preset` setting (`"standard"`).
  """

  import Ecto.Query

  require Logger

  alias PhoenixKit.RepoHelper
  alias PhoenixKitProjects.Activity
  alias PhoenixKitProjects.Extensions
  alias PhoenixKitProjects.Extensions.Registry
  alias PhoenixKitProjects.PubSub
  alias PhoenixKitProjects.Schemas.Project

  @settings_key "features"
  @presets_setting "projects_default_preset"

  # ── Catalog ─────────────────────────────────────────────────────────

  @doc """
  The full flag catalog: `%{flag_key => %{key, label, default, requires,
  ext_key}}` — every extension's declared flags, stamped with their owner.
  First declaration wins on key collisions (logged).
  """
  @spec catalog() :: %{String.t() => map()}
  def catalog do
    Registry.list()
    |> Enum.flat_map(fn ext ->
      Enum.map(ext.feature_flags, &Map.put(&1, :ext_key, ext.key))
    end)
    |> Enum.reduce(%{}, fn flag, acc ->
      if Map.has_key?(acc, flag.key) do
        Logger.warning(
          "[Projects.Features] Duplicate flag key #{inspect(flag.key)} from " <>
            "extension #{inspect(flag.ext_key)} — keeping the first one."
        )

        acc
      else
        Map.put(acc, flag.key, flag)
      end
    end)
  end

  @doc "Flags grouped per extension, for the Modules panel: `[{%Extension{}, [flag]}]`."
  @spec catalog_by_extension() :: [{Extensions.Extension.t(), [map()]}]
  def catalog_by_extension do
    cat = catalog()

    Registry.list()
    |> Enum.map(fn ext ->
      {ext,
       cat |> Map.values() |> Enum.filter(&(&1.ext_key == ext.key)) |> Enum.sort_by(& &1.key)}
    end)
    |> Enum.reject(fn {_ext, flags} -> flags == [] end)
  end

  # ── Resolution ──────────────────────────────────────────────────────

  @doc """
  Whether a flag is on for a project. See the moduledoc for the frozen
  resolution order. Accepts a `%Project{}` (preferred — no extra reads) or
  a project uuid (loads the settings map).
  """
  @spec on?(Project.t() | map() | binary(), String.t()) :: boolean()
  def on?(project_or_uuid, flag_key) when is_binary(flag_key) do
    resolve(project_or_uuid, flag_key, [])
  rescue
    e ->
      Logger.warning("[Projects.Features] on? failed: #{Exception.message(e)}")
      false
  catch
    :exit, _ -> false
  end

  # `seen` is a plain list (not MapSet — dialyzer's opaqueness false
  # positive on literal MapSet construction; flag graphs are tiny anyway).
  defp resolve(project_or_uuid, flag_key, seen) do
    # Cycle guard first: a requires-cycle in provider-declared data can
    # never resolve on (guard rather than loop).
    if flag_key in seen do
      false
    else
      case Map.get(catalog(), flag_key) do
        nil ->
          false

        flag ->
          seen = [flag_key | seen]

          Extensions.enabled?(project_uuid(project_or_uuid), flag.ext_key) and
            Enum.all?(flag.requires, &resolve(project_or_uuid, &1, seen)) and
            explicit_or_default(project_or_uuid, flag)
      end
    end
  end

  defp explicit_or_default(project_or_uuid, flag) do
    case Map.get(settings_features(project_or_uuid), flag.key) do
      value when is_boolean(value) -> value
      _ -> flag.default
    end
  end

  # ── Gate maps (the render layer's one-stop lookup) ──────────────────

  # ATOM list (not strings): the module-attribute literal interns every gate
  # atom at compile time — a string list + String.to_existing_atom crashed
  # under suite orderings where gates/1 ran before anything else mentioned
  # :view_timeline (caught by the Step 5 full run).
  @task_gates [
    :assignees,
    :estimates,
    :progress,
    :dependencies,
    :statuses,
    :scheduling,
    :subprojects,
    :priorities,
    :labels,
    :ledger,
    :view_board,
    :view_timeline,
    :view_calendar
  ]

  @doc """
  The resolved gate map LiveViews assign as `@fx`: the `tasks` extension
  plus every built-in task flag, resolved for one project in one call.
  Rebuild it on `:project_features_changed` / `:project_modules_changed`.
  """
  @spec gates(Project.t() | map() | binary()) :: %{atom() => boolean()}
  def gates(project_or_uuid) do
    base = %{tasks: Extensions.enabled?(project_or_uuid, "tasks")}

    Enum.reduce(@task_gates, base, fn gate, acc ->
      Map.put(acc, gate, on?(project_or_uuid, to_string(gate)))
    end)
  end

  @doc """
  Gate map for surfaces with NO project yet (the :new forms): the catalog
  defaults — i.e. what a fresh project would resolve. All pre-hub flags
  default true, so this is all-true today and stays correct if a default
  ever changes.
  """
  @spec default_gates() :: %{atom() => boolean()}
  def default_gates do
    cat = catalog()

    base = %{tasks: true}

    Enum.reduce(@task_gates, base, fn gate, acc ->
      default =
        case Map.get(cat, to_string(gate)) do
          nil -> false
          flag -> flag.default and Enum.all?(flag.requires, &default_of(cat, &1))
        end

      Map.put(acc, gate, default)
    end)
  end

  defp default_of(cat, key) do
    case Map.get(cat, key) do
      nil -> false
      flag -> flag.default
    end
  end

  # ── Writes ──────────────────────────────────────────────────────────

  @doc """
  Writes explicit flag values (`%{"flag_key" => boolean}`) into the
  project's `settings["features"]`, whitelisted against the catalog —
  unknown keys and non-boolean values are dropped, known keys merge over
  the stored map. Logs one `projects.feature_toggled` activity row with the
  changed keys; broadcasts `:project_features_changed`.
  """
  @spec set_flags(Project.t(), map(), keyword()) :: {:ok, Project.t()} | {:error, term()}
  def set_flags(%Project{} = project, flags, opts \\ []) when is_map(flags) do
    known = catalog()

    accepted =
      flags
      |> Enum.filter(fn {k, v} -> is_binary(k) and is_boolean(v) and Map.has_key?(known, k) end)
      |> Map.new()

    if accepted == %{} do
      {:ok, project}
    else
      # ATOMIC targeted merge, not a whole-map read-merge-write: `settings`
      # is a SHARED column — the authz "who can X" floors live beside the
      # features key, so writing a map merged from a possibly-stale struct
      # silently clobbered concurrent writes to sibling keys, a
      # security-relevant lost update (final panel, ZAI). jsonb_set touches
      # ONLY settings["features"], merging over whatever is in the row NOW.
      query =
        from(p in Project,
          where: p.uuid == ^project.uuid,
          update: [
            set: [
              settings:
                fragment(
                  """
                  jsonb_set(
                    COALESCE(settings, '{}'::jsonb),
                    '{features}',
                    COALESCE(settings->'features', '{}'::jsonb) || ?::jsonb
                  )
                  """,
                  ^accepted
                ),
              updated_at: fragment("NOW()")
            ]
          ],
          select: p
        )

      {1, [updated]} = RepoHelper.repo().update_all(query, [])

      Activity.log("projects.feature_toggled",
        actor_uuid: Keyword.get(opts, :actor_uuid),
        resource_type: "project",
        resource_uuid: project.uuid,
        metadata: %{"changed" => accepted}
      )

      PubSub.broadcast_project(:project_features_changed, %{uuid: project.uuid})
      {:ok, updated}
    end
  rescue
    e in [MatchError, Postgrex.Error] ->
      Logger.warning("[Projects.Features] set_flags failed: #{Exception.message(e)}")
      {:error, :not_found}
  end

  # ── Presets ─────────────────────────────────────────────────────────

  @doc """
  Named flag bundles. `flags` are written as EXPLICIT values by
  `apply_preset/3`; keys absent from a preset keep resolving by default.
  """
  @spec presets() :: [map()]
  def presets do
    [
      %{
        key: "simple",
        name: "Simple to-do list",
        description: "Just a task list — no assignees, estimates, statuses, or scheduling.",
        flags: %{
          "assignees" => false,
          "priorities" => false,
          "labels" => false,
          "estimates" => false,
          "progress" => false,
          "dependencies" => false,
          "statuses" => false,
          "scheduling" => false,
          "subprojects" => false,
          "view_timeline" => false,
          "view_calendar" => false
        }
      },
      %{
        key: "standard",
        name: "Standard project",
        description: "The default feature set — everything the module ships on today.",
        flags: %{}
      },
      %{
        key: "full",
        name: "Full tracker",
        description: "Every task feature explicitly on.",
        flags: %{
          "assignees" => true,
          "priorities" => true,
          "labels" => true,
          "estimates" => true,
          "progress" => true,
          "dependencies" => true,
          "statuses" => true,
          "scheduling" => true,
          "subprojects" => true,
          "view_timeline" => true,
          "view_calendar" => true
        }
      }
    ]
  end

  @doc "Look up a preset by key."
  @spec get_preset(String.t()) :: map() | nil
  def get_preset(key), do: Enum.find(presets(), &(&1.key == key))

  # ── New-project page layout (site-configurable) ──────────────────
  #
  # Which optional creation-page blocks render TOP-LEVEL instead of
  # inside the "Setup options" accordion (Max's call: the default page
  # is name + description + kind, everything else folded — but a site
  # that lives off templates can promote that block in Settings).

  @creation_blocks_setting "projects_new_form_top_blocks"

  @creation_blocks [
    %{key: "template", label: "From template"},
    %{key: "start", label: "Start timing"},
    %{key: "statuses", label: "Workflow statuses"},
    %{key: "people", label: "People"}
  ]

  @creation_block_keys Enum.map(@creation_blocks, & &1.key)

  @doc "The promotable creation-page blocks (key + label), for the settings UI."
  @spec creation_blocks() :: [map()]
  def creation_blocks, do: @creation_blocks

  @doc """
  The block keys the site promoted to top level (default: none). A plain
  list, not a MapSet — dialyzer's opaqueness false positive on literal
  MapSet construction (the resolve/3 precedent in this module).
  """
  @spec creation_top_blocks() :: [String.t()]
  def creation_top_blocks do
    PhoenixKit.Settings.get_setting(@creation_blocks_setting, "")
    |> String.split(",", trim: true)
    |> Enum.filter(&(&1 in @creation_block_keys))
    |> Enum.uniq()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  @doc "Persist the promoted block set (unknown keys dropped)."
  @spec set_creation_top_blocks([String.t()]) :: {:ok, term()} | {:error, term()}
  def set_creation_top_blocks(keys) when is_list(keys) do
    value =
      keys
      |> Enum.filter(&(&1 in @creation_block_keys))
      |> Enum.uniq()
      |> Enum.join(",")

    PhoenixKit.Settings.update_setting_with_module(@creation_blocks_setting, value, "projects")
  end

  @doc "The site-default preset key for new projects (`projects_default_preset`)."
  @spec default_preset_key() :: String.t()
  def default_preset_key do
    PhoenixKit.Settings.get_setting(@presets_setting, "standard")
  rescue
    _ -> "standard"
  catch
    :exit, _ -> "standard"
  end

  @doc """
  Applies a preset's flag bundle to a project (explicit writes via
  `set_flags/3`). Unknown preset keys are a no-op `{:ok, project}` — a
  stale site-default setting must not break project creation.
  """
  @spec apply_preset(Project.t(), String.t(), keyword()) :: {:ok, Project.t()} | {:error, term()}
  def apply_preset(%Project{} = project, preset_key, opts \\ []) do
    case get_preset(preset_key) do
      nil -> {:ok, project}
      %{flags: flags} -> set_flags(project, flags, opts)
    end
  end

  # ── Internals ───────────────────────────────────────────────────────

  defp project_uuid(%{uuid: uuid}), do: uuid
  defp project_uuid(uuid) when is_binary(uuid), do: uuid

  defp settings_features(%{settings: settings}) when is_map(settings),
    do: Map.get(settings, @settings_key, %{})

  defp settings_features(uuid) when is_binary(uuid) do
    RepoHelper.repo().one(from(p in Project, where: p.uuid == ^uuid, select: p.settings))
    |> case do
      settings when is_map(settings) -> Map.get(settings, @settings_key, %{})
      _ -> %{}
    end
  end

  defp settings_features(_), do: %{}
end
