defmodule PhoenixKitProjects.Activity do
  @moduledoc "Activity logging wrapper for the Projects module."

  @module "projects"

  @doc """
  Logs a projects activity entry through `PhoenixKit.Activity.log/3`,
  which never raises — a failure is logged there and returned as
  `{:error, _}`.

  An entry that names a recipient (`target_uuid`) gets its notification
  line, icon and link in the recipient's language on the way through
  (`PhoenixKitProjects.Notices.decorate/2`).

  A project's history is read from these rows (`PhoenixKitProjects.History`),
  and an order is looked back on long after core's activity retention would
  have pruned it, so the rows that make up that story are written
  `permanent` (never pruned). Comment notices are not: the comments
  themselves are the record.
  """
  @spec log(binary(), keyword()) :: {:ok, struct()} | {:error, term()}
  def log(action, opts) when is_binary(action) and is_list(opts) do
    opts =
      action
      |> PhoenixKitProjects.Notices.decorate(opts)
      |> then(&if(history?(action), do: Keyword.put(&1, :permanent, true), else: &1))

    PhoenixKit.Activity.log(@module, action, opts)
  end

  @history_prefixes ~w(projects.assignment_ projects.project_ projects.member_
                       projects.subproject_ projects.dependency_ projects.event_
                       projects.task_list_edited projects.health_updated)

  @doc "Whether `action` is part of a project's lasting history."
  @spec history?(binary()) :: boolean()
  def history?(action) when is_binary(action),
    do: Enum.any?(@history_prefixes, &String.starts_with?(action, &1))

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
