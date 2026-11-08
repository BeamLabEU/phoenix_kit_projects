defmodule PhoenixKitProjects.Health do
  @moduledoc """
  Project health — the hub's native status signal (P2b), Basecamp's
  "Needle": a MANUAL three-state judgment (`on_track` / `some_risk` /
  `concerned`) with a note, set by a human — never auto-computed (the
  research's deliberate-omission lesson: progress math answers "how much",
  health answers "how do we feel about it").

  Stored in the project's `settings["health"]`
  (`%{"status", "note", "updated_at", "updated_by"}`) — no migration.
  History = the `projects.health_updated` activity rows; the current value
  is just the latest judgment.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKit.RepoHelper
  alias PhoenixKitProjects.Activity
  alias PhoenixKitProjects.PubSub
  alias PhoenixKitProjects.Schemas.Project

  @statuses ~w(on_track some_risk concerned)

  @doc "Valid health statuses, best first."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "The project's current health map, or nil when never set."
  @spec get(Project.t() | map()) :: map() | nil
  def get(%{settings: settings}) when is_map(settings) do
    case Map.get(settings, "health") do
      %{"status" => status} = health when status in @statuses -> health
      _ -> nil
    end
  end

  def get(_), do: nil

  @doc """
  Sets the project's health. Unknown statuses are rejected
  (`{:error, :invalid_status}`); an empty note is stored as absent.
  """
  @spec set(Project.t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, Project.t()} | {:error, term()}
  def set(%Project{} = project, status, note \\ nil, opts \\ []) do
    if status in @statuses do
      actor_uuid = Keyword.get(opts, :actor_uuid)

      health =
        %{
          "status" => status,
          "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "updated_by" => actor_uuid
        }
        |> maybe_put_note(note)

      project
      |> write_health(health)
      |> case do
        {:ok, updated} ->
          Activity.log("projects.health_updated",
            actor_uuid: actor_uuid,
            resource_type: "project",
            resource_uuid: project.uuid,
            metadata: %{
              "status" => status,
              "note" => note || "",
              "previous" => (get(project) || %{})["status"]
            }
          )

          PubSub.broadcast_project(:project_updated, %{
            uuid: updated.uuid,
            is_template: updated.is_template
          })

          {:ok, updated}

        {:error, _} = error ->
          error
      end
    else
      {:error, :invalid_status}
    end
  end

  # ATOMIC targeted write, like `Features.set_flags/3`: `settings` is a shared
  # column (visibility, the "who can do what" floors, features, completion,
  # the agent policy live beside "health"), and a whole-map write from the
  # caller's struct — a project page mounted before an owner tightened any of
  # them — silently put the old values back. jsonb_set touches ONLY
  # settings["health"], over whatever is in the row now.
  defp write_health(%Project{uuid: uuid}, health) do
    query =
      from(p in Project,
        where: p.uuid == ^uuid,
        update: [
          set: [
            settings:
              fragment(
                "jsonb_set(COALESCE(settings, '{}'::jsonb), '{health}', ?::jsonb)",
                ^health
              ),
            updated_at: fragment("NOW()")
          ]
        ],
        select: p
      )

    case RepoHelper.repo().update_all(query, []) do
      {1, [updated]} -> {:ok, updated}
      _ -> {:error, :not_found}
    end
  rescue
    e in Postgrex.Error ->
      Logger.warning("[Projects.Health] set failed: #{Exception.message(e)}")
      {:error, :not_found}
  end

  defp maybe_put_note(health, note) when is_binary(note) do
    case String.trim(note) do
      "" -> health
      trimmed -> Map.put(health, "note", trimmed)
    end
  end

  defp maybe_put_note(health, _), do: health

  @doc "daisyUI badge/alert classes per status (whitelist — scanner-safe)."
  @spec color_class(String.t()) :: String.t()
  def color_class("on_track"), do: "alert-success"
  def color_class("some_risk"), do: "alert-warning"
  def color_class("concerned"), do: "alert-error"
  def color_class(_), do: ""

  @doc "Localizable label per status (call under the caller's gettext)."
  @spec label(String.t()) :: String.t()
  def label("on_track"), do: "On track"
  def label("some_risk"), do: "Some risk"
  def label("concerned"), do: "Concerned"
  def label(other), do: other
end
