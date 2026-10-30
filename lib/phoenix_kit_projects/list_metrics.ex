defmodule PhoenixKitProjects.ListMetrics do
  @moduledoc """
  What the projects list shows beside a project's name, read for a whole
  page of projects at once.

  The list's columns are each viewer's own choice, so most of them are not
  on screen most of the time. They are grouped into **families** — the
  reads that answer them — and `load/3` runs only the families asked for,
  each as a fixed number of statements however many projects there are
  (`test/phoenix_kit_projects/batched_list_metrics_test.exs` pins that):

    * `:tasks`    — `%{total, done, open, has_work, progress_pct, planned_end,
      subprojects}` — its own tasks; progress rolls sub-projects in
    * `:due`      — `%{overdue, next_due}` (a task's deadline)
    * `:events`   — the next event's start, where the project has one
    * `:members`  — `%{count, people: [%{uuid, name, role}]}`, oldest first
    * `:assignee` — the project's own assignee, `%{label, kind}`
    * `:ledger`   — `%{minutes, billable_minutes, ai_minutes, tokens, cost_cents}`
    * `:activity` — when anything about the project last changed
    * `:creators` — who created it (from the activity log)
    * `:parents`  — the project a sub-project sits under, `%{uuid, name}`
    * `:ext`      — the extensions' own columns (`Extensions.project_columns/2`)

  Every family answers `%{project_uuid => value}` (`:ext` a list of
  columns); a project with nothing to say is simply absent. A family that
  fails answers empty — one bad read must not take the list down.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitProjects.{Extensions, People, Projects}
  alias PhoenixKitProjects.Schemas.{Assignment, Project, ProjectEvent, ProjectMember, WorkEntry}

  @families ~w(tasks due events members assignee ledger activity creators parents ext)a

  @type family ::
          :tasks
          | :due
          | :events
          | :members
          | :assignee
          | :ledger
          | :activity
          | :creators
          | :parents
          | :ext

  @type t :: %{optional(family()) => map() | [map()]}

  @doc "Every family `load/3` knows."
  @spec families() :: [family()]
  def families, do: @families

  @doc """
  Reads `families` for `projects`. Options: `:scope` (who is looking — the
  extensions' columns are gated on it), `:today` and `:now` (pinned by
  tests).
  """
  @spec load([Project.t()], [family()], keyword()) :: t()
  def load(projects, families, opts \\ []) when is_list(projects) and is_list(families) do
    uuids = Enum.map(projects, & &1.uuid)

    families
    |> Enum.uniq()
    |> Enum.filter(&(&1 in @families))
    |> Map.new(fn family -> {family, safe(family, projects, uuids, opts)} end)
  end

  defp safe(family, projects, uuids, opts) do
    read(family, projects, uuids, opts)
  rescue
    e ->
      Logger.warning("[Projects.ListMetrics] #{family} failed: #{Exception.message(e)}")
      empty(family)
  catch
    :exit, _ -> empty(family)
  end

  defp empty(:ext), do: []
  defp empty(_family), do: %{}

  # The extensions' columns are asked for even with no projects: the picker
  # needs the columns themselves.
  defp read(:ext, _projects, uuids, opts),
    do: Extensions.project_columns(uuids, Keyword.get(opts, :scope))

  defp read(_family, _projects, [], _opts), do: %{}

  # The tree summary, not the flat one: a done task counts as 100 whatever
  # its slider says, and a sub-project's own progress rolls into its
  # parent's — the figure the project page and the dashboard cards show.
  # One read per depth level of the forest, however many projects.
  defp read(:tasks, projects, _uuids, _opts) do
    projects
    |> Projects.project_tree_summaries()
    |> Map.new(fn node ->
      {node.project.uuid,
       %{
         total: node.task_total,
         done: node.task_done,
         open: node.task_total - node.task_done,
         has_work: node.total > 0,
         progress_pct: node.progress_pct,
         planned_end: node.planned_end,
         subprojects: node.subproject_count
       }}
    end)
  end

  # A task's deadline (chain V26): how many are past it and not done, and
  # the nearest one still ahead. The planned days never make a task late.
  # A submission nobody accepted yet is not work, as everywhere the plan is
  # measured.
  defp read(:due, _projects, uuids, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    from(a in Assignment,
      where:
        a.project_uuid in ^uuids and a.status != "done" and not is_nil(a.deadline) and
          a.review_status == "accepted",
      group_by: a.project_uuid,
      select:
        {a.project_uuid, filter(count(a.uuid), a.deadline < ^now),
         filter(min(a.deadline), a.deadline >= ^now)}
    )
    |> repo().all()
    |> Map.new(fn {uuid, overdue, next_due} ->
      {uuid, %{overdue: overdue, next_due: next_due}}
    end)
  end

  defp read(:events, _projects, uuids, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    from(e in ProjectEvent,
      where: e.project_uuid in ^uuids and e.starts_at >= ^now,
      group_by: e.project_uuid,
      select: {e.project_uuid, min(e.starts_at)}
    )
    |> repo().all()
    |> Map.new()
  end

  defp read(:members, _projects, uuids, _opts) do
    from(m in ProjectMember,
      join: u in User,
      on: u.uuid == m.user_uuid,
      where: m.project_uuid in ^uuids,
      order_by: [asc: m.inserted_at],
      select: {m.project_uuid, m.role, u}
    )
    |> repo().all()
    |> Enum.group_by(&elem(&1, 0))
    |> Map.new(fn {uuid, rows} ->
      people =
        Enum.map(rows, fn {_p, role, user} ->
          %{uuid: user.uuid, name: user_name(user), role: role}
        end)

      {uuid, %{count: length(people), people: people}}
    end)
  end

  # The project's OWN assignee (a team, a department or a person), named
  # through the People doorway — one read per kind in use, never per row.
  defp read(:assignee, projects, _uuids, _opts) do
    teams = People.names_by_uuid(:team, pluck(projects, :assigned_team_uuid))
    departments = People.names_by_uuid(:department, pluck(projects, :assigned_department_uuid))
    people = People.person_names(pluck(projects, :assigned_person_uuid))

    for p <- projects, assignee = assignee_of(p, teams, departments, people), into: %{} do
      {p.uuid, assignee}
    end
  end

  # People's time and an agent's are kept apart, as on the project page:
  # `minutes` is people's, `ai_minutes` an agent's own report.
  defp read(:ledger, _projects, uuids, _opts) do
    from(e in WorkEntry,
      where: e.project_uuid in ^uuids,
      group_by: [e.project_uuid, e.kind, e.billable, e.actor_kind],
      select: {e.project_uuid, e.kind, e.billable, e.actor_kind, sum(e.amount)}
    )
    |> repo().all()
    |> Enum.reduce(%{}, fn {uuid, kind, billable, actor_kind, sum}, acc ->
      Map.update(
        acc,
        uuid,
        add_ledger(empty_ledger(), kind, billable, actor_kind, sum),
        &add_ledger(&1, kind, billable, actor_kind, sum)
      )
    end)
  end

  # The latest of: the project row, any of its tasks, any ledger entry.
  defp read(:activity, projects, uuids, _opts) do
    tasks =
      from(a in Assignment,
        where: a.project_uuid in ^uuids,
        group_by: a.project_uuid,
        select: {a.project_uuid, max(a.updated_at)}
      )
      |> repo().all()
      |> Map.new()

    entries =
      from(e in WorkEntry,
        where: e.project_uuid in ^uuids,
        group_by: e.project_uuid,
        select: {e.project_uuid, max(e.inserted_at)}
      )
      |> repo().all()
      |> Map.new()

    Map.new(projects, fn p ->
      latest =
        [p.updated_at, Map.get(tasks, p.uuid), Map.get(entries, p.uuid)]
        |> Enum.reject(&is_nil/1)
        |> Enum.max(DateTime, fn -> nil end)

      {p.uuid, latest}
    end)
  end

  defp read(:creators, _projects, uuids, _opts) do
    Projects.creation_actors(uuids, [
      "projects.project_created",
      "projects.project_created_from_template"
    ])
  end

  # Only a parent the viewer may open: a project's name is information
  # (`Crumbs.viewable_chain/2`'s rule), and someone who holds the
  # sub-project alone must not read its parent's off the list. The answer
  # is asked once per distinct parent, not per row.
  defp read(:parents, _projects, uuids, opts) do
    scope = Keyword.get(opts, :scope)

    rows =
      from(a in Assignment,
        join: p in Project,
        on: p.uuid == a.project_uuid,
        where: a.child_project_uuid in ^uuids,
        select: {a.child_project_uuid, p}
      )
      |> repo().all()

    viewable =
      rows
      |> Enum.map(&elem(&1, 1))
      |> Enum.uniq_by(& &1.uuid)
      |> Enum.filter(&PhoenixKitProjects.Authz.can?(scope, &1, :view))
      |> MapSet.new(& &1.uuid)

    for {child, parent} <- rows,
        MapSet.member?(viewable, parent.uuid),
        into: %{},
        do: {child, parent}
  end

  defp pluck(projects, field) do
    projects |> Enum.map(&Map.get(&1, field)) |> Enum.reject(&is_nil/1) |> Enum.uniq()
  end

  defp assignee_of(%Project{assigned_team_uuid: uuid}, teams, _departments, _people)
       when is_binary(uuid),
       do: named(Map.get(teams, uuid), :team)

  defp assignee_of(%Project{assigned_department_uuid: uuid}, _teams, departments, _people)
       when is_binary(uuid),
       do: named(Map.get(departments, uuid), :department)

  defp assignee_of(%Project{assigned_person_uuid: uuid}, _teams, _departments, people)
       when is_binary(uuid),
       do: named(Map.get(people, uuid), :person)

  defp assignee_of(_project, _teams, _departments, _people), do: nil

  defp named(nil, _kind), do: nil
  defp named(label, kind), do: %{label: label, kind: kind}

  defp empty_ledger,
    do: %{minutes: 0.0, billable_minutes: 0.0, ai_minutes: 0.0, tokens: 0.0, cost_cents: 0.0}

  defp add_ledger(acc, kind, billable, actor_kind, sum) do
    sum = Decimal.to_float(sum)

    case {kind, actor_kind} do
      {"time", "ai_agent"} ->
        Map.update!(acc, :ai_minutes, &(&1 + sum))

      {"time", _} ->
        acc = Map.update!(acc, :minutes, &(&1 + sum))
        if billable, do: Map.update!(acc, :billable_minutes, &(&1 + sum)), else: acc

      {"tokens", _} ->
        Map.update!(acc, :tokens, &(&1 + sum))

      {"cost", _} ->
        Map.update!(acc, :cost_cents, &(&1 + sum))

      _ ->
        acc
    end
  end

  defp user_name(user) do
    case User.full_name(user) do
      name when is_binary(name) and name != "" -> name
      _ -> user.email
    end
  end

  defp repo, do: RepoHelper.repo()
end
