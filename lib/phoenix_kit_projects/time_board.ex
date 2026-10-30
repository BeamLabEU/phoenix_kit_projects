defmodule PhoenixKitProjects.TimeBoard do
  @moduledoc """
  The data behind the **Time** page (`Web.TimeLive`): for a day or a week,
  every person and what their time went to — each task as its own line, with
  where it was **planned** and when it was **actually** done.

  Everything a line carries is read from the task itself, never invented:

    * **planned** — the task's own planned dates (with their times when it has
      them, else the work day); failing that, its **deadline walked back by its
      estimate** through work hours (08:00–17:00, weekdays unless the task
      counts weekends), which may split across days. A deadline with no
      estimate is a pin only; an estimate with no deadline is on no clock.
    * **actual** — `started_at` → `completed_at`, or → now while in progress.
    * **late** — the part of the actual after the deadline.
    * **logged** — the ledger's human time entries. An entry with a clock span
      is drawn where it happened; one with only a duration is a total.

  Who a line sits on: a task for a person sits on that person. A task for a
  team or a department keeps its plan on the team's (department's) row, and
  the work on the row of whoever did it — the person who started it, and
  anyone who logged time on it. It is never copied onto every member.

  Every instant is shown on the viewer's wall clock (`PhoenixKitProjects.L10n`,
  settled per LiveView); the planned dates and times are zone-free wall clock
  already. `build/4` is pure (the tests feed it structs); `load/4` reads the
  database for the projects the viewer may see (`Hours.visible_project_uuids/1`).
  """

  import Ecto.Query

  require Logger
  require PhoenixKitProjects.Hours

  alias PhoenixKit.RepoHelper

  alias PhoenixKitProjects.{
    Activity,
    Authz,
    Extensions,
    Features,
    Hours,
    L10n,
    People,
    Projects,
    ScheduleLayout
  }

  alias PhoenixKitProjects.People.{Department, Person, Team}
  alias PhoenixKitProjects.Schemas.{Assignment, Project, Task, WorkEntry}
  alias PhoenixKitProjects.Web.Helpers, as: WebHelpers

  @work_start ~T[08:00:00]
  @work_end ~T[17:00:00]
  # A walk-back never goes further than this many working days (an estimate
  # in months would otherwise paint half a year of ghost).
  @max_walk_days 60
  # How far past the viewed range a deadline may sit and still have its
  # walked-back plan reach into it.
  @deadline_horizon_days 90
  @unscheduled_cap 500
  # Whose time the board shows: people's, with or without an account — an
  # agent's work is not anyone's day.
  @human_actor_kinds ~w(user staff_person)

  @type segment :: {NaiveDateTime.t(), NaiveDateTime.t()}
  @type row_key :: {:person | :team | :department, binary()}

  @doc "The work day the board's default axis shows and the walk-back fills."
  @spec work_hours() :: {Time.t(), Time.t()}
  def work_hours, do: {@work_start, @work_end}

  # ── Planned window ──────────────────────────────────────────────

  @doc """
  The planned window of a task as `{segments, source}`:

    * `{[seg], :explicit}` from its planned dates (`start_date`/`end_date`,
      with `start_time`/`end_time` when set, else the work day);
    * `{segs, :deadline}` — the deadline walked back by `hours` through work
      hours (`walk_back/3`);
    * `{[], nil}` — nothing to place (a deadline alone is a pin, not a plan).

  `deadline` is the viewer's wall clock (`NaiveDateTime`) or nil.
  """
  @spec planned_window(Assignment.t(), NaiveDateTime.t() | nil, number(), boolean()) ::
          {[segment()], :explicit | :deadline | nil}
  def planned_window(%Assignment{start_date: sd, end_date: ed} = a, _deadline, _hours, _weekends?)
      when not is_nil(sd) or not is_nil(ed) do
    sd = sd || ed
    ed = ed || sd
    from = NaiveDateTime.new!(sd, a.start_time || @work_start)
    to = NaiveDateTime.new!(ed, a.end_time || @work_end)

    to =
      cond do
        NaiveDateTime.compare(to, from) == :gt ->
          to

        NaiveDateTime.compare(NaiveDateTime.new!(ed, ~T[23:59:59]), from) == :gt ->
          NaiveDateTime.new!(ed, ~T[23:59:59])

        true ->
          NaiveDateTime.add(from, 3600)
      end

    {[{from, to}], :explicit}
  end

  def planned_window(_a, %NaiveDateTime{} = deadline, hours, weekends?)
      when is_number(hours) and hours > 0,
      do: {walk_back(deadline, hours, weekends?), :deadline}

  def planned_window(_a, _deadline, _hours, _weekends?), do: {[], nil}

  @doc """
  Walks `hours` of work back from `deadline` through the work day
  (08:00–17:00), skipping weekends unless `weekends?`. Returns the segments in
  time order — one when it fits the deadline's day, several when it spills
  into earlier days. A deadline after the work day counts from its end; one
  before it (or on a day off) from the previous working day's end.
  """
  @spec walk_back(NaiveDateTime.t(), number(), boolean()) :: [segment()]
  def walk_back(%NaiveDateTime{} = deadline, hours, weekends?)
      when is_number(hours) and hours > 0 do
    deadline
    |> clamp_back(weekends?)
    |> do_walk(round(hours * 60), weekends?, [], @max_walk_days)
  end

  def walk_back(_deadline, _hours, _weekends?), do: []

  defp do_walk(_cursor, minutes, _weekends?, acc, days) when minutes <= 0 or days <= 0, do: acc

  defp do_walk(cursor, minutes, weekends?, acc, days) do
    day_start = NaiveDateTime.new!(NaiveDateTime.to_date(cursor), @work_start)
    available = div(NaiveDateTime.diff(cursor, day_start), 60)

    if minutes <= available do
      [{NaiveDateTime.add(cursor, -minutes * 60), cursor} | acc]
    else
      acc = if available > 0, do: [{day_start, cursor} | acc], else: acc
      prev = previous_working_end(NaiveDateTime.to_date(cursor), weekends?)
      do_walk(prev, minutes - available, weekends?, acc, days - 1)
    end
  end

  # The latest working instant at or before `t`.
  defp clamp_back(t, weekends?) do
    date = NaiveDateTime.to_date(t)
    time = NaiveDateTime.to_time(t)

    cond do
      not working_day?(date, weekends?) -> previous_working_end(date, weekends?)
      Time.compare(time, @work_end) == :gt -> NaiveDateTime.new!(date, @work_end)
      Time.compare(time, @work_start) != :gt -> previous_working_end(date, weekends?)
      true -> t
    end
  end

  defp previous_working_end(date, weekends?) do
    prev = Date.add(date, -1)

    if working_day?(prev, weekends?),
      do: NaiveDateTime.new!(prev, @work_end),
      else: previous_working_end(prev, weekends?)
  end

  defp working_day?(_date, true), do: true
  defp working_day?(date, _), do: Date.day_of_week(date) <= 5

  # ── Building the board ─────────────────────────────────────────

  @doc """
  Builds the board from already-read data. Pure.

    * `assignments` — with `:project` and `:task` preloaded (and the assignee
      assocs when available, for names);
    * `people` — `%Person{}` rows (user preloaded) listed on the board;
    * `entries` — `%WorkEntry{}` human time entries of those assignments;
    * `opts` — `:from`, `:to` (dates, required), `:now` (UTC `DateTime`),
      `:include_idle?` (list people with nothing on the range; default true),
      `:unscheduled` (assignments with no clock), `:lang`.

  Returns `%{people: [row], groups: [row], unscheduled: %{row_key => [a]}}`;
  a row is `%{key, kind, name, person, lines}` and a line is described by
  `line/…` below (`:planned`, `:plan_source`, `:deadline`, `:actual`,
  `:live?`, `:late`, `:done_at`, `:logged`, `:overdue?`, `:rank`, `:via`,
  `:role`).
  """
  @spec build([Assignment.t()], [Person.t()], [WorkEntry.t()], keyword()) :: map()
  def build(assignments, people, entries, opts) do
    from = Keyword.fetch!(opts, :from)
    to = Keyword.fetch!(opts, :to)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    lang = Keyword.get(opts, :lang)
    now_local = local_naive(now)
    today = NaiveDateTime.to_date(now_local)

    range =
      {NaiveDateTime.new!(from, ~T[00:00:00]), NaiveDateTime.new!(Date.add(to, 1), ~T[00:00:00])}

    unscheduled_in = Keyword.get(opts, :unscheduled, [])

    # A trashed person has no row: not listed, not as an assignee, not as
    # whoever did the work.
    people = Enum.reject(people, &trashed?/1)

    # The assignees of the unscheduled tasks too: the strip counts their
    # tasks on their row, so the row must be there.
    known_people =
      (people ++
         Enum.flat_map(assignments ++ unscheduled_in, &List.wrap(loaded(&1.assigned_person))))
      |> Enum.reject(&trashed?/1)
      |> Enum.uniq_by(& &1.uuid)

    by_actor = actor_index(known_people)

    entries_by_a = Enum.group_by(entries, & &1.assignment_uuid)

    keyed_lines =
      assignments
      |> Enum.flat_map(fn a ->
        place(a, Map.get(entries_by_a, a.uuid, []), by_actor, now, lang)
      end)
      |> Enum.filter(fn {_key, line} -> relevant?(line, range, today) end)
      |> Enum.map(fn {key, line} -> {key, Map.put(line, :rank, rank(line, range))} end)

    by_key =
      keyed_lines
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {k, lines} -> {k, Enum.sort_by(lines, &line_sort_key/1)} end)

    unscheduled =
      unscheduled_in
      |> Enum.flat_map(fn a ->
        case assignee_key(a) do
          nil -> []
          key -> [{key, a}]
        end
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    people_by_uuid = Map.new(known_people, &{&1.uuid, &1})

    listed =
      if Keyword.get(opts, :include_idle?, true),
        do: Enum.map(people, &{:person, &1.uuid}),
        else: []

    person_keys =
      (listed ++
         Enum.filter(Map.keys(by_key), &match?({:person, _}, &1)) ++
         Enum.filter(Map.keys(unscheduled), &match?({:person, _}, &1)))
      |> Enum.uniq()
      |> Enum.filter(fn {:person, uuid} -> Map.has_key?(people_by_uuid, uuid) end)

    person_rows =
      person_keys
      |> Enum.map(fn {:person, uuid} = key ->
        person = Map.fetch!(people_by_uuid, uuid)

        %{
          key: key,
          kind: :person,
          name: People.display_name(person),
          person: person,
          lines: Map.get(by_key, key, [])
        }
      end)
      |> Enum.sort_by(&{&1.lines == [], String.downcase(&1.name)})

    group_names = group_names(assignments ++ unscheduled_in)

    group_rows =
      (Enum.reject(Map.keys(by_key), &match?({:person, _}, &1)) ++
         Enum.reject(Map.keys(unscheduled), &match?({:person, _}, &1)))
      |> Enum.uniq()
      |> Enum.map(fn {kind, _uuid} = key ->
        %{
          key: key,
          kind: kind,
          name: Map.get(group_names, key) || "—",
          person: nil,
          lines: Map.get(by_key, key, [])
        }
      end)
      |> Enum.sort_by(&{&1.kind != :team, String.downcase(&1.name)})

    %{people: person_rows, groups: group_rows, unscheduled: unscheduled}
  end

  @doc "An empty board (nothing visible, or a failed read)."
  @spec empty() :: map()
  def empty, do: %{people: [], groups: [], unscheduled: %{}}

  defp trashed?(%{status: "trashed"}), do: true
  defp trashed?(_person), do: false

  # Who an entry or a start names, to their person: a `"user"` actor by the
  # account, a `"staff_person"` one (time logged for a person picked from
  # the project's people) by the person.
  defp actor_index(people) do
    Enum.reduce(people, %{}, fn p, acc ->
      acc = Map.put(acc, {"staff_person", p.uuid}, p)
      if is_binary(p.user_uuid), do: Map.put(acc, {"user", p.user_uuid}, p), else: acc
    end)
  end

  defp actor_person(%WorkEntry{actor_kind: kind, actor_uuid: uuid}, by_actor),
    do: Map.get(by_actor, {kind, uuid})

  defp starter_person(%{started_by_uuid: uuid}, by_actor) when is_binary(uuid),
    do: Map.get(by_actor, {"user", uuid})

  defp starter_person(_a, _by_actor), do: nil

  # Which rows an assignment's lines go to.
  defp place(a, entries, by_actor, now, lang) do
    base = base_line(a, now, lang)

    case assignee_key(a) do
      {:person, _} = key ->
        [{key, %{base | logged: Enum.map(entries, &entry/1), role: :own}}]

      nil ->
        # Unassigned: only what someone actually did on it is anyone's time.
        a
        |> workers(entries, by_actor)
        |> Enum.map(fn {person, mine} -> worker_line(base, person, mine, a, nil) end)

      group_key ->
        workers = workers(a, entries, by_actor)
        worker_uuids = Enum.map(workers, fn {p, _} -> p.uuid end)
        placed? = &(match?(%{}, &1) and &1.uuid in worker_uuids)
        starter_placed? = placed?.(starter_person(a, by_actor))

        # Logged by someone the board can't put on a row stays on the plan line.
        stray = Enum.reject(entries, &placed?.(actor_person(&1, by_actor)))

        plan_line = %{
          base
          | actual: if(starter_placed?, do: nil, else: base.actual),
            live?: base.live? and not starter_placed?,
            late: if(starter_placed?, do: nil, else: base.late),
            logged: Enum.map(stray, &entry/1),
            role: :plan,
            worked_by: Enum.map(workers, fn {p, _} -> People.display_name(p) end)
        }

        [
          {group_key, plan_line}
          | Enum.map(workers, fn {person, mine} ->
              worker_line(base, person, mine, a, group_name(a))
            end)
        ]
    end
  end

  # The people who did work on `a`: whoever started it, and whoever logged
  # time on it — each with their own entries.
  defp workers(a, entries, by_actor) do
    loggers = Enum.map(entries, &actor_person(&1, by_actor))

    [starter_person(a, by_actor) | loggers]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.uuid)
    |> Enum.map(fn %{uuid: uuid} = p ->
      {p, Enum.filter(entries, &match?(%{uuid: ^uuid}, actor_person(&1, by_actor)))}
    end)
  end

  defp worker_line(base, person, mine, a, via) do
    starter? = is_binary(a.started_by_uuid) and a.started_by_uuid == person.user_uuid

    {{:person, person.uuid},
     %{
       base
       | planned: [],
         plan_source: nil,
         deadline: nil,
         overdue?: false,
         actual: if(starter?, do: base.actual),
         live?: starter? and base.live?,
         late: if(starter?, do: base.late),
         done_at: if(starter?, do: base.done_at),
         logged: Enum.map(mine, &entry/1),
         role: :worker,
         via: via
     }}
  end

  defp base_line(%Assignment{} = a, now, lang) do
    project = loaded(a.project)
    weekends? = if project, do: ScheduleLayout.task_counts_weekends?(a, project), else: false
    hours = if project, do: ScheduleLayout.assignment_hours(a, project), else: 0
    deadline = a.deadline && local_naive(a.deadline)
    {planned, source} = planned_window(a, deadline, hours, weekends?)
    completed = a.completed_at && local_naive(a.completed_at)
    {actual, live?} = actual_of(a, now)
    late = late_of(actual, deadline)

    %{
      id: a.uuid,
      assignment: a,
      project: project,
      title: title(a, lang),
      project_name: project && Project.localized_name(project, lang),
      status: a.status,
      planned: planned,
      plan_source: source,
      estimate_hours: hours,
      deadline: deadline,
      actual: actual,
      live?: live?,
      late: late,
      done_at: if(a.status == "done" and actual == nil, do: completed),
      logged: [],
      overdue?: Assignment.overdue?(a, now),
      role: :own,
      via: nil,
      worked_by: [],
      rank: 4
    }
  end

  # started → finished, or → now while in progress (live).
  defp actual_of(%Assignment{started_at: %DateTime{} = s, status: "in_progress"}, now),
    do: {local_span(s, now), true}

  defp actual_of(%Assignment{started_at: %DateTime{} = s, completed_at: %DateTime{} = c}, _now),
    do: {local_span(s, c), false}

  defp actual_of(_a, _now), do: {nil, false}

  # An instant span on the wall clock. Across the autumn fold the wall end
  # can sit before the wall start (03:45 summer time → 03:15 winter time is
  # 30 minutes), and the axis has only one 03:00–04:00: the span keeps its
  # real length from its wall start instead of collapsing to nothing. An end
  # before the start (bad data) is a point, as before.
  defp local_span(%DateTime{} = s, %DateTime{} = e) do
    from = local_naive(s)
    to = local_naive(e)

    if NaiveDateTime.compare(to, from) == :lt,
      do: {from, NaiveDateTime.add(from, max(DateTime.diff(e, s), 0))},
      else: {from, to}
  end

  # The part of the actual after the deadline.
  defp late_of({f, t}, %NaiveDateTime{} = d) do
    if NaiveDateTime.compare(t, d) == :gt, do: {max_naive(f, d), t}
  end

  defp late_of(_actual, _deadline), do: nil

  defp entry(%WorkEntry{} = e) do
    at = e.ended_at || e.started_at || e.inserted_at

    span =
      if e.started_at && e.ended_at && DateTime.compare(e.ended_at, e.started_at) == :gt,
        do: local_span(e.started_at, e.ended_at)

    %{
      uuid: e.uuid,
      minutes: minutes(e.amount),
      at: at && local_naive(at),
      span: span
    }
  end

  defp minutes(%Decimal{} = d), do: Decimal.to_float(d)
  defp minutes(n) when is_number(n), do: n * 1.0
  defp minutes(_), do: 0.0

  @doc """
  Whether a line has a reason to be on the range: a planned segment in it,
  its deadline in it, work done in it (actual, finish, logged time), or it is
  overdue and the range holds today.
  """
  @spec relevant?(map(), {NaiveDateTime.t(), NaiveDateTime.t()}, Date.t()) :: boolean()
  def relevant?(line, {rs, re} = range, today) do
    Enum.any?(line.planned, &overlaps?(&1, range)) or
      in_range?(line.deadline, range) or
      (line.actual != nil and overlaps?(line.actual, range)) or
      in_range?(line.done_at, range) or
      Enum.any?(line.logged, &(in_range?(&1.at, range) or (&1.span && overlaps?(&1.span, range)))) or
      (line.overdue? and in_range?(NaiveDateTime.new!(today, ~T[12:00:00]), {rs, re}))
  end

  defp rank(line, range) do
    cond do
      line.live? -> 0
      line.overdue? -> 1
      Enum.any?(line.planned, &overlaps?(&1, range)) or in_range?(line.deadline, range) -> 2
      line.status == "done" -> 3
      true -> 4
    end
  end

  defp line_sort_key(line) do
    first =
      [
        line.actual && elem(line.actual, 0),
        line.planned |> List.first() |> then(&(&1 && elem(&1, 0))),
        line.deadline,
        line.done_at
      ]
      |> Enum.find(&(&1 != nil))

    {line.rank, (first && NaiveDateTime.to_iso8601(first)) || "~", line.title}
  end

  defp overlaps?({f, t}, {rs, re}) do
    if NaiveDateTime.compare(f, t) == :eq,
      do: in_range?(f, {rs, re}),
      else: NaiveDateTime.compare(f, re) == :lt and NaiveDateTime.compare(t, rs) == :gt
  end

  defp in_range?(nil, _), do: false

  defp in_range?(t, {rs, re}),
    do: NaiveDateTime.compare(t, rs) != :lt and NaiveDateTime.compare(t, re) == :lt

  @doc "The row an assignment's plan belongs to, or nil when unassigned."
  @spec assignee_key(Assignment.t()) :: row_key() | nil
  def assignee_key(%{assigned_person_uuid: u}) when is_binary(u), do: {:person, u}
  def assignee_key(%{assigned_team_uuid: u}) when is_binary(u), do: {:team, u}
  def assignee_key(%{assigned_department_uuid: u}) when is_binary(u), do: {:department, u}
  def assignee_key(_), do: nil

  defp group_names(assignments) do
    Enum.reduce(assignments, %{}, fn a, acc ->
      case {assignee_key(a), group_name(a)} do
        {{kind, _} = key, name} when kind != :person and is_binary(name) ->
          Map.put(acc, key, name)

        _ ->
          acc
      end
    end)
  end

  defp group_name(%{assigned_team: %Team{name: n}}), do: n
  defp group_name(%{assigned_department: %Department{name: n}}), do: n
  defp group_name(_), do: nil

  @doc "A task's display title in `lang`."
  @spec title(Assignment.t(), String.t() | nil) :: String.t()
  def title(%Assignment{} = a, lang) do
    case loaded(a.task) do
      %Task{} = t -> Task.localized_title(t, lang) || t.title || "—"
      _ -> "—"
    end
  end

  defp loaded(%Ecto.Association.NotLoaded{}), do: nil
  defp loaded(other), do: other

  defp local_naive(%DateTime{} = dt), do: dt |> L10n.local() |> DateTime.to_naive()

  defp max_naive(a, b), do: if(NaiveDateTime.compare(a, b) == :lt, do: b, else: a)

  # ── Reading ────────────────────────────────────────────────────

  @doc """
  Reads and builds the board for the viewer (`scope`) over `from..to` (the
  viewer's local dates). Options: `:project_uuid` (only that project),
  `:now`, `:lang`.

  The projects read are the ones the viewer may see
  (`Hours.visible_project_uuids/1`), templates, archived projects and
  sub-project link rows excluded, tasks still in review left out. People
  with nothing on the range are listed only for a viewer who administers
  every project — anyone else sees the people their projects show.
  """
  @spec load(term(), Date.t(), Date.t(), keyword()) :: map()
  def load(scope, %Date{} = from, %Date{} = to, opts \\ []) do
    case visible(scope, Keyword.get(opts, :project_uuid)) do
      [] ->
        empty()

      projects ->
        now = Keyword.get(opts, :now, DateTime.utc_now())
        assignments = read_assignments(projects, from, to, now)
        entries = read_entries(Enum.map(assignments, & &1.uuid), from, to)
        unscheduled = read_unscheduled(projects)
        admin? = Authz.admin_all?(scope)

        # A site admin sees everyone, idle included; anyone else the people
        # their projects show — the assignees, plus whoever did the work.
        people =
          if admin?,
            do: People.list_people(preload: [:user]),
            else: workers_people(assignments, entries)

        build(assignments, people, entries,
          from: from,
          to: to,
          now: now,
          lang: Keyword.get(opts, :lang),
          unscheduled: unscheduled,
          include_idle?: admin?
        )
    end
  rescue
    e in [Postgrex.Error, DBConnection.ConnectionError, Ecto.QueryError] ->
      Logger.warning("[TimeBoard] load failed: #{Exception.message(e)}")
      empty()
  end

  # The people behind the starts and the entries: an account for a start
  # or a `"user"` entry, the person itself for a `"staff_person"` one.
  # Trashed people are left out, as the admin's list leaves them out.
  defp workers_people(assignments, entries) do
    user_uuids =
      Enum.map(assignments, & &1.started_by_uuid) ++
        for(%{actor_kind: "user", actor_uuid: u} <- entries, do: u)

    person_uuids = for %{actor_kind: "staff_person", actor_uuid: u} <- entries, do: u
    user_uuids = user_uuids |> Enum.filter(&is_binary/1) |> Enum.uniq()
    person_uuids = person_uuids |> Enum.filter(&is_binary/1) |> Enum.uniq()

    if user_uuids == [] and person_uuids == [] do
      []
    else
      from(p in Person,
        where: p.status != "trashed" and (p.user_uuid in ^user_uuids or p.uuid in ^person_uuids),
        preload: [:user]
      )
      |> RepoHelper.repo().all()
    end
  end

  defp visible(scope, project_uuid) do
    case {Hours.visible_project_uuids(scope), project_uuid} do
      {[], _} -> []
      {:all, nil} -> :all
      {:all, uuid} -> [uuid]
      {list, nil} -> list
      {list, uuid} -> if uuid in list, do: [uuid], else: []
    end
  end

  defp base_query(projects) do
    q =
      from(a in Assignment,
        join: p in Project,
        on: p.uuid == a.project_uuid,
        where:
          p.is_template == false and is_nil(p.archived_at) and a.review_status == "accepted" and
            is_nil(a.child_project_uuid)
      )

    case projects do
      :all -> q
      uuids -> where(q, [a], a.project_uuid in ^uuids)
    end
  end

  @preloads [:project, :task, :assigned_team, :assigned_department, assigned_person: :user]

  defp read_assignments(projects, from, to, now) do
    start_utc = wall_utc(NaiveDateTime.new!(from, ~T[00:00:00]))
    end_utc = wall_utc(NaiveDateTime.new!(Date.add(to, 1), ~T[00:00:00]))
    horizon = DateTime.add(end_utc, @deadline_horizon_days * 86_400, :second)
    today = L10n.local_date(now)

    cond =
      dynamic(
        [a],
        ^planned_condition(from, to, start_utc, horizon) or
          ^worked_condition(start_utc, end_utc)
      )

    cond =
      if Date.compare(from, today) != :gt and Date.compare(to, today) != :lt,
        do: dynamic([a], ^cond or (a.deadline < ^now and a.status != "done")),
        else: cond

    projects
    |> base_query()
    |> where(^cond)
    |> preload(^@preloads)
    |> RepoHelper.repo().all()
  end

  # Planned dates in the range, or a deadline whose walked-back plan may be.
  defp planned_condition(from, to, start_utc, horizon) do
    dynamic(
      [a],
      (a.start_date <= ^to and coalesce(a.end_date, a.start_date) >= ^from) or
        (is_nil(a.start_date) and a.end_date >= ^from and a.end_date <= ^to) or
        (a.deadline >= ^start_utc and a.deadline < ^horizon)
    )
  end

  # Worked on in the range: running through it, finished in it, or logged.
  defp worked_condition(start_utc, end_utc) do
    entries_in_range =
      from(e in WorkEntry,
        where: not is_nil(e.assignment_uuid),
        where: ^entry_in_range(start_utc, end_utc),
        select: e.assignment_uuid
      )

    dynamic(
      [a],
      (a.started_at < ^end_utc and
         (a.completed_at >= ^start_utc or
            (is_nil(a.completed_at) and a.status == "in_progress"))) or
        (a.completed_at >= ^start_utc and a.completed_at < ^end_utc) or
        a.uuid in subquery(entries_in_range)
    )
  end

  defp read_entries([], _from, _to), do: []

  defp read_entries(uuids, from, to) do
    start_utc = wall_utc(NaiveDateTime.new!(from, ~T[00:00:00]))
    end_utc = wall_utc(NaiveDateTime.new!(Date.add(to, 1), ~T[00:00:00]))

    RepoHelper.repo().all(
      from(e in WorkEntry,
        where: e.assignment_uuid in ^uuids,
        where: ^entry_in_range(start_utc, end_utc)
      )
    )
  end

  # A person's time entry that belongs to the range: one with a clock span
  # when the span overlaps it, any other on its work moment
  # (`Hours.work_at/1` — when the work was done, else when it was recorded,
  # as the Hours page counts it). Reading a start-less entry by when it was
  # recorded put time reported for the 28th on the 29th into no day at all.
  defp entry_in_range(start_utc, end_utc) do
    dynamic(
      [e],
      e.kind == "time" and e.actor_kind in ^@human_actor_kinds and
        ((not is_nil(e.started_at) and not is_nil(e.ended_at) and e.started_at < ^end_utc and
            e.ended_at >= ^start_utc) or
           ((is_nil(e.started_at) or is_nil(e.ended_at)) and
              Hours.work_at(e) >= ^start_utc and Hours.work_at(e) < ^end_utc))
    )
  end

  # Assigned, open, and on no clock at all: no deadline, no planned dates,
  # never started.
  defp read_unscheduled(projects) do
    projects
    |> base_query()
    |> where(
      [a],
      a.status != "done" and is_nil(a.deadline) and is_nil(a.start_date) and is_nil(a.end_date) and
        is_nil(a.started_at) and
        (not is_nil(a.assigned_person_uuid) or not is_nil(a.assigned_team_uuid) or
           not is_nil(a.assigned_department_uuid))
    )
    |> limit(@unscheduled_cap)
    |> preload(^@preloads)
    |> RepoHelper.repo().all()
  end

  defp wall_utc(%NaiveDateTime{} = naive),
    do: L10n.from_wall(naive) || DateTime.from_naive!(naive, "Etc/UTC")

  @doc """
  The projects the viewer may pick in the board's filter, `[{name, uuid}]`.
  """
  @spec project_options(term(), String.t() | nil) :: [{String.t(), binary()}]
  def project_options(scope, lang) do
    scope
    |> Projects.list_projects_for(archived: false, sort_by: :name)
    |> Enum.map(&{Project.localized_name(&1, lang), &1.uuid})
  rescue
    _ -> []
  end

  @doc """
  The projects (`%{uuid => true}`) in which the viewer may change a task's
  deadline — the task form's own check: `:edit_tasks` on the project, with
  its task list and its dates on.
  """
  @spec editable_projects(term(), [Project.t()]) :: %{binary() => boolean()}
  def editable_projects(scope, projects) do
    projects
    |> Enum.uniq_by(& &1.uuid)
    |> Map.new(&{&1.uuid, may_edit?(scope, &1)})
  end

  # The dates flag too: with it off the task form shows no deadline and
  # strips one from a save, so this page must not set one either.
  defp may_edit?(scope, %Project{is_template: false} = project),
    do:
      Authz.can?(scope, project, :edit_tasks) and Extensions.enabled?(project, "tasks") and
        Features.on?(project, "dates")

  defp may_edit?(_scope, _project), do: false

  # ── Writing ────────────────────────────────────────────────────

  @doc """
  Sets (or, with `""`, clears) a task's deadline from a `datetime-local`
  value read on the viewer's wall clock — under the task form's permission
  (`:edit_tasks` on the project, task list and dates on). Logs the change
  like the form does. A value posted back exactly as the box showed it
  writes nothing.
  """
  @spec set_deadline(term(), binary(), String.t() | nil, keyword()) ::
          {:ok, Assignment.t()} | {:error, :forbidden | :not_found | Ecto.Changeset.t()}
  def set_deadline(scope, assignment_uuid, value, opts \\ []) when is_binary(assignment_uuid) do
    with %Assignment{} = a <- Projects.get_assignment(assignment_uuid) || {:error, :not_found},
         %Project{} = project <- Projects.get_project(a.project_uuid) || {:error, :not_found},
         true <- may_edit?(scope, project) || {:error, :forbidden} do
      if unchanged_wall?(value, a.deadline),
        do: {:ok, a},
        else: write_deadline(a, project, value, opts)
    end
  end

  # The box shows the stored deadline to the minute on the viewer's wall
  # clock (the task form's `drop_unchanged_wall`): read back, the same value
  # would lose the stored seconds and, in the autumn fold's repeated hour,
  # could land on the other of the two instants it names.
  defp unchanged_wall?(value, %DateTime{} = deadline) when is_binary(value) do
    shown =
      deadline |> local_naive() |> NaiveDateTime.to_iso8601() |> String.slice(0, 16)

    value == shown
  end

  defp unchanged_wall?(_value, _deadline), do: false

  defp write_deadline(a, project, value, opts) do
    attrs =
      %{"deadline" => value || ""}
      |> WebHelpers.normalize_datetime_local_attrs(["deadline"])
      |> Map.update!("deadline", &if(&1 == "", do: nil, else: &1))

    log_opts = [
      actor_uuid: Keyword.get(opts, :actor_uuid),
      resource_type: "assignment",
      resource_uuid: a.uuid,
      metadata: %{"project" => project.name, "field" => "deadline"}
    ]

    case Projects.update_assignment_form(a, attrs) do
      {:ok, updated} ->
        Activity.log(
          "projects.assignment_updated",
          Keyword.put(log_opts, :target_uuid, Activity.assignee_target_uuid(updated))
        )

        {:ok, updated}

      {:error, cs} ->
        Activity.log_failed("projects.assignment_updated", log_opts)
        {:error, cs}
    end
  end
end
