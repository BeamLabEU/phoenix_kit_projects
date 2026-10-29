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

  People @-mentioned in the text are told too, once: the mentions are
  recorded and their delivery claimed here, so the comments box's own ping
  (which a comment from the API or a reopen's reason never gets) finds them
  delivered. A comment written as the reason of a
  reopen (`metadata["reopen_reason"]`) or as the note of a hand-off
  (`metadata["handoff_note"]`, the "next up" dialog) does not tell the
  task's assignees again — the reopen's or the "your turn" notice quotes it
  to the people it was meant for, and the dialog's unticked people are
  told nothing.
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

  @doc """
  Which of these tasks the viewer may see — core's mentions ask it before
  showing a task comment's title or preview (the same answer `ResourceLinks`
  gives for the task type).
  """
  @spec visible_resource_uuids([binary()], keyword()) :: [binary()]
  def visible_resource_uuids(uuids, opts), do: ResourceLinks.visible_resource_uuids(uuids, opts)

  @impl true
  # A comment still waiting for moderation tells nobody yet.
  def on_comment_created(type, uuid, %Comment{status: "published"} = comment)
      when type in ["assignment", "project"] and is_binary(uuid) do
    case subject(type, uuid) do
      nil ->
        :ok

      subject ->
        project_uuid = if type == "project", do: subject.uuid, else: subject.project_uuid

        Notices.notify("projects.comment_added", subject,
          actor_uuid: comment.user_uuid,
          recipients: recipients(type, subject, comment),
          metadata: %{
            "comment" => comment.uuid,
            "excerpt" => Notices.excerpt(comment.content)
          }
        )

        # After the notices: History reloads with who was told.
        PhoenixKitProjects.PubSub.broadcast_to_project(project_uuid, :comment_added, %{
          project_uuid: project_uuid,
          resource_uuid: uuid
        })
    end
  rescue
    error ->
      Logger.warning("[Projects] comment notice failed: #{inspect(error.__struct__)}")
      :ok
  catch
    :exit, _ -> :ok
  end

  # A note on a task written by a person — a note, or a new direction —
  # tells the task's people and anyone it names. An agent's working notes
  # tell nobody: an agent writes many, and its outcome reaches people
  # through the task's own status.
  def on_comment_created("project_task_notes", uuid, %Comment{status: "published"} = comment)
      when is_binary(uuid) do
    kind = (comment.metadata || %{})["kind"] || "note"

    with true <- kind in ["note", "redirect"],
         %Assignment{} = a <- Projects.get_assignment(uuid) do
      Notices.notify("projects.comment_added", a,
        actor_uuid: comment.user_uuid,
        recipients: Enum.uniq(People.assignee_user_uuids(a) ++ mentioned(comment)),
        metadata: %{
          "comment" => comment.uuid,
          "note" => kind,
          "excerpt" => Notices.excerpt((comment.metadata || %{})["summary"] || comment.content)
        }
      )

      PhoenixKitProjects.PubSub.broadcast_to_project(a.project_uuid, :comment_added, %{
        project_uuid: a.project_uuid,
        resource_uuid: uuid
      })
    end

    :ok
  rescue
    error ->
      Logger.warning("[Projects] note notice failed: #{inspect(error.__struct__)}")
      :ok
  catch
    :exit, _ -> :ok
  end

  def on_comment_created(_type, _uuid, _comment), do: :ok

  # The comments module tells a handler when a comment held for moderation
  # is approved (a release that has the callback; an older one never calls
  # it): its readers see it only now, so it tells them now, as a comment
  # published on creation does.
  @published_callback? {:on_comment_published, 3} in PhoenixKitComments.ResourceHandler.behaviour_info(
                         :callbacks
                       )

  @impl @published_callback?
  @doc "A comment approved after moderation tells its people, as `on_comment_created/3` does."
  def on_comment_published(type, uuid, comment), do: on_comment_created(type, uuid, comment)

  # The comments module's moderation page asks which records a viewer may
  # moderate (a release that declares the callback; an older one never
  # asks). Declared `@impl` only where the behaviour has it, as above.
  @moderatable_callback? {:moderatable_resources, 2} in PhoenixKitComments.ResourceHandler.behaviour_info(
                           :callbacks
                         )

  @impl @moderatable_callback?
  @doc "Which task discussions the viewer may moderate — see `PhoenixKitProjects.CommentModeration`."
  def moderatable_resources(type, scope),
    do: PhoenixKitProjects.CommentModeration.moderatable_resources(type, scope)

  @doc """
  A deleted comment's words leave the notices that quoted them: each notice
  row keeps that there was a comment (History and the bell still say who
  wrote on which task) but its excerpt goes, and its line is rewritten
  without the quote, in its reader's language. The notice rows are
  permanent, so this is the only place those words can be taken back.
  """
  @impl true
  def on_comment_deleted(type, _uuid, %Comment{uuid: comment_uuid})
      when type in ["assignment", "project", "project_task_notes"] do
    Notices.scrub_comment(comment_uuid)
    :ok
  rescue
    error ->
      Logger.warning("[Projects] comment notice scrub failed: #{inspect(error.__struct__)}")
      :ok
  catch
    :exit, _ -> :ok
  end

  def on_comment_deleted(_type, _uuid, _comment), do: :ok

  defp subject("assignment", uuid), do: Projects.get_assignment(uuid)
  defp subject("project", uuid), do: Projects.get_project(uuid)

  defp recipients(type, subject, comment) do
    # Whoever a task reopened with this reason belongs to — a person, or a
    # team's or department's people (`Notices.tell_assignees/2`) — hears it from
    # the reopen's notice, which quotes it, even when they commented before.
    told_by_reopen =
      case {type, subject} do
        {"assignment", %Assignment{} = a} ->
          if reopen_reason?(comment), do: People.assignee_user_uuids(a), else: []

        _ ->
          []
      end

    # People @-mentioned are told like everyone else: core's mention ping
    # runs only from the comments box, not for a comment written through the
    # API or as a reopen's reason.
    mentioned = mentioned(comment)

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

  # The people @-mentioned in the comment that this notice tells. The
  # mentions are recorded here (core's index, as the comments box records
  # them) and their delivery CLAIMED — the comments box's own ping then
  # finds them delivered and sends nothing, so a person mentioned from the
  # box is told once, by this notice. One already delivered (a re-save) is
  # not told again.
  defp mentioned(%Comment{uuid: uuid, content: content, user_uuid: author}) do
    users = (content || "") |> Token.parse() |> Enum.filter(&(&1.kind == :user))

    cond do
      users == [] -> []
      # With mentions switched off there is no ping to keep apart from.
      not PhoenixKit.Mentions.enabled?() -> Enum.map(users, & &1.uuid)
      true -> claim_mentions(uuid, content, author)
    end
  rescue
    _ -> []
  end

  defp claim_mentions(uuid, content, author) do
    {:ok, _} =
      PhoenixKit.Mentions.sync("comment", uuid, content, field: "content", actor_uuid: author)

    "comment"
    |> PhoenixKit.Mentions.list_for_source(uuid, "content")
    |> Enum.filter(&(&1.kind == "user"))
    |> PhoenixKit.Mentions.claim_for_delivery()
    |> Enum.map(& &1.target_uuid)
  end

  defp reopen_reason?(%Comment{metadata: %{"reopen_reason" => true}}), do: true
  defp reopen_reason?(%Comment{metadata: %{"handoff_note" => true}}), do: true
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
