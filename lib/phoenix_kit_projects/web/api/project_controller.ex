defmodule PhoenixKitProjects.Web.Api.ProjectController do
  @moduledoc """
  The key's project itself: `GET /project` (the same shape `/me` carries,
  with the sub-projects nested in it), `POST /project/status` — the
  project's WORKFLOW status, one of the slugs `available_workflow_statuses`
  lists (workflow statuses belong to the project, not to its tasks; a task
  has only the three lifecycle states) — and `POST /subprojects`, a new
  project nested in it. Each takes `project` to act on a sub-project
  within the key's reach instead (`Json.scope_project/2`).
  """

  use Phoenix.Controller, formats: [:json]

  alias PhoenixKitProjects.{Activity, Projects, Statuses}
  alias PhoenixKitProjects.Schemas.ApiKey
  alias PhoenixKitProjects.Web.Api.{Json, TasksController}

  # A key reaches at most this many levels under its own project
  # (`Projects.parent_chain/1` walks eight hops); one is kept in hand so
  # what the API creates stays within what it can reach.
  @max_nesting 7

  def show(conn, params) do
    with {:ok, conn} <- Json.require_scope(conn, "tasks:read"),
         {:ok, conn} <- Json.scope_project(conn, params),
         {:ok, conn} <- Json.require_action(conn, :view) do
      json(conn, %{project: Json.project(conn.assigns.pk_project)})
    else
      {:halt, conn} -> conn
    end
  end

  def set_status(conn, params) do
    with {:ok, conn} <- Json.require_scope(conn, "project:write"),
         {:ok, conn} <- Json.scope_project(conn, params),
         {:ok, conn} <- Json.require_feature(conn, :statuses),
         {:ok, conn} <- Json.require_action(conn, :update_status) do
      Json.idempotent(conn, [], fn -> do_set_status(conn, params["status"]) end)
    else
      {:halt, conn} -> conn
    end
  end

  def create_subproject(conn, params) do
    with {:ok, conn} <- Json.require_scope(conn, "tasks:write"),
         {:ok, conn} <- Json.scope_project(conn, params),
         {:ok, conn} <- Json.require_feature(conn, :tasks),
         {:ok, conn} <- Json.require_feature(conn, :subprojects),
         {:ok, conn} <- Json.require_action(conn, :create_tasks) do
      Json.idempotent(conn, [], fn -> do_create_subproject(conn, params) end)
    else
      {:halt, conn} -> conn
    end
  end

  # The same path the Add sub-project form takes: a fresh child project
  # linked into the parent's plan as a task row of kind `subproject`.
  defp do_create_subproject(conn, params) do
    %{pk_api_key: key, pk_project: parent} = conn.assigns
    name = params["name"]

    cond do
      not is_binary(name) or String.trim(name) == "" ->
        Json.error_body(422, "validation_failed", "name is required.", %{
          name: ["can't be blank"]
        })

      length(Projects.parent_chain(parent.uuid)) >= @max_nesting ->
        Json.error_body(
          422,
          "validation_failed",
          "This project is nested too deep for another level.",
          %{
            max_nesting: @max_nesting
          }
        )

      true ->
        attrs =
          %{"name" => String.trim(name)}
          |> maybe_put("description", params["description"])
          |> maybe_put_completion(params["completion"])

        case Projects.create_subproject(parent.uuid, attrs) do
          {:ok, %{child_project: child, assignment: link}} ->
            Activity.log("projects.subproject_created",
              actor_uuid: ApiKey.accountable_uuid(key),
              resource_type: "assignment",
              resource_uuid: link.uuid,
              metadata:
                TasksController.api_metadata(key, %{
                  "name" => child.name,
                  "child_project_uuid" => child.uuid
                })
            )

            {201,
             %{
               project: Json.project(Projects.get_project(child.uuid) || child),
               task: Json.task(Projects.get_assignment(link.uuid) || link)
             }}

          {:error, %Ecto.Changeset{} = cs} ->
            Json.changeset_error(cs)

          {:error, _} ->
            Json.error_body(404, "not_found", "No such project within this key's reach.")
        end
    end
  end

  # `completion` names how the child ends; left out, it copies the parent's.
  defp maybe_put_completion(attrs, mode) when mode in ["auto", "manual"],
    do: Map.put(attrs, "settings", %{"completion" => mode})

  defp maybe_put_completion(attrs, _), do: attrs

  defp maybe_put(attrs, _k, v) when not is_binary(v) or v == "", do: attrs
  defp maybe_put(attrs, k, v), do: Map.put(attrs, k, v)

  defp do_set_status(conn, slug) do
    %{pk_api_key: key, pk_project: project} = conn.assigns
    available = project |> Statuses.statuses_for() |> Enum.map(& &1.slug)

    cond do
      not is_binary(slug) or slug == "" ->
        Json.error_body(422, "validation_failed", "status is required.", %{
          available_workflow_statuses: available
        })

      slug not in available ->
        Json.error_body(422, "validation_failed", "Unknown workflow status for this project.", %{
          status: slug,
          available_workflow_statuses: available
        })

      true ->
        case Statuses.set_current_status(project, slug) do
          {:ok, updated} ->
            Activity.log("projects.project_status_changed",
              actor_uuid: ApiKey.accountable_uuid(key),
              resource_type: "project",
              resource_uuid: project.uuid,
              metadata: TasksController.api_metadata(key, %{"status" => slug})
            )

            {200, %{project: Json.project(Projects.get_project(updated.uuid) || updated)}}

          {:error, %Ecto.Changeset{} = cs} ->
            Json.changeset_error(cs)

          {:error, reason} ->
            Json.error_body(
              422,
              "validation_failed",
              "Could not set the status: #{inspect(reason)}."
            )
        end
    end
  end
end
