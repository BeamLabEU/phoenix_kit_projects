defmodule PhoenixKitProjects.Notices do
  @moduledoc """
  What a person is told about work in a project, and in whose words.

  Core's notification bell renders a module's notice exactly as its activity
  row carries it — `notification_text`, `notification_icon`,
  `notification_link` in the metadata (`PhoenixKit.Notifications.Render`) —
  and has no way to translate it per reader. So the line is written HERE,
  once per recipient, in that person's language (`RecipientLocale`): one
  recipient per activity row, which is the bridge's model anyway
  (`target_uuid`). Rows written only to carry a notice are marked
  `"notice" => true`; `History` folds them into the event they announce.

  Two ways in:

    * `decorate/2` — `PhoenixKitProjects.Activity.log/2` passes every entry
      through it: an entry that already names a recipient (`target_uuid`)
      and has no text of its own gets one. That covers the module's existing
      notices (a task assigned, started, completed, reopened; a membership)
      without touching their call sites.
    * `notify/3` — a notice for several people (a comment, "your turn",
      "on hold"): one decorated row each, the actor left out.

  Nothing here raises into a caller: a notice that cannot be written is
  dropped, never the change it announces.
  """

  use Gettext, backend: PhoenixKitProjects.Gettext

  import Ecto.Query, only: [from: 2]

  require Logger

  alias PhoenixKit.Mentions.Token
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Utils.RecipientLocale
  alias PhoenixKitProjects.{Activity, Authz, L10n, Paths, Projects}
  alias PhoenixKitProjects.Schemas.{Assignment, Project}

  @task_actions ~w(projects.assignment_created projects.assignment_updated
                   projects.assignment_started projects.assignment_completed
                   projects.assignment_reopened projects.assignment_ready
                   projects.assignment_on_hold projects.assignment_reassigned
                   projects.assignment_removed projects.comment_added)

  @project_actions ~w(projects.member_added projects.member_role_changed
                      projects.member_removed projects.comment_added)

  @excerpt_length 120

  @doc """
  Adds the notification text, icon and link to an `Activity.log/2` option
  list when the entry names a recipient other than its actor and carries no
  text yet. Anything it cannot work out leaves the options as they were.
  """
  @spec decorate(String.t(), keyword(), Assignment.t() | Project.t() | nil) :: keyword()
  def decorate(action, opts, subject \\ nil)

  def decorate(action, opts, subject) when is_binary(action) and is_list(opts) do
    target = Keyword.get(opts, :target_uuid)
    meta = Keyword.get(opts, :metadata) || %{}

    cond do
      not is_binary(target) -> opts
      target == Keyword.get(opts, :actor_uuid) -> opts
      Map.has_key?(meta, "notification_text") -> opts
      true -> with_display(action, opts, target, meta, subject)
    end
  rescue
    error ->
      Logger.warning("[Projects] notice text failed: #{inspect(error.__struct__)}")
      opts
  catch
    :exit, _ -> opts
  end

  def decorate(_action, opts, _subject), do: opts

  @doc """
  Writes one notice per recipient for `action` about `subject` — an
  `%Assignment{}` (task preloaded) or a `%Project{}`.

  Options: `:actor_uuid` (left out of the recipients, named in the line),
  `:recipients` (user uuids; duplicates and the actor dropped), `:metadata`
  (merged into each row — `"reason"`, `"after"`, `"excerpt"` feed the line).
  """
  @spec notify(String.t(), Assignment.t() | Project.t(), keyword()) :: :ok
  def notify(action, subject, opts) do
    actor = Keyword.get(opts, :actor_uuid)
    meta = Keyword.get(opts, :metadata) || %{}

    {resource_type, resource_uuid, project_uuid} =
      case subject do
        %Assignment{} = a -> {"assignment", a.uuid, a.project_uuid}
        %Project{} = p -> {"project", p.uuid, p.uuid}
      end

    project = project_of(subject)

    # A template's tasks are nobody's work yet.
    recipients =
      if match?(%Project{is_template: true}, project),
        do: [],
        else: Keyword.get(opts, :recipients, [])

    recipients
    |> Enum.reject(&(is_nil(&1) or &1 == actor))
    |> Enum.uniq()
    |> Enum.filter(&may_view?(&1, project))
    |> Enum.each(fn recipient ->
      Activity.log(action,
        notice_subject: subject,
        actor_uuid: actor,
        resource_type: resource_type,
        resource_uuid: resource_uuid,
        target_uuid: recipient,
        metadata:
          Map.merge(meta, %{
            "notice" => true,
            "project_uuid" => project_uuid,
            # The primary names, like every audit row (the line itself is
            # in the reader's language).
            "task" => primary_label(subject),
            "project" => primary_project_name(subject)
          })
      )
    end)
  end

  @doc """
  Takes a deleted comment's words out of the notices that quoted it: the
  excerpt is dropped and each row's line becomes "<actor> commented on
  “<task>” — the comment was deleted", in that row's reader's language.
  """
  @spec scrub_comment(binary()) :: :ok
  def scrub_comment(comment_uuid) when is_binary(comment_uuid) do
    repo = PhoenixKit.RepoHelper.repo()

    from(e in PhoenixKit.Activity.Entry,
      where:
        e.module == "projects" and e.action == "projects.comment_added" and
          fragment("?->>'comment' = ?", e.metadata, ^comment_uuid)
    )
    |> repo.all()
    |> Enum.each(fn entry ->
      meta = entry.metadata || %{}
      recipient = entry.target_uuid && Auth.get_user(entry.target_uuid)

      text =
        RecipientLocale.in_locale(RecipientLocale.for_rendering(recipient), fn ->
          gettext("%{actor} commented on “%{task}” — the comment was deleted",
            actor: actor_name(entry.actor_uuid),
            task: meta["task"] || meta["project"] || ""
          )
        end)

      new_meta =
        meta
        |> Map.delete("excerpt")
        |> Map.put("notification_text", text)
        |> Map.put("comment_deleted", true)

      repo.update_all(
        from(x in PhoenixKit.Activity.Entry, where: x.uuid == ^entry.uuid),
        set: [metadata: new_meta]
      )
    end)
  end

  @doc """
  Whether `user_uuid` may open `project` now — the gate every notice passes,
  so a person removed from a project, a team member with no grant on it, or
  a deactivated account never receives a line of its words.
  """
  @spec may_view?(binary(), Project.t() | nil) :: boolean()
  def may_view?(_user_uuid, nil), do: false

  def may_view?(user_uuid, %Project{} = project) do
    case Auth.get_user(user_uuid) do
      %User{is_active: false} -> false
      %User{} = user -> Authz.can?(Scope.for_user(user), project, :view)
      _ -> false
    end
  rescue
    _ -> false
  end

  defp tellable?(_user_uuid, %Project{is_template: true}), do: false
  defp tellable?(user_uuid, project), do: may_view?(user_uuid, project)

  defp project_of(%Project{} = p), do: p
  defp project_of(%Assignment{project: %Project{} = p}), do: p
  defp project_of(%Assignment{project_uuid: uuid}), do: Projects.get_project(uuid)

  # ── The line ────────────────────────────────────────────────────────

  defp subject_of(action, opts) do
    resource = Keyword.get(opts, :resource_uuid)

    cond do
      is_nil(resource) ->
        nil

      action in @task_actions and opts[:resource_type] == "assignment" ->
        Projects.get_assignment(resource)

      action in @project_actions and opts[:resource_type] == "project" ->
        Projects.get_project(resource)

      true ->
        nil
    end
  end

  # `known` is the subject when the caller has it already — a deleted
  # task's notice is written after the task is gone.
  defp with_display(action, opts, target, meta, known) do
    subject = known || subject_of(action, opts)

    cond do
      is_nil(subject) ->
        opts

      # A task's notice goes only to someone who may open the project (a task
      # can be handed to a person who is not a member), and never for a
      # template's task: the row then names no recipient, so core's bridge
      # sends nothing either. A membership line is about the reader's own
      # access — a removed member is told although they are out.
      action in @task_actions and not tellable?(target, project_of(subject)) ->
        Keyword.delete(opts, :target_uuid)

      true ->
        recipient = Auth.get_user(target)

        # `for_rendering/1` never answers nil: no preference means the
        # site's language, never whatever the sender is reading in.
        display =
          RecipientLocale.in_locale(RecipientLocale.for_rendering(recipient), fn ->
            # Inside: the "Someone" fallback is the reader's word too.
            actor = actor_name(Keyword.get(opts, :actor_uuid))

            %{
              "notification_text" => line(action, subject, actor, meta),
              "notification_icon" => icon(action),
              "notification_link" => link(action, subject)
            }
          end)

        Keyword.put(opts, :metadata, Map.merge(meta, display))
    end
  end

  # What a task's people hear about whoever else changes it. An entry for
  # one of these that names no recipient (a team's or department's task, or
  # a path that does not name the assignee: the API, quick-add, the typed
  # list) tells the task's people here; one that names its person is told by
  # its own row.
  @assignee_actions ~w(projects.assignment_created projects.assignment_updated
                       projects.assignment_started projects.assignment_completed
                       projects.assignment_reopened)

  # What a notice row may carry over from the entry it follows.
  @carried ~w(reason via api_key api_key_name source_activity_uuid)

  @doc """
  Called by `Activity.log/2` after every entry: a task event that names no
  recipient tells the task's people (a person, or a team's or department's
  people), one notice row each through `notify/3`. Rows that tell nobody on
  purpose pass `tell: false`; notice rows and the tick rules' own rows
  (`auto`) never fan out.
  """
  @spec tell_assignees(String.t(), keyword()) :: :ok
  def tell_assignees(action, opts) when action in @assignee_actions do
    meta = Keyword.get(opts, :metadata) || %{}

    with "assignment" <- Keyword.get(opts, :resource_type),
         uuid when is_binary(uuid) <- Keyword.get(opts, :resource_uuid),
         nil <- Keyword.get(opts, :target_uuid),
         false <- meta["notice"] == true or meta["auto"] == true,
         %Assignment{} = a <- Projects.get_assignment(uuid),
         [_ | _] = people <- PhoenixKitProjects.People.assignee_user_uuids(a) do
      notify(action, a,
        actor_uuid: Keyword.get(opts, :actor_uuid),
        recipients: people,
        metadata: Map.take(meta, @carried)
      )
    end

    :ok
  rescue
    error ->
      Logger.warning("[Projects] assignee notice failed: #{inspect(error.__struct__)}")
      :ok
  catch
    :exit, _ -> :ok
  end

  def tell_assignees(_action, _opts), do: :ok

  @doc """
  A task handed from one assignee to another: one history row, the new
  people told it is theirs now, the old ones who has it instead. Nothing
  when the assignee did not change. Answers whether it did.
  """
  @spec reassigned(Assignment.t(), Assignment.t(), binary() | nil, map()) :: boolean()
  def reassigned(%Assignment{} = was, %Assignment{} = now, actor_uuid, extra \\ %{}) do
    if assignee_key(was) == assignee_key(now) do
      false
    else
      fresh = Projects.get_assignment(now.uuid) || now
      to = PhoenixKitProjects.People.assignee_name(fresh) || ""
      from_name = PhoenixKitProjects.People.assignee_name(was) || ""

      result =
        Activity.log("projects.assignment_reassigned",
          actor_uuid: actor_uuid,
          resource_type: "assignment",
          resource_uuid: now.uuid,
          tell: false,
          metadata:
            Map.merge(extra, %{"task" => primary_label(fresh), "from" => from_name, "to" => to})
        )

      extra =
        case result do
          {:ok, entry} -> Map.put(extra, "source_activity_uuid", entry.uuid)
          _ -> extra
        end

      new_people = PhoenixKitProjects.People.assignee_user_uuids(fresh)
      old_people = PhoenixKitProjects.People.assignee_user_uuids(was) -- new_people

      notify("projects.assignment_reassigned", fresh,
        actor_uuid: actor_uuid,
        recipients: new_people,
        metadata: Map.merge(extra, %{"role" => "new", "from" => from_name, "to" => to})
      )

      notify("projects.assignment_reassigned", fresh,
        actor_uuid: actor_uuid,
        recipients: old_people,
        metadata: Map.merge(extra, %{"role" => "old", "from" => from_name, "to" => to})
      )

      true
    end
  rescue
    error ->
      Logger.warning("[Projects] reassign notice failed: #{inspect(error.__struct__)}")
      true
  end

  @doc """
  Runs `delete` (a task's deletion, which takes everything under it too)
  and, when it answers `{:ok, _}`, tells the people of every task it
  removed. The branch is read before the delete — afterwards it is gone.
  Answers what `delete` answered.
  """
  @spec removing(Assignment.t(), binary() | nil, map(), (-> result)) :: result when result: term()
  def removing(%Assignment{} = a, actor_uuid, extra \\ %{}, delete) when is_function(delete, 0) do
    branch =
      try do
        [a | PhoenixKitProjects.Outline.rows_below(a)]
      rescue
        _ -> [a]
      end

    result = delete.()
    if match?({:ok, _}, result), do: Enum.each(branch, &removed(&1, actor_uuid, extra))
    result
  end

  @doc "Tells a deleted task's people that it is gone (call with the task as it was)."
  @spec removed(Assignment.t(), binary() | nil, map()) :: :ok
  def removed(%Assignment{} = a, actor_uuid, extra \\ %{}) do
    notify("projects.assignment_removed", a,
      actor_uuid: actor_uuid,
      recipients: PhoenixKitProjects.People.assignee_user_uuids(a),
      metadata: extra
    )
  rescue
    error ->
      Logger.warning("[Projects] removal notice failed: #{inspect(error.__struct__)}")
      :ok
  end

  defp assignee_key(a),
    do: {a.assigned_person_uuid, a.assigned_team_uuid, a.assigned_department_uuid}

  @doc false
  # The one line, in the current Gettext locale. Public for the tests.
  @spec line(String.t(), Assignment.t() | Project.t(), String.t(), map()) :: String.t()
  def line(action, subject, actor, meta) do
    ctx = %{
      actor: actor,
      task: subject_label(subject),
      project: project_name(subject),
      meta: localize_after(meta),
      subject: subject
    }

    case subject do
      %Assignment{} -> with_note(text(action, ctx), action, meta) <> " · " <> ctx.project
      %Project{} -> text(action, ctx)
    end
  end

  # A hand-off's note (the "next up" dialog) rides along in its notice.
  defp with_note(line, "projects.assignment_ready", %{"note" => note})
       when is_binary(note) and note != "",
       do: gettext("%{line} — “%{note}”", line: line, note: excerpt(note))

  defp with_note(line, _action, _meta), do: line

  defp text("projects.assignment_created", c),
    do: gettext("%{actor} gave you a task: “%{task}”", actor: c.actor, task: c.task)

  defp text("projects.assignment_updated", c),
    do: gettext("%{actor} changed your task “%{task}”", actor: c.actor, task: c.task)

  defp text("projects.assignment_started", c),
    do: gettext("%{actor} started your task “%{task}”", actor: c.actor, task: c.task)

  defp text("projects.assignment_completed", c),
    do: gettext("%{actor} marked your task “%{task}” done", actor: c.actor, task: c.task)

  defp text("projects.assignment_reopened", %{meta: %{"reason" => reason}} = c)
       when is_binary(reason) and reason != "" do
    gettext("%{actor} reopened “%{task}”: “%{reason}”",
      actor: c.actor,
      task: c.task,
      reason: excerpt(reason)
    )
  end

  defp text("projects.assignment_reopened", c),
    do: gettext("%{actor} reopened your task “%{task}”", actor: c.actor, task: c.task)

  defp text("projects.assignment_ready", %{meta: %{"resume" => true, "more" => n}} = c)
       when is_integer(n) and n > 0 do
    ngettext(
      "Go on with “%{task}” and 1 more task — “%{after}” is done again",
      "Go on with “%{task}” and %{count} more tasks — “%{after}” is done again",
      n,
      task: c.task,
      after: c.meta["after"] || ""
    )
  end

  defp text("projects.assignment_ready", %{meta: %{"resume" => true}} = c) do
    gettext("Go on with “%{task}” — “%{after}” is done again",
      task: c.task,
      after: c.meta["after"] || ""
    )
  end

  defp text("projects.assignment_ready", %{meta: %{"after" => after_task, "more" => n}} = c)
       when is_binary(after_task) and after_task != "" and is_integer(n) and n > 0 do
    ngettext(
      "Your turn: “%{task}” and 1 more task — “%{after}” is done",
      "Your turn: “%{task}” and %{count} more tasks — “%{after}” is done",
      n,
      task: c.task,
      after: after_task
    )
  end

  defp text("projects.assignment_ready", %{meta: %{"after" => after_task}} = c)
       when is_binary(after_task) and after_task != "" do
    gettext("Your turn: “%{task}” — “%{after}” is done", task: c.task, after: after_task)
  end

  defp text("projects.assignment_ready", %{meta: %{"more" => n}} = c)
       when is_integer(n) and n > 0 do
    ngettext(
      "Your turn: “%{task}” and 1 more task",
      "Your turn: “%{task}” and %{count} more tasks",
      n,
      task: c.task
    )
  end

  defp text("projects.assignment_ready", c),
    do: gettext("Your turn: “%{task}” can start", task: c.task)

  defp text("projects.assignment_on_hold", %{meta: %{"more" => n}} = c)
       when is_integer(n) and n > 0 do
    ngettext(
      "On hold: “%{task}” and 1 more task — %{actor} reopened “%{after}”",
      "On hold: “%{task}” and %{count} more tasks — %{actor} reopened “%{after}”",
      n,
      task: c.task,
      actor: c.actor,
      after: c.meta["after"] || ""
    )
  end

  defp text("projects.assignment_on_hold", c) do
    gettext("On hold: “%{task}” — %{actor} reopened “%{after}”",
      task: c.task,
      actor: c.actor,
      after: c.meta["after"] || ""
    )
  end

  defp text("projects.assignment_reassigned", %{meta: %{"role" => "new"}} = c),
    do: gettext("%{actor} gave you a task: “%{task}”", actor: c.actor, task: c.task)

  defp text("projects.assignment_reassigned", %{meta: %{"to" => to}} = c)
       when is_binary(to) and to != "" do
    gettext("%{actor} handed “%{task}” to %{to}", actor: c.actor, task: c.task, to: to)
  end

  defp text("projects.assignment_reassigned", c),
    do: gettext("%{actor} took “%{task}” off you", actor: c.actor, task: c.task)

  defp text("projects.assignment_removed", c),
    do: gettext("%{actor} removed your task “%{task}”", actor: c.actor, task: c.task)

  defp text(
         "projects.comment_added",
         %{subject: %Assignment{}, meta: %{"note" => "redirect"}} = c
       ) do
    gettext("%{actor} changed the direction of “%{task}”: “%{text}”",
      actor: c.actor,
      task: c.task,
      text: c.meta["excerpt"] || ""
    )
  end

  defp text("projects.comment_added", %{subject: %Assignment{}, meta: %{"note" => _}} = c) do
    gettext("%{actor} added a note to “%{task}”: “%{text}”",
      actor: c.actor,
      task: c.task,
      text: c.meta["excerpt"] || ""
    )
  end

  defp text("projects.comment_added", %{subject: %Assignment{}} = c) do
    gettext("%{actor} on “%{task}”: “%{text}”",
      actor: c.actor,
      task: c.task,
      text: c.meta["excerpt"] || ""
    )
  end

  defp text("projects.comment_added", c) do
    gettext("%{actor} on %{project}: “%{text}”",
      actor: c.actor,
      project: c.project,
      text: c.meta["excerpt"] || ""
    )
  end

  defp text("projects.member_added", c),
    do: gettext("%{actor} added you to %{project}", actor: c.actor, project: c.project)

  defp text("projects.member_role_changed", c),
    do: gettext("%{actor} changed your role in %{project}", actor: c.actor, project: c.project)

  defp text("projects.member_removed", c),
    do: gettext("%{actor} removed you from %{project}", actor: c.actor, project: c.project)

  defp text(_action, c),
    do: gettext("%{actor} updated %{project}", actor: c.actor, project: c.project)

  defp icon("projects.assignment_ready"), do: "hero-arrow-right-circle"
  defp icon("projects.assignment_on_hold"), do: "hero-pause-circle"
  defp icon("projects.assignment_completed"), do: "hero-check-circle"
  defp icon("projects.assignment_reopened"), do: "hero-arrow-uturn-left"
  defp icon("projects.assignment_started"), do: "hero-play-circle"
  defp icon("projects.assignment_reassigned"), do: "hero-arrows-right-left"
  defp icon("projects.assignment_removed"), do: "hero-trash"
  defp icon("projects.comment_added"), do: "hero-chat-bubble-left-right"
  defp icon("projects.member_" <> _), do: "hero-user-group"
  defp icon(_), do: "hero-clipboard-document-list"

  defp link("projects.assignment_removed", %Assignment{} = a), do: Paths.project(a.project_uuid)
  defp link(_action, subject), do: link(subject)

  defp link(%Assignment{project: %Project{} = p} = a), do: Paths.task(p, a)
  defp link(%Assignment{} = a), do: Paths.task(a.project_uuid, a)
  defp link(%Project{} = p), do: Paths.project(p)

  # The task a hand-off names as done, in the reader's language (the row
  # keeps the primary name, like every audit row).
  defp localize_after(%{"after_uuid" => uuid} = meta) when is_binary(uuid) do
    case Projects.get_assignment(uuid) do
      %Assignment{} = a ->
        case Assignment.label(a, L10n.current_content_lang()) do
          label when is_binary(label) and label != "" -> Map.put(meta, "after", label)
          _ -> meta
        end

      _ ->
        meta
    end
  end

  defp localize_after(meta), do: meta

  @doc "A task's or project's name as a notice and the history say it."
  @spec subject_label(Assignment.t() | Project.t()) :: String.t()
  def subject_label(%Assignment{} = a), do: Assignment.label(a, L10n.current_content_lang()) || ""
  def subject_label(%Project{} = p), do: project_name(p)

  defp primary_label(%Assignment{} = a), do: Assignment.label(a) || ""
  defp primary_label(%Project{name: name}), do: name || ""

  defp primary_project_name(%Assignment{project: %Project{name: name}}), do: name || ""
  defp primary_project_name(%Project{name: name}), do: name || ""
  defp primary_project_name(_), do: ""

  defp project_name(%Assignment{project: %Project{} = p}), do: project_name(p)

  defp project_name(%Assignment{project_uuid: uuid}) do
    case Projects.get_project(uuid) do
      %Project{} = p -> project_name(p)
      _ -> ""
    end
  end

  defp project_name(%Project{} = p), do: Project.localized_name(p, L10n.current_content_lang())

  @doc "The actor's name for a line: their staff/account name, else \"Someone\"."
  @spec actor_name(binary() | nil) :: String.t()
  def actor_name(uuid) when is_binary(uuid) do
    case Auth.get_user(uuid) do
      %User{} = user -> User.display_name(user)
      _ -> gettext("Someone")
    end
  end

  def actor_name(_), do: gettext("Someone")

  @doc "A comment or reason cut to one readable line."
  @spec excerpt(String.t() | nil) :: String.t()
  def excerpt(nil), do: ""

  def excerpt(text) when is_binary(text) do
    plain =
      text
      |> Token.to_plain_text()
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()

    if String.length(plain) > @excerpt_length,
      do: String.slice(plain, 0, @excerpt_length - 1) <> "…",
      else: plain
  end
end
