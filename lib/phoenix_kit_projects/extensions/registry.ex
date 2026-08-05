defmodule PhoenixKitProjects.Extensions.Registry do
  @moduledoc """
  Discovers and caches the project-extension catalog.

  The catalog is the union of every PhoenixKit module defining
  `phoenix_kit_project_extensions/0` (see
  `PhoenixKitProjects.Extensions.Extension` for the contract). **This module's
  own `PhoenixKitProjects` is one such provider** — the built-in Tasks
  extension and the hub-side bridge descriptors (for modules that don't
  self-declare, e.g. comments) ship through the same entry point, no
  special-cased path.

  Host apps contribute providers without being PhoenixKit modules:

      config :phoenix_kit_projects, extension_providers: [MyApp.ProjectExtensions]

  The catalog structure is memoized in `:persistent_term` (the dashboards
  Registry pattern). Module **enablement** and **permission** are re-checked
  live on every read; a newly installed provider or changed descriptor needs
  `refresh/0` (this module calls it on its own enable).
  """

  require Logger

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitProjects.Extensions.Extension

  @pt_key {__MODULE__, :catalog}
  @provider_callback :phoenix_kit_project_extensions

  @doc "The full extension catalog, keyed by extension key. Memoized."
  @spec catalog() :: %{String.t() => Extension.t()}
  def catalog do
    case :persistent_term.get(@pt_key, :miss) do
      :miss -> refresh()
      catalog -> catalog
    end
  end

  @doc "All catalog extensions, stable order (built-ins first, then by name)."
  @spec list() :: [Extension.t()]
  def list do
    catalog()
    |> Map.values()
    |> Enum.sort_by(&{&1.source != PhoenixKitProjects, &1.name})
  end

  @doc "Look up one extension type by key."
  @spec get(String.t()) :: Extension.t() | nil
  def get(key) when is_binary(key), do: Map.get(catalog(), key)

  @doc """
  Catalog extensions OFFERABLE right now: the backing site module (if any)
  is enabled. This is the availability half of the gate; per-scope
  permission is checked separately via `visible_for_scope?/2` because the
  Modules panel wants to show unavailable extensions greyed-out rather than
  hidden.
  """
  @spec list_available() :: [Extension.t()]
  def list_available do
    Enum.filter(list(), &available?/1)
  end

  @doc "Whether the extension's backing site module (if any) is enabled."
  @spec available?(Extension.t()) :: boolean()
  def available?(%Extension{module_key: nil}), do: true
  def available?(%Extension{module_key: key}), do: module_enabled?(key)

  @doc """
  Whether a scope may SEE this extension's contributed surface. `nil`
  permission falls back to the hub's own `"projects"` module permission
  (already required to reach any project page); an explicit `permission`
  requires that module key on the scope. Fail-closed on a nil scope.
  """
  @spec visible_for_scope?(Extension.t(), Scope.t() | nil) :: boolean()
  def visible_for_scope?(%Extension{}, nil), do: false

  def visible_for_scope?(%Extension{} = ext, scope) do
    available?(ext) and has_access?(scope, ext.permission || "projects")
  end

  @doc "Rebuild the catalog from every discovered provider and re-cache it."
  @spec refresh() :: %{String.t() => Extension.t()}
  def refresh do
    catalog =
      provider_modules()
      |> Enum.flat_map(fn module ->
        module
        |> safe_extensions()
        |> Enum.flat_map(&normalize(&1, module))
      end)
      |> Enum.reduce(%{}, fn ext, acc ->
        if Map.has_key?(acc, ext.key) do
          Logger.warning(
            "[Projects.Extensions] Duplicate extension key #{inspect(ext.key)} from " <>
              "#{inspect(ext.source)} — keeping the first registered one."
          )

          acc
        else
          Map.put(acc, ext.key, ext)
        end
      end)

    :persistent_term.put(@pt_key, catalog)
    catalog
  end

  # ── Discovery ──────────────────────────────────────────────────────

  defp provider_modules do
    discovered =
      if Code.ensure_loaded?(PhoenixKit.ModuleRegistry) do
        PhoenixKit.ModuleRegistry.all_modules()
      else
        []
      end

    ([PhoenixKitProjects | discovered] ++ config_providers())
    |> Enum.uniq()
    |> Enum.filter(&function_exported?(&1, @provider_callback, 0))
  rescue
    e ->
      Logger.warning("[Projects.Extensions] Provider discovery failed: #{Exception.message(e)}")
      [PhoenixKitProjects]
  end

  defp config_providers do
    :phoenix_kit_projects
    |> Application.get_env(:extension_providers, [])
    |> List.wrap()
    |> Enum.filter(&(is_atom(&1) and Code.ensure_loaded?(&1)))
  end

  defp safe_extensions(module) do
    List.wrap(apply(module, @provider_callback, []))
  rescue
    e ->
      Logger.warning(
        "[Projects.Extensions] #{inspect(module)}.#{@provider_callback}/0 raised: " <>
          Exception.message(e)
      )

      []
  catch
    kind, reason ->
      Logger.warning(
        "[Projects.Extensions] #{inspect(module)}.#{@provider_callback}/0 #{kind}: " <>
          inspect(reason)
      )

      []
  end

  defp normalize(map, source) do
    case Extension.from_map(map, source) do
      {:ok, ext} ->
        [ext]

      {:error, reason} ->
        Logger.warning(
          "[Projects.Extensions] Dropping invalid extension from #{inspect(source)}: " <>
            inspect(reason)
        )

        []
    end
  end

  defp module_enabled?(module_key) do
    if Code.ensure_loaded?(PhoenixKit.ModuleRegistry) do
      case PhoenixKit.ModuleRegistry.get_by_key(module_key) do
        nil -> false
        module -> module.enabled?()
      end
    else
      false
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp has_access?(scope, permission_key) do
    Scope.has_module_access?(scope, permission_key)
  rescue
    _ -> false
  end
end
