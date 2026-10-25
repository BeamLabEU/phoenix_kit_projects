defmodule PhoenixKitProjects.Activity do
  @moduledoc "Activity logging wrapper for the Projects module."

  import Ecto.Query, only: [from: 2]

  @module "projects"

  @doc """
  Logs a projects activity entry through `PhoenixKit.Activity.log/3`,
  which never raises — a failure is logged there and returned as
  `{:error, _}`.

  An entry that names a recipient (`target_uuid`) gets its notification
  line, icon and link in the recipient's language on the way through
  (`PhoenixKitProjects.Notices.decorate/3`). A task event that names none
  tells the task's people itself (`Notices.tell_assignees/2`) unless the
  caller passes `tell: false`.

  A project's history is read from these rows (`PhoenixKitProjects.History`),
  and an order is looked back on long after core's activity retention would
  have pruned it, so the rows that make up that story are written
  `permanent` (never pruned) — comment notices included, since they are
  how History says who a comment told.
  """
  @spec log(binary(), keyword()) :: {:ok, struct()} | {:error, term()}
  def log(action, opts) when is_binary(action) and is_list(opts) do
    {tell?, opts} = Keyword.pop(opts, :tell, true)
    {subject, opts} = Keyword.pop(opts, :notice_subject)

    opts =
      action
      |> PhoenixKitProjects.Notices.decorate(opts, subject)
      |> with_project_uuid()
      |> then(&if(history?(action), do: Keyword.put(&1, :permanent, true), else: &1))

    result = PhoenixKit.Activity.log(@module, action, opts)

    if tell? and match?({:ok, _}, result) do
      {:ok, entry} = result

      # History folds each recipient's notice into this exact change,
      # even when another edit follows immediately or delivery is slow.
      opts =
        Keyword.update(opts, :metadata, %{"source_activity_uuid" => entry.uuid}, fn meta ->
          Map.put(meta || %{}, "source_activity_uuid", entry.uuid)
        end)

      PhoenixKitProjects.Notices.tell_assignees(action, opts)
    end

    result
  end

  # A task's row names its project too, so the project's History still finds
  # it once the task is deleted (it is found by the task's uuid until then).
  defp with_project_uuid(opts) do
    meta = Keyword.get(opts, :metadata) || %{}

    with "assignment" <- Keyword.get(opts, :resource_type),
         uuid when is_binary(uuid) <- Keyword.get(opts, :resource_uuid),
         false <- Map.has_key?(meta, "project_uuid"),
         project_uuid when is_binary(project_uuid) <- project_of_assignment(uuid) do
      Keyword.put(opts, :metadata, Map.put(meta, "project_uuid", project_uuid))
    else
      _ -> opts
    end
  end

  defp project_of_assignment(uuid) do
    PhoenixKit.RepoHelper.repo().one(
      from(a in PhoenixKitProjects.Schemas.Assignment,
        where: a.uuid == ^uuid,
        select: a.project_uuid
      )
    )
  rescue
    _ -> nil
  end

  # `projects.comment_added` too: the notice rows are how History says who
  # a comment told, long after core would have pruned them.
  @history_prefixes ~w(projects.assignment_ projects.project_ projects.member_
                       projects.subproject_ projects.dependency_ projects.event_
                       projects.task_list_edited projects.health_updated
                       projects.comment_added projects.work_amended
                       projects.work_removed)

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
