defmodule PhoenixKitProjects.Activity do
  @moduledoc "Activity logging wrapper for the Projects module."

  require Logger

  @module "projects"

  @doc "Logs a projects activity entry via `PhoenixKit.Activity`. Swallows errors so it never crashes the caller."
  def log(action, opts) when is_binary(action) and is_list(opts) do
    if Code.ensure_loaded?(PhoenixKit.Activity) do
      PhoenixKit.Activity.log(%{
        action: action,
        module: @module,
        mode: Keyword.get(opts, :mode, "manual"),
        actor_uuid: Keyword.get(opts, :actor_uuid),
        resource_type: Keyword.get(opts, :resource_type),
        resource_uuid: Keyword.get(opts, :resource_uuid),
        target_uuid: Keyword.get(opts, :target_uuid),
        metadata: Keyword.get(opts, :metadata, %{})
      })
    else
      :activity_unavailable
    end
  rescue
    Postgrex.Error ->
      :ok

    DBConnection.OwnershipError ->
      :ok

    e ->
      Logger.warning("[Projects] Activity logging error: #{Exception.message(e)}")
      {:error, e}
  catch
    :exit, _reason -> :ok
  end

  @doc """
  Logs a user-driven mutation that did NOT land cleanly — the success
  path would have called `log/2` with the same action + opts; this
  variant tags the metadata with `db_pending: true` so audit-feed
  readers can distinguish attempted-but-failed actions from completed
  ones. Per the post-Apr 2026 pipeline standard
  (publishing-Batch-3 / catalogue-Batch-4 precedent): a Drive/DB
  outage must NOT erase admin clicks from the activity feed.

  Identical signature to `log/2`. Same rescue/catch shape.
  """
  def log_failed(action, opts) when is_binary(action) and is_list(opts) do
    metadata = Keyword.get(opts, :metadata, %{}) |> Map.put("db_pending", true)
    log(action, Keyword.put(opts, :metadata, metadata))
  end

  @doc "Extracts `user.uuid` from the LiveView socket assigns."
  def actor_uuid(socket) do
    case socket.assigns[:phoenix_kit_current_user] do
      %{uuid: uuid} -> uuid
      _ -> nil
    end
  end
end
