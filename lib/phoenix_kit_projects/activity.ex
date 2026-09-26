defmodule PhoenixKitProjects.Activity do
  @moduledoc "Activity logging wrapper for the Projects module."

  @module "projects"

  @doc """
  Logs a projects activity entry through `PhoenixKit.Activity.log/3`,
  which never raises — a failure is logged there and returned as
  `{:error, _}`.
  """
  @spec log(binary(), keyword()) :: {:ok, struct()} | {:error, term()}
  def log(action, opts) when is_binary(action) and is_list(opts),
    do: PhoenixKit.Activity.log(@module, action, opts)

  @doc """
  Logs a user-driven mutation that did NOT land cleanly — the success
  path would have called `log/2` with the same action + opts; core tags
  the metadata with `db_pending: true` so audit-feed readers can tell
  attempted-but-failed actions from completed ones. A Drive/DB outage
  must not erase admin clicks from the activity feed.
  """
  @spec log_failed(binary(), keyword()) :: {:ok, struct()} | {:error, term()}
  def log_failed(action, opts) when is_binary(action) and is_list(opts),
    do: PhoenixKit.Activity.log_failed(@module, action, opts)

  @doc "The acting user's uuid — see `PhoenixKitWeb.Actor.uuid/1`."
  @spec actor_uuid(Phoenix.LiveView.Socket.t() | map() | nil) :: binary() | nil
  defdelegate actor_uuid(source), to: PhoenixKitWeb.Actor, as: :uuid

  @doc """
  Resolves an assignment's assignee to a core USER uuid for `target_uuid` —
  the field core's activity→notification bridge treats as the recipient
  (Step 7 wiring). Person-assigned rows resolve through the staff person's
  linked account (preloaded or by lookup); team/department/unassigned rows
  resolve nil (multi-recipient fan-out is a later layer — the bridge is
  one-target-per-entry). Nil-safe at every hop; a staff outage degrades to
  nil, never blocks the mutation being logged.
  """
  @spec assignee_target_uuid(map() | nil) :: binary() | nil
  def assignee_target_uuid(%{assigned_person: %{user_uuid: user_uuid}})
      when is_binary(user_uuid),
      do: user_uuid

  def assignee_target_uuid(%{assigned_person_uuid: person_uuid})
      when is_binary(person_uuid) do
    case PhoenixKitProjects.People.get_person(person_uuid, preload: []) do
      %{user_uuid: user_uuid} when is_binary(user_uuid) -> user_uuid
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  def assignee_target_uuid(_), do: nil
end
