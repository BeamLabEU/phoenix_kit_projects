defmodule PhoenixKitProjects.Extensions do
  @moduledoc """
  Per-project extension enablement — the hub's context layer.

  The **catalog** (which extension types exist) lives in
  `PhoenixKitProjects.Extensions.Registry`; this module owns the
  **per-project state**: which extensions a given project has enabled, each
  instance's `config`, and the enable/disable lifecycle (activity rows,
  PubSub, provider callbacks).

  ## Semantics (locked by the 2026-08-05 plan + panel round)

    * **Disable hides, never deletes** — `disable/3` flips `enabled` to
      false; the row, its `config`, and the extension's own data survive.
      Re-enabling restores everything.
    * **Instance-keyed identity** — every function threads `instance_key`
      (default `"default"`); v1 UI exposes one instance per extension.
    * **Config writes are whitelisted** against the extension's declared
      `config_schema` keys — raw params never reach the JSONB.
    * **Effective enablement is an intersection**: a row with
      `enabled: true` counts only while the extension is in the catalog AND
      its backing site module is enabled (`Registry.available?/1`) — a
      site-level disable wins instantly without touching rows.
    * **Defaults**: a project with NO row for an extension falls back to the
      catalog's `default_enabled` (the built-in Tasks extension ships
      `default_enabled: true`, preserving pre-hub behavior for every
      existing project). Presets (Step 3) write explicit rows at creation —
      absence always means "inherit the catalog default", never a frozen
      choice.

  Authorization note: these functions trust their caller (the LiveView
  layer gates on `PhoenixKitProjects.Authz.can?/5` with `:manage_modules`).
  Activity actor flows in via `opts[:actor_uuid]`, LV-layer convention.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKit.RepoHelper
  alias PhoenixKitProjects.Activity
  alias PhoenixKitProjects.Extensions.{Extension, Registry}
  alias PhoenixKitProjects.PubSub
  alias PhoenixKitProjects.Schemas.ProjectModule

  @default_instance "default"

  # ── Catalog passthroughs ─────────────────────────────────────────────

  defdelegate catalog(), to: Registry
  defdelegate list_types(), to: Registry, as: :list
  defdelegate get_type(key), to: Registry, as: :get
  defdelegate refresh(), to: Registry

  # ── Per-project reads ───────────────────────────────────────────────

  @doc "All enablement rows for a project (enabled AND disabled — panel UI needs both)."
  @spec list_rows(binary()) :: [ProjectModule.t()]
  def list_rows(project_uuid) when is_binary(project_uuid) do
    RepoHelper.repo().all(
      from(pm in ProjectModule,
        where: pm.project_uuid == ^project_uuid,
        order_by: [asc: pm.ext_key, asc: pm.instance_key]
      )
    )
  end

  @doc """
  The extensions EFFECTIVELY enabled for a project: catalog availability ∩
  (explicit row OR catalog default). Returns `[{%Extension{}, %ProjectModule{} | nil}]`
  — the row is nil when enablement comes from `default_enabled` with no
  explicit row yet.
  """
  @spec enabled_for_project(binary()) :: [{Extension.t(), ProjectModule.t() | nil}]
  def enabled_for_project(project_uuid) when is_binary(project_uuid) do
    rows = list_rows(project_uuid)
    by_key = Map.new(rows, &{{&1.ext_key, &1.instance_key}, &1})

    Registry.list_available()
    |> Enum.flat_map(fn ext ->
      case Map.get(by_key, {ext.key, @default_instance}) do
        %ProjectModule{enabled: true} = row -> [{ext, row}]
        %ProjectModule{enabled: false} -> []
        nil -> if ext.default_enabled, do: [{ext, nil}], else: []
      end
    end)
  end

  @doc """
  Whether one extension is effectively enabled for a project.

  Accepts a project struct or uuid. The intersection rule from the
  moduledoc applies; unknown keys are always false (fail-closed).
  """
  @spec enabled?(map() | binary(), String.t(), String.t()) :: boolean()
  def enabled?(project_or_uuid, ext_key, instance_key \\ @default_instance)

  def enabled?(%{uuid: uuid}, ext_key, instance_key), do: enabled?(uuid, ext_key, instance_key)

  def enabled?(project_uuid, ext_key, instance_key)
      when is_binary(project_uuid) and is_binary(ext_key) do
    case Registry.get(ext_key) do
      nil ->
        false

      ext ->
        Registry.available?(ext) and row_enabled?(project_uuid, ext_key, instance_key, ext)
    end
  rescue
    e ->
      Logger.warning("[Projects.Extensions] enabled? failed: #{Exception.message(e)}")
      false
  catch
    :exit, _ -> false
  end

  defp row_enabled?(project_uuid, ext_key, instance_key, ext) do
    query =
      from(pm in ProjectModule,
        where:
          pm.project_uuid == ^project_uuid and pm.ext_key == ^ext_key and
            pm.instance_key == ^instance_key,
        select: pm.enabled
      )

    case RepoHelper.repo().all(query) do
      [enabled] -> enabled
      [] -> ext.default_enabled
    end
  end

  @doc "One enablement row (or nil)."
  @spec get_row(binary(), String.t(), String.t()) :: ProjectModule.t() | nil
  def get_row(project_uuid, ext_key, instance_key \\ @default_instance) do
    RepoHelper.repo().one(
      from(pm in ProjectModule,
        where:
          pm.project_uuid == ^project_uuid and pm.ext_key == ^ext_key and
            pm.instance_key == ^instance_key
      )
    )
  end

  # ── Enable / disable ────────────────────────────────────────────────

  @doc """
  Enables an extension for a project (upserts the instance row).

  Options: `:actor_uuid`, `:instance_key`, `:config` (whitelisted),
  `:name`. Returns `{:ok, row}` or `{:error, reason}`. Unknown extension
  keys are rejected (`{:error, :unknown_extension}`); an extension whose
  site module is disabled is rejected (`{:error, :module_disabled}`) —
  enabling something that can't render is a config trap.
  """
  @spec enable(map() | binary(), String.t(), keyword()) ::
          {:ok, ProjectModule.t()} | {:error, term()}
  def enable(project_or_uuid, ext_key, opts \\ [])

  def enable(%{uuid: uuid}, ext_key, opts), do: enable(uuid, ext_key, opts)

  def enable(project_uuid, ext_key, opts) when is_binary(project_uuid) do
    instance_key = Keyword.get(opts, :instance_key, @default_instance)
    actor_uuid = Keyword.get(opts, :actor_uuid)

    with {:ok, ext} <- fetch_type(ext_key),
         :ok <- ensure_available(ext) do
      result =
        case get_row(project_uuid, ext_key, instance_key) do
          nil ->
            # Upsert on the identity index (panel R2-1): a concurrent
            # enable that lost the race converges on the winner's row
            # instead of surfacing a unique-violation changeset.
            %ProjectModule{}
            |> ProjectModule.changeset(%{
              project_uuid: project_uuid,
              ext_key: ext.key,
              instance_key: instance_key,
              name: Keyword.get(opts, :name),
              enabled: true,
              config: whitelist_config(Keyword.get(opts, :config, %{}), ext),
              enabled_by_uuid: actor_uuid
            })
            |> RepoHelper.repo().insert(
              on_conflict: {:replace, [:enabled, :enabled_by_uuid, :updated_at]},
              conflict_target: [:project_uuid, :ext_key, :instance_key],
              returning: true
            )

          row ->
            # Re-enable preserves what the caller didn't pass (panel
            # R2-5/R2-6): stored name and config survive a plain toggle;
            # a passed config MERGES over the stored map (mirroring
            # update_config) rather than replacing it.
            attrs =
              %{enabled: true, enabled_by_uuid: actor_uuid}
              |> maybe_put_name(opts)
              |> maybe_merge_config(row, opts, ext)

            # No-op quiet (creation-panel find): enabling an already-
            # enabled instance with nothing effectively changing must not
            # re-fire on_enable / re-log / re-broadcast — the creation
            # form's reconcile pass enables template-carried extensions a
            # second time by design.
            if row.enabled and Map.get(attrs, :config, row.config) == row.config and
                 not Map.has_key?(attrs, :name) do
              {:noop, row}
            else
              row |> ProjectModule.changeset(attrs) |> RepoHelper.repo().update()
            end
        end

      case result do
        {:noop, row} ->
          {:ok, row}

        {:ok, row} ->
          log_toggle("projects.module_enabled", project_uuid, ext, actor_uuid)
          broadcast_change(project_uuid, ext.key)
          run_callback(ext.on_enable, project_uuid, row.config, ext)
          {:ok, row}

        {:error, _} = error ->
          error
      end
    end
  end

  @doc """
  Disables an extension instance for a project. The row (and its config)
  survives — see the moduledoc. Creates an explicit disabled row when the
  enablement was implicit (catalog `default_enabled`), so "turn tasks off"
  works on a project that never had a row.
  """
  @spec disable(map() | binary(), String.t(), keyword()) ::
          {:ok, ProjectModule.t()} | {:error, term()}
  def disable(project_or_uuid, ext_key, opts \\ [])

  def disable(%{uuid: uuid}, ext_key, opts), do: disable(uuid, ext_key, opts)

  def disable(project_uuid, ext_key, opts) when is_binary(project_uuid) do
    instance_key = Keyword.get(opts, :instance_key, @default_instance)
    actor_uuid = Keyword.get(opts, :actor_uuid)

    with {:ok, ext} <- fetch_type(ext_key) do
      result =
        case get_row(project_uuid, ext_key, instance_key) do
          nil ->
            %ProjectModule{}
            |> ProjectModule.changeset(%{
              project_uuid: project_uuid,
              ext_key: ext.key,
              instance_key: instance_key,
              enabled: false,
              enabled_by_uuid: actor_uuid
            })
            |> RepoHelper.repo().insert()

          row ->
            row
            |> ProjectModule.changeset(%{enabled: false, enabled_by_uuid: actor_uuid})
            |> RepoHelper.repo().update()
        end

      case result do
        {:ok, row} ->
          log_toggle("projects.module_disabled", project_uuid, ext, actor_uuid)
          broadcast_change(project_uuid, ext.key)
          run_callback(ext.on_disable, project_uuid, row.config, ext)
          {:ok, row}

        {:error, _} = error ->
          error
      end
    end
  end

  @doc """
  Updates one instance's `config`, whitelisted against the extension's
  `config_schema` keys. Unknown keys are silently dropped (never written);
  the stored map is REPLACED by the whitelisted input merged over it, so
  omitted known keys survive.
  """
  @spec update_config(map() | binary(), String.t(), map(), keyword()) ::
          {:ok, ProjectModule.t()} | {:error, term()}
  def update_config(project_or_uuid, ext_key, config, opts \\ [])

  def update_config(%{uuid: uuid}, ext_key, config, opts),
    do: update_config(uuid, ext_key, config, opts)

  def update_config(project_uuid, ext_key, config, opts)
      when is_binary(project_uuid) and is_map(config) do
    instance_key = Keyword.get(opts, :instance_key, @default_instance)

    with {:ok, ext} <- fetch_type(ext_key),
         %ProjectModule{} = row <-
           get_row(project_uuid, ext_key, instance_key) || {:error, :not_enabled} do
      merged = Map.merge(row.config || %{}, whitelist_config(config, ext))

      row
      |> ProjectModule.changeset(%{config: merged})
      |> RepoHelper.repo().update()
      |> case do
        {:ok, updated} ->
          broadcast_change(project_uuid, ext.key)
          {:ok, updated}

        {:error, _} = error ->
          error
      end
    end
  end

  # ── Internals ───────────────────────────────────────────────────────

  defp maybe_put_name(attrs, opts) do
    case Keyword.fetch(opts, :name) do
      {:ok, name} -> Map.put(attrs, :name, name)
      :error -> attrs
    end
  end

  defp maybe_merge_config(attrs, row, opts, ext) do
    case Keyword.fetch(opts, :config) do
      {:ok, config} ->
        Map.put(attrs, :config, Map.merge(row.config || %{}, whitelist_config(config, ext)))

      :error ->
        attrs
    end
  end

  defp fetch_type(ext_key) do
    case Registry.get(ext_key) do
      nil -> {:error, :unknown_extension}
      ext -> {:ok, ext}
    end
  end

  defp ensure_available(ext) do
    if Registry.available?(ext), do: :ok, else: {:error, :module_disabled}
  end

  # Whitelist: only keys declared in the extension's config_schema reach
  # the JSONB (the #665 lesson — never write raw param keys).
  defp whitelist_config(config, %Extension{config_schema: schema}) do
    allowed = MapSet.new(schema, & &1.key)

    config
    |> Enum.filter(fn {k, _v} -> is_binary(k) and MapSet.member?(allowed, k) end)
    |> Map.new()
  end

  defp log_toggle(action, project_uuid, ext, actor_uuid) do
    Activity.log(action,
      actor_uuid: actor_uuid,
      resource_type: "project",
      resource_uuid: project_uuid,
      metadata: %{"ext_key" => ext.key, "ext_name" => ext.name}
    )
  end

  defp broadcast_change(project_uuid, ext_key) do
    PubSub.broadcast_project(:project_modules_changed, %{uuid: project_uuid, ext_key: ext_key})
  end

  # Provider lifecycle callbacks are best-effort: a raising on_enable must
  # never abort the toggle the admin just made.
  defp run_callback(nil, _project_uuid, _config, _ext), do: :ok

  defp run_callback({m, f}, project_uuid, config, ext) do
    if Code.ensure_loaded?(m) and function_exported?(m, f, 2) do
      apply(m, f, [project_uuid, config || %{}])
    end

    :ok
  rescue
    e ->
      Logger.warning(
        "[Projects.Extensions] #{ext.key} lifecycle callback #{inspect(m)}.#{f}/2 raised: " <>
          Exception.message(e)
      )

      :ok
  catch
    kind, reason ->
      Logger.warning(
        "[Projects.Extensions] #{ext.key} lifecycle callback #{kind}: #{inspect(reason)}"
      )

      :ok
  end
end
