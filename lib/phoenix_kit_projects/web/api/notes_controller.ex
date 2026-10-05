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

  alias PhoenixKitProjects.Schemas.ApiKey
  alias PhoenixKitProjects.TaskNotes
  alias PhoenixKitProjects.Web.Api.{Json, TasksController}

  @future_tolerance_seconds 300

  def index(conn, %{"id" => id}) do
    with {:ok, conn} <- Json.require_scope(conn, "tasks:read"),
         {:ok, conn} <- Json.require_feature(conn, :tasks),
         {:ok, conn} <- require_notes(conn),
         {:ok, conn} <- Json.require_action(conn, :view),
         {:ok, conn, a} <- TasksController.fetch(conn, id) do
      notes = TaskNotes.list(a.uuid)
      latest = TaskNotes.latest(notes)

      json(conn, %{
        task_uuid: a.uuid,
        direction: latest.redirect && TaskNotes.to_json(latest.redirect),
        latest_agent_note: latest.agent && TaskNotes.to_json(latest.agent),
        latest_human_note: latest.human && TaskNotes.to_json(latest.human),
        notes: Enum.map(notes, &TaskNotes.to_json/1),
        count: length(notes)
      })
    else
      {:halt, conn} -> conn
      {:error, :not_found} -> TasksController.not_found(conn)
    end
  end

  def create(conn, %{"id" => id} = params) do
    with {:ok, conn} <- Json.require_scope(conn, "tasks:write"),
         {:ok, conn} <- Json.require_feature(conn, :tasks),
         {:ok, conn} <- require_notes(conn),
         {:ok, conn} <- Json.require_action(conn, :edit_tasks),
         {:ok, conn} <- require_usage_rights(conn, params["usage"]),
         {:ok, conn, a} <- TasksController.fetch(conn, id) do
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
  # the usage endpoints, checked only when usage is sent.
  defp require_usage_rights(conn, usage) when is_map(usage) and map_size(usage) > 0 do
    with {:ok, conn} <- Json.require_scope(conn, "usage:write"),
         {:ok, conn} <- Json.require_feature(conn, :ledger) do
      Json.require_action(conn, :log_time)
    end
  end

  defp require_usage_rights(conn, _), do: {:ok, conn}

  defp do_create(conn, a, params) do
    key = conn.assigns.pk_api_key

    with {:ok, usage} <- parse_usage(params["usage"]),
         {:ok, fields} <- validate(Map.put(params, "usage", usage)),
         {:ok, user_uuid} <- accountable(key) do
      case TaskNotes.create(a, fields,
             user_uuid: user_uuid,
             kind: "agent_note",
             label: key.name,
             actor: %{kind: "ai_agent", uuid: key.uuid},
             metadata: %{"api_key" => key.uuid, "api_key_name" => key.name, "via" => "api"}
           ) do
        {:ok, %{note: note, entries: entries}} ->
          {201,
           %{
             note: TaskNotes.to_json(note),
             entries:
               Enum.map(entries, fn e ->
                 %{uuid: e.uuid, kind: e.kind, amount: Decimal.to_float(e.amount)}
               end)
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
    with {:ok, tokens} <- non_negative(usage["tokens"], "usage.tokens"),
         {:ok, cost} <- non_negative(usage["cost_cents"], "usage.cost_cents"),
         {:ok, minutes} <- non_negative(usage["minutes"], "usage.minutes"),
         {:ok, occurred_at} <- occurred_at(usage["occurred_at"]) do
      {:ok,
       %{
         tokens: tokens,
         cost_cents: cost,
         minutes: minutes,
         model: if(is_binary(usage["model"]) and usage["model"] != "", do: usage["model"]),
         occurred_at: occurred_at
       }}
    end
  end

  defp parse_usage(_),
    do:
      {:error,
       Json.error_body(422, "validation_failed", "usage must be an object.", %{
         usage: ["must be an object"]
       })}

  defp non_negative(nil, _field), do: {:ok, nil}
  defp non_negative(n, _field) when is_integer(n) and n >= 0, do: {:ok, n}

  defp non_negative(_, field),
    do:
      {:error,
       Json.error_body(422, "validation_failed", "#{field} must be a non-negative integer.", %{
         field => ["must be a non-negative integer"]
       })}

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
