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
                   projects.assignment_on_hold projects.comment_added)

  @project_actions ~w(projects.member_added projects.member_role_changed
                      projects.member_removed projects.comment_added)

  @excerpt_length 120

  @doc """
  Adds the notification text, icon and link to an `Activity.log/2` option
  list when the entry names a recipient other than its actor and carries no
  text yet. Anything it cannot work out leaves the options as they were.
  """
  @spec decorate(String.t(), keyword()) :: keyword()
  def decorate(action, opts) when is_binary(action) and is_list(opts) do
    target = Keyword.get(opts, :target_uuid)
    meta = Keyword.get(opts, :metadata) || %{}

    cond do
      not is_binary(target) -> opts
      target == Keyword.get(opts, :actor_uuid) -> opts
      Map.has_key?(meta, "notification_text") -> opts
      true -> with_display(action, opts, target, meta)
    end
  rescue
    error ->
      Logger.warning("[Projects] notice text failed: #{inspect(error.__struct__)}")
      opts
  catch
    :exit, _ -> opts
  end

  def decorate(_action, opts), do: opts

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

    opts
    |> Keyword.get(:recipients, [])
    |> Enum.reject(&(is_nil(&1) or &1 == actor))
    |> Enum.uniq()
    |> Enum.filter(&may_view?(&1, project))
    |> Enum.each(fn recipient ->
      Activity.log(action,
        actor_uuid: actor,
        resource_type: resource_type,
        resource_uuid: resource_uuid,
        target_uuid: recipient,
        metadata:
          Map.merge(meta, %{
            "notice" => true,
            "project_uuid" => project_uuid,
            "task" => subject_label(subject),
            "project" => project_name(subject)
          })
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

  defp project_of(%Project{} = p), do: p
  defp project_of(%Assignment{project: %Project{} = p}), do: p
  defp project_of(%Assignment{project_uuid: uuid}), do: Projects.get_project(uuid)

  # ── The line ────────────────────────────────────────────────────────

  defp with_display(action, opts, target, meta) do
    resource = Keyword.get(opts, :resource_uuid)

    subject =
      cond do
        action in @task_actions and Keyword.get(opts, :resource_type) == "assignment" ->
          resource && Projects.get_assignment(resource)

        action in @project_actions and Keyword.get(opts, :resource_type) == "project" ->
          resource && Projects.get_project(resource)

        true ->
          nil
      end

    case subject do
      nil ->
        opts

      subject ->
        actor = actor_name(Keyword.get(opts, :actor_uuid))
        recipient = Auth.get_user(target)

        # `for_rendering/1` never answers nil: no preference means the
        # site's language, never whatever the sender is reading in.
        display =
          RecipientLocale.in_locale(RecipientLocale.for_rendering(recipient), fn ->
            %{
              "notification_text" => line(action, subject, actor, meta),
              "notification_icon" => icon(action),
              "notification_link" => link(subject)
            }
          end)

        Keyword.put(opts, :metadata, Map.merge(meta, display))
    end
  end

  @doc false
  # The one line, in the current Gettext locale. Public for the tests.
  @spec line(String.t(), Assignment.t() | Project.t(), String.t(), map()) :: String.t()
  def line(action, subject, actor, meta) do
    ctx = %{
      actor: actor,
      task: subject_label(subject),
      project: project_name(subject),
      meta: meta,
      subject: subject
    }

    case subject do
      %Assignment{} -> text(action, ctx) <> " · " <> ctx.project
      %Project{} -> text(action, ctx)
    end
  end

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

  defp text("projects.assignment_on_hold", c) do
    gettext("On hold: “%{task}” — %{actor} reopened “%{after}”",
      task: c.task,
      actor: c.actor,
      after: c.meta["after"] || ""
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
  defp icon("projects.comment_added"), do: "hero-chat-bubble-left-right"
  defp icon("projects.member_" <> _), do: "hero-user-group"
  defp icon(_), do: "hero-clipboard-document-list"

  defp link(%Assignment{project: %Project{} = p} = a), do: Paths.task(p, a)
  defp link(%Assignment{} = a), do: Paths.task(a.project_uuid, a)
  defp link(%Project{} = p), do: Paths.project(p)

  @doc "A task's or project's name as a notice and the history say it."
  @spec subject_label(Assignment.t() | Project.t()) :: String.t()
  def subject_label(%Assignment{} = a), do: Assignment.label(a, L10n.current_content_lang()) || ""
  def subject_label(%Project{} = p), do: project_name(p)

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
