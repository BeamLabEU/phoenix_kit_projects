defmodule PhoenixKitProjects.CommentMentions do
  @moduledoc """
  What a task's comment box hands the comments module for `@` mentions
  (the boss's list, 2026-11-18, item 21):

    * `people/2` — whom to offer first after `@`, in order: the task's own
      people (its assignees, a team's or department's people), then the
      project's members, owners first. Everyone else comes from core's user
      search below them. Passed as the comments component's
      `mention_people`.
    * `warning/1` — the component's `mention_warning`: a function saying,
      for a person mentioned in the draft, whether they will hear of it. A
      person who cannot open the project is not told (core's mention
      notice drops a ping its reader may not follow), so the writer is told
      that instead.

  A mention in a comment only notifies; it never assigns. Nothing here
  raises: a failed read is an empty list or no warning.
  """

  use Gettext, backend: PhoenixKitProjects.Gettext

  alias PhoenixKitProjects.{Members, Notices, People}
  alias PhoenixKitProjects.Schemas.{Assignment, Project}

  @type person :: %{uuid: binary(), title: String.t(), subtitle: String.t() | nil}

  @doc """
  The people to offer first after `@` on `assignment`'s comments: its
  people, then the project's members, each once, as
  `%{uuid, title, subtitle}` with the user's account uuid. A person with no
  login has nothing to mention and is left out.
  """
  @spec people(Project.t(), Assignment.t() | nil) :: [person()]
  def people(%Project{} = project, assignment) do
    task_users =
      case assignment do
        %Assignment{} = a -> People.assignee_user_uuids(a)
        _ -> []
      end

    member_users = project.uuid |> Members.list_members() |> Enum.map(& &1.user_uuid)
    ordered = Enum.uniq(task_users ++ member_users)
    names = People.user_display_names(ordered)
    task_set = MapSet.new(task_users)

    for uuid <- ordered, name = names[uuid], is_binary(name) and name != "" do
      %{
        uuid: uuid,
        title: name,
        subtitle: if(MapSet.member?(task_set, uuid), do: gettext("On this task"))
      }
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  def people(_project, _assignment), do: []

  @doc """
  The comments component's `mention_warning` for `project`: `nil` for a
  person who can open it, else the sentence the writer sees under the box.
  """
  @spec warning(Project.t()) :: (binary() -> String.t() | nil)
  def warning(%Project{} = project) do
    fn user_uuid ->
      if Notices.may_view?(user_uuid, project) do
        nil
      else
        name = Map.get(People.user_display_names([user_uuid]), user_uuid) || gettext("Someone")

        gettext(
          "%{name} can't open this project, so they won't be told about this comment. Add them to the project's members, or assign them a task here.",
          name: name
        )
      end
    end
  end
end
