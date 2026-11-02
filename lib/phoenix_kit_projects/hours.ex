defmodule PhoenixKitProjects.Hours do
  @moduledoc """
  The reading side of the work ledger: who worked, on what, when and for
  how long — the Hours tab, the site-wide Hours page, the report and the
  API's `GET /hours` all ask here.

  `PhoenixKitProjects.Ledger` stays the only place an entry is written,
  amended or removed; nothing here writes.

  ## Filters

  Every function takes the same filter map (build it with `filters/1`):

    * `:project_uuids` — the projects to read, or `:all`. `project_uuids/2`
      and `visible_project_uuids/1` build the usual sets.
    * `:from` / `:until` — the period, as UTC instants; `:until` is
      exclusive. The time an entry counts on is **when the work was done**:
      its `ended_at`, else its `started_at`, else the moment it was recorded
      (`work_at/0`).
    * `:workers` — worker keys (`"user:<uuid>"`, `"staff_person:<uuid>"`,
      `"ai_agent:<uuid>"`). A person who has both a user account and a staff
      record linked to it is ONE worker: `canonical_workers/1` folds the
      staff record into the user, and a filter on the user finds both.
    * `:assignment_uuid` — one task.
    * `:billable` — `true` / `false`, or nil for both.
    * `:offset_seconds` — the viewer's distance from UTC, for cutting the
      period into days. A fixed figure, so a day next to a daylight-saving
      switch can sit an hour off; the totals never do.

  ## Numbers

  Time is in minutes, as the ledger stores it. `minutes` is people's time
  and `ai_minutes` an agent's (the split `Ledger.totals_for_project/1`
  makes), so "how many hours did we put in" never counts a model's.

  Every summary is grouped in SQL; names are resolved once per call, never
  per row.
  """

  import Ecto.Query

  use Gettext, backend: PhoenixKitProjects.Gettext

  require Logger

  alias PhoenixKit.RepoHelper
  alias PhoenixKitProjects.{Authz, L10n, Members, Projects}
  alias PhoenixKitProjects.People.Person
  alias PhoenixKitProjects.Schemas.{ApiKey, Assignment, Project, Task, WorkEntry}

  @type worker_key :: String.t()

  @type filters :: %{
          project_uuids: [binary()] | :all,
          from: DateTime.t() | nil,
          until: DateTime.t() | nil,
          workers: [worker_key()],
          assignment_uuid: binary() | nil,
          billable: boolean() | nil,
          who: :all | :people | :ai,
          offset_seconds: integer()
        }

  @type worker :: %{key: worker_key(), kind: String.t(), uuid: binary() | nil, name: String.t()}

  @sort_fields ~w(at worker task amount)a
  @max_limit 1000

  # ── Filters ─────────────────────────────────────────────────────────

  @doc "A filter map with every key present; unknown keys are dropped."
  @spec filters(keyword() | map()) :: filters()
  def filters(opts \\ []) do
    opts = Map.new(opts)

    %{
      project_uuids: project_set(Map.get(opts, :project_uuids, [])),
      from: datetime(Map.get(opts, :from)),
      until: datetime(Map.get(opts, :until)),
      workers: opts |> Map.get(:workers, []) |> List.wrap() |> Enum.filter(&worker_key?/1),
      assignment_uuid: uuid_or_nil(Map.get(opts, :assignment_uuid)),
      billable: if(is_boolean(Map.get(opts, :billable)), do: Map.get(opts, :billable)),
      # Whose time: everyone's, people's only, or the agents' only.
      who: if(Map.get(opts, :who) in [:people, :ai], do: Map.get(opts, :who), else: :all),
      offset_seconds: if(is_integer(opts[:offset_seconds]), do: opts[:offset_seconds], else: 0)
    }
  end

  defp project_set(:all), do: :all
  defp project_set(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp project_set(uuid) when is_binary(uuid), do: [uuid]
  defp project_set(_), do: []

  defp datetime(%DateTime{} = dt), do: dt
  defp datetime(_), do: nil

  defp uuid_or_nil(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp uuid_or_nil(_), do: nil

  @doc "The sort fields `list/2` accepts."
  @spec sort_fields() :: [atom()]
  def sort_fields, do: @sort_fields

  @doc """
  The projects one project's hours cover: itself, or itself and every
  project nested under it.
  """
  @spec project_uuids(binary(), boolean()) :: [binary()]
  def project_uuids(project_uuid, include_subprojects?) when is_binary(project_uuid) do
    if include_subprojects?, do: Projects.subtree_uuids(project_uuid), else: [project_uuid]
  end

  @doc """
  The projects a viewer's site-wide Hours page reads: `:all` for someone
  who administers every project, otherwise what they hold through
  membership, a group grant or an open project — `Projects.list_projects_for/2`'s
  rule, and every project nested under those: whoever can open a project
  already reads its sub-projects' tasks on its Tasks tab, so their hours
  are read the same way. (A sub-project CAN have members of its own;
  writing still asks the sub-project itself.)
  """
  @spec visible_project_uuids(term()) :: [binary()] | :all
  def visible_project_uuids(scope) do
    cond do
      Authz.admin_all?(scope) ->
        :all

      user_uuid = Authz.subject_user_uuid_of(scope) ->
        user_uuid |> Members.accessible_project_uuids() |> with_descendants()

      true ->
        []
    end
  end

  # Every project nested under `roots`, the roots included: one read per
  # level of nesting, never one per project.
  defp with_descendants(roots), do: descend(roots, roots, 8)

  defp descend([], acc, _hops), do: Enum.uniq(acc)
  defp descend(_level, acc, 0), do: Enum.uniq(acc)

  defp descend(level, acc, hops) do
    children =
      RepoHelper.repo().all(
        from(a in Assignment,
          where: a.project_uuid in ^level and not is_nil(a.child_project_uuid),
          select: a.child_project_uuid
        )
      ) -- acc

    descend(children, acc ++ children, hops - 1)
  end

  @doc """
  The projects behind a set of uuids, in one read, as `%{uuid => project}`
  — what a page needs to ask `Authz.can?/5` about each project in sight
  (the resolver reads a project's own "who can do what" floors off the
  struct; a bare uuid would be judged by the defaults).
  """
  @spec projects_by_uuid([binary()]) :: %{binary() => Project.t()}
  def projects_by_uuid([]), do: %{}

  def projects_by_uuid(uuids) when is_list(uuids) do
    from(p in Project, where: p.uuid in ^Enum.uniq(uuids))
    |> RepoHelper.repo().all()
    |> Map.new(&{&1.uuid, &1})
  rescue
    _ -> %{}
  end

  # ── The query ───────────────────────────────────────────────────────

  @doc "The moment an entry counts on: when the work was done, else when it was recorded."
  defmacro work_at(e) do
    quote do
      fragment(
        "coalesce(?, ?, ?)",
        unquote(e).ended_at,
        unquote(e).started_at,
        unquote(e).inserted_at
      )
    end
  end

  # The local calendar day of an entry, `offset` seconds from UTC.
  defmacrop work_day(e, offset) do
    quote do
      fragment(
        "((coalesce(?, ?, ?) AT TIME ZONE 'UTC') + make_interval(secs => ?))::date",
        unquote(e).ended_at,
        unquote(e).started_at,
        unquote(e).inserted_at,
        unquote(offset)
      )
    end
  end

  defp base(%{} = f) do
    WorkEntry
    |> from(as: :entry)
    |> in_projects(f.project_uuids)
    |> since(f.from)
    |> before(f.until)
    |> on_assignment(f.assignment_uuid)
    |> billable(f.billable)
    |> by_workers(f.workers)
    |> by_who(Map.get(f, :who, :all))
  end

  defp by_who(q, :people), do: where(q, [e], e.actor_kind != "ai_agent")
  defp by_who(q, :ai), do: where(q, [e], e.actor_kind == "ai_agent")
  defp by_who(q, _all), do: q

  defp in_projects(q, :all), do: q
  defp in_projects(q, uuids), do: where(q, [e], e.project_uuid in ^uuids)

  defp since(q, nil), do: q
  defp since(q, %DateTime{} = from), do: where(q, [e], work_at(e) >= ^from)

  defp before(q, nil), do: q
  defp before(q, %DateTime{} = until), do: where(q, [e], work_at(e) < ^until)

  defp on_assignment(q, nil), do: q
  defp on_assignment(q, uuid), do: where(q, [e], e.assignment_uuid == ^uuid)

  defp billable(q, nil), do: q
  defp billable(q, flag), do: where(q, [e], e.billable == ^flag)

  defp by_workers(q, []), do: q

  # The chosen workers are ONE bracketed term beside the other filters.
  defp by_workers(q, keys) do
    picked =
      keys
      |> expand_workers()
      |> Enum.map(&split_key/1)
      |> Enum.reduce(dynamic(false), fn
        {kind, nil}, dyn ->
          dynamic([e], ^dyn or (e.actor_kind == ^kind and is_nil(e.actor_uuid)))

        {kind, uuid}, dyn ->
          dynamic([e], ^dyn or (e.actor_kind == ^kind and e.actor_uuid == ^uuid))
      end)

    where(q, ^picked)
  end

  # ── Entries ─────────────────────────────────────────────────────────

  @doc """
  Entries matching `filters`, with who, which task and which project
  resolved for the whole page in a fixed number of reads.

  Options: `:kinds` (default `["time"]`), `:sort_by` (`sort_fields/0`,
  default `:at`), `:sort_dir` (`:asc` / `:desc`, default `:desc`), `:limit`
  (default 50, at most #{@max_limit}), `:offset`, `:lang`.

  Returns `%{entries: [row], total: integer}`; a row is
  `%{entry, at, worker, task, project}` — `task` is nil for time logged on
  the project itself.
  """
  @spec list(filters(), keyword()) :: %{entries: [map()], total: non_neg_integer()}
  def list(%{} = f, opts \\ []) do
    kinds = Keyword.get(opts, :kinds, ["time"])
    limit = opts |> Keyword.get(:limit, 50) |> max(1) |> min(@max_limit)
    offset = opts |> Keyword.get(:offset, 0) |> max(0)
    sort_by = Keyword.get(opts, :sort_by, :at)
    sort_dir = if Keyword.get(opts, :sort_dir) == :asc, do: :asc, else: :desc

    query = f |> base() |> where([e], e.kind in ^kinds)
    total = RepoHelper.repo().aggregate(query, :count, :uuid)

    entries =
      query
      |> sorted(sort_by, sort_dir)
      |> limit(^limit)
      |> offset(^offset)
      |> RepoHelper.repo().all()

    %{entries: decorate(entries, Keyword.get(opts, :lang)), total: total}
  rescue
    e ->
      Logger.warning("[Projects.Hours] list failed: #{Exception.message(e)}")
      %{entries: [], total: 0}
  end

  defp sorted(q, :amount, dir), do: order_by(q, [e], [{^dir, e.amount}, {:desc, e.uuid}])

  defp sorted(q, :worker, dir),
    do: order_by(q, [e], [{^dir, e.actor_kind}, {^dir, e.actor_uuid}, {:desc, work_at(e)}])

  defp sorted(q, :task, dir) do
    q
    |> join(:left, [e], a in Assignment, on: a.uuid == e.assignment_uuid, as: :assignment)
    |> join(:left, [assignment: a], t in Task, on: t.uuid == a.task_uuid, as: :task)
    |> order_by([e, task: t], [{^dir, t.title}, {:desc, work_at(e)}])
  end

  defp sorted(q, _at, dir), do: order_by(q, [e], [{^dir, work_at(e)}, {^dir, e.uuid}])

  defp decorate(entries, lang) do
    workers = entries |> Enum.map(&{&1.actor_kind, &1.actor_uuid, &1.metadata}) |> worker_index()
    tasks = entries |> Enum.map(& &1.assignment_uuid) |> task_titles(lang)
    projects = entries |> Enum.map(& &1.project_uuid) |> project_names(lang)

    Enum.map(entries, fn e ->
      %{
        entry: e,
        at: e.ended_at || e.started_at || e.inserted_at,
        worker: Map.fetch!(workers, actor_key(e.actor_kind, e.actor_uuid)),
        task: e.assignment_uuid && task_map(e.assignment_uuid, tasks),
        project: %{uuid: e.project_uuid, name: projects[e.project_uuid]}
      }
    end)
  end

  # ── Summary ─────────────────────────────────────────────────────────

  @doc """
  Everything the Hours page shows above its entry list, for `filters`:

    * `:totals` — `%{minutes, billable_minutes, ai_minutes, tokens,
      cost_cents, entries, people}`
    * `:by_worker` — `[%{worker, minutes, billable_minutes, entries}]`,
      most time first (an agent's minutes are its `minutes` here)
    * `:by_task` — `[%{task, project, minutes, billable_minutes, entries,
      below_minutes, below_billable_minutes}]` (`task` nil = logged on the
      project itself). `minutes` is the task's OWN time; `below_*` is what
      was logged on the tasks under it, so a task with subtasks reads own +
      below. A task with nothing of its own but time below it is listed
      with `entries: 0`.
    * `:by_project` — `[%{project, minutes, billable_minutes, entries}]`
    * `:by_day` — `[%{date, minutes, by_worker: %{key => minutes}}]`,
      oldest first, days with nothing logged left out
    * `:matrix` — `%{key => %{date => minutes}}`, the timesheet
    * `:workers` — every worker in the result, by key

  Six grouped reads plus the name lookups, whatever the number of entries.
  """
  @spec summary(filters(), keyword()) :: map()
  def summary(%{} = f, opts \\ []) do
    lang = Keyword.get(opts, :lang)
    query = base(f)
    time = where(query, [e], e.kind == "time")

    worker_rows = worker_rows(time)
    day_rows = day_rows(time, f.offset_seconds)
    task_rows = task_rows(time)
    project_rows = project_rows(time)

    workers =
      (worker_rows ++ day_rows)
      |> Enum.map(&{&1.kind, &1.uuid, %{"api_key_name" => Map.get(&1, :key_name)}})
      |> worker_index()

    tasks = task_rows |> Enum.map(& &1.assignment_uuid) |> task_titles(lang)

    projects =
      (Enum.map(task_rows, & &1.project_uuid) ++ Enum.map(project_rows, & &1.project_uuid))
      |> project_names(lang)

    by_worker = fold_workers(worker_rows, workers)

    %{
      totals: totals(query, by_worker),
      by_worker: by_worker,
      by_task: task_rows |> Enum.map(&task_row(&1, tasks, projects)) |> fold_branches(lang),
      by_project: Enum.map(project_rows, &project_row(&1, projects)),
      by_day: by_day(day_rows, workers),
      matrix: matrix(day_rows, workers),
      workers: workers |> Map.values() |> Map.new(&{&1.key, &1})
    }
  rescue
    e ->
      Logger.warning("[Projects.Hours] summary failed: #{Exception.message(e)}")
      empty_summary()
  end

  @doc "A summary with nothing in it — what a failed read answers."
  @spec empty_summary() :: map()
  def empty_summary do
    %{
      totals: %{
        minutes: 0.0,
        billable_minutes: 0.0,
        ai_minutes: 0.0,
        tokens: 0.0,
        cost_cents: 0.0,
        entries: 0,
        people: 0
      },
      by_worker: [],
      by_task: [],
      by_project: [],
      by_day: [],
      matrix: %{},
      workers: %{}
    }
  end

  defp totals(query, by_worker) do
    rows =
      RepoHelper.repo().all(
        from(e in query,
          group_by: [e.kind, e.billable, e.actor_kind],
          select: {e.kind, e.billable, e.actor_kind, sum(e.amount), count(e.uuid)}
        )
      )

    base = %{
      empty_summary().totals
      | people: Enum.count(by_worker, &(&1.worker.kind != "ai_agent"))
    }

    Enum.reduce(rows, base, fn {kind, billable, actor_kind, sum, count}, acc ->
      sum = Decimal.to_float(sum)

      acc =
        case {kind, actor_kind} do
          {"time", "ai_agent"} -> Map.update!(acc, :ai_minutes, &(&1 + sum))
          {"time", _} -> acc |> Map.update!(:minutes, &(&1 + sum)) |> bump_entries(count)
          {"tokens", _} -> Map.update!(acc, :tokens, &(&1 + sum))
          {"cost", _} -> Map.update!(acc, :cost_cents, &(&1 + sum))
        end

      if kind == "time" and billable and actor_kind != "ai_agent",
        do: Map.update!(acc, :billable_minutes, &(&1 + sum)),
        else: acc
    end)
  end

  defp bump_entries(acc, count), do: Map.update!(acc, :entries, &(&1 + count))

  defp worker_rows(time) do
    RepoHelper.repo().all(
      from(e in time,
        group_by: [e.actor_kind, e.actor_uuid],
        select: %{
          kind: e.actor_kind,
          uuid: e.actor_uuid,
          minutes: sum(e.amount),
          billable_minutes: sum(fragment("CASE WHEN ? THEN ? ELSE 0 END", e.billable, e.amount)),
          entries: count(e.uuid),
          key_name: max(fragment("?->>'api_key_name'", e.metadata))
        }
      )
    )
  end

  # The day is computed in a subquery and grouped by its column: grouping by
  # the expression itself binds the offset twice, and Postgres does not see
  # two parameters as one expression.
  defp day_rows(time, offset) do
    days =
      from(e in time,
        select: %{
          date: work_day(e, ^offset),
          kind: e.actor_kind,
          uuid: e.actor_uuid,
          amount: e.amount
        }
      )

    RepoHelper.repo().all(
      from(d in subquery(days),
        group_by: [d.date, d.kind, d.uuid],
        select: %{date: d.date, kind: d.kind, uuid: d.uuid, minutes: sum(d.amount)}
      )
    )
  end

  defp task_rows(time) do
    RepoHelper.repo().all(
      from(e in time,
        group_by: [e.assignment_uuid, e.project_uuid],
        select: %{
          assignment_uuid: e.assignment_uuid,
          project_uuid: e.project_uuid,
          minutes: sum(e.amount),
          billable_minutes: sum(fragment("CASE WHEN ? THEN ? ELSE 0 END", e.billable, e.amount)),
          entries: count(e.uuid),
          last_at: max(work_at(e))
        },
        order_by: [desc: sum(e.amount)]
      )
    )
  end

  defp project_rows(time) do
    RepoHelper.repo().all(
      from(e in time,
        group_by: e.project_uuid,
        select: %{
          project_uuid: e.project_uuid,
          minutes: sum(e.amount),
          billable_minutes: sum(fragment("CASE WHEN ? THEN ? ELSE 0 END", e.billable, e.amount)),
          entries: count(e.uuid)
        },
        order_by: [desc: sum(e.amount)]
      )
    )
  end

  # A person's user rows and staff rows are one line.
  defp fold_workers(rows, workers) do
    rows
    |> Enum.group_by(&Map.fetch!(workers, actor_key(&1.kind, &1.uuid)).key)
    |> Enum.map(fn {key, group} ->
      %{
        worker: workers |> Map.values() |> Enum.find(&(&1.key == key)),
        minutes: sum_floats(group, :minutes),
        billable_minutes: sum_floats(group, :billable_minutes),
        entries: group |> Enum.map(& &1.entries) |> Enum.sum()
      }
    end)
    |> Enum.sort_by(&{-&1.minutes, &1.worker.name})
  end

  defp task_row(row, tasks, projects) do
    %{
      task: row.assignment_uuid && task_map(row.assignment_uuid, tasks),
      project: %{uuid: row.project_uuid, name: projects[row.project_uuid]},
      minutes: to_float(row.minutes),
      billable_minutes: to_float(row.billable_minutes),
      entries: row.entries,
      last_at: row.last_at
    }
  end

  # A task with subtasks reads its own time plus what was logged under it
  # (chain V23). Every row gains `below_*`; a task that carries no entry of
  # its own but has some below is added, so the branch has a line. Sorted
  # as before: most time (own + below) first.
  defp fold_branches(rows, lang) do
    project_uuids = rows |> Enum.map(& &1.project.uuid) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    parents =
      from(a in Assignment,
        where: a.project_uuid in ^project_uuids and not is_nil(a.parent_uuid),
        select: {a.uuid, a.parent_uuid}
      )
      |> RepoHelper.repo().all()
      |> Map.new()

    if parents == %{} do
      Enum.map(rows, &Map.merge(&1, %{below_minutes: 0.0, below_billable_minutes: 0.0}))
    else
      below =
        Enum.reduce(rows, %{}, fn row, acc ->
          row.task
          |> then(&(&1 && &1.uuid))
          |> chain_above(parents, [])
          |> Enum.reduce(acc, &add_below(&2, &1, row))
        end)

      listed = MapSet.new(rows, &(&1.task && &1.task.uuid))
      extra_uuids = below |> Map.keys() |> Enum.reject(&MapSet.member?(listed, &1))
      titles = task_titles(extra_uuids, lang)

      extra =
        Enum.map(extra_uuids, fn uuid ->
          {_m, _b, project} = Map.fetch!(below, uuid)

          %{
            task: task_map(uuid, titles),
            project: project,
            minutes: 0.0,
            billable_minutes: 0.0,
            entries: 0,
            last_at: nil
          }
        end)

      (rows ++ extra)
      |> Enum.map(fn row ->
        {m, b, _} = Map.get(below, row.task && row.task.uuid, {0.0, 0.0, nil})
        Map.merge(row, %{below_minutes: m, below_billable_minutes: b})
      end)
      |> Enum.sort_by(&(-(&1.minutes + &1.below_minutes)))
    end
  rescue
    _ -> Enum.map(rows, &Map.merge(&1, %{below_minutes: 0.0, below_billable_minutes: 0.0}))
  end

  # One row's time added to a task it sits under.
  defp add_below(acc, up, row) do
    Map.update(
      acc,
      up,
      {row.minutes, row.billable_minutes, row.project},
      fn {m, b, p} -> {m + row.minutes, b + row.billable_minutes, p} end
    )
  end

  defp chain_above(nil, _parents, acc), do: acc
  defp chain_above(_uuid, _parents, acc) when length(acc) > 100, do: acc

  defp chain_above(uuid, parents, acc) do
    case Map.get(parents, uuid) do
      nil -> acc
      up -> if up in acc, do: acc, else: chain_above(up, parents, [up | acc])
    end
  end

  defp project_row(row, projects) do
    %{
      project: %{uuid: row.project_uuid, name: projects[row.project_uuid]},
      minutes: to_float(row.minutes),
      billable_minutes: to_float(row.billable_minutes),
      entries: row.entries
    }
  end

  defp by_day(rows, workers) do
    rows
    |> Enum.group_by(& &1.date)
    |> Enum.map(fn {date, group} ->
      by_worker =
        Enum.reduce(group, %{}, fn row, acc ->
          key = Map.fetch!(workers, actor_key(row.kind, row.uuid)).key
          Map.update(acc, key, to_float(row.minutes), &(&1 + to_float(row.minutes)))
        end)

      %{date: date, minutes: by_worker |> Map.values() |> Enum.sum(), by_worker: by_worker}
    end)
    |> Enum.sort_by(& &1.date, Date)
  end

  defp matrix(rows, workers) do
    Enum.reduce(rows, %{}, fn row, acc ->
      key = Map.fetch!(workers, actor_key(row.kind, row.uuid)).key
      minutes = to_float(row.minutes)

      Map.update(acc, key, %{row.date => minutes}, fn days ->
        Map.update(days, row.date, minutes, &(&1 + minutes))
      end)
    end)
  end

  defp sum_floats(rows, field),
    do: rows |> Enum.map(&to_float(Map.fetch!(&1, field))) |> Enum.sum()

  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float(n) when is_number(n), do: n * 1.0
  defp to_float(_), do: 0.0

  @doc """
  The timesheet for a span of days: `%{matrix: %{worker_key => %{date =>
  minutes}}, workers: %{worker_key => worker}}` — two reads, for a week the
  page pages through without re-reading the whole summary.
  """
  @spec timesheet(filters()) :: %{matrix: map(), workers: map()}
  def timesheet(%{} = f) do
    rows = f |> base() |> where([e], e.kind == "time") |> day_rows(f.offset_seconds)
    workers = rows |> Enum.map(&{&1.kind, &1.uuid, nil}) |> worker_index()

    %{
      matrix: matrix(rows, workers),
      workers: workers |> Map.values() |> Map.new(&{&1.key, &1})
    }
  rescue
    e ->
      Logger.warning("[Projects.Hours] timesheet failed: #{Exception.message(e)}")
      %{matrix: %{}, workers: %{}}
  end

  @doc """
  The tasks time can be logged on in a set of projects, as
  `[%{uuid, title, project_uuid}]` in plan order — the task filter and the
  "Log time" picker. Sub-project rows are left out (their time belongs to
  the tasks inside them) and so are requests nobody accepted yet.
  """
  @spec task_options([binary()] | :all, String.t() | nil) :: [map()]
  def task_options(:all, _lang), do: []
  def task_options([], _lang), do: []

  def task_options(project_uuids, lang) when is_list(project_uuids) do
    lang = lang || L10n.current_content_lang()

    from(a in Assignment,
      where:
        a.project_uuid in ^project_uuids and is_nil(a.child_project_uuid) and
          a.review_status == "accepted",
      order_by: [asc: a.project_uuid, asc: a.position, asc: a.inserted_at],
      preload: [:task, parent: :task]
    )
    |> RepoHelper.repo().all()
    |> Enum.map(
      &%{uuid: &1.uuid, title: Assignment.label_under(&1, lang), project_uuid: &1.project_uuid}
    )
  rescue
    _ -> []
  end

  @doc """
  The tasks of `project_uuids` matching `query`, for a search-as-you-type
  picker: `{[%{uuid, title, ref, project_uuid}], more?}`, at most `limit`
  of them, in plan order. An empty query is the first page. The match is
  made in the database (a title containing the words, or the task's
  number — `42` or `ACME-42`), so a project with any number of tasks
  answers the same way; nothing is ever listed whole.
  """
  @spec search_tasks([binary()] | :all, String.t(), pos_integer(), String.t() | nil) ::
          {[map()], boolean()}
  def search_tasks(project_uuids, query, limit, lang \\ nil)
  def search_tasks(:all, _query, _limit, _lang), do: {[], false}
  def search_tasks([], _query, _limit, _lang), do: {[], false}

  def search_tasks(project_uuids, query, limit, lang) when is_list(project_uuids) do
    lang = lang || L10n.current_content_lang()
    limit = limit |> max(1) |> min(50)
    q = query |> to_string() |> String.trim()

    base =
      from(a in Assignment,
        join: t in assoc(a, :task),
        where:
          a.project_uuid in ^project_uuids and is_nil(a.child_project_uuid) and
            a.review_status == "accepted",
        order_by: [asc: a.project_uuid, asc: a.position, asc: a.inserted_at],
        limit: ^(limit + 1),
        preload: [:project, task: t, parent: :task]
      )

    rows =
      base
      |> matching_task(q)
      |> RepoHelper.repo().all()
      |> Enum.map(&task_option(&1, lang))

    {Enum.take(rows, limit), length(rows) > limit}
  rescue
    _ -> {[], false}
  end

  defp matching_task(queryable, ""), do: queryable

  defp matching_task(queryable, q) do
    pattern = "%" <> String.replace(q, ~r/([\\%_])/, "\\\\\\1") <> "%"

    case Regex.run(~r/(\d{1,9})$/, q) do
      [_, digits] ->
        number = String.to_integer(digits)
        where(queryable, [a, t], ilike(t.title, ^pattern) or a.number == ^number)

      _ ->
        where(queryable, [_a, t], ilike(t.title, ^pattern))
    end
  end

  @doc "One task as a picker shows it (`search_tasks/4`'s row), or nil."
  @spec task_option(binary() | Assignment.t() | nil, String.t() | nil) :: map() | nil
  def task_option(assignment_or_uuid, lang \\ nil)

  def task_option(%Assignment{} = a, lang) do
    %{
      uuid: a.uuid,
      # "Kitchen / Order tiles" for a subtask, when its parent is loaded.
      title: Assignment.label_under(a, lang || L10n.current_content_lang()),
      ref: Assignment.row_ref(a),
      project_uuid: a.project_uuid
    }
  end

  def task_option(uuid, lang) when is_binary(uuid) and uuid != "" do
    case Projects.get_assignment(uuid) do
      %Assignment{child_project_uuid: nil} = a ->
        a |> RepoHelper.repo().preload(parent: :task) |> task_option(lang)

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  def task_option(_other, _lang), do: nil

  # ── Workers ─────────────────────────────────────────────────────────

  @doc """
  Everyone with an entry in the given projects (the period and the other
  filters ignored) — the choices of the worker filter, by name.
  """
  @spec workers(filters()) :: [worker()]
  def workers(%{} = f) do
    rows =
      RepoHelper.repo().all(
        from(e in WorkEntry,
          as: :entry,
          where: e.kind == "time",
          group_by: [e.actor_kind, e.actor_uuid],
          select: {e.actor_kind, e.actor_uuid, max(fragment("?->>'api_key_name'", e.metadata))}
        )
        |> in_projects(f.project_uuids)
      )

    rows
    |> Enum.map(fn {kind, uuid, key_name} -> {kind, uuid, %{"api_key_name" => key_name}} end)
    |> worker_index()
    |> Map.values()
    |> Enum.uniq_by(& &1.key)
    |> Enum.sort_by(&{&1.kind == "ai_agent", String.downcase(&1.name)})
  rescue
    e ->
      Logger.warning("[Projects.Hours] workers failed: #{Exception.message(e)}")
      []
  end

  @doc "The key of an actor as the ledger stores it: `\"user:<uuid>\"`."
  @spec actor_key(String.t(), binary() | nil) :: worker_key()
  def actor_key(kind, uuid), do: "#{kind}:#{uuid}"

  defp split_key(key) do
    case String.split(key, ":", parts: 2) do
      [kind, ""] -> {kind, nil}
      [kind, uuid] -> {kind, uuid}
    end
  end

  defp worker_key?(key) when is_binary(key) do
    case String.split(key, ":", parts: 2) do
      [kind, ""] -> kind in WorkEntry.actor_kinds()
      [kind, uuid] -> kind in WorkEntry.actor_kinds() and match?({:ok, _}, Ecto.UUID.cast(uuid))
      _ -> false
    end
  end

  defp worker_key?(_), do: false

  # A chosen user also means the staff records linked to that account, and
  # a chosen staff person the account they are linked to.
  defp expand_workers(keys) do
    pairs = Enum.map(keys, &split_key/1)
    user_uuids = for {"user", uuid} <- pairs, is_binary(uuid), do: uuid
    person_uuids = for {"staff_person", uuid} <- pairs, is_binary(uuid), do: uuid

    linked =
      if user_uuids == [] and person_uuids == [] do
        []
      else
        RepoHelper.repo().all(
          from(p in Person,
            where: p.user_uuid in ^user_uuids or p.uuid in ^person_uuids,
            select: {p.uuid, p.user_uuid}
          )
        )
      end

    extra =
      Enum.flat_map(linked, fn {person_uuid, user_uuid} ->
        [actor_key("staff_person", person_uuid)] ++
          if(user_uuid, do: [actor_key("user", user_uuid)], else: [])
      end)

    Enum.uniq(keys ++ extra)
  rescue
    _ -> keys
  end

  @doc """
  Names for a set of actors in one pass: `%{raw_key => worker}` for
  `{actor_kind, actor_uuid, metadata}` triples. The worker's `:key` is the
  CANONICAL one — a staff person linked to a user account answers with the
  user's key, so the two sum as one line.
  """
  @spec worker_index([{String.t(), binary() | nil, map() | nil}]) :: %{worker_key() => worker()}
  def worker_index(actors) do
    actors = Enum.uniq_by(actors, fn {kind, uuid, _meta} -> {kind, uuid} end)
    uuids = fn kind -> for {^kind, uuid, _} <- actors, is_binary(uuid), do: uuid end

    people = people_by_uuid(uuids.("staff_person"))
    linked_users = for {_uuid, %{user_uuid: u}} <- people, is_binary(u), do: u
    users = users_by_uuid(uuids.("user") ++ linked_users)
    keys = key_names(uuids.("ai_agent"))

    Map.new(actors, fn {kind, uuid, meta} ->
      {actor_key(kind, uuid), worker(kind, uuid, meta || %{}, users, people, keys)}
    end)
  end

  defp worker("user", uuid, _meta, users, _people, _keys) do
    %{
      key: actor_key("user", uuid),
      kind: "user",
      uuid: uuid,
      name: Map.get(users, uuid) || gettext("Someone")
    }
  end

  defp worker("staff_person", uuid, _meta, users, people, _keys) do
    case Map.get(people, uuid) do
      %{user_uuid: user_uuid, name: name} when is_binary(user_uuid) ->
        %{
          key: actor_key("user", user_uuid),
          kind: "user",
          uuid: user_uuid,
          name: Map.get(users, user_uuid) || name
        }

      %{name: name} ->
        %{key: actor_key("staff_person", uuid), kind: "staff_person", uuid: uuid, name: name}

      nil ->
        %{
          key: actor_key("staff_person", uuid),
          kind: "staff_person",
          uuid: uuid,
          name: gettext("Someone")
        }
    end
  end

  defp worker(kind, uuid, meta, _users, _people, keys) do
    name = Map.get(keys, uuid) || meta["api_key_name"] || gettext("AI agent")
    %{key: actor_key(kind, uuid), kind: kind, uuid: uuid, name: name}
  end

  defp users_by_uuid([]), do: %{}

  # An account without a first and last name showed as its email in the
  # time logs although its staff person was named: that name comes first.
  defp users_by_uuid(uuids), do: PhoenixKitProjects.People.user_display_names(uuids)

  defp people_by_uuid([]), do: %{}

  defp people_by_uuid(uuids) do
    RepoHelper.repo().all(
      from(p in Person,
        where: p.uuid in ^uuids,
        select: {p.uuid, %{user_uuid: p.user_uuid, name: p.name}}
      )
    )
    |> Map.new(fn {uuid, %{name: name} = row} ->
      {uuid, %{row | name: if(name in [nil, ""], do: gettext("Unnamed"), else: name)}}
    end)
  rescue
    _ -> %{}
  end

  defp key_names([]), do: %{}

  defp key_names(uuids) do
    RepoHelper.repo().all(from(k in ApiKey, where: k.uuid in ^uuids, select: {k.uuid, k.name}))
    |> Map.new()
  rescue
    _ -> %{}
  end

  # ── Names ───────────────────────────────────────────────────────────

  # A task as the page, the report and the API name it: its title and its
  # ref. A task that is gone keeps its uuid and has neither.
  defp task_map(uuid, tasks) do
    info = Map.get(tasks, uuid, %{})
    %{uuid: uuid, title: info[:title], ref: info[:ref]}
  end

  defp task_titles(uuids, lang) do
    case uuids |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] ->
        %{}

      uuids ->
        lang = lang || L10n.current_content_lang()

        # `:project` for the row's ref (`ACME-42`, `Assignment.ref/1`).
        # `parent: :task` — a subtask is named with the task it sits under.
        from(a in Assignment,
          where: a.uuid in ^uuids,
          preload: [:task, :child_project, :project, parent: :task]
        )
        |> RepoHelper.repo().all()
        |> Map.new(
          &{&1.uuid, %{title: Assignment.label_under(&1, lang), ref: Assignment.ref(&1)}}
        )
    end
  end

  defp project_names(uuids, lang) do
    case uuids |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] ->
        %{}

      uuids ->
        lang = lang || L10n.current_content_lang()

        from(p in Project, where: p.uuid in ^uuids)
        |> RepoHelper.repo().all()
        |> Map.new(&{&1.uuid, Project.localized_name(&1, lang)})
    end
  end
end
