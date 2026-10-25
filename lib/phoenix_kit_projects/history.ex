defmodule PhoenixKitProjects.History do
  @moduledoc """
  A project's story: who did what, when, and who was told.

  Merged at read time from what the project already records, never copied:

    * the project's activity rows — those about the project itself, about
      any of its tasks, and those naming it in `metadata["project_uuid"]`
      (starts, completions, reopens with their reason, waiting, "your turn",
      "on hold", members, …);
    * the comments and notes on the project and on its tasks;
    * the ledger's time entries.

  Comment notices and `work_logged` rows are left out (the comment and the
  time entry are the record); the notices a status change caused are folded
  into the line they belong to, as **who was told** — and whether they have
  seen it — from core's notification rows.

  `list/2` answers `%{entries: [entry], total: n}`, newest first. An entry is
  a map with `:at`, `:kind` (`:activity | :comment | :note | :time`),
  `:action`, `:actor` (name), `:actor_uuid`, `:target` (the name of whom a
  row is about, e.g. a member added), `:task` (`%{uuid, label}` or nil), `:quote`, `:told` (`[%{name, seen_at}]`), `:auto` (a row the tick
  rules moved), `:icon` and `:meta`. The sentence is the page's to write
  (`Web.ProjectHistoryLive`), in the viewer's language.

  The whole project is read and merged in memory (about a dozen statements
  whatever its size). A project's story is hundreds of lines, not hundreds of
  thousands; past `@cap` lines per source the oldest are dropped and
  `:truncated` says so.
  """

  import Ecto.Query

  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.Notifications.Notification
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitComments.Comment
  alias PhoenixKitProjects.{L10n, TaskNotes}
  alias PhoenixKitProjects.Schemas.{Assignment, Project, WorkEntry}

  @cap 2_000

  # Rows a notice was written for: the comment or the time entry itself is the line.
  @dropped ~w(projects.comment_added projects.work_logged)

  # Notices folded into the line of the change that caused them.
  @notice_actions ~w(projects.assignment_ready projects.assignment_on_hold)

  @type entry :: map()

  @doc """
  The history of `project`. Options: `:task` — only the lines about that task
  (its uuid); `:kinds` — a subset of `[:activity, :comment, :note, :time]`.
  """
  @spec list(Project.t(), keyword()) :: %{
          entries: [entry()],
          total: non_neg_integer(),
          truncated: boolean()
        }
  def list(%Project{} = project, opts \\ []) do
    tasks = task_index(project.uuid)
    only = Keyword.get(opts, :task)
    kinds = Keyword.get(opts, :kinds, [:activity, :comment, :note, :time])

    task_uuids = if only, do: [only], else: Map.keys(tasks)

    sources = [
      {:activity, fn -> activity(project, task_uuids, only) end},
      {:comment,
       fn ->
         project
         |> comments(task_uuids, only, ["assignment", "project"])
         |> with_comment_told()
       end},
      {:note,
       fn ->
         comments(project, task_uuids, only, [TaskNotes.resource_type(), "project_notes"])
       end},
      {:time, fn -> time(project, task_uuids, only) end}
    ]

    raw =
      for {kind, read} <- sources, kind in kinds do
        {kind, read.()}
      end

    truncated = Enum.any?(raw, fn {_k, rows} -> length(rows) >= @cap end)

    entries =
      raw
      |> Enum.flat_map(fn {kind, rows} -> Enum.map(rows, &normalize(kind, &1, tasks)) end)
      |> Enum.reject(&is_nil/1)
      |> fold_notices()
      |> name_people()
      |> Enum.sort_by(&{DateTime.to_unix(&1.at, :microsecond), order(&1)}, :desc)

    %{entries: entries, total: length(entries), truncated: truncated}
  end

  # Lines of the same instant, newest first: what a change caused ("ready",
  # "on hold", a parent ticked with it) above the change, the change above
  # the comment or time entry that came with it.
  defp order(%{kind: :activity, action: action}) when action in @notice_actions, do: 4
  defp order(%{kind: :activity, auto: true}), do: 3
  defp order(%{kind: :activity}), do: 2
  defp order(%{kind: :comment}), do: 1
  defp order(_), do: 0

  # ── Sources ─────────────────────────────────────────────────────────

  # Every task the project has: uuid → label. Deleted tasks are gone from
  # here; their rows still say what they were through `metadata["task"]`.
  defp task_index(project_uuid) do
    from(a in Assignment,
      where: a.project_uuid == ^project_uuid,
      preload: [:task, :child_project]
    )
    |> RepoHelper.repo().all()
    |> Map.new(&{&1.uuid, Assignment.label(&1, L10n.current_content_lang()) || ""})
  end

  defp activity(project, task_uuids, only) do
    ids = if only, do: task_uuids, else: [project.uuid | task_uuids]

    query =
      from(e in Entry,
        where: e.module == "projects" and e.action not in ^@dropped,
        order_by: [desc: e.inserted_at],
        limit: @cap
      )

    query =
      if only do
        where(query, [e], e.resource_uuid in ^ids)
      else
        where(
          query,
          [e],
          e.resource_uuid in ^ids or fragment("?->>'project_uuid' = ?", e.metadata, ^project.uuid)
        )
      end

    entries = RepoHelper.repo().all(query)
    told = told(entries)

    Enum.map(entries, &{&1, Map.get(told, &1.uuid, [])})
  end

  # Who each row's notice reached, and when they saw it: one read.
  defp told([]), do: %{}

  defp told(entries) do
    ids = entries |> Enum.filter(& &1.target_uuid) |> Enum.map(& &1.uuid)

    from(n in Notification,
      where: n.activity_uuid in ^ids,
      select: {n.activity_uuid, n.recipient_uuid, n.seen_at}
    )
    |> RepoHelper.repo().all()
    |> Enum.group_by(&elem(&1, 0), fn {_, who, seen} -> %{uuid: who, seen_at: seen} end)
  end

  defp comments(project, task_uuids, only, [task_type, project_type]) do
    where_clause =
      if only do
        dynamic([c], c.resource_type == ^task_type and c.resource_uuid in ^task_uuids)
      else
        dynamic(
          [c],
          (c.resource_type == ^task_type and c.resource_uuid in ^task_uuids) or
            (c.resource_type == ^project_type and c.resource_uuid == ^project.uuid)
        )
      end

    from(c in Comment,
      where: c.status == "published",
      where: ^where_clause,
      order_by: [desc: c.inserted_at],
      limit: @cap
    )
    |> RepoHelper.repo().all()
  end

  # Who each comment's notices reached, and when they saw it: one read over
  # the notice rows (`metadata.comment`) and their notifications.
  defp with_comment_told([]), do: []

  defp with_comment_told(comments) do
    ids = Enum.map(comments, & &1.uuid)

    told =
      from(n in Notification,
        join: e in Entry,
        on: e.uuid == n.activity_uuid,
        where:
          e.module == "projects" and e.action == "projects.comment_added" and
            fragment("?->>'comment'", e.metadata) in type(^ids, {:array, :string}),
        select: {fragment("?->>'comment'", e.metadata), n.recipient_uuid, n.seen_at}
      )
      |> RepoHelper.repo().all()
      |> Enum.group_by(&elem(&1, 0), fn {_, who, seen} -> %{uuid: who, seen_at: seen} end)

    Enum.map(comments, &{&1, Map.get(told, &1.uuid, [])})
  end

  defp time(project, task_uuids, only) do
    query =
      from(w in WorkEntry,
        where: w.project_uuid == ^project.uuid and w.kind == "time",
        order_by: [desc: w.inserted_at],
        limit: @cap
      )

    query = if only, do: where(query, [w], w.assignment_uuid in ^task_uuids), else: query

    RepoHelper.repo().all(query)
  end

  # ── One shape ───────────────────────────────────────────────────────

  defp normalize(:activity, {%Entry{} = e, told}, tasks) do
    meta = e.metadata || %{}

    %{
      id: "a-" <> e.uuid,
      at: e.inserted_at,
      kind: :activity,
      action: e.action,
      actor_uuid: e.actor_uuid,
      target_uuid: e.target_uuid,
      task: task_ref(e.resource_type, e.resource_uuid, meta, tasks),
      quote: meta["reason"],
      told: told,
      auto: meta["auto"] == true,
      notice: meta["notice"] == true,
      meta: meta
    }
  end

  # A reopen's reason is quoted by the reopen's own line.
  defp normalize(:comment, {%Comment{metadata: %{"reopen_reason" => true}}, _told}, _tasks),
    do: nil

  defp normalize(:comment, {%Comment{} = c, told}, tasks),
    do: %{normalize(:note_or_comment, c, tasks) | kind: :comment, told: told}

  defp normalize(:note, %Comment{} = c, tasks),
    do: %{normalize(:note_or_comment, c, tasks) | kind: :note}

  defp normalize(:note_or_comment, %Comment{} = c, tasks) do
    %{
      id: "c-" <> c.uuid,
      at: c.inserted_at,
      kind: :comment,
      action: nil,
      actor_uuid: c.user_uuid,
      target_uuid: nil,
      task:
        if(c.resource_type in ["assignment", TaskNotes.resource_type()],
          do: %{uuid: c.resource_uuid, label: Map.get(tasks, c.resource_uuid, "")}
        ),
      quote: c.content,
      told: [],
      auto: false,
      notice: false,
      reply: not is_nil(c.parent_uuid),
      meta: c.metadata || %{}
    }
  end

  defp normalize(:time, %WorkEntry{} = w, tasks) do
    %{
      id: "w-" <> w.uuid,
      at: w.ended_at || w.started_at || w.inserted_at,
      kind: :time,
      action: nil,
      actor_uuid: w.actor_uuid,
      target_uuid: nil,
      task:
        if(w.assignment_uuid,
          do: %{uuid: w.assignment_uuid, label: Map.get(tasks, w.assignment_uuid, "")}
        ),
      quote: w.note,
      told: [],
      auto: false,
      notice: false,
      minutes: w.amount && Decimal.to_float(w.amount),
      actor_kind: w.actor_kind,
      meta: w.metadata || %{}
    }
  end

  defp task_ref("assignment", uuid, meta, tasks) when is_binary(uuid),
    do: %{uuid: uuid, label: Map.get(tasks, uuid) || meta["task"] || ""}

  defp task_ref(_type, _uuid, _meta, _tasks), do: nil

  # Notice rows ("your turn", "on hold") about the same task in the same
  # second are one line naming everyone who was told.
  defp fold_notices(entries) do
    {notices, rest} =
      Enum.split_with(entries, &(&1.kind == :activity and &1.action in @notice_actions))

    folded =
      notices
      |> Enum.group_by(&{&1.action, &1.task && &1.task.uuid, DateTime.to_unix(&1.at)})
      |> Enum.map(fn {_key, [first | _] = group} ->
        %{first | told: Enum.flat_map(group, & &1.told), target_uuid: nil}
      end)

    rest ++ folded
  end

  # Names for every actor and everyone told, in one read.
  defp name_people(entries) do
    uuids =
      entries
      |> Enum.flat_map(fn e -> [e.actor_uuid, e.target_uuid | Enum.map(e.told, & &1.uuid)] end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    names =
      from(u in User, where: u.uuid in ^uuids)
      |> RepoHelper.repo().all()
      |> Map.new(&{&1.uuid, User.display_name(&1)})

    Enum.map(entries, fn e ->
      e
      |> Map.put(:actor, e.actor_uuid && Map.get(names, e.actor_uuid))
      |> Map.put(:target, e.target_uuid && Map.get(names, e.target_uuid))
      |> Map.put(
        :told,
        e.told
        |> Enum.uniq_by(& &1.uuid)
        |> Enum.map(&Map.put(&1, :name, Map.get(names, &1.uuid)))
      )
    end)
  end
end
