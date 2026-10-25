defmodule PhoenixKitProjects.CommentNotices do
  @moduledoc """
  Who hears about a comment on a task or a project.

  The comments module calls its resource handler's `on_comment_created/3`
  after every new comment, from every path (the comments box, the API,
  `create_comment/4`). Task comments are written under the type
  `"assignment"`, which this module registers (`ResourceLinks.types/0`) —
  apart from `ResourceLinks` on purpose: that one is also the `#` search
  handler, and a second searchable type would list every task twice.
  Project comments arrive through `ResourceLinks`, which delegates here.

  Told, each once, never the author:

    * a task comment — the task's assignee (a team or department: its
      people), and everyone who commented on that task before;
    * a project comment — the project's owners and managers, and everyone
      who commented on the project before.

  People @-mentioned in the text are left out: core's mention ping
  (`PhoenixKit.Mentions.notify/2`) already told them. A comment written as
  the reason of a reopen (`metadata["reopen_reason"]`) does not tell the
  task's assignee again — the reopen notice quotes it.
  """

  @behaviour PhoenixKitComments.ResourceHandler

  import Ecto.Query

  require Logger

  alias PhoenixKit.Mentions.Token
  alias PhoenixKit.RepoHelper
  alias PhoenixKitComments.Comment
  alias PhoenixKitProjects.{Members, Notices, People, Projects, ResourceLinks}
  alias PhoenixKitProjects.Schemas.{Assignment, Project}

  @impl true
  def resolve_comment_resources(uuids), do: ResourceLinks.resolve_comment_resources(uuids)

  @impl true
  def on_comment_created(type, uuid, %Comment{} = comment)
      when type in ["assignment", "project"] and is_binary(uuid) do
    case subject(type, uuid) do
      nil ->
        :ok

      subject ->
        project_uuid = if type == "project", do: subject.uuid, else: subject.project_uuid

        PhoenixKitProjects.PubSub.broadcast_to_project(project_uuid, :comment_added, %{
          project_uuid: project_uuid,
          resource_uuid: uuid
        })

        Notices.notify("projects.comment_added", subject,
          actor_uuid: comment.user_uuid,
          recipients: recipients(type, subject, comment),
          metadata: %{
            "comment" => comment.uuid,
            "excerpt" => Notices.excerpt(comment.content)
          }
        )
    end
  rescue
    error ->
      Logger.warning("[Projects] comment notice failed: #{inspect(error.__struct__)}")
      :ok
  catch
    :exit, _ -> :ok
  end

  def on_comment_created(_type, _uuid, _comment), do: :ok

  defp subject("assignment", uuid), do: Projects.get_assignment(uuid)
  defp subject("project", uuid), do: Projects.get_project(uuid)

  defp recipients(type, subject, comment) do
    mentioned =
      comment.content
      |> Token.parse()
      |> Enum.filter(&(&1.kind == :user))
      |> MapSet.new(& &1.uuid)

    # The assignee of a task reopened with this reason hears it from the
    # reopen's notice, which quotes it — even when they commented before.
    told_by_reopen =
      if type == "assignment" and reopen_reason?(comment),
        do: MapSet.new(People.assignee_user_uuids(subject)),
        else: MapSet.new()

    (own_people(type, subject) ++ earlier_commenters(type, subject.uuid))
    |> Enum.uniq()
    |> Enum.reject(
      &(&1 == comment.user_uuid or MapSet.member?(mentioned, &1) or
          MapSet.member?(told_by_reopen, &1))
    )
  end

  defp own_people("assignment", %Assignment{} = a), do: People.assignee_user_uuids(a)

  defp own_people("project", %Project{} = p) do
    p.uuid
    |> Members.list_members()
    |> Enum.filter(&(&1.role in ["owner", "manager"]))
    |> Enum.map(& &1.user_uuid)
  end

  defp reopen_reason?(%Comment{metadata: %{"reopen_reason" => true}}), do: true
  defp reopen_reason?(_), do: false

  defp earlier_commenters(type, uuid) do
    from(c in Comment,
      where: c.resource_type == ^type and c.resource_uuid == ^uuid and c.status == "published",
      select: c.user_uuid,
      distinct: true
    )
    |> RepoHelper.repo().all()
    |> Enum.reject(&is_nil/1)
  end
end
