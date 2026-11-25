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

  @limit 200

  def index(conn, params) do
    with {:ok, conn} <- Json.scope_project(conn, params),
         {:ok, conn} <- Json.require_scope(conn, "events:read"),
         {:ok, conn} <- require_events(conn),
         {:ok, conn} <- Json.require_action(conn, :view),
         {:ok, from} <- bound(params["from"], "from"),
         {:ok, before} <- bound(params["until"], "until") do
      # One more than the cap, to tell a full page from a cut one.
      events =
        ProjectEvents.list_for_project(conn.assigns.pk_project.uuid,
          from: from,
          before: before,
          limit: @limit + 1
        )

      {events, truncated} =
        if length(events) > @limit, do: {Enum.take(events, @limit), true}, else: {events, false}

      json(conn, %{
        events: Enum.map(events, &event_json/1),
        count: length(events),
        limit: @limit,
        truncated: truncated
      })
    else
      {:halt, conn} -> conn
      {:error, {status, body}} -> conn |> put_status(status) |> json(body)
    end
  end

  def show(conn, %{"id" => id} = params) do
    with {:ok, conn} <- Json.scope_project(conn, params),
         {:ok, conn} <- Json.require_scope(conn, "events:read"),
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

  # A day (`2026-11-01`: that day's start, UTC, as `GET /hours` reads it),
  # an ISO 8601 instant, or one without an offset (read as UTC). Anything
  # else is a 422: a bound dropped in silence answered the OLDEST events
  # as though they were the window asked for.
  defp bound(nil, _field), do: {:ok, nil}
  defp bound("", _field), do: {:ok, nil}

  defp bound(value, field) when is_binary(value) do
    with {:error, _} <- Date.from_iso8601(value),
         {:error, _} <- datetime(value) do
      invalid(field)
    else
      {:ok, %Date{} = date} -> {:ok, DateTime.new!(date, ~T[00:00:00], "Etc/UTC")}
      {:ok, %DateTime{} = dt} -> {:ok, dt}
    end
  end

  defp bound(_value, field), do: invalid(field)

  defp datetime(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} ->
        {:ok, dt}

      {:error, :missing_offset} ->
        with {:ok, naive} <- NaiveDateTime.from_iso8601(value),
             do: {:ok, DateTime.from_naive!(naive, "Etc/UTC")}

      error ->
        error
    end
  end

  defp invalid(field) do
    why = "must be a day (2026-11-01) or an ISO 8601 datetime"
    {:error, Json.error_body(422, "validation_failed", "#{field} #{why}.", %{field => [why]})}
  end
end
