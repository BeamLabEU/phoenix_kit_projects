defmodule PhoenixKitProjects.Web.Api.NotesController do
  @moduledoc """
  A task's notes thread over the API (`TaskNotes`): the long record an
  agent keeps while working, apart from the task's discussion.

    * `GET /tasks/:id/notes` — every note, oldest first, plus what to read
      first: the latest direction (a person's `redirect`), the latest
      agent note, the latest human note.
    * `POST /tasks/:id/notes` — an `agent_note`: a required one-line
      `summary`, optional `content` (the long record), `outcome`,
      `next_steps`, `refs` (commit, branch, PR, …) and `usage` (tokens,
      cost, minutes — written to the ledger in the same transaction).
      `Idempotency-Key` required: this is an append, and a retried timeout
      must not record the work twice.

  A key cannot write a `redirect`: changing the direction is a person's
  act, done in the drawer; the API only reads it back.
  """

  use Phoenix.Controller, formats: [:json]

  alias PhoenixKitProjects.Schemas.{ApiKey, WorkEntry}
  alias PhoenixKitProjects.TaskNotes
  alias PhoenixKitProjects.Web.Api.{Json, TasksController}

  @future_tolerance_seconds 300

  def index(conn, %{"id" => id}) do
    with {:ok, conn, a} <- TasksController.fetch(conn, id),
         {:ok, conn} <- Json.require_scope(conn, "notes:read"),
         {:ok, conn} <- Json.require_feature(conn, :tasks),
         {:ok, conn} <- require_notes(conn),
         {:ok, conn} <- Json.require_action(conn, :view) do
      notes = TaskNotes.list(a.uuid)
      latest = TaskNotes.latest(notes)

      json(conn, %{
        task_uuid: a.uuid,
        direction: latest.redirect && Json.note(latest.redirect),
        latest_agent_note: latest.agent && Json.note(latest.agent),
        latest_human_note: latest.human && Json.note(latest.human),
        notes: Enum.map(notes, &Json.note/1),
        count: length(notes)
      })
    else
      {:halt, conn} -> conn
      {:error, :not_found} -> TasksController.not_found(conn)
    end
  end

  def create(conn, %{"id" => id} = params) do
    with {:ok, conn, a} <- TasksController.fetch(conn, id),
         {:ok, conn} <- Json.require_scope(conn, "notes:write"),
         {:ok, conn} <- Json.require_feature(conn, :tasks),
         {:ok, conn} <- require_notes(conn),
         {:ok, conn} <- Json.require_action(conn, :edit_tasks),
         {:ok, conn} <- require_usage_rights(conn, params["usage"]) do
      Json.idempotent(conn, [required: true], fn -> do_create(conn, a, params) end)
    else
      {:halt, conn} -> conn
      {:error, :not_found} -> TasksController.not_found(conn)
    end
  end

  # Notes live in the comments module: absent or switched off, the
  # thread cannot be stored, and the key is told so in the same words as
  # any other gate.
  defp require_notes(conn) do
    if TaskNotes.available?(),
      do: {:ok, conn},
      else:
        {:halt,
         Json.error(
           conn,
           :forbidden,
           "feature_disabled",
           "Task notes need the comments module switched on for this site.",
           %{feature: "notes"}
         )}
  end

  # Usage on a note is a ledger append: the same scope, gate and floor as
  # the usage endpoints, checked only when usage is sent. Minutes are TIME
  # rows, the time area's (`json.ex`: "minutes are the time area's"), so
  # they also need `time:write` — a key with time "none" otherwise wrote
  # hours through a note that `POST /time` refuses it.
  defp require_usage_rights(conn, usage) when is_map(usage) and map_size(usage) > 0 do
    with {:ok, conn} <- Json.require_scope(conn, "usage:write"),
         {:ok, conn} <- require_time_scope(conn, usage),
         {:ok, conn} <- Json.require_feature(conn, :ledger) do
      Json.require_action(conn, :log_time)
    end
  end

  defp require_usage_rights(conn, _), do: {:ok, conn}

  defp require_time_scope(conn, usage) do
    if minutes?(usage), do: Json.require_scope(conn, "time:write"), else: {:ok, conn}
  end

  defp minutes?(%{"minutes" => m}) when is_number(m), do: m > 0
  defp minutes?(_), do: false

  # A project note's minutes are time on the project as a whole — kept only
  # where the project keeps it (`project_time`), as `POST /time` asks.
  defp require_project_time(conn, usage) do
    if minutes?(usage) and not Map.get(conn.assigns.pk_fx, :project_time, false) do
      {:halt,
       Json.error(
         conn,
         :unprocessable_entity,
         "task_required",
         "Name a task — this project keeps time on its tasks only. " <>
           "Put the minutes on a note of the task they went on.",
         %{feature: :project_time}
       )}
    else
      {:ok, conn}
    end
  end

  # ── The project's own notes ──────────────────────────────────────

  @doc false
  def project_index(conn, params) do
    with {:ok, conn} <- Json.scope_project(conn, params),
         {:ok, conn} <- Json.require_scope(conn, "notes:read"),
         {:ok, conn} <- require_notes(conn),
         {:ok, conn} <- Json.require_action(conn, :view) do
      since = parse_since(params["since"])
      notes = TaskNotes.list_for_project(conn.assigns.pk_project.uuid, since)

      json(conn, %{
        project_uuid: conn.assigns.pk_project.uuid,
        since: since,
        now: DateTime.utc_now() |> DateTime.truncate(:second),
        notes: Enum.map(notes, &Json.note/1),
        count: length(notes)
      })
    else
      {:halt, conn} -> conn
    end
  end

  @doc false
  def project_create(conn, params) do
    with {:ok, conn} <- Json.scope_project(conn, params),
         {:ok, conn} <- Json.require_scope(conn, "notes:write"),
         {:ok, conn} <- require_notes(conn),
         {:ok, conn} <- Json.require_action(conn, :comment),
         {:ok, conn} <- require_usage_rights(conn, params["usage"]),
         {:ok, conn} <- require_project_time(conn, params["usage"]) do
      Json.idempotent(conn, [required: true], fn -> do_create(conn, nil, params) end)
    else
      {:halt, conn} -> conn
    end
  end

  @doc false
  @spec parse_since(term()) :: DateTime.t() | nil
  def parse_since(since) when is_binary(since) do
    case DateTime.from_iso8601(since) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  def parse_since(_), do: nil

  defp do_create(conn, a, params) do
    key = conn.assigns.pk_api_key

    with {:ok, usage} <- parse_usage(params["usage"]),
         {:ok, fields} <- validate(Map.put(params, "usage", usage)),
         {:ok, user_uuid} <- accountable(key) do
      case write_note(a, conn.assigns.pk_project, fields,
             user_uuid: user_uuid,
             kind: "agent_note",
             label: key.name,
             actor: %{kind: "ai_agent", uuid: key.uuid},
             metadata: %{"api_key" => key.uuid, "api_key_name" => key.name, "via" => "api"}
           ) do
        {:ok, %{note: note, entries: entries}} ->
          {201,
           %{
             note: Json.note(note),
             entries: Enum.map(entries, &Json.entry/1)
           }}

        {:error, :content_too_long} ->
          Json.error_body(422, "validation_failed", "content is longer than the site allows.", %{
            content: ["too long"]
          })

        {:error, %Ecto.Changeset{} = cs} ->
          Json.changeset_error(cs)

        {:error, reason} ->
          Json.error_body(
            422,
            "validation_failed",
            "Could not store the note: #{inspect(reason)}."
          )
      end
    else
      {:error, {status, _} = pair} when is_integer(status) ->
        pair

      {:error, %{} = details} ->
        Json.error_body(422, "validation_failed", "Some fields are invalid.", details)
    end
  end

  defp validate(params) do
    case TaskNotes.validate(params, "agent_note") do
      {:ok, fields} -> {:ok, fields}
      {:error, details} -> {:error, details}
    end
  end

  defp write_note(nil, project, fields, opts),
    do: TaskNotes.create_for_project(project, fields, opts)

  defp write_note(a, _project, fields, opts), do: TaskNotes.create(a, fields, opts)

  # The comment's author is the person the key acts for, else the one who
  # minted it. A key with nobody behind it (a script over the node) cannot
  # write notes.
  defp accountable(key) do
    case ApiKey.accountable_uuid(key) do
      uuid when is_binary(uuid) -> {:ok, uuid}
      _ -> no_person()
    end
  end

  defp no_person do
    {:error,
     Json.error_body(
       403,
       "forbidden",
       "This key has no accountable person behind it; mint it from the project's page to write notes."
     )}
  end

  # `usage`: `tokens` / `cost_cents` / `minutes` whole and non-negative,
  # `model`, `occurred_at` (ISO 8601, not in the future). Absent or all
  # zero means no ledger rows.
  defp parse_usage(nil), do: {:ok, nil}

  defp parse_usage(usage) when is_map(usage) do
    with {:ok, tokens} <- non_negative(usage["tokens"], "usage.tokens", WorkEntry.max_amount()),
         {:ok, cost} <-
           non_negative(usage["cost_cents"], "usage.cost_cents", WorkEntry.max_amount()),
         {:ok, minutes} <-
           non_negative(usage["minutes"], "usage.minutes", WorkEntry.max_minutes()),
         {:ok, occurred_at} <- occurred_at(usage["occurred_at"]) do
      {:ok,
       %{
         tokens: tokens,
         cost_cents: cost,
         minutes: minutes,
         model: if(is_binary(usage["model"]) and usage["model"] != "", do: usage["model"]),
         occurred_at: occurred_at,
         estimated: usage["estimated"] in [true, "true"]
       }}
    end
  end

  defp parse_usage(_),
    do:
      {:error,
       Json.error_body(422, "validation_failed", "usage must be an object.", %{
         usage: ["must be an object"]
       })}

  defp non_negative(nil, _field, _max), do: {:ok, nil}
  defp non_negative(n, _field, max) when is_integer(n) and n >= 0 and n <= max, do: {:ok, n}

  defp non_negative(_, field, max),
    do:
      {:error,
       Json.error_body(
         422,
         "validation_failed",
         "#{field} must be a non-negative integer, at most #{max}.",
         %{field => ["must be a non-negative integer, at most #{max}"]}
       )}

  defp occurred_at(nil), do: {:ok, nil}

  defp occurred_at(value) when is_binary(value) do
    with {:ok, dt, _offset} <- DateTime.from_iso8601(value),
         dt = DateTime.truncate(dt, :second),
         true <- DateTime.diff(dt, DateTime.utc_now(), :second) <= @future_tolerance_seconds do
      {:ok, dt}
    else
      false -> occurred_at_error("must not be in the future")
      _ -> occurred_at_error("must be an ISO 8601 datetime")
    end
  end

  defp occurred_at(_), do: occurred_at_error("must be an ISO 8601 datetime")

  defp occurred_at_error(why) do
    {:error,
     Json.error_body(422, "validation_failed", "usage.occurred_at #{why}.", %{
       "usage.occurred_at" => [why]
     })}
  end
end
