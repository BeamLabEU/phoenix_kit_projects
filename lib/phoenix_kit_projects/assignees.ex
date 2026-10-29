defmodule PhoenixKitProjects.Assignees do
  @moduledoc """
  The single resolver for "whose work is this?" questions against the
  polymorphic assignment assignee (person OR team OR department).

  A person's **effective scope** is themselves plus one level of inherited
  membership: the teams they belong to (staff `TeamMembership`) and the
  departments those teams sit in plus their own primary department. One level
  only, by design — transitive roll-ups (team of team, parent departments)
  don't exist in the staff model and would be guesswork here.

  `match/2` answers whether an assignment falls in a scope and HOW — `:direct`
  or `{:team, name}` / `{:department, name}` — so UIs can show provenance
  ("via Engineering") instead of implying personal ownership. Consumers pick
  their semantics: inherited = any match; direct-only = `:direct` matches.

  Built for the Overview calendar's assignee filter, but deliberately
  UI-agnostic: any future per-person surface (widgets, queues, a staff-side
  consumer via an events contract) should resolve through this module rather
  than re-deriving membership joins — the panel-review risk was exactly this
  logic drifting between call sites.

  Staff reads are rescued to safe defaults (same convention as
  `Projects.list_assignments_for_user/1`) — an assignee filter must never
  crash the dashboard.
  """

  use Gettext, backend: PhoenixKitProjects.Gettext

  import Ecto.Query

  alias PhoenixKitProjects.Schemas.{Assignment, Project}
  # SHADOW schemas + the People doorway (staff-optional seam) — the
  # direct Ecto queries below run over projects' own read-only mappings
  # of the core-owned staff tables; the staff PACKAGE is not required.
  alias PhoenixKitProjects.People
  alias PhoenixKitProjects.People.{Department, Person, Team, TeamMembership}

  require Logger

  @typedoc """
  A resolved person scope: the person plus their one-level memberships, with
  display names captured for provenance labels.
  """
  @type scope :: %{
          person_uuid: String.t(),
          person_name: String.t(),
          team_names: %{optional(String.t()) => String.t()},
          department_names: %{optional(String.t()) => String.t()}
        }

  @doc """
  Builds the effective scope for a staff person: their uuid, their teams
  (via memberships), and their departments (the teams' departments + their
  primary department). Names are localized to `lang` for provenance labels.

  Returns `nil` when the person doesn't exist (or the staff read fails).
  """
  @spec scope_for_person(String.t(), String.t() | nil) :: scope() | nil
  def scope_for_person(person_uuid, lang \\ nil) when is_binary(person_uuid) do
    case People.get_person(person_uuid, preload: [:user, :primary_department]) do
      nil -> nil
      person -> build_scope(person, lang)
    end
  rescue
    e in [Postgrex.Error, DBConnection.ConnectionError, Ecto.QueryError] ->
      Logger.warning(
        "[Assignees] staff lookup failed for #{person_uuid}: #{Exception.message(e)}"
      )

      nil
  end

  @doc """
  The scope for the CURRENT USER (auth uuid → staff person), or `nil` when
  they have no staff person. Backs the filter's "Me" shortcut.
  """
  @spec scope_for_user(String.t() | nil, String.t() | nil) :: scope() | nil
  def scope_for_user(nil, _lang), do: nil

  def scope_for_user(user_uuid, lang) when is_binary(user_uuid) do
    case People.get_person_by_user_uuid(user_uuid, preload: []) do
      nil -> nil
      person -> scope_for_person(person.uuid, lang)
    end
  rescue
    e in [Postgrex.Error, DBConnection.ConnectionError, Ecto.QueryError] ->
      Logger.warning(
        "[Assignees] staff lookup failed for user #{user_uuid}: #{Exception.message(e)}"
      )

      nil
  end

  @doc """
  How `assignment` falls inside `scope`:

    * `:direct` — assigned to the person themselves
    * `{:team, name}` — assigned to a team the person belongs to
    * `{:department, name}` — assigned to a department in the person's scope
    * `nil` — outside the scope

  Direct-only consumers accept only `:direct`; inherited consumers accept any
  non-nil result (and can show the tuple's name as provenance).
  """
  @spec match(Assignment.t(), scope()) ::
          :direct | {:team, String.t()} | {:department, String.t()} | nil
  def match(%Assignment{} = a, scope) do
    cond do
      a.assigned_person_uuid && a.assigned_person_uuid == scope.person_uuid ->
        :direct

      a.assigned_team_uuid && Map.has_key?(scope.team_names, a.assigned_team_uuid) ->
        {:team, Map.fetch!(scope.team_names, a.assigned_team_uuid)}

      a.assigned_department_uuid &&
          Map.has_key?(scope.department_names, a.assigned_department_uuid) ->
        {:department, Map.fetch!(scope.department_names, a.assigned_department_uuid)}

      true ->
        nil
    end
  end

  @typedoc "Who an assignee is, as faces: up to `max` people and how many more."
  @type faces :: %{faces: [%{name: String.t(), user: struct() | nil}], extra: non_neg_integer()}

  @doc """
  The faces behind each assignment's assignee, for showing who has what at
  a glance (the boss, 2026-10-29): a person is themselves; a team is its
  members; a department is the people whose primary department it is and
  the members of its teams. One query per kind for the whole list.

  Returns `%{assignment_uuid => faces}` for the assigned rows only, each
  holding up to `max` people (named, with their user for the picture when
  they have one) and the count left over. A failed staff read gives `%{}`:
  faces are decoration and must never take a page down.
  """
  @spec faces([Assignment.t()], pos_integer()) :: %{optional(String.t()) => faces()}
  def faces(assignments, max \\ 4) do
    persons = assignments |> Enum.map(& &1.assigned_person_uuid) |> Enum.reject(&is_nil/1)
    teams = assignments |> Enum.map(& &1.assigned_team_uuid) |> Enum.reject(&is_nil/1)
    depts = assignments |> Enum.map(& &1.assigned_department_uuid) |> Enum.reject(&is_nil/1)

    by_person = people_by(:person, persons)
    by_team = people_by(:team, teams)
    by_dept = people_by(:department, depts)

    Enum.reduce(assignments, %{}, fn a, acc ->
      case assignee_people(a, by_person, by_team, by_dept) do
        [] ->
          acc

        people ->
          {shown, rest} = Enum.split(people, max)
          Map.put(acc, a.uuid, %{faces: shown, extra: length(rest)})
      end
    end)
  rescue
    e in [Postgrex.Error, DBConnection.ConnectionError, Ecto.QueryError] ->
      Logger.warning("[Assignees] faces failed: #{Exception.message(e)}")
      %{}
  end

  defp assignee_people(%{assigned_person_uuid: u}, by_person, _, _) when is_binary(u),
    do: Map.get(by_person, u, [])

  defp assignee_people(%{assigned_team_uuid: u}, _, by_team, _) when is_binary(u),
    do: Map.get(by_team, u, [])

  defp assignee_people(%{assigned_department_uuid: u}, _, _, by_dept) when is_binary(u),
    do: Map.get(by_dept, u, [])

  defp assignee_people(_, _, _, _), do: []

  defp people_by(_kind, []), do: %{}

  defp people_by(:person, uuids) do
    from(p in Person,
      left_join: u in assoc(p, :user),
      where: p.uuid in ^uuids,
      select: {p.uuid, p, u}
    )
    |> repo().all()
    |> Map.new(fn {uuid, p, u} -> {uuid, [face(p, u)]} end)
  end

  defp people_by(:team, uuids) do
    from(m in TeamMembership,
      join: p in assoc(m, :person),
      left_join: u in assoc(p, :user),
      where: m.team_uuid in ^uuids and p.status != "trashed",
      order_by: [asc: p.name],
      select: {m.team_uuid, p, u}
    )
    |> repo().all()
    |> group_faces()
  end

  defp people_by(:department, uuids) do
    primary =
      from(p in Person,
        left_join: u in assoc(p, :user),
        where: p.primary_department_uuid in ^uuids and p.status != "trashed",
        select: {p.primary_department_uuid, p, u}
      )

    via_teams =
      from(m in TeamMembership,
        join: t in Team,
        on: t.uuid == m.team_uuid,
        join: p in assoc(m, :person),
        left_join: u in assoc(p, :user),
        where: t.department_uuid in ^uuids and p.status != "trashed",
        select: {t.department_uuid, p, u}
      )

    (repo().all(primary) ++ repo().all(via_teams))
    |> Enum.uniq_by(fn {dept, p, _u} -> {dept, p.uuid} end)
    |> Enum.sort_by(fn {_dept, p, _u} -> p.name || "" end)
    |> group_faces()
  end

  defp group_faces(rows) do
    Enum.group_by(rows, &elem(&1, 0), fn {_key, p, u} -> face(p, u) end)
  end

  defp face(%Person{name: name}, user),
    do: %{name: name || (user && user.email) || "?", user: user}

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @doc "Whether the assignment has no assignee at all (person/team/department)."
  @spec unassigned?(Assignment.t()) :: boolean()
  def unassigned?(%Assignment{} = a) do
    is_nil(a.assigned_person_uuid) and is_nil(a.assigned_team_uuid) and
      is_nil(a.assigned_department_uuid)
  end

  @doc """
  Searches people for the assignee picker (core `<.search_picker>` contract):
  name/email typeahead, LIMITed at the database (limit+1 probes `has_more` for
  the picker's Load more), trashed people excluded. An empty query is browse
  mode — the first page, name-sorted — per the workspace picker rule that a
  picker must offer options before any typing.

  **Only relevant people are offered**: someone at least one non-template
  assignment points at — directly, via a team they belong to, or via a
  department in their one-level scope (their teams' departments + their
  primary department). A person no task has ever touched would only ever
  filter the calendar to an empty month, so the picker doesn't suggest them
  (and on a fresh install with no projects it correctly offers nobody).
  `opts[:project_uuids]` narrows relevance to assignments of the given
  projects — the per-project Calendar tab passes its rendered tree so the
  picker offers only that project's people.

  Returns `{rows, has_more}` where each row is the picker's
  `%{kind:, uuid:, label:, sublabel:, icon:}` shape. `{[], false}` on a
  failed staff read. `opts[:exclude]` drops the given person uuids at the
  database (already-picked chips shouldn't reappear as suggestions) without
  disturbing the page/`has_more` math.

  Queries the staff `Person` schema directly (already a hard schema dep via
  the assignment FKs) because the staff context's `list_people/1` has no
  LIMIT — the whole point here is not loading 1000 people per keystroke.
  """
  @spec search_people(String.t() | nil, pos_integer(), keyword()) :: {[map()], boolean()}
  def search_people(query, limit \\ 8, opts \\ []) do
    limit = limit |> max(1) |> min(50)
    q = query |> to_string() |> String.trim()
    exclude = Keyword.get(opts, :exclude, [])
    project_uuids = Keyword.get(opts, :project_uuids)

    base =
      from(p in Person,
        as: :person,
        left_join: u in assoc(p, :user),
        where: p.status != "trashed" and p.uuid not in ^exclude,
        where: ^relevance_condition(project_uuids),
        order_by: [asc: fragment("coalesce(?, ?)", p.name, u.email), asc: p.uuid],
        limit: ^(limit + 1),
        select: %{uuid: p.uuid, name: p.name, email: u.email}
      )

    rows =
      if q == "" do
        base
      else
        escaped =
          q
          |> String.replace("\\", "\\\\")
          |> String.replace("%", "\\%")
          |> String.replace("_", "\\_")

        pattern = "%#{escaped}%"
        where(base, [p, u], ilike(p.name, ^pattern) or ilike(u.email, ^pattern))
      end
      |> PhoenixKit.RepoHelper.repo().all()

    {page, rest} = Enum.split(rows, limit)

    picker_rows =
      Enum.map(page, fn r ->
        label = r.name || r.email || "?"

        %{
          kind: "person",
          uuid: r.uuid,
          label: label,
          sublabel: if(r.name && r.email, do: r.email),
          icon: "hero-user"
        }
      end)

    {picker_rows, rest != []}
  rescue
    e in [Postgrex.Error, DBConnection.ConnectionError, Ecto.QueryError] ->
      Logger.warning("[Assignees] people search failed: #{Exception.message(e)}")
      {[], false}
  end

  # ── The task form's assignee picker ─────────────────────────────────

  @doc """
  Searches people, teams and departments together for the task form's
  assignee picker (core `<.search_picker>` rows, `%{kind:, uuid:, label:,
  sublabel:, icon:}`, `kind` being `"person"`, `"team"` or `"department"`):
  a task goes to any one of the three, so the person typing should not have
  to say which kind first (the boss, 2026-10-29: switching the kind swapped
  the fields below without a word).

  Unlike `search_people/3` this offers everyone who is not trashed — the
  picker is where a person gets their first task. People come first, then
  teams, then departments, each name-sorted; an empty query is browse mode.
  Returns `{rows, has_more}`, `{[], false}` on a failed staff read.
  """
  @spec search_assignees(String.t() | nil, pos_integer(), String.t() | nil) ::
          {[map()], boolean()}
  def search_assignees(query, limit \\ 20, lang \\ nil) do
    limit = limit |> max(1) |> min(100)
    pattern = like_pattern(query)

    people =
      from(p in Person,
        left_join: u in assoc(p, :user),
        where: p.status != "trashed",
        order_by: [asc: fragment("coalesce(?, ?)", p.name, u.email), asc: p.uuid],
        limit: ^(limit + 1),
        select: %{uuid: p.uuid, name: p.name, email: u.email}
      )
      |> then(fn q ->
        if pattern,
          do: where(q, [p, u], ilike(p.name, ^pattern) or ilike(u.email, ^pattern)),
          else: q
      end)
      |> repo().all()
      |> Enum.map(&person_row/1)

    teams =
      from(t in Team, order_by: [asc: t.name], limit: ^(limit + 1), preload: [:department])
      |> name_like(pattern)
      |> repo().all()
      |> Enum.map(&team_row(&1, lang))

    departments =
      from(d in Department, order_by: [asc: d.name], limit: ^(limit + 1))
      |> name_like(pattern)
      |> repo().all()
      |> Enum.map(&department_row(&1, lang))

    {page, rest} = Enum.split(people ++ teams ++ departments, limit)
    {page, rest != []}
  rescue
    e in [Postgrex.Error, DBConnection.ConnectionError, Ecto.QueryError] ->
      Logger.warning("[Assignees] assignee search failed: #{Exception.message(e)}")
      {[], false}
  end

  @doc """
  One assignee as the picker shows it once chosen: its picker row plus its
  faces (`faces/2`), or nil for an unknown uuid, nothing chosen, or a failed
  read. `kind` is `"person"`, `"team"` or `"department"`.
  """
  @spec describe(String.t() | nil, String.t() | nil, String.t() | nil) :: map() | nil
  def describe(kind, uuid, lang \\ nil)

  def describe(kind, uuid, lang)
      when kind in ~w(person team department) and is_binary(uuid) and uuid != "" do
    case row_for(kind, uuid, lang) do
      nil ->
        nil

      row ->
        probe = struct(Assignment, [{:uuid, "chosen"}, {assignee_field(kind), uuid}])
        Map.put(row, :faces, Map.get(faces([probe], 5), "chosen"))
    end
  rescue
    e in [Postgrex.Error, DBConnection.ConnectionError, Ecto.QueryError] ->
      Logger.warning("[Assignees] assignee lookup failed: #{Exception.message(e)}")
      nil
  end

  def describe(_kind, _uuid, _lang), do: nil

  @doc """
  Whom a project's tasks went to lately — people, teams and departments,
  newest first, at most `limit` — as picker rows: the one-click "Recent"
  chips under the task form's assignee picker. `[]` on a failed read.
  """
  @spec recent_for_project(String.t() | nil, pos_integer(), String.t() | nil) :: [map()]
  def recent_for_project(project_uuid, limit \\ 6, lang \\ nil)

  def recent_for_project(project_uuid, limit, lang) when is_binary(project_uuid) do
    from(a in Assignment,
      where: a.project_uuid == ^project_uuid,
      where:
        not is_nil(a.assigned_person_uuid) or not is_nil(a.assigned_team_uuid) or
          not is_nil(a.assigned_department_uuid),
      order_by: [desc: a.updated_at],
      limit: 100,
      select: {a.assigned_person_uuid, a.assigned_team_uuid, a.assigned_department_uuid}
    )
    |> repo().all()
    |> Enum.map(fn
      {p, _, _} when is_binary(p) -> {"person", p}
      {_, t, _} when is_binary(t) -> {"team", t}
      {_, _, d} -> {"department", d}
    end)
    |> Enum.uniq()
    |> Enum.take(limit)
    |> Enum.map(fn {kind, uuid} -> row_for(kind, uuid, lang) end)
    |> Enum.reject(&is_nil/1)
  rescue
    e in [Postgrex.Error, DBConnection.ConnectionError, Ecto.QueryError] ->
      Logger.warning("[Assignees] recent assignees failed: #{Exception.message(e)}")
      []
  end

  def recent_for_project(_project_uuid, _limit, _lang), do: []

  @doc "The assignment field that holds an assignee of `kind`."
  @spec assignee_field(String.t()) :: atom()
  def assignee_field("person"), do: :assigned_person_uuid
  def assignee_field("team"), do: :assigned_team_uuid
  def assignee_field("department"), do: :assigned_department_uuid

  defp row_for("person", uuid, _lang) do
    from(p in Person,
      left_join: u in assoc(p, :user),
      where: p.uuid == ^uuid,
      select: %{uuid: p.uuid, name: p.name, email: u.email}
    )
    |> repo().one()
    |> case do
      nil -> nil
      r -> person_row(r)
    end
  end

  defp row_for("team", uuid, lang) do
    case repo().one(from(t in Team, where: t.uuid == ^uuid, preload: [:department])) do
      nil -> nil
      t -> team_row(t, lang)
    end
  end

  defp row_for("department", uuid, lang) do
    case repo().get(Department, uuid) do
      nil -> nil
      d -> department_row(d, lang)
    end
  end

  defp person_row(r) do
    %{
      kind: "person",
      uuid: r.uuid,
      label: r.name || r.email || "?",
      sublabel: if(r.name && r.email, do: r.email),
      icon: "hero-user"
    }
  end

  defp team_row(t, lang) do
    dept = if match?(%Department{}, t.department), do: People.localized_name(t.department, lang)

    %{
      kind: "team",
      uuid: t.uuid,
      label: People.localized_name(t, lang) || "?",
      sublabel:
        if(dept, do: gettext("Team · %{department}", department: dept), else: gettext("Team")),
      icon: "hero-user-group"
    }
  end

  defp department_row(d, lang) do
    %{
      kind: "department",
      uuid: d.uuid,
      label: People.localized_name(d, lang) || "?",
      sublabel: gettext("Department"),
      icon: "hero-building-office-2"
    }
  end

  defp like_pattern(query) do
    case query |> to_string() |> String.trim() do
      "" ->
        nil

      q ->
        escaped =
          q
          |> String.replace("\\", "\\\\")
          |> String.replace("%", "\\%")
          |> String.replace("_", "\\_")

        "%#{escaped}%"
    end
  end

  defp name_like(query, nil), do: query
  defp name_like(query, pattern), do: where(query, [x], ilike(x.name, ^pattern))

  # The four ways an assignment can point at `:person` — each an EXISTS the
  # planner can short-circuit, OR'd into one condition for the picker query.
  # Mirrors `match/2`'s one-level inheritance: direct, a team the person
  # belongs to, or a department in their scope (primary + their teams').
  defp relevance_condition(project_uuids) do
    assignments = relevant_assignments(project_uuids)

    direct = where(assignments, [a], a.assigned_person_uuid == parent_as(:person).uuid)

    # Named bindings throughout: `assignments` may already carry a joined
    # Project, so positional `[a, m]` would silently bind m to it.
    via_team =
      assignments
      |> join(:inner, [a], m in TeamMembership,
        as: :membership,
        on: m.team_uuid == a.assigned_team_uuid
      )
      |> where([membership: m], m.staff_person_uuid == parent_as(:person).uuid)

    via_primary_department =
      where(
        assignments,
        [a],
        a.assigned_department_uuid == parent_as(:person).primary_department_uuid
      )

    via_team_department =
      assignments
      |> join(:inner, [a], t in Team,
        as: :team,
        on: t.department_uuid == a.assigned_department_uuid
      )
      |> join(:inner, [team: t], m in TeamMembership,
        as: :membership,
        on: m.team_uuid == t.uuid
      )
      |> where([membership: m], m.staff_person_uuid == parent_as(:person).uuid)

    dynamic(
      exists(subquery(direct)) or exists(subquery(via_team)) or
        exists(subquery(via_primary_department)) or exists(subquery(via_team_department))
    )
  end

  # Scoped: the given projects' assignments count VERBATIM — no template
  # exclusion, deliberately: the per-project Calendar tab passes exactly its
  # rendered tree (sub-projects included), and when that tree IS a template
  # (direct `/calendar` URL or a host embed) its default assignees are
  # precisely the people on screen. Unscoped: any non-template project's —
  # template defaults alone don't make a person globally filterable on the
  # Overview.
  defp relevant_assignments(nil) do
    from(a in Assignment,
      join: pr in Project,
      on: pr.uuid == a.project_uuid,
      where: not pr.is_template
    )
  end

  defp relevant_assignments(uuids) when is_list(uuids) do
    from(a in Assignment, where: a.project_uuid in ^uuids)
  end

  defp build_scope(person, lang) do
    memberships =
      try do
        People.list_memberships_for_person(person.uuid)
      rescue
        e in [Postgrex.Error, DBConnection.ConnectionError, Ecto.QueryError] ->
          Logger.warning(
            "[Assignees] memberships lookup failed for #{person.uuid}: #{Exception.message(e)}"
          )

          []
      end

    teams = memberships |> Enum.map(& &1.team) |> Enum.reject(&is_nil/1)

    team_names =
      Map.new(teams, fn t -> {t.uuid, People.localized_name(t, lang)} end)

    departments =
      teams
      |> Enum.map(& &1.department)
      |> Enum.reject(&is_nil/1)
      |> then(fn deps ->
        case person.primary_department do
          %{} = d -> [d | deps]
          _ -> deps
        end
      end)

    department_names =
      Map.new(departments, fn d ->
        {d.uuid, People.localized_name(d, lang)}
      end)

    %{
      person_uuid: person.uuid,
      person_name: People.display_name(person),
      team_names: team_names,
      department_names: department_names
    }
  end
end
