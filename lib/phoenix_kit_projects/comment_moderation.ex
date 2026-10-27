defmodule PhoenixKitProjects.CommentModeration do
  @moduledoc """
  Which of this module's commented records a viewer may moderate comments
  on — the answer behind `moderatable_resources/2`, which
  `phoenix_kit_comments` asks once per resource type per page load.

  The rule: a `projects.admin_all` holder moderates every record (`:all`);
  anyone else moderates the discussions of the projects they MANAGE — hold
  `:owner` or `:manager` on, directly or through a group grant
  (`Authz.managed_project_uuids/1`). Manager, not an `Authz` action: the
  container actions (`:manage_members`, `:edit_settings`) floor at owner and
  are not overridable, so they would shut out the managers who run a
  project's day-to-day, while every work action (`:comment` included)
  floors at viewer and would hand moderation to anyone on the project.
  Taking a comment down is a manager's job, so the line sits there.

  Types and the uuid each comment carries:

    * `"project"`, `"project_notes"` — the project's uuid;
    * `"assignment"`, `"project_task_notes"` — an assignment's uuid, so the
      answer is the managed projects' assignment uuids (one more read).

  Fail-closed: an unknown type, a scope with no user, or any error is `[]`.
  Built from the viewer's projects, never from every commented record, and
  a fixed number of reads however many projects they manage.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKit.RepoHelper
  alias PhoenixKitProjects.Authz
  alias PhoenixKitProjects.Schemas.Assignment

  @project_types ~w(project project_notes)
  @assignment_types ~w(assignment project_task_notes)

  @doc "The comment types this module answers for."
  @spec types() :: [String.t()]
  def types, do: @project_types ++ @assignment_types

  @spec moderatable_resources(String.t(), term()) :: :all | [String.t()]
  def moderatable_resources(type, scope) when type in @project_types do
    if Authz.admin_all?(scope), do: :all, else: Authz.managed_project_uuids(scope)
  end

  def moderatable_resources(type, scope) when type in @assignment_types do
    if Authz.admin_all?(scope) do
      :all
    else
      case Authz.managed_project_uuids(scope) do
        [] -> []
        project_uuids -> assignment_uuids(project_uuids)
      end
    end
  end

  def moderatable_resources(_type, _scope), do: []

  defp assignment_uuids(project_uuids) do
    RepoHelper.repo().all(
      from(a in Assignment, where: a.project_uuid in ^project_uuids, select: a.uuid)
    )
  rescue
    e ->
      Logger.warning(
        "[Projects.CommentModeration] assignment read failed: #{Exception.message(e)}"
      )

      []
  catch
    :exit, _ -> []
  end
end
