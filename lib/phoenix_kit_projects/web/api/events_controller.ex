defmodule PhoenixKitProjects.Web.Api.EventsController do
  @moduledoc """
  `GET /events` and `GET /events/{id}` — the project's planned events
  (meetings, milestones, reviews): the plan a client interaction may be
  the record of (`event_uuid`). Read-only; needs the project's events
  extension on.
  """

  use Phoenix.Controller, formats: [:json]

  alias PhoenixKitProjects.{Extensions, ProjectEvents}
  alias PhoenixKitProjects.Web.Api.Json

  def index(conn, params) do
    with {:ok, conn} <- Json.require_scope(conn, "tasks:read"),
         {:ok, conn} <- Json.scope_project(conn, params),
         {:ok, conn} <- require_events(conn),
         {:ok, conn} <- Json.require_action(conn, :view) do
      opts =
        [limit: 200]
        |> maybe_bound(:from, params["from"])
        |> maybe_bound(:until, params["until"])

      events = ProjectEvents.list_for_project(conn.assigns.pk_project.uuid, opts)
      json(conn, %{events: Enum.map(events, &event_json/1), count: length(events)})
    else
      {:halt, conn} -> conn
    end
  end

  def show(conn, %{"id" => id} = params) do
    with {:ok, conn} <- Json.require_scope(conn, "tasks:read"),
         {:ok, conn} <- Json.scope_project(conn, params),
         {:ok, conn} <- require_events(conn),
         {:ok, conn} <- Json.require_action(conn, :view) do
      case ProjectEvents.get(conn.assigns.pk_project.uuid, id) do
        nil -> Json.error(conn, :not_found, "not_found", "No such event on this project.")
        event -> json(conn, %{event: event_json(event)})
      end
    else
      {:halt, conn} -> conn
    end
  end

  @doc false
  @spec event_json(map()) :: map()
  def event_json(e) do
    %{
      uuid: e.uuid,
      title: e.title,
      description: e.description,
      starts_at: e.starts_at,
      ends_at: e.ends_at,
      all_day: e.all_day,
      location: e.location,
      inserted_at: e.inserted_at,
      updated_at: e.updated_at
    }
  end

  defp require_events(conn) do
    if Extensions.enabled?(conn.assigns.pk_project, "events"),
      do: {:ok, conn},
      else:
        {:halt,
         Json.error(
           conn,
           :forbidden,
           "feature_disabled",
           "The events extension is not enabled on this project.",
           %{feature: "events"}
         )}
  end

  defp maybe_bound(opts, key, value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> Keyword.put(opts, key, dt)
      _ -> opts
    end
  end

  defp maybe_bound(opts, _key, _), do: opts
end
