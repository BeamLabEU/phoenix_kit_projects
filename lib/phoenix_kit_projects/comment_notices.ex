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

  Only a published comment tells anyone, and only people who may open the
  project now (`Notices.may_view?/2`).

  People @-mentioned in the text are told too (core's own mention ping runs
  only from the comments box, so a comment from the API or a reopen's reason
  would otherwise reach nobody it names; from the box a mentioned person
  hears it twice, once as a mention). A comment written as the reason of a
  reopen (`metadata["reopen_reason"]`) does not tell the task's person
  assignee again — the reopen's notice quotes it to them.
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
  # A comment still waiting for moderation tells nobody yet.
  def on_comment_created(type, uuid, %Comment{status: "published"} = comment)
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
    # The person a task reopened with this reason belongs to hears it from
    # the reopen's notice, which quotes it — even when they commented
    # before. A team or department assignee is not told by the reopen (its
    # notice names one person), so they keep the comment's.
    told_by_reopen =
      case {type, subject} do
        {"assignment", %Assignment{assigned_person_uuid: p} = a} when is_binary(p) ->
          if reopen_reason?(comment), do: People.assignee_user_uuids(a), else: []

        _ ->
          []
      end

    # People @-mentioned are told like everyone else: core's mention ping
    # runs only from the comments box, not for a comment written through the
    # API or as a reopen's reason.
    mentioned =
      comment.content
      |> Token.parse()
      |> Enum.filter(&(&1.kind == :user))
      |> Enum.map(& &1.uuid)

    skip = [comment.user_uuid | told_by_reopen]

    (own_people(type, subject) ++ earlier_commenters(type, subject) ++ mentioned)
    |> Enum.uniq()
    |> Enum.reject(&(&1 in skip))
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

  # Everyone who commented on the thread before. Whether each may still open
  # the project is `Notices.notify/3`'s check, as for every notice.
  defp earlier_commenters(type, subject) do
    from(c in Comment,
      where:
        c.resource_type == ^type and c.resource_uuid == ^subject.uuid and c.status == "published",
      select: c.user_uuid,
      distinct: true
    )
    |> RepoHelper.repo().all()
    |> Enum.reject(&is_nil/1)
  end
end
