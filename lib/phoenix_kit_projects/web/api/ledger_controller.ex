defmodule PhoenixKitProjects.Web.Api.LedgerController do
  @moduledoc """
  What the agent reports about its work, into the project's work ledger:

    * `POST /tasks/:id/time` and `POST /time` — minutes spent. Recorded as
      `kind: "time"` by the key (`actor_kind: "ai_agent"`), never billable:
      the project's totals show it as AI time, apart from people's time, and
      invoicing bills people only.
    * `POST /tasks/:id/usage` and `POST /usage` — tokens and cost
      (`cost_cents`, an integer), through `Ledger.record_ai/3`, the same
      path the kit's own AI calls take.

  Both require an `Idempotency-Key`: these are appends, and a retried
  timeout must not record the work twice. Both take an optional
  `occurred_at` (ISO 8601) — when the work happened, for an agent that
  reports in batches after the fact — stored as the entry's `ended_at`
  and echoed back; `recorded_at` stays the server's receipt time.
  """

  use Phoenix.Controller, formats: [:json]

  alias PhoenixKitProjects.Ledger
  alias PhoenixKitProjects.Web.Api.{Json, TasksController}

  # How far ahead of the server's clock an `occurred_at` may be: an agent's
  # clock skew, not a report from the future.
  @future_tolerance_seconds 300

  def task_time(conn, %{"id" => id} = params) do
    with {:ok, conn} <- checks(conn, "time:write", :log_time),
         {:ok, a} <- TasksController.fetch(conn, id) do
      Json.idempotent(conn, [required: true], fn -> record_time(conn, a.uuid, params) end)
    else
      {:halt, conn} -> conn
      {:error, :not_found} -> TasksController.not_found(conn)
    end
  end

  def project_time(conn, params) do
    case checks(conn, "time:write", :log_time) do
      {:ok, conn} ->
        Json.idempotent(conn, [required: true], fn -> record_time(conn, nil, params) end)

      {:halt, conn} ->
        conn
    end
  end

  def task_usage(conn, %{"id" => id} = params) do
    with {:ok, conn} <- checks(conn, "usage:write", :log_time),
         {:ok, a} <- TasksController.fetch(conn, id) do
      Json.idempotent(conn, [required: true], fn -> record_usage(conn, a.uuid, params) end)
    else
      {:halt, conn} -> conn
      {:error, :not_found} -> TasksController.not_found(conn)
    end
  end

  def project_usage(conn, params) do
    case checks(conn, "usage:write", :log_time) do
      {:ok, conn} ->
        Json.idempotent(conn, [required: true], fn -> record_usage(conn, nil, params) end)

      {:halt, conn} ->
        conn
    end
  end

  defp checks(conn, scope, action) do
    with {:ok, conn} <- Json.require_scope(conn, scope),
         {:ok, conn} <- Json.require_feature(conn, :ledger) do
      Json.require_action(conn, action)
    end
  end

  defp record_time(conn, assignment_uuid, params) do
    with {:ok, minutes} <- validate_minutes(params["minutes"]),
         {:ok, occurred_at} <- validate_occurred_at(params["occurred_at"]) do
      do_record_time(conn, assignment_uuid, minutes, occurred_at, params)
    else
      {:error, pair} -> pair
    end
  end

  defp validate_minutes(minutes) when is_integer(minutes) and minutes > 0, do: {:ok, minutes}

  defp validate_minutes(_) do
    {:error,
     Json.error_body(
       422,
       "validation_failed",
       "minutes must be a positive integer (whole minutes).",
       %{minutes: ["must be a positive integer"]}
     )}
  end

  defp do_record_time(conn, assignment_uuid, minutes, occurred_at, params) do
    %{pk_api_key: key, pk_project: project} = conn.assigns

    case Ledger.log_time(project.uuid, minutes,
           assignment_uuid: assignment_uuid,
           note: string_or_nil(params["note"]),
           billable: false,
           actor_kind: "ai_agent",
           actor_uuid: key.uuid,
           source: "ai",
           ended_at: occurred_at,
           metadata: %{"api_key_name" => key.name, "via" => "api"}
         ) do
      {:ok, entry} ->
        {201,
         %{
           entry: %{
             uuid: entry.uuid,
             kind: "time",
             minutes: minutes,
             task_uuid: assignment_uuid,
             note: entry.note,
             occurred_at: entry.ended_at,
             recorded_at: entry.inserted_at
           }
         }}

      {:error, %Ecto.Changeset{} = cs} ->
        Json.changeset_error(cs)

      {:error, reason} ->
        Json.error_body(
          422,
          "validation_failed",
          "Could not record the time: #{inspect(reason)}."
        )
    end
  end

  defp record_usage(conn, assignment_uuid, params) do
    with {:ok, tokens, cost} <- validate_usage(params["tokens"], params["cost_cents"]),
         {:ok, occurred_at} <- validate_occurred_at(params["occurred_at"]) do
      do_record_usage(conn, assignment_uuid, tokens, cost, occurred_at, params)
    else
      {:error, pair} -> pair
    end
  end

  defp validate_usage(tokens, cost) do
    cond do
      not (is_nil(tokens) or (is_integer(tokens) and tokens >= 0)) ->
        {:error,
         Json.error_body(422, "validation_failed", "tokens must be a non-negative integer.", %{
           tokens: ["must be a non-negative integer"]
         })}

      not (is_nil(cost) or (is_integer(cost) and cost >= 0)) ->
        {:error,
         Json.error_body(
           422,
           "validation_failed",
           "cost_cents must be a non-negative integer (whole cents).",
           %{cost_cents: ["must be a non-negative integer"]}
         )}

      (tokens || 0) == 0 and (cost || 0) == 0 ->
        {:error,
         Json.error_body(
           422,
           "validation_failed",
           "Nothing to record: tokens and cost_cents are both zero or absent."
         )}

      true ->
        {:ok, tokens, cost}
    end
  end

  defp do_record_usage(conn, assignment_uuid, tokens, cost, occurred_at, params) do
    %{pk_api_key: key, pk_project: project} = conn.assigns

    usage =
      %{
        tokens: tokens,
        cost_cents: cost,
        agent_uuid: key.uuid,
        api_key_name: key.name,
        via: "api"
      }
      |> maybe_put(:model, string_or_nil(params["model"]))
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    case Ledger.record_ai(project.uuid, usage,
           assignment_uuid: assignment_uuid,
           occurred_at: occurred_at
         ) do
      {:ok, entries} ->
        {201,
         %{
           entries:
             Enum.map(entries, fn e ->
               %{
                 uuid: e.uuid,
                 kind: e.kind,
                 amount: Decimal.to_float(e.amount),
                 task_uuid: assignment_uuid,
                 occurred_at: e.ended_at,
                 recorded_at: e.inserted_at
               }
             end)
         }}

      {:error, :nothing_to_record} ->
        Json.error_body(422, "validation_failed", "Nothing to record.")

      {:error, %Ecto.Changeset{} = cs} ->
        Json.changeset_error(cs)

      {:error, reason} ->
        Json.error_body(
          422,
          "validation_failed",
          "Could not record the usage: #{inspect(reason)}."
        )
    end
  end

  # `occurred_at`: absent → nil (the entry carries only its receipt time);
  # an ISO 8601 datetime → UTC, whole seconds, not meaningfully in the
  # future. Anything else is a 422 that names the field.
  defp validate_occurred_at(nil), do: {:ok, nil}

  defp validate_occurred_at(value) when is_binary(value) do
    with {:ok, dt, _offset} <- DateTime.from_iso8601(value),
         dt = DateTime.truncate(dt, :second),
         true <- DateTime.diff(dt, DateTime.utc_now(), :second) <= @future_tolerance_seconds do
      {:ok, dt}
    else
      false -> {:error, occurred_at_error("must not be in the future")}
      _ -> {:error, occurred_at_error("must be an ISO 8601 datetime, e.g. 2026-10-05T14:30:00Z")}
    end
  end

  defp validate_occurred_at(_), do: {:error, occurred_at_error("must be an ISO 8601 datetime")}

  defp occurred_at_error(why) do
    Json.error_body(422, "validation_failed", "occurred_at #{why}.", %{occurred_at: [why]})
  end

  defp string_or_nil(v) when is_binary(v) and v != "", do: v
  defp string_or_nil(_), do: nil

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)
end
