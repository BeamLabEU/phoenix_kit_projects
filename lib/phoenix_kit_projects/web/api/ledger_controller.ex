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
  timeout must not record the work twice.
  """

  use Phoenix.Controller, formats: [:json]

  alias PhoenixKitProjects.Ledger
  alias PhoenixKitProjects.Web.Api.{Json, TasksController}

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
    %{pk_api_key: key, pk_project: project} = conn.assigns

    case params["minutes"] do
      minutes when is_integer(minutes) and minutes > 0 ->
        case Ledger.log_time(project.uuid, minutes,
               assignment_uuid: assignment_uuid,
               note: string_or_nil(params["note"]),
               billable: false,
               actor_kind: "ai_agent",
               actor_uuid: key.uuid,
               source: "ai",
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

      _ ->
        Json.error_body(
          422,
          "validation_failed",
          "minutes must be a positive integer (whole minutes).",
          %{
            minutes: ["must be a positive integer"]
          }
        )
    end
  end

  defp record_usage(conn, assignment_uuid, params) do
    case validate_usage(params["tokens"], params["cost_cents"]) do
      {:error, pair} -> pair
      {:ok, tokens, cost} -> do_record_usage(conn, assignment_uuid, tokens, cost, params)
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

  defp do_record_usage(conn, assignment_uuid, tokens, cost, params) do
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

    case Ledger.record_ai(project.uuid, usage, assignment_uuid: assignment_uuid) do
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

  defp string_or_nil(v) when is_binary(v) and v != "", do: v
  defp string_or_nil(_), do: nil

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)
end
