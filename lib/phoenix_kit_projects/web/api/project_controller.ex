defmodule PhoenixKitProjects.Web.Api.ProjectController do
  @moduledoc """
  The key's project itself: `GET /project` (the same shape `/me` carries)
  and `POST /project/status` — the project's WORKFLOW status, one of the
  slugs `available_workflow_statuses` lists. Workflow statuses belong to the
  project, not to its tasks; a task has only the three lifecycle states.
  """

  use Phoenix.Controller, formats: [:json]

  alias PhoenixKitProjects.{Activity, Projects, Statuses}
  alias PhoenixKitProjects.Schemas.ApiKey
  alias PhoenixKitProjects.Web.Api.{Json, TasksController}

  def show(conn, _params) do
    with {:ok, conn} <- Json.require_scope(conn, "tasks:read"),
         {:ok, conn} <- Json.require_action(conn, :view) do
      json(conn, %{project: Json.project(conn.assigns.pk_project)})
    else
      {:halt, conn} -> conn
    end
  end

  def set_status(conn, params) do
    with {:ok, conn} <- Json.require_scope(conn, "project:write"),
         {:ok, conn} <- Json.require_feature(conn, :statuses),
         {:ok, conn} <- Json.require_action(conn, :update_status) do
      Json.idempotent(conn, [], fn -> do_set_status(conn, params["status"]) end)
    else
      {:halt, conn} -> conn
    end
  end

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
