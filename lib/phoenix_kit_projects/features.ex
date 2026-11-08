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
       present; otherwise the site's default for a flag declared
       `site_default: true` (the module's settings page, `site_flags/0`),
       when one is set; otherwise the flag's declared `default`.

  **Absence semantics are frozen**: a missing settings key ALWAYS means
  "inherit the flag's catalog default", never a latent choice. Presets and
  the Modules panel write explicit booleans; pre-hub projects have no keys
  and every pre-hub flag defaults true — behavior-preserving with no
  backfill migration.

  ## Presets

  Named flag bundles applied at creation (or any time before a team relies
  on the current shape): `"simple"` (a todo list — everything off but the
  list), `"standard"` (the pre-hub defaults), `"embedded"` (a project a
  host app keeps on one of its own records, such as an order: lean, with
  its extensions set too), `"full"` (everything on).
  `apply_preset/3` writes the bundle as EXPLICIT values. The site default
  for new projects is the `projects_default_preset` setting (`"standard"`).
  """

  import Ecto.Query
  # `gettext_noop/1` only: the preset names and the creation-block labels are
  # catalog data, translated where they are drawn (`Web.Helpers.translate_catalog/1`).
  use Gettext, backend: PhoenixKitProjects.Gettext

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

  @doc """
  The flags' catalog labels, untranslated (render them through
  `Web.Helpers.translate_catalog/1`), in the order given; a key the
  catalog does not know keeps its key.
  """
  @spec flag_labels([String.t()]) :: [String.t()]
  def flag_labels(keys) when is_list(keys) do
    cat = catalog()
    Enum.map(keys, fn key -> get_in(cat, [key, :label]) || key end)
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
    resolve(context(project_or_uuid), flag_key, [])
  rescue
    e ->
      Logger.warning("[Projects.Features] on? failed: #{Exception.message(e)}")
      false
  catch
    :exit, _ -> false
  end

  # Everything a resolution reads, gathered ONCE: the project's effective
  # extension map (one `list_rows/1` read) and its explicit flag values
  # (on the struct; one read for a bare uuid). `gates/1` used to ask the
  # database per flag and per `requires` hop — 22 reads for the 16 gates,
  # on every project-page mount and every modules-changed broadcast (the
  # 2026-09-05 N+1 audit).
  defp context(project_or_uuid) do
    %{
      enabled: Extensions.enabled_map(project_uuid(project_or_uuid)),
      features: settings_features(project_or_uuid),
      site: site_defaults()
    }
  end

  # `seen` is a plain list (not MapSet — dialyzer's opaqueness false
  # positive on literal MapSet construction; flag graphs are tiny anyway).
  defp resolve(ctx, flag_key, seen) do
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

          Map.get(ctx.enabled, flag.ext_key, false) and
            Enum.all?(flag.requires, &resolve(ctx, &1, seen)) and
            explicit_or_default(ctx, flag)
      end
    end
  end

  defp explicit_or_default(ctx, flag) do
    case Map.get(ctx.features, flag.key) do
      value when is_boolean(value) -> value
      _ -> site_or_default(Map.get(ctx, :site, %{}), flag)
    end
  end

  defp site_or_default(site, flag) do
    case Map.get(site, flag.key) do
      value when is_boolean(value) -> value
      _ -> flag.default
    end
  end

  # ── Site defaults ───────────────────────────────────────────────────
  #
  # A flag declared `site_default: true` takes its default from the
  # module's settings page when the site set one (the boss, 2026-10-30:
  # project-level time logging and billable time are off unless a site
  # turns them on). Absence still means "the catalog default", so an
  # existing install reads exactly what it read before. A project's own
  # explicit value wins over both.

  @site_default_prefix "projects_feature_default_"

  @doc "The flags whose default the site sets, in catalog order of key: `[flag]`."
  @spec site_flags() :: [map()]
  def site_flags do
    catalog()
    |> Map.values()
    |> Enum.filter(&Map.get(&1, :site_default, false))
    |> Enum.sort_by(& &1.key)
  end

  @doc """
  What a new project inherits for each `site_flags/0` flag:
  `%{flag_key => boolean}` (the site's value, else the catalog default).
  """
  @spec site_default_values() :: %{String.t() => boolean()}
  def site_default_values do
    site = site_defaults()
    Map.new(site_flags(), &{&1.key, site_or_default(site, &1)})
  end

  @doc "Sets the site's default for one `site_flags/0` flag."
  @spec set_site_default(String.t(), boolean()) ::
          {:ok, term()} | {:error, :unknown_flag | term()}
  def set_site_default(flag_key, value) when is_binary(flag_key) and is_boolean(value) do
    if Enum.any?(site_flags(), &(&1.key == flag_key)) do
      PhoenixKit.Settings.update_boolean_setting_with_module(
        @site_default_prefix <> flag_key,
        value,
        "projects"
      )
    else
      {:error, :unknown_flag}
    end
  end

  # The values the site set — only those: an unset one is absent, so the
  # catalog default applies. One cached batch read for all of them (one
  # query on a cold cache).
  defp site_defaults do
    keys = Map.new(site_flags(), &{@site_default_prefix <> &1.key, &1.key})
    values = PhoenixKit.Settings.get_settings_cached(Map.keys(keys))

    Enum.reduce(keys, %{}, fn {setting, flag_key}, acc ->
      case Map.get(values, setting) do
        "true" -> Map.put(acc, flag_key, true)
        "false" -> Map.put(acc, flag_key, false)
        _ -> acc
      end
    end)
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  # ── Gate maps (the render layer's one-stop lookup) ──────────────────

  # ATOM list (not strings): the module-attribute literal interns every gate
  # atom at compile time — a string list + String.to_existing_atom crashed
  # under suite orderings where gates/1 ran before anything else mentioned
  # :view_timeline (caught by the Step 5 full run).
  @task_gates [
    :library,
    :in_progress,
    :subtasks,
    :waiting,
    :dates,
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
    :lifecycle,
    :view_board,
    :view_timeline,
    :view_calendar,
    # Time logged on the project as a whole (its "Log time" and the logged
    # chip in the header) and the billable mark on a time entry. Off unless
    # the site or the project turns them on (the boss, 2026-10-30).
    :project_time,
    :billable,
    # A sub-project's row follows its own tasks (waiting until released,
    # in progress once one starts, done when all are); off, it is set by
    # hand like a task.
    :subproject_auto,
    # The Discussions extension's two tabs: the project's own thread and
    # every comment on its tasks.
    :project_comments,
    :all_comments
  ]

  # Not part of "Full tracker": time on the project as a whole and the
  # billable mark are a site's or a project's own choice (the boss,
  # 2026-10-30: off unless someone turns them on).
  @opt_in_gates [:project_time, :billable]

  @doc """
  EVERY catalog flag resolved for one project, `%{flag_key => boolean}`
  (string keys — built-in task flags and extension-owned ones alike),
  from one context read. The batched form of `on?/2` for the surfaces
  that show the whole catalog: the Modules & Features panel and the
  permission floors, which asked per flag.
  """
  @spec flags(Project.t() | map() | binary()) :: %{String.t() => boolean()}
  def flags(project_or_uuid) do
    ctx = context(project_or_uuid)
    Map.new(catalog(), fn {key, _flag} -> {key, resolve(ctx, key, [])} end)
  rescue
    e ->
      Logger.warning("[Projects.Features] flags failed: #{Exception.message(e)}")
      %{}
  catch
    :exit, _ -> %{}
  end

  @doc """
  The resolved gate map LiveViews assign as `@fx`: the `tasks` extension
  plus every built-in task flag, resolved for one project in one call.
  Rebuild it on `:project_features_changed` / `:project_modules_changed`.
  """
  @spec gates(Project.t() | map() | binary() | [Project.t()]) ::
          %{atom() => boolean()} | %{binary() => %{atom() => boolean()}}
  def gates(projects) when is_list(projects) do
    enabled = Extensions.enabled_maps(Enum.map(projects, & &1.uuid))
    site = site_defaults()

    Map.new(projects, fn project ->
      ctx = %{
        enabled: Map.get(enabled, project.uuid, %{}),
        features: settings_features(project),
        site: site
      }

      {project.uuid, resolve_gates(ctx)}
    end)
  end

  def gates(project_or_uuid) do
    resolve_gates(context(project_or_uuid))
  rescue
    e ->
      Logger.warning("[Projects.Features] gates failed: #{Exception.message(e)}")
      Map.new([:tasks | @task_gates], &{&1, false})
  catch
    :exit, _ -> Map.new([:tasks | @task_gates], &{&1, false})
  end

  defp resolve_gates(ctx) do
    Enum.reduce(@task_gates, %{tasks: Map.get(ctx.enabled, "tasks", false)}, fn gate, acc ->
      Map.put(acc, gate, resolve(ctx, to_string(gate), []))
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
    site = site_defaults()

    base = %{tasks: true}

    Enum.reduce(@task_gates, base, fn gate, acc ->
      default =
        case Map.get(cat, to_string(gate)) do
          nil ->
            false

          flag ->
            site_or_default(site, flag) and Enum.all?(flag.requires, &default_of(cat, site, &1))
        end

      Map.put(acc, gate, default)
    end)
  end

  defp default_of(cat, site, key) do
    case Map.get(cat, key) do
      nil -> false
      flag -> site_or_default(site, flag)
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
        name: gettext_noop("Simple task list"),
        description:
          gettext_noop("Just a task list — no start or finish, no tracking, no scheduling."),
        flags: %{
          # A checklist is typed in place — no shared library to pick
          # from or feed (Max, 2026-09-05: "for the checklist it's not
          # needed"). The other starting points keep the default (on).
          "library" => false,
          # A checklist item is done or it is not — no "started" in between
          # (Max, 2026-09-05).
          "in_progress" => false,
          "assignees" => false,
          "priorities" => false,
          "labels" => false,
          "estimates" => false,
          "progress" => false,
          "dependencies" => false,
          "statuses" => false,
          "scheduling" => false,
          "subprojects" => false,
          # A checklist has no beginning and no end — it is a list that
          # exists. With this on, the hub asked the reader to "start" it
          # and then parked it in the dashboard's not-started bucket
          # indefinitely, for a project type whose whole promise is "no
          # scheduling overhead".
          "lifecycle" => false,
          # The other two the preset silently missed: the work ledger put
          # a "Logged: 0m" readout on a list nobody is billing, and the
          # board is a view of workflow statuses this preset turns off.
          "ledger" => false,
          "view_board" => false,
          "view_timeline" => false,
          "view_calendar" => false,
          "project_time" => false,
          "billable" => false
        }
      },
      %{
        key: "standard",
        name: gettext_noop("Standard project"),
        description:
          gettext_noop("The default feature set — everything the module ships on today."),
        flags: %{}
      },
      %{
        key: "embedded",
        name: gettext_noop("Embedded project"),
        description:
          gettext_noop(
            "Work that lives on another record: tasks with deadlines, files and their comments — no general comments, priorities, labels, progress or time on the project itself."
          ),
        # The project a host app keeps on one of its own records — an order,
        # a case (the boss, 2026-10-31: half the features on an order's
        # project were never needed). The record has its own comments, so
        # the project's general thread is off and the tab of every task's
        # comments is on; time is logged on tasks only; estimates, the
        # Timeline and sub-projects stay (Max). The module names no host
        # record: any app embedding a project per record can use it.
        flags: %{
          "library" => true,
          "in_progress" => true,
          "assignees" => true,
          "subtasks" => true,
          # The "Waiting on / requested by" fields this flag gated are gone.
          "waiting" => false,
          "dates" => true,
          "estimates" => true,
          "progress" => false,
          "dependencies" => true,
          "statuses" => true,
          "scheduling" => true,
          "subprojects" => true,
          "priorities" => false,
          "labels" => false,
          "ledger" => true,
          "lifecycle" => true,
          "view_board" => true,
          "view_timeline" => true,
          "view_calendar" => true,
          "project_time" => false,
          "billable" => false,
          "project_comments" => false,
          "all_comments" => true,
          "portal_submit" => false,
          "portal_list" => false,
          "portal_status" => false
        },
        # Extensions this preset turns on or off (`apply_preset/3`); one not
        # installed, or whose site module is off, is left as it is.
        extensions: %{
          "tasks" => true,
          "files" => true,
          "discussions" => true,
          "whiteboards" => false,
          "events" => false,
          "portal" => false
        }
      },
      %{
        key: "full",
        name: gettext_noop("Full tracker"),
        description: gettext_noop("Every task feature explicitly on."),
        # EVERY built-in flag, derived from the gate list rather than typed
        # out: a hand-kept map missed lifecycle, ledger and view_board, so
        # "Full" applied over "Simple" left three explicit falses standing
        # (found seeding the boss's Test project at full power, 2026-09-05).
        flags: Map.new(@task_gates -- @opt_in_gates, &{to_string(&1), true})
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
    %{key: "template", label: gettext_noop("From template")},
    %{key: "start", label: gettext_noop("Start timing")},
    %{key: "statuses", label: gettext_noop("Workflow statuses")},
    %{key: "people", label: gettext_noop("People")}
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
      nil ->
        {:ok, project}

      %{flags: flags} = preset ->
        with {:ok, project} <- set_flags(project, flags, opts) do
          apply_preset_extensions(project, preset, opts)
          {:ok, project}
        end
    end
  end

  @doc """
  Turns on or off the extensions a preset names (its `extensions` map;
  most presets name none). Only what differs from the project's current
  state is written; an extension that is not installed or cannot be
  enabled is left alone. Best-effort: returns `:ok`.
  """
  @spec apply_preset_extensions(Project.t() | map(), String.t() | map(), keyword()) :: :ok
  def apply_preset_extensions(project, preset_key, opts \\ [])

  def apply_preset_extensions(project, preset_key, opts) when is_binary(preset_key) do
    case get_preset(preset_key) do
      nil -> :ok
      preset -> apply_preset_extensions(project, preset, opts)
    end
  end

  def apply_preset_extensions(%{uuid: uuid}, %{} = preset, opts) do
    wanted = Map.get(preset, :extensions, %{})

    if wanted != %{} do
      current = Extensions.enabled_map(uuid)
      ext_opts = Keyword.take(opts, [:actor_uuid])

      Enum.each(wanted, fn {ext_key, on?} ->
        case {on?, Map.get(current, ext_key, false)} do
          {true, false} -> Extensions.enable(uuid, ext_key, ext_opts)
          {false, true} -> Extensions.disable(uuid, ext_key, ext_opts)
          _ -> :ok
        end
      end)
    end

    :ok
  rescue
    e ->
      Logger.warning("[Projects.Features] preset extensions failed: #{Exception.message(e)}")
      :ok
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
