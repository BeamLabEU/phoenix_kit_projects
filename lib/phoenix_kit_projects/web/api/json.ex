defmodule PhoenixKitProjects.Web.Api.Json do
  @moduledoc """
  What every API controller shares: the error envelope, the checks a call
  passes before it does anything (scope, role floor, feature gate), the
  idempotency wrapper, and the JSON shapes of a task and a project.

  Errors are one shape, `{"error": {"code", "message", "details"?}}`, with
  a stable machine code and an English message (the API is locale-free; the
  codes are the contract, the messages are display text).
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias PhoenixKitProjects.{ApiKeys, Authz, Statuses}
  alias PhoenixKitProjects.Schemas.{ApiKey, Assignment, Project, Task}

  @lifecycle ~w(todo in_progress done)
  @transitions %{
    "todo" => ~w(in_progress done),
    "in_progress" => ~w(done todo),
    "done" => ~w(todo)
  }

  @doc "The lifecycle states a task can be in, and the moves allowed from each."
  @spec lifecycle() :: [String.t()]
  def lifecycle, do: @lifecycle

  @spec transitions() :: %{String.t() => [String.t()]}
  def transitions, do: @transitions

  @doc "Sends the error envelope with `status` and halts nothing — the caller returns the conn."
  @spec error(Plug.Conn.t(), atom() | integer(), String.t(), String.t(), map() | nil) ::
          Plug.Conn.t()
  def error(conn, status, code, message, details \\ nil) do
    body = %{code: code, message: message}
    body = if details, do: Map.put(body, :details, details), else: body

    conn
    |> put_status(status)
    |> json(%{error: body})
  end

  @doc "The key must carry `scope`, else 403 `scope_missing`."
  @spec require_scope(Plug.Conn.t(), String.t()) :: {:ok, Plug.Conn.t()} | {:halt, Plug.Conn.t()}
  def require_scope(conn, scope) do
    if ApiKey.scope?(conn.assigns.pk_api_key, scope),
      do: {:ok, conn},
      else:
        {:halt,
         error(
           conn,
           :forbidden,
           "scope_missing",
           "This key does not carry the #{scope} scope.",
           %{
             scope: scope
           }
         )}
  end

  @doc "The key's role must meet `action`'s floor on this project, else 403 `forbidden`."
  @spec require_action(Plug.Conn.t(), atom()) :: {:ok, Plug.Conn.t()} | {:halt, Plug.Conn.t()}
  def require_action(conn, action) do
    %{pk_api_key: key, pk_project: project} = conn.assigns

    if Authz.can_role?(project, key.role, action),
      do: {:ok, conn},
      else:
        {:halt,
         error(
           conn,
           :forbidden,
           "forbidden",
           "A #{key.role} key may not #{action} on this project.",
           %{
             action: action,
             role: key.role
           }
         )}
  end

  @doc "The project's `feature` (a gate of `Features.gates/1`) must be on, else 403 `feature_disabled`."
  @spec require_feature(Plug.Conn.t(), atom()) :: {:ok, Plug.Conn.t()} | {:halt, Plug.Conn.t()}
  def require_feature(conn, feature) do
    if Map.get(conn.assigns.pk_fx, feature, false),
      do: {:ok, conn},
      else:
        {:halt,
         error(
           conn,
           :forbidden,
           "feature_disabled",
           "The #{feature} feature is turned off for this project.",
           %{feature: feature}
         )}
  end

  @doc """
  Runs `fun` (returning `{status, body}`) once per `Idempotency-Key`
  header; a replay answers the stored response. `required: true` refuses a
  POST without the header (422 `idempotency_key_required`).
  """
  @spec idempotent(Plug.Conn.t(), keyword(), (-> {integer(), map()})) :: Plug.Conn.t()
  def idempotent(conn, opts, fun) do
    key = conn.assigns.pk_api_key
    header = idempotency_key(conn)

    if is_nil(header) and Keyword.get(opts, :required, false) do
      error(
        conn,
        :unprocessable_entity,
        "idempotency_key_required",
        "Send an Idempotency-Key header (any unique string per attempt), so a retry cannot record this twice."
      )
    else
      case ApiKeys.idempotent(key, header, fun) do
        {:ok, status, body} ->
          conn |> put_status(status) |> json(body)

        {:replay, status, body} ->
          conn
          |> put_resp_header("idempotent-replayed", "true")
          |> put_status(status)
          |> json(body)
      end
    end
  end

  defp idempotency_key(conn) do
    case get_req_header(conn, "idempotency-key") do
      [v] when byte_size(v) in 1..128 -> v
      _ -> nil
    end
  end

  @doc "The error envelope for a changeset, as a `{422, body}` pair for `idempotent/3`."
  @spec changeset_error(Ecto.Changeset.t()) :: {422, map()}
  def changeset_error(%Ecto.Changeset{} = cs) do
    details =
      Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {k, v}, acc ->
          String.replace(acc, "%{#{k}}", to_string(v))
        end)
      end)

    {422,
     %{error: %{code: "validation_failed", message: "Some fields are invalid.", details: details}}}
  end

  @doc "A `{status, body}` error pair for `idempotent/3`."
  @spec error_body(integer(), String.t(), String.t(), map() | nil) :: {integer(), map()}
  def error_body(status, code, message, details \\ nil) do
    body = %{code: code, message: message}
    body = if details, do: Map.put(body, :details, details), else: body
    {status, %{error: body}}
  end

  @doc "The JSON shape of a task (an assignment with its task or sub-project preloaded)."
  @spec task(Assignment.t()) :: map()
  def task(%Assignment{} = a) do
    %{
      uuid: a.uuid,
      kind: if(a.child_project_uuid, do: "subproject", else: "task"),
      title: Assignment.label(a),
      description: description(a),
      status: a.status,
      allowed_transitions: Map.get(@transitions, a.status, []),
      priority: a.priority,
      progress_pct: a.progress_pct,
      estimated_duration: a.estimated_duration,
      estimated_duration_unit: a.estimated_duration_unit,
      position: a.position,
      task_uuid: a.task_uuid,
      child_project_uuid: a.child_project_uuid,
      library_task: library_task?(a),
      completed_at: a.completed_at,
      inserted_at: a.inserted_at,
      updated_at: a.updated_at
    }
  end

  defp description(%Assignment{description: d}) when is_binary(d) and d != "", do: d
  defp description(%Assignment{task: %Task{description: d}}), do: d
  defp description(_), do: nil

  defp library_task?(%Assignment{task: %Task{ad_hoc: ad_hoc}}), do: not ad_hoc
  defp library_task?(_), do: false

  @doc "The JSON shape of the key's project."
  @spec project(Project.t()) :: map()
  def project(%Project{} = p) do
    statuses =
      p
      |> Statuses.statuses_for()
      |> Enum.map(&%{slug: &1.slug, name: Map.get(&1, :name) || Map.get(&1, :title)})

    %{
      uuid: p.uuid,
      name: p.name,
      description: p.description,
      start_mode: p.start_mode,
      started_at: p.started_at,
      completed_at: p.completed_at,
      archived_at: p.archived_at,
      workflow_status: p.current_status_slug,
      available_workflow_statuses: statuses
    }
  rescue
    _ -> %{uuid: p.uuid, name: p.name}
  end
end
