defmodule PhoenixKitProjects.Extensions.Extension do
  @moduledoc """
  A project **extension type** — the catalog entry describing a capability
  that can be enabled per project (the hub's equivalent of a site module).

  ## The provider contract (decoupled by design)

  A provider module exposes extensions by defining a zero-arity
  `phoenix_kit_project_extensions/0` returning a list of **plain maps** — it
  does NOT depend on `phoenix_kit_projects`; this module normalizes the maps
  via `from_map/2` (mirrors `phoenix_kit_dashboards`' widget contract):

      # in phoenix_kit_crm.ex
      def phoenix_kit_project_extensions do
        [
          %{
            key: "crm_client",
            name: "Client",
            description: "Attach a CRM company + contacts to this project",
            icon: "hero-building-office-2",
            module_key: "crm",
            tabs: [
              %{key: "client", label: "Client",
                lv: PhoenixKitCRM.Web.ProjectClientLive}
            ],
            config_schema: [
              %{key: "company_uuid", type: :string, label: "Company"}
            ]
          }
        ]
      end

  Contributed tab LVs are rendered by the hub via `live_render` — the LV must
  be mountable off-router (`:not_mounted_at_router`, no `handle_params/3`),
  exactly like this module's own embeddable LVs — with this session:

    * `"project_uuid"` — the project being viewed. The only key a tab needs.
    * `"ext_key"` — the `key` of the extension entry that contributed the tab.
    * `"instance_key"` — which enablement row this render is; always
      `"default"` (see "Instances").
    * `"config"` — the project's stored values for the extension's
      `config_schema`; `%{}` when none are stored.
    * `"can_write"` — boolean the hub resolved for the viewer: may they
      perform the extension's write action (its first `permission_actions`
      entry other than `:view`) on this project. `false` when the extension
      declares none or the viewer is unidentified. The tab has no scope, so
      this is its only write authorization.
    * `"current_user_uuid"` — the viewer's uuid as a string, or `nil`.
      Identity only, never authorization.
    * `"locale"` — the Gettext locale to set on mount.
    * `"wrapper_class"` — class for the tab's outermost element; the hub
      passes `""` because the project page already pads the pane.
    * `"mode"` / `"pubsub_topic"` / `"frame_ref"` — the hub's emit contract,
      forwarded from its own mount: the mode as the decoded atom
      (`:navigate`, `:emit` or `:popup` — not the string a host passes the
      hub), the topic to emit on or `nil`, and the popup frame integer or
      `nil`. A tab that never navigates or opens a dialog ignores all three.
    * `"host_paths"` — `%{"new_task" => path}`: the hub's own pages, so a tab
      can link to them without naming this module's routes.

  A tab may name a feature flag it depends on (`requires_flag: "ledger"`):
  the hub then offers the tab only while that flag resolves on for the
  project (`Features.on?/2`, so the flag's own `requires` count too). The
  Tasks extension's Hours tab is the first: it has nothing to show once the
  work ledger is switched off.

  ## Forward-looking surface (declared now, dispatched incrementally)

  The contract carries its FULL surface from day one so providers never need
  rework when later hub layers land —

    * `feature_flags` — per-project flags this extension owns
      (`%{key, label, default, requires: [...], site_default: bool}`); the
      hub's Features layer resolves them. `site_default: true` lets the
      module's settings page set the default every project inherits.
    * `permission_actions` — action keys the extension's UI asks
      `PhoenixKitProjects.Authz.can?/5` about.
    * `notification_types` — passthrough entries merged into this module's
      `notification_types/0` (core's prefs-UI shape).
    * `calendar` — `{module, function}` called with
      `(project_uuid, from, until)` (UTC `DateTime`s): dated things of the
      extension's own that belong on the project's Calendar tab, read-only
      (a planned client meeting, say). Answers
      `%{items: [item], truncated: boolean}`; an item is
      `%{source, id, title, label, starts_at, ends_at | nil, all_day, status,
      location, url, updated_at}` — `status: "cancelled"` is the one value
      the hub treats specially. Nothing is copied: the hub asks each time.
    * `project_columns` — `{module, function}` called with a LIST of project
      uuids: columns of the extension's own on the projects list (the CRM's
      Client, say), read in one go for the whole page. Answers
      `[%{key, label, values: %{project_uuid => %{text, url | nil}}}]`; the
      list offers each as an optional column it can sort and filter by.
      Values for a project the extension is off on are dropped by the hub.
    * `on_enable` / `on_disable` — `{module, function}` called with
      `(project_uuid, config)` after a successful toggle. Best-effort:
      failures are logged, never abort the toggle.
    * `data_retention` — `:keep` (only supported value; documented Redmine
      semantics: disabling hides, never deletes; a future `:purge_api` value
      may name an explicit cleanup entry point).

  ## Instances

  Enablement rows are instance-keyed (`instance_key`, default `"default"`);
  v1 exposes toggle semantics (one instance per extension per project) but
  the storage and lookups thread the instance key throughout, so
  Basecamp-style multi-instance tools are a constraint relaxation, not a
  migration.
  """

  require Logger

  @enforce_keys [:key, :name]
  defstruct key: nil,
            name: nil,
            description: nil,
            icon: "hero-puzzle-piece",
            module_key: nil,
            permission: nil,
            tabs: [],
            config_schema: [],
            feature_flags: [],
            permission_actions: [],
            notification_types: [],
            on_enable: nil,
            on_disable: nil,
            api: nil,
            calendar: nil,
            project_columns: nil,
            data_retention: :keep,
            default_enabled: false,
            category: nil,
            source: nil

  @type tab :: %{
          key: String.t(),
          label: String.t(),
          icon: String.t() | nil,
          lv: module(),
          requires_flag: String.t() | nil
        }

  @type t :: %__MODULE__{
          key: String.t(),
          name: String.t(),
          description: String.t() | nil,
          icon: String.t(),
          module_key: String.t() | nil,
          permission: String.t() | nil,
          tabs: [tab()],
          config_schema: [map()],
          feature_flags: [map()],
          permission_actions: [atom() | String.t()],
          notification_types: [map()],
          on_enable: {module(), atom()} | nil,
          on_disable: {module(), atom()} | nil,
          api: module() | [module()] | nil,
          calendar: {module(), atom()} | nil,
          project_columns: {module(), atom()} | nil,
          data_retention: :keep,
          default_enabled: boolean(),
          category: String.t() | nil,
          source: module() | nil
        }

  @doc """
  Normalizes a provider's plain map into `{:ok, %Extension{}}` or
  `{:error, reason}`. Accepts atom or string keys. Invalid tabs/callbacks
  are dropped with a warning rather than failing the whole extension.
  """
  @spec from_map(map(), module()) :: {:ok, t()} | {:error, term()}
  def from_map(%{} = map, source) do
    map = Map.new(map, fn {k, v} -> {to_atom_key(k), v} end)

    with {:ok, key} <- fetch(map, :key),
         true <- is_binary(key) or is_atom(key) or {:error, {:invalid_key, key}},
         {:ok, name} <- fetch(map, :name),
         true <- is_binary(name) or is_atom(name) or {:error, {:invalid_name, name}} do
      {:ok,
       %__MODULE__{
         key: to_string(key),
         name: to_string(name),
         description: map[:description],
         icon: map[:icon] || "hero-puzzle-piece",
         module_key: map[:module_key] && to_string(map[:module_key]),
         permission: map[:permission] && to_string(map[:permission]),
         tabs: normalize_tabs(List.wrap(map[:tabs]), source),
         config_schema: normalize_schema(List.wrap(map[:config_schema])),
         feature_flags: normalize_flags(List.wrap(map[:feature_flags])),
         permission_actions: List.wrap(map[:permission_actions]),
         notification_types: List.wrap(map[:notification_types]),
         on_enable: normalize_callback(map[:on_enable], source, :on_enable),
         on_disable: normalize_callback(map[:on_disable], source, :on_disable),
         # A record of this extension on the projects JSON API — see
         # `PhoenixKitProjects.Extensions.ApiProvider`.
         api: normalize_api(map[:api], source),
         calendar: normalize_callback(map[:calendar], source, :calendar),
         project_columns: normalize_callback(map[:project_columns], source, :project_columns),
         data_retention: :keep,
         default_enabled: map[:default_enabled] == true,
         category: map[:category] && to_string(map[:category]),
         source: source
       }}
    end
  end

  def from_map(_other, _source), do: {:error, :not_a_map}

  # ── Tabs ────────────────────────────────────────────────────────────

  # A tab's key is also its URL segment (`/projects/:id/<key>`, the
  # `projects/:id/:tab` catch-all — declared after every literal sibling
  # route, so a key that reuses one would deep-link to the wrong page
  # while the strip's data-url named this tab). Reserved, refused here.
  @reserved_tab_keys ~w(edit files activity members modules api board gantt calendar tasks comments history new)

  @doc "The URL segments a contributed tab key may not reuse."
  @spec reserved_tab_keys() :: [String.t()]
  def reserved_tab_keys, do: @reserved_tab_keys

  defp normalize_tabs(tabs, source) do
    Enum.flat_map(tabs, fn tab ->
      tab = if is_map(tab), do: Map.new(tab, fn {k, v} -> {to_atom_key(k), v} end), else: tab

      with true <- is_map(tab),
           true <- valid_key?(tab[:key]) and valid_key?(tab[:label]),
           false <- to_string(tab[:key]) in @reserved_tab_keys,
           lv = tab[:lv],
           true <- is_atom(lv) and not is_nil(lv) and Code.ensure_loaded?(lv) do
        [
          %{
            key: to_string(tab[:key]),
            label: to_string(tab[:label]),
            icon: tab[:icon],
            lv: lv,
            requires_flag: tab[:requires_flag] && to_string(tab[:requires_flag])
          }
        ]
      else
        _ ->
          Logger.warning(
            "[Projects.Extensions] Dropping invalid tab #{inspect(tab)} from #{inspect(source)} " <>
              "(a tab needs a key that is not a project-page URL segment " <>
              "#{inspect(@reserved_tab_keys)}, a label and a loaded LiveView)"
          )

          []
      end
    end)
  end

  # ── Config schema (dashboards settings_schema semantics) ────────────

  @schema_types [:string, :text, :number, :boolean, :select]

  defp normalize_schema(fields) do
    Enum.flat_map(fields, fn field ->
      field =
        if is_map(field), do: Map.new(field, fn {k, v} -> {to_atom_key(k), v} end), else: field

      with true <- is_map(field),
           true <- valid_key?(field[:key]),
           type when type in @schema_types <- to_atom_key(field[:type] || :string) do
        [Map.merge(field, %{key: to_string(field[:key]), type: type})]
      else
        _ -> []
      end
    end)
  end

  # ── Feature flags ──────────────────────────────────────────────────

  defp normalize_flags(flags) do
    Enum.flat_map(flags, fn flag ->
      flag = if is_map(flag), do: Map.new(flag, fn {k, v} -> {to_atom_key(k), v} end), else: flag

      with true <- is_map(flag),
           true <- valid_key?(flag[:key]) do
        [
          %{
            key: to_string(flag[:key]),
            label: to_string(flag[:label] || flag[:key]),
            default: flag[:default] == true,
            requires: flag[:requires] |> List.wrap() |> Enum.map(&to_string/1),
            # The site may set this flag's default on the module's settings
            # page (`Features.site_flags/0`); a project still overrides it.
            site_default: flag[:site_default] == true
          }
        ]
      else
        _ -> []
      end
    end)
  end

  # ── Lifecycle callbacks ────────────────────────────────────────────

  defp normalize_api(nil, _source), do: nil

  # Several resources from one extension: a list of provider modules.
  defp normalize_api(mods, source) when is_list(mods) do
    case mods |> Enum.map(&normalize_api(&1, source)) |> Enum.reject(&is_nil/1) do
      [] -> nil
      [one] -> one
      many -> many
    end
  end

  defp normalize_api(mod, source) when is_atom(mod) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :resource, 0) do
      mod
    else
      Logger.warning(
        "[Projects.Extensions] Dropping api provider #{inspect(mod)} from #{inspect(source)} " <>
          "(not loaded, or no resource/0)"
      )

      nil
    end
  end

  defp normalize_api(other, source) do
    Logger.warning(
      "[Projects.Extensions] Dropping invalid api #{inspect(other)} from #{inspect(source)} (want a module)"
    )

    nil
  end

  defp normalize_callback(nil, _source, _name), do: nil

  defp normalize_callback({m, f}, _source, _name) when is_atom(m) and is_atom(f), do: {m, f}

  defp normalize_callback(other, source, name) do
    Logger.warning(
      "[Projects.Extensions] Dropping invalid #{name} #{inspect(other)} from #{inspect(source)} " <>
        "(want {module, function})"
    )

    nil
  end

  # ── Shared helpers ─────────────────────────────────────────────────

  # A usable identifier: non-empty binary, or an atom that isn't nil/true/
  # false. `is_atom(nil)` is true in Elixir — a bare is_atom guard admits
  # missing keys (the normalizer bug the unit test caught on first run).
  defp valid_key?(k) when is_binary(k), do: k != ""
  defp valid_key?(k) when is_atom(k), do: not is_nil(k) and not is_boolean(k)
  defp valid_key?(_), do: false

  defp fetch(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when not is_nil(value) -> {:ok, value}
      _ -> {:error, {:missing_field, key}}
    end
  end

  defp to_atom_key(k) when is_atom(k), do: k

  defp to_atom_key(k) when is_binary(k) do
    String.to_existing_atom(k)
  rescue
    ArgumentError -> :__unknown_key__
  end
end
