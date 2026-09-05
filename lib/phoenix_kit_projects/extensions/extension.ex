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

  Contributed tab LVs are rendered by the hub via `live_render` with the
  projects embed-session contract (`project_uuid` / `current_user_uuid` /
  `locale` / emit keys) — the LV must be mountable off-router
  (`:not_mounted_at_router`, no `handle_params/3`), exactly like this
  module's own embeddable LVs.

  ## Forward-looking surface (declared now, dispatched incrementally)

  Per the 2026-08-05 plan-review panel: the contract carries its FULL surface
  from day one so providers never need rework when later hub layers land —

    * `feature_flags` — per-project flags this extension owns
      (`%{key, label, default, requires: [...]}`); the hub's Features layer
      resolves them.
    * `permission_actions` — action keys the extension's UI asks
      `PhoenixKitProjects.Authz.can?/5` about.
    * `notification_types` — passthrough entries merged into this module's
      `notification_types/0` (core's prefs-UI shape).
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
            data_retention: :keep,
            default_enabled: false,
            category: nil,
            source: nil

  @type tab :: %{
          key: String.t(),
          label: String.t(),
          icon: String.t() | nil,
          lv: module()
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
  @reserved_tab_keys ~w(edit files activity members modules board gantt calendar tasks comments new)

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
        [%{key: to_string(tab[:key]), label: to_string(tab[:label]), icon: tab[:icon], lv: lv}]
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
            requires: flag[:requires] |> List.wrap() |> Enum.map(&to_string/1)
          }
        ]
      else
        _ -> []
      end
    end)
  end

  # ── Lifecycle callbacks ────────────────────────────────────────────

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
