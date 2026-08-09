defmodule PhoenixKitProjects.ProjectEvents do
  @moduledoc """
  Project events (Step 12): CRUD for the V6 `phoenix_kit_project_events`
  table — the Events extension tab's data layer. Every write logs
  activity and broadcasts on the project topic; there is no notification
  fan-out yet (events carry no `target_uuid` — deciding who an event
  should notify is a product call for daylight).
  """

  import Ecto.Query

  alias PhoenixKit.RepoHelper
  alias PhoenixKitProjects.Activity
  alias PhoenixKitProjects.Members
  alias PhoenixKitProjects.PubSub
  alias PhoenixKitProjects.Schemas.ProjectEvent

  @doc """
  Events for a project ordered by start. Options: `:from`/`:until`
  (DateTime bounds on `starts_at`), `:limit`.
  """
  @spec list_for_project(binary(), keyword()) :: [ProjectEvent.t()]
  def list_for_project(project_uuid, opts \\ []) do
    from(e in ProjectEvent,
      where: e.project_uuid == ^project_uuid,
      order_by: [asc: e.starts_at, asc: e.inserted_at]
    )
    |> maybe_bound(:from, Keyword.get(opts, :from))
    |> maybe_bound(:until, Keyword.get(opts, :until))
    |> maybe_limit(Keyword.get(opts, :limit))
    |> RepoHelper.repo().all()
  rescue
    _ -> []
  end

  @doc "Fetches an event scoped to its project (nil on cross-project uuids)."
  @spec get(binary(), binary()) :: ProjectEvent.t() | nil
  def get(project_uuid, event_uuid) do
    RepoHelper.repo().one(
      from(e in ProjectEvent,
        where: e.uuid == ^event_uuid and e.project_uuid == ^project_uuid
      )
    )
  rescue
    _ -> nil
  end

  @doc "Creates an event for a project. `opts[:actor_uuid]` for the trail."
  @spec create(map(), map(), keyword()) ::
          {:ok, ProjectEvent.t()} | {:error, Ecto.Changeset.t()}
  def create(project, attrs, opts \\ []) do
    actor_uuid = Keyword.get(opts, :actor_uuid)

    %ProjectEvent{}
    |> ProjectEvent.changeset(
      attrs
      |> Map.put(:project_uuid, project.uuid)
      |> Map.put_new(:created_by_uuid, actor_uuid)
    )
    |> RepoHelper.repo().insert()
    |> tap_event("projects.event_created", :project_event_created, actor_uuid)
  end

  @doc "Updates an event."
  @spec update(ProjectEvent.t(), map(), keyword()) ::
          {:ok, ProjectEvent.t()} | {:error, Ecto.Changeset.t()}
  def update(%ProjectEvent{} = event, attrs, opts \\ []) do
    event
    |> ProjectEvent.changeset(attrs)
    |> RepoHelper.repo().update()
    |> tap_event("projects.event_updated", :project_event_updated, Keyword.get(opts, :actor_uuid))
  end

  @doc "Deletes an event."
  @spec delete(ProjectEvent.t(), keyword()) :: :ok | {:error, term()}
  def delete(%ProjectEvent{} = event, opts \\ []) do
    case RepoHelper.repo().delete(event) do
      {:ok, deleted} ->
        {:ok, _} =
          tap_event(
            {:ok, deleted},
            "projects.event_deleted",
            :project_event_deleted,
            Keyword.get(opts, :actor_uuid)
          )

        :ok

      {:error, _} = error ->
        error
    end
  end

  defp tap_event({:ok, event} = result, action, broadcast, actor_uuid) do
    log_result =
      Activity.log(action,
        actor_uuid: actor_uuid,
        resource_type: "project",
        resource_uuid: event.project_uuid,
        metadata: %{
          "title" => event.title,
          "event_uuid" => event.uuid,
          "starts_at" => DateTime.to_iso8601(event.starts_at)
        }
      )

    notify_members(log_result, event.project_uuid)
    PubSub.broadcast_project(broadcast, %{uuid: event.project_uuid})
    result
  end

  defp tap_event({:error, _} = error, _action, _broadcast, _actor), do: error

  # Fan the ONE feed entry out to every project member's notification
  # rules (Max's call: events notify all members). Core's
  # fan_out_from_activity/2 re-routes the committed entry per recipient
  # (prefs, channels, digests, actor self-skip) without extra feed rows.
  # `apply/3` + function_exported?: the fan-out ships in an unreleased
  # core — against the Hex pin this is a clean no-op until the release
  # (the release-gating convention); the path-dep build runs it live.
  defp notify_members({:ok, entry}, project_uuid) do
    if function_exported?(PhoenixKit.Notifications, :fan_out_from_activity, 2) do
      recipients =
        project_uuid
        |> Members.list_members()
        |> Enum.map(& &1.user_uuid)

      if recipients != [] do
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        apply(PhoenixKit.Notifications, :fan_out_from_activity, [entry, recipients])
      end
    end

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp notify_members(_log_result, _project_uuid), do: :ok

  defp maybe_bound(query, _key, nil), do: query
  defp maybe_bound(query, :from, dt), do: where(query, [e], e.starts_at >= ^dt)
  defp maybe_bound(query, :until, dt), do: where(query, [e], e.starts_at <= ^dt)

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, n) when is_integer(n) and n > 0, do: limit(query, ^n)
end
