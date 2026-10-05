defmodule PhoenixKitProjects.Web.Api.TasksController do
  @moduledoc """
  The tasks of the key's project: list, read, create, edit content, and move
  through the lifecycle (`todo` → `in_progress` → `done` → `todo`).

  Every write goes through the same context functions the admin pages use
  (`Projects.create_task_with_assignment/3`, `update_assignment_form/3`,
  `update_assignment_status/2`, `complete_assignment/2`, `reopen_assignment/1`)
  and logs the same activity actions, with the key named in the metadata;
  the activity's actor is the person who minted the key. After a lifecycle
  move the project's own completion is recomputed, as the project page does.

  Content edits to a task that is a LIBRARY task (shared across projects)
  are refused: an agent renaming a shared task would rename it everywhere.
  """

  use Phoenix.Controller, formats: [:json]

  alias PhoenixKit.Mentions
  alias PhoenixKitProjects.{Activity, Ledger, Projects}
  alias PhoenixKitProjects.Schemas.Assignment
  alias PhoenixKitProjects.Web.Api.Json

  @priorities ~w(urgent high normal low)
  @units ~w(minutes hours days weeks fortnights months years)

  def index(conn, params) do
    with {:ok, conn} <- Json.require_scope(conn, "tasks:read"),
         {:ok, conn} <- Json.require_feature(conn, :tasks),
         {:ok, conn} <- Json.require_action(conn, :view) do
      tasks =
        conn.assigns.pk_project.uuid
        |> Projects.list_assignments()
        |> filter_status(params["status"])

      totals = Ledger.totals_for_assignments(Enum.map(tasks, & &1.uuid))
      json(conn, %{tasks: Enum.map(tasks, &Json.task(&1, totals[&1.uuid])), count: length(tasks)})
    else
      {:halt, conn} -> conn
    end
  end

  defp filter_status(tasks, status) when status in ["todo", "in_progress", "done"],
    do: Enum.filter(tasks, &(&1.status == status))

  defp filter_status(tasks, "open"), do: Enum.reject(tasks, &(&1.status == "done"))
  defp filter_status(tasks, _), do: tasks

  def show(conn, %{"id" => id}) do
    with {:ok, conn} <- Json.require_scope(conn, "tasks:read"),
         {:ok, conn} <- Json.require_feature(conn, :tasks),
         {:ok, conn} <- Json.require_action(conn, :view),
         {:ok, a} <- fetch(conn, id) do
      json(conn, %{task: Map.merge(Json.task(a), Json.task_detail(a))})
    else
      {:halt, conn} -> conn
      {:error, :not_found} -> not_found(conn)
    end
  end

  def create(conn, params) do
    with {:ok, conn} <- Json.require_scope(conn, "tasks:write"),
         {:ok, conn} <- Json.require_feature(conn, :tasks),
         {:ok, conn} <- Json.require_action(conn, :create_tasks) do
      Json.idempotent(conn, [], fn -> do_create(conn, params) end)
    else
      {:halt, conn} -> conn
    end
  end

  defp do_create(conn, params) do
    %{pk_api_key: key, pk_project: project} = conn.assigns

    with {:ok, title} <- required_string(params, "title"),
         {:ok, assignment_attrs} <- assignment_attrs(params) do
      task_attrs =
        %{"title" => title, "ad_hoc" => true}
        |> maybe_put("description", params["description"])

      case Projects.create_task_with_assignment(project.uuid, task_attrs, assignment_attrs) do
        {:ok, %{assignment: a}} ->
          Activity.log("projects.assignment_created",
            actor_uuid: key.created_by_uuid,
            resource_type: "assignment",
            resource_uuid: a.uuid,
            metadata: api_metadata(key, %{"task" => title})
          )

          sync_mentions(a.uuid, task_attrs["description"], key)

          {201, %{task: Json.task(Projects.get_assignment(a.uuid))}}

        {:error, _step, %Ecto.Changeset{} = cs} ->
          Json.changeset_error(cs)

        {:error, :project, :not_found} ->
          Json.error_body(404, "not_found", "The key's project is gone.")
      end
    else
      {:error, {422, _} = pair} -> pair
    end
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, conn} <- Json.require_scope(conn, "tasks:write"),
         {:ok, conn} <- Json.require_feature(conn, :tasks),
         {:ok, conn} <- Json.require_action(conn, :edit_tasks),
         {:ok, a} <- fetch(conn, id) do
      Json.idempotent(conn, [], fn -> do_update(conn, a, params) end)
    else
      {:halt, conn} -> conn
      {:error, :not_found} -> not_found(conn)
    end
  end

  defp do_update(conn, %Assignment{} = a, params) do
    key = conn.assigns.pk_api_key
    content = Map.take(params, ["title", "description"])

    with :ok <- content_editable(a, content),
         {:ok, assignment_attrs} <- assignment_attrs(params),
         {:ok, _} <- update_content(a, content),
         {:ok, _} <- update_fields(a, assignment_attrs) do
      Activity.log("projects.assignment_updated",
        actor_uuid: key.created_by_uuid,
        resource_type: "assignment",
        resource_uuid: a.uuid,
        metadata: api_metadata(key, %{"fields" => Map.keys(Map.merge(content, assignment_attrs))})
      )

      if Map.has_key?(content, "description"),
        do: sync_mentions(a.uuid, content["description"], key)

      {200, %{task: Json.task(Projects.get_assignment(a.uuid))}}
    else
      {:error, {status, _} = pair} when is_integer(status) -> pair
      {:error, %Ecto.Changeset{} = cs} -> Json.changeset_error(cs)
    end
  end

  # Indexes the `#` links in a saved description, so a task that says
  # "from this meeting" is listed on the meeting (core keeps the reverse
  # index). Never fails the save: a mention that does not index is a
  # missing backlink, not lost work.
  defp sync_mentions(assignment_uuid, description, key) when is_binary(description) do
    Mentions.sync("project_task", assignment_uuid, description,
      field: "description",
      actor_uuid: key.created_by_uuid
    )
  rescue
    _ -> :ok
  end

  defp sync_mentions(_uuid, _description, _key), do: :ok

  defp content_editable(_a, content) when map_size(content) == 0, do: :ok

  defp content_editable(%Assignment{task: %{ad_hoc: true}}, _content), do: :ok

  defp content_editable(_a, _content),
    do:
      {:error,
       Json.error_body(
         409,
         "library_task",
         "This task comes from the shared library; its title and description are edited there, not per project."
       )}

  defp update_content(_a, content) when map_size(content) == 0, do: {:ok, nil}
  defp update_content(%Assignment{task: task}, content), do: Projects.update_task(task, content)

  defp update_fields(_a, attrs) when map_size(attrs) == 0, do: {:ok, nil}
  defp update_fields(a, attrs), do: Projects.update_assignment_form(a, attrs)

  def transition(conn, %{"id" => id} = params) do
    with {:ok, conn} <- Json.require_scope(conn, "tasks:write"),
         {:ok, conn} <- Json.require_feature(conn, :tasks),
         {:ok, conn} <- Json.require_action(conn, :update_status),
         {:ok, a} <- fetch(conn, id) do
      Json.idempotent(conn, [], fn -> do_transition(conn, a, params["status"]) end)
    else
      {:halt, conn} -> conn
      {:error, :not_found} -> not_found(conn)
    end
  end

  def start(conn, params), do: transition(conn, Map.put(params, "status", "in_progress"))
  def complete(conn, params), do: transition(conn, Map.put(params, "status", "done"))
  def reopen(conn, params), do: transition(conn, Map.put(params, "status", "todo"))

  defp do_transition(conn, %Assignment{} = a, to) do
    key = conn.assigns.pk_api_key
    allowed = Map.get(Json.transitions(), a.status, [])

    cond do
      to not in Json.lifecycle() ->
        Json.error_body(
          422,
          "validation_failed",
          "status must be one of todo, in_progress, done.",
          %{
            status: Json.lifecycle()
          }
        )

      to not in allowed ->
        Json.error_body(
          409,
          "invalid_transition",
          "The task is #{a.status}; from there it can only go to #{Enum.join(allowed, " or ")}.",
          %{from: a.status, allowed_transitions: allowed}
        )

      true ->
        {action, result} = apply_transition(a, to, key)

        case result do
          {:ok, _} ->
            Activity.log(action,
              actor_uuid: key.created_by_uuid,
              resource_type: "assignment",
              resource_uuid: a.uuid,
              target_uuid: Activity.assignee_target_uuid(a),
              metadata: api_metadata(key, %{"task" => Assignment.label(a)})
            )

            sync_project_completion(conn)
            {200, %{task: Json.task(Projects.get_assignment(a.uuid))}}

          {:error, %Ecto.Changeset{} = cs} ->
            Json.changeset_error(cs)
        end
    end
  end

  # The same moves the project page makes, with the same side effects: a
  # start keeps the progress unless the task had been finished, a completion
  # stamps who and when (the key's minter), a reopen clears both.
  defp apply_transition(a, "in_progress", _key) do
    pct = if a.progress_pct == 100, do: 0, else: a.progress_pct

    {"projects.assignment_started",
     Projects.update_assignment_status(a, %{status: "in_progress", progress_pct: pct})}
  end

  defp apply_transition(a, "done", key),
    do: {"projects.assignment_completed", Projects.complete_assignment(a, key.created_by_uuid)}

  defp apply_transition(a, "todo", _key),
    do: {"projects.assignment_reopened", Projects.reopen_assignment(a)}

  defp sync_project_completion(conn) do
    %{pk_api_key: key, pk_project: project} = conn.assigns

    case Projects.recompute_project_completion(project.uuid) do
      {:completed, p} ->
        Activity.log("projects.project_completed",
          actor_uuid: key.created_by_uuid,
          resource_type: "project",
          resource_uuid: p.uuid,
          metadata: api_metadata(key, %{"name" => p.name})
        )

      {:reopened, p} ->
        Activity.log("projects.project_reopened",
          actor_uuid: key.created_by_uuid,
          resource_type: "project",
          resource_uuid: p.uuid,
          metadata: api_metadata(key, %{"name" => p.name})
        )

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  # ── Shared ──────────────────────────────────────────────────────

  @doc false
  def fetch(conn, id) do
    case Projects.get_assignment(id) do
      %Assignment{project_uuid: pid} = a when pid == conn.assigns.pk_project.uuid -> {:ok, a}
      _ -> {:error, :not_found}
    end
  rescue
    _ -> {:error, :not_found}
  end

  @doc false
  def not_found(conn),
    do: Json.error(conn, :not_found, "not_found", "No such task in this project.")

  @doc false
  def api_metadata(key, extra),
    do: Map.merge(%{"via" => "api", "api_key" => key.uuid, "api_key_name" => key.name}, extra)

  defp required_string(params, field) do
    case params[field] do
      v when is_binary(v) ->
        if String.trim(v) == "",
          do:
            {:error,
             Json.error_body(422, "validation_failed", "#{field} can't be blank.", %{
               field => ["can't be blank"]
             })},
          else: {:ok, String.trim(v)}

      _ ->
        {:error,
         Json.error_body(422, "validation_failed", "#{field} is required.", %{
           field => ["is required"]
         })}
    end
  end

  # The assignment-level fields an agent may set, validated to the same
  # closed sets the schema enforces, so a bad value is a 422 with the list
  # rather than a changeset error worded for a form.
  defp assignment_attrs(params) do
    attrs =
      %{}
      |> maybe_put("priority", params["priority"])
      |> maybe_put("progress_pct", params["progress_pct"])
      |> maybe_put("estimated_duration", params["estimated_duration"])
      |> maybe_put("estimated_duration_unit", params["estimated_duration_unit"])

    cond do
      Map.has_key?(attrs, "priority") and attrs["priority"] not in @priorities ->
        {:error,
         Json.error_body(
           422,
           "validation_failed",
           "priority must be one of #{Enum.join(@priorities, ", ")}.",
           %{
             priority: @priorities
           }
         )}

      Map.has_key?(attrs, "estimated_duration_unit") and
          attrs["estimated_duration_unit"] not in @units ->
        {:error,
         Json.error_body(
           422,
           "validation_failed",
           "estimated_duration_unit must be one of #{Enum.join(@units, ", ")}.",
           %{
             estimated_duration_unit: @units
           }
         )}

      Map.has_key?(attrs, "progress_pct") and not integer_in?(attrs["progress_pct"], 0, 100) ->
        {:error,
         Json.error_body(
           422,
           "validation_failed",
           "progress_pct must be an integer from 0 to 100.",
           %{
             progress_pct: ["must be an integer from 0 to 100"]
           }
         )}

      Map.has_key?(attrs, "estimated_duration") and
          not integer_in?(attrs["estimated_duration"], 1, nil) ->
        {:error,
         Json.error_body(
           422,
           "validation_failed",
           "estimated_duration must be a positive integer.",
           %{
             estimated_duration: ["must be a positive integer"]
           }
         )}

      true ->
        {:ok, attrs}
    end
  end

  defp integer_in?(v, min, max) when is_integer(v),
    do: v >= min and (is_nil(max) or v <= max)

  defp integer_in?(_, _, _), do: false

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)
end
