defmodule PhoenixKitProjects.MediaReorganizer do
  @moduledoc """
  Projects' media-reorganizer plan source: each project's `project-<uuid>`
  folder (its `Portal submissions` subfolder moves with it), planned by
  core's `PhoenixKit.Modules.Storage.Reorganizer.ResourceSource`, which
  applies the `Reorganizer.Source` contract.

  What is projects' own: every project row is live — an archived project
  included; only a deleted one leaves an orphan. The parent hook receives
  the project itself (the bare struct, as on every read) and the name hook
  may give it a human name. A project stores no folder pointer (folders
  are found by name), so a taken target is reported rather than renamed,
  and there are no pending-upload folders.
  """

  alias PhoenixKit.Modules.Storage.Reorganizer.ResourceSource
  alias PhoenixKitProjects.Schemas.Project

  @doc "The plan (`Reorganizer.Source.plan/2`); `opts` is passed through."
  @spec plan(String.t() | nil, keyword()) :: [map()]
  def plan(actor_uuid, opts \\ []), do: ResourceSource.plan(spec(), actor_uuid, opts)

  defp spec do
    %{
      source: "projects",
      app: :phoenix_kit_projects,
      noun: "project",
      kinds: [%{kind: :project, schema: Project, prefix: "project-"}]
    }
  end
end
