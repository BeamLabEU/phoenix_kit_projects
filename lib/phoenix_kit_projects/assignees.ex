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

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitProjects.AssigneeSet
  alias PhoenixKitProjects.Schemas.{Assignment, AssignmentAssignee, Project}
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
    keys = AssigneeSet.keys(a)

    # The closest reach wins when a task names someone several ways (V29):
    # the person themselves, then a team of theirs, then a department.
    Enum.find_value(keys, fn
      {"person", u} -> if u == scope.person_uuid, do: :direct
      _ -> nil
    end) ||
      Enum.find_value(keys, fn
        {"team", u} -> if Map.has_key?(scope.team_names, u), do: {:team, scope.team_names[u]}
        _ -> nil
      end) ||
      Enum.find_value(keys, fn
        {"department", u} ->
          if Map.has_key?(scope.department_names, u),
            do: {:department, scope.department_names[u]}

        _ ->
          nil
      end)
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
    assignments = AssigneeSet.ensure_loaded(assignments)
    keys_of = Map.new(assignments, &{&1.uuid, People.assignee_keys(&1)})
    all = keys_of |> Map.values() |> List.flatten()

    by_person = people_by(:person, AssigneeSet.of_kind(all, "person") |> Enum.uniq())
    by_team = people_by(:team, AssigneeSet.of_kind(all, "team") |> Enum.uniq())
    by_dept = people_by(:department, AssigneeSet.of_kind(all, "department") |> Enum.uniq())
    lookup = %{"person" => by_person, "team" => by_team, "department" => by_dept}

    Enum.reduce(assignments, %{}, fn a, acc ->
      # Everyone on the task once, in chip order (V29: several assignees).
      people =
        keys_of
        |> Map.get(a.uuid, [])
        |> Enum.flat_map(fn {kind, u} -> lookup |> Map.fetch!(kind) |> Map.get(u, []) end)
        |> Enum.uniq_by(&face_id/1)

      case people do
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

  defp face_id(%{uuid: uuid}), do: uuid
  defp face_id(face), do: face

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

  defp face(%Person{uuid: uuid, name: name}, user),
    do: %{uuid: uuid, name: name || (user && user.email) || "?", user: user}

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @doc "Whether the assignment has no assignee at all (person/team/department)."
  @spec unassigned?(Assignment.t()) :: boolean()
  def unassigned?(%Assignment{} = a), do: AssigneeSet.empty?(a)

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

    {page |> Enum.map(&person_row/1) |> with_places(nil), rest != []}
  rescue
    e in [Postgrex.Error, DBConnection.ConnectionError, Ecto.QueryError] ->
      Logger.warning("[Assignees] people search failed: #{Exception.message(e)}")
      {[], false}
  end

  # ── The task form's assignee picker ─────────────────────────────────

  @doc """
  Searches people, teams and departments together for the task form's
  assignee picker (core `<.search_picker>` rows, `%{kind:, uuid:, label:,
  sublabel:, icon:}`, `kind` being `"person"`, `"team"`, `"department"` or `"user"`):
  a task goes to any one of the three, so the person typing should not have
  to say which kind first (the boss, 2026-10-29: switching the kind swapped
  the fields below without a word).

  Unlike `search_people/3` this offers everyone who is not trashed — the
  picker is where a person gets their first task. People come first, then
  teams, then departments, then — as `kind: "user"` — active accounts with
  no staff person at all (any user can be given a task; picking one makes
  their person, `People.ensure_person_for_user/2`), each name-sorted; an
  empty query is browse mode. A team or department the text matches brings
  its people right under it (Max, 2026-10-30: typing "finance" should find
  the Finance department and the people in it), each labelled with where
  they come from and listed once: a department's are those whose primary
  department it is and the members of its teams, as `faces/2` counts them.
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
      |> with_places(lang)

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

    users =
      from(u in User,
        as: :user,
        where: u.is_active == true and not coalesce(u.api_only, false),
        where: not exists(from(p in Person, where: p.user_uuid == parent_as(:user).uuid)),
        order_by: [
          asc:
            fragment(
              "lower(coalesce(nullif(trim(concat_ws(' ', ?, ?)), ''), ?))",
              u.first_name,
              u.last_name,
              u.email
            ),
          asc: u.uuid
        ],
        limit: ^(limit + 1)
      )
      |> then(fn q ->
        if pattern,
          do:
            where(
              q,
              [u],
              ilike(u.email, ^pattern) or ilike(u.first_name, ^pattern) or
                ilike(u.last_name, ^pattern)
            ),
          else: q
      end)
      |> repo().all()
      |> Enum.map(&user_row/1)

    groups =
      if pattern,
        do: with_members(teams, departments, people, lang),
        else: teams ++ departments

    {page, rest} = Enum.split(people ++ groups ++ users, limit)
    {page, rest != []}
  rescue
    e in [Postgrex.Error, DBConnection.ConnectionError, Ecto.QueryError] ->
      Logger.warning("[Assignees] assignee search failed: #{Exception.message(e)}")
      {[], false}
  end

  # ── Paged lists for the several-assignee picker ─────────────────────

  # How many of a matched team's or department's people the pickers list
  # under it.
  @members_per_group 10

  @typedoc """
  Where a paged list stopped: the phase it is in (`"team"`,
  `"department"`, `"person"`, `"user"`) and the sort key and uuid of the
  last row given. `nil` is the start.
  """
  @type cursor :: {String.t(), String.t(), String.t()} | nil

  @doc """
  One page of the picker's lists (the boss, 2026-10-31: no "Load more"
  every five people): `{:browse, kind}` lists one kind, name-sorted
  (`"person"` then also accounts with no staff record yet, as `"user"`
  rows); `{:search, text}` lists matching teams, then departments — each
  followed by its people, labelled with where they come from — then
  matching people, then matching accounts. Keyset paging on the lowercased
  name and the uuid: a row added or renamed meanwhile never shifts a page.

  Returns `{rows, next_cursor}`; `next_cursor` is nil at the end. Each row
  has `:id` (unique in the list — a person under two groups is two rows)
  besides the picker row's fields. `{[], nil}` on a failed read.
  """
  @spec page(
          {:browse, String.t()} | {:search, String.t()},
          cursor(),
          pos_integer(),
          String.t() | nil
        ) :: {[map()], cursor()}
  def page(mode, cursor, limit \\ 20, lang \\ nil) do
    limit = limit |> max(1) |> min(100)
    {phases, pattern, members?} = page_plan(mode)

    phases =
      case cursor do
        {phase, _k, _u} -> Enum.drop_while(phases, &(&1 != phase))
        nil -> phases
      end

    collect(phases, cursor, pattern, members?, limit, lang, [])
  rescue
    e in [Postgrex.Error, DBConnection.ConnectionError, Ecto.QueryError] ->
      Logger.warning("[Assignees] picker page failed: #{Exception.message(e)}")
      {[], nil}
  end

  defp page_plan({:browse, "person"}), do: {~w(person user), nil, false}
  defp page_plan({:browse, kind}) when kind in ~w(team department), do: {[kind], nil, false}
  defp page_plan({:search, text}), do: {~w(team department person user), like_pattern(text), true}

  defp collect([], _cursor, _pattern, _members?, _left, _lang, acc), do: {acc, nil}

  defp collect([phase | rest], cursor, pattern, members?, left, lang, acc) do
    after_key =
      case cursor do
        {^phase, k, u} -> {k, u}
        _ -> nil
      end

    units = phase_units(phase, pattern, after_key, left + 1, lang)
    {taken, more} = Enum.split(units, left)
    rows = unit_rows(phase, taken, members?, lang)
    acc = acc ++ rows

    cond do
      more != [] ->
        {_row, k, u} = List.last(taken)
        {acc, {phase, k, u}}

      length(taken) < left ->
        collect(rest, nil, pattern, members?, left - length(taken), lang, acc)

      # Exactly filled: the next phase may still hold rows.
      rest != [] ->
        {_row, k, u} = List.last(taken)
        {acc, {phase, k, u}}

      true ->
        {acc, nil}
    end
  end

  # Up to `n` rows of one phase after `after_key`, each `{row, key, uuid}`.
  defp phase_units("team", pattern, after_key, n, lang) do
    from(t in Team, preload: [:department])
    |> name_like(pattern)
    |> keyset(
      after_key,
      &dynamic(
        [t],
        fragment(
          "(lower(coalesce(?, '')), ?) > (?, ?)",
          t.name,
          t.uuid,
          ^elem(&1, 0),
          type(^elem(&1, 1), Ecto.UUID)
        )
      )
    )
    |> order_by([t], asc: fragment("lower(coalesce(?, ''))", t.name), asc: t.uuid)
    |> limit(^n)
    |> select([t], {t, fragment("lower(coalesce(?, ''))", t.name)})
    |> repo().all()
    |> Enum.map(fn {t, k} -> {team_row(t, lang), k, t.uuid} end)
  end

  defp phase_units("department", pattern, after_key, n, lang) do
    from(d in Department)
    |> name_like(pattern)
    |> keyset(
      after_key,
      &dynamic(
        [d],
        fragment(
          "(lower(coalesce(?, '')), ?) > (?, ?)",
          d.name,
          d.uuid,
          ^elem(&1, 0),
          type(^elem(&1, 1), Ecto.UUID)
        )
      )
    )
    |> order_by([d], asc: fragment("lower(coalesce(?, ''))", d.name), asc: d.uuid)
    |> limit(^n)
    |> select([d], {d, fragment("lower(coalesce(?, ''))", d.name)})
    |> repo().all()
    |> Enum.map(fn {d, k} -> {department_row(d, lang), k, d.uuid} end)
  end

  defp phase_units("person", pattern, after_key, n, lang) do
    rows =
      from(p in Person,
        left_join: u in assoc(p, :user),
        where: p.status != "trashed",
        order_by: [asc: fragment("lower(coalesce(?, ?, ''))", p.name, u.email), asc: p.uuid],
        limit: ^n,
        select:
          {%{uuid: p.uuid, name: p.name, email: u.email},
           fragment("lower(coalesce(?, ?, ''))", p.name, u.email)}
      )
      |> then(fn q ->
        if pattern,
          do: where(q, [p, u], ilike(p.name, ^pattern) or ilike(u.email, ^pattern)),
          else: q
      end)
      |> keyset(
        after_key,
        &dynamic(
          [p, u],
          fragment(
            "(lower(coalesce(?, ?, '')), ?) > (?, ?)",
            p.name,
            u.email,
            p.uuid,
            ^elem(&1, 0),
            type(^elem(&1, 1), Ecto.UUID)
          )
        )
      )
      |> repo().all()

    placed = rows |> Enum.map(fn {r, _k} -> person_row(r) end) |> with_places(lang)

    Enum.zip_with(rows, placed, fn {r, k}, row -> {row, k, r.uuid} end)
  end

  defp phase_units("user", pattern, after_key, n, _lang) do
    from(u in User,
      as: :user,
      where: u.is_active == true and not coalesce(u.api_only, false),
      where: not exists(from(p in Person, where: p.user_uuid == parent_as(:user).uuid)),
      order_by: [
        asc:
          fragment(
            "lower(coalesce(nullif(trim(concat_ws(' ', ?, ?)), ''), ?, ''))",
            u.first_name,
            u.last_name,
            u.email
          ),
        asc: u.uuid
      ],
      limit: ^n,
      select:
        {u,
         fragment(
           "lower(coalesce(nullif(trim(concat_ws(' ', ?, ?)), ''), ?, ''))",
           u.first_name,
           u.last_name,
           u.email
         )}
    )
    |> then(fn q ->
      if pattern,
        do:
          where(
            q,
            [u],
            ilike(u.email, ^pattern) or ilike(u.first_name, ^pattern) or
              ilike(u.last_name, ^pattern)
          ),
        else: q
    end)
    |> keyset(after_key, fn {k, id} ->
      dynamic(
        [u],
        fragment(
          "(lower(coalesce(nullif(trim(concat_ws(' ', ?, ?)), ''), ?, '')), ?) > (?, ?)",
          u.first_name,
          u.last_name,
          u.email,
          u.uuid,
          ^k,
          type(^id, Ecto.UUID)
        )
      )
    end)
    |> repo().all()
    |> Enum.map(fn {u, k} -> {user_row(u), k, u.uuid} end)
  end

  defp keyset(query, nil, _cond), do: query
  defp keyset(query, after_key, cond), do: where(query, ^cond.(after_key))

  # A page's rows: each unit as one row, a matched group followed by its
  # people. Ids are unique in the list (`group-kind-uuid`, a member's under
  # its group's).
  defp unit_rows(phase, units, members?, lang) when phase in ~w(team department) do
    groups = Enum.map(units, &elem(&1, 0))

    by_group =
      if members?,
        do: members_by(String.to_existing_atom(phase), Enum.map(groups, & &1.uuid), lang),
        else: %{}

    Enum.flat_map(groups, fn g ->
      members =
        by_group
        |> Map.get(g.uuid, [])
        |> Enum.take(@members_per_group)
        |> Enum.map(&Map.put(&1, :id, "#{g.kind}-#{g.uuid}-person-#{&1.uuid}"))

      [Map.put(g, :id, "#{g.kind}-#{g.uuid}") | members]
    end)
  end

  defp unit_rows(_phase, units, _members?, _lang),
    do: Enum.map(units, fn {row, _k, _u} -> Map.put(row, :id, "#{row.kind}-#{row.uuid}") end)

  @doc """
  One assignee as the picker shows it once chosen: its picker row plus its
  faces (`faces/2`), or nil for an unknown uuid, nothing chosen, or a failed
  read. `kind` is `"person"`, `"team"` or `"department"`.
  """
  @spec describe(String.t() | nil, String.t() | nil, String.t() | nil) :: map() | nil
  def describe(kind, uuid, lang \\ nil)

  def describe(kind, uuid, lang)
      when kind in ~w(person team department) and is_binary(uuid) and uuid != "" do
    # A uuid from the client is cast first: a malformed one would raise in
    # the query (`Ecto.Query.CastError`) and take the form down with it.
    with {:ok, uuid} <- Ecto.UUID.cast(uuid),
         row when is_map(row) <- row_for(kind, uuid, lang) do
      # A stand-in task holding just this one assignee.
      probe = %Assignment{uuid: uuid, assignee_keys: [{kind, uuid}]}
      Map.put(row, :faces, Map.get(faces([probe], 5), uuid))
    else
      _ -> nil
    end
  rescue
    e in [Postgrex.Error, DBConnection.ConnectionError, Ecto.QueryError] ->
      Logger.warning("[Assignees] assignee lookup failed: #{Exception.message(e)}")
      nil
  end

  def describe(_kind, _uuid, _lang), do: nil

  @doc """
  `describe/3` for a new pick. A trashed person is offered nowhere (the
  lists, Recent, the API), so a pick naming one — a crafted event, or a
  list row drawn before the trashing — takes nobody. An assignee already
  on a task keeps its chip through `describe/3`.
  """
  @spec describe_pick(String.t() | nil, String.t() | nil) :: map() | nil
  def describe_pick("person", uuid) do
    if trashed_person?(uuid), do: nil, else: describe("person", uuid)
  end

  def describe_pick(kind, uuid), do: describe(kind, uuid)

  defp trashed_person?(uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, id} ->
        repo().exists?(from(p in Person, where: p.uuid == ^id and p.status == "trashed"))

      _ ->
        false
    end
  rescue
    _ -> true
  end

  @doc """
  Whom a project's tasks went to lately — people, teams and departments,
  newest first, at most `limit` — as picker rows: the one-click "Recent"
  chips under the task form's assignee picker. A project with no assigned
  task yet gets whom tasks went to lately in any project, so the first
  task of a new project has suggestions too. `[]` on a failed read.
  """
  @spec recent_for_project(String.t() | nil, pos_integer(), String.t() | nil) :: [map()]
  def recent_for_project(project_uuid, limit \\ 6, lang \\ nil)

  def recent_for_project(project_uuid, limit, lang) when is_binary(project_uuid) do
    case recent_assignees(project_uuid, limit, lang) do
      [] -> recent_assignees(nil, limit, lang)
      rows -> rows
    end
  end

  def recent_for_project(_project_uuid, _limit, _lang), do: []

  # ── The viewer's own recent picks ───────────────────────────────────
  #
  # The boss, 2026-10-30: he picked a person, removed them again, and had to
  # search for them anew — "Recent" knew only whom tasks had been saved to.
  # Every pick the viewer makes in an assignee picker is remembered on their
  # account (core `custom_fields`, one internal key, merged — never a
  # whole-map replace), newest first, so a removed pick stays one press
  # away.

  @recent_key "projects_recent_assignees"
  @recent_cap 10

  @doc "The `custom_fields` key the viewer's recent picks live under."
  @spec recent_picks_key() :: String.t()
  def recent_picks_key, do: @recent_key

  @doc """
  Remembers that `user_uuid` picked the `kind` (`"person"`, `"team"`,
  `"department"`) with `uuid`: first in their list, once, at most
  #{@recent_cap} kept. Written with `Auth.merge_user_custom_fields/3`, which
  replaces this one key and leaves every other as it is. Never raises.
  """
  @spec remember_pick(String.t() | nil, String.t(), String.t()) :: :ok
  def remember_pick(user_uuid, kind, uuid)
      when is_binary(user_uuid) and kind in ~w(person team department) and is_binary(uuid) do
    case Auth.get_user(user_uuid) do
      %User{} = user ->
        entry = %{"kind" => kind, "uuid" => uuid}

        picks =
          [entry | Enum.reject(stored_picks(user), &(&1 == entry))]
          |> Enum.take(@recent_cap)

        _ =
          Auth.merge_user_custom_fields(
            user,
            %{@recent_key => picks},
            ensure_definitions: false,
            broadcast: false
          )

        :ok

      _ ->
        :ok
    end
  rescue
    e ->
      Logger.warning("[Assignees] remembering a pick failed: #{Exception.message(e)}")
      :ok
  end

  def remember_pick(_user_uuid, _kind, _uuid), do: :ok

  @doc "The viewer's remembered picks as `{kind, uuid}`, newest first."
  @spec remembered_picks(User.t() | String.t() | nil) :: [{String.t(), String.t()}]
  def remembered_picks(%User{} = user),
    do: for(%{"kind" => k, "uuid" => u} <- stored_picks(user), do: {k, u})

  def remembered_picks(user_uuid) when is_binary(user_uuid) do
    case Auth.get_user(user_uuid) do
      %User{} = user -> remembered_picks(user)
      _ -> []
    end
  rescue
    _ -> []
  end

  def remembered_picks(_), do: []

  defp stored_picks(%User{custom_fields: %{@recent_key => picks}}) when is_list(picks),
    do:
      Enum.filter(picks, fn
        %{"kind" => k, "uuid" => u} when k in ~w(person team department) and is_binary(u) -> true
        _ -> false
      end)

  defp stored_picks(_), do: []

  @doc """
  The "Recent" chips of an assignee picker for `user_uuid` on a project: the
  viewer's own picks first (`remember_pick/3`), then whom this project's
  tasks went to lately, then whom tasks went to lately anywhere — each
  listed once, at most `limit`, a pick that no longer resolves (a trashed
  person, a deleted team) left out. `[]` on a failed read.
  """
  @spec recent_for_viewer(String.t() | nil, String.t() | nil, pos_integer(), String.t() | nil) ::
          [map()]
  def recent_for_viewer(user_uuid, project_uuid, limit \\ 8, lang \\ nil) do
    own = remembered_picks(user_uuid)
    project = if is_binary(project_uuid), do: recent_keys(project_uuid), else: []
    site = recent_keys(nil)

    (own ++ project ++ site)
    |> Enum.uniq()
    |> rows_for(lang)
    |> Enum.take(limit)
  rescue
    e in [Postgrex.Error, DBConnection.ConnectionError, Ecto.QueryError] ->
      Logger.warning("[Assignees] recent picks failed: #{Exception.message(e)}")
      []
  end

  # `{kind, uuid}` keys as picker rows, in their order, in a fixed number
  # of reads however many there are (one per kind, and the people's places
  # once) — the picker asks on every mount and pick, so never a read per
  # chip. A key that no longer resolves (a trashed person, a deleted team)
  # is left out.
  defp rows_for([], _lang), do: []

  defp rows_for(keys, lang) do
    wanted = Enum.group_by(keys, &elem(&1, 0), &elem(&1, 1))

    people =
      case Map.get(wanted, "person", []) |> Enum.flat_map(&cast_uuid/1) do
        [] ->
          []

        uuids ->
          from(p in Person,
            left_join: u in assoc(p, :user),
            where: p.uuid in ^uuids and p.status != "trashed",
            select: %{uuid: p.uuid, name: p.name, email: u.email}
          )
          |> repo().all()
          |> Enum.map(&person_row/1)
          |> with_places(lang)
      end

    teams =
      case Map.get(wanted, "team", []) |> Enum.flat_map(&cast_uuid/1) do
        [] ->
          []

        uuids ->
          from(t in Team, where: t.uuid in ^uuids, preload: [:department])
          |> repo().all()
          |> Enum.map(&team_row(&1, lang))
      end

    departments =
      case Map.get(wanted, "department", []) |> Enum.flat_map(&cast_uuid/1) do
        [] ->
          []

        uuids ->
          from(d in Department, where: d.uuid in ^uuids)
          |> repo().all()
          |> Enum.map(&department_row(&1, lang))
      end

    found = Map.new(people ++ teams ++ departments, &{{&1.kind, to_string(&1.uuid)}, &1})
    for {kind, uuid} <- keys, %{} = row <- [Map.get(found, {kind, to_string(uuid)})], do: row
  end

  defp cast_uuid(uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, uuid} -> [uuid]
      :error -> []
    end
  end

  defp in_project_of_row(nil), do: dynamic(true)
  defp in_project_of_row(uuid), do: dynamic([_r, a], a.project_uuid == ^uuid)

  defp recent_assignees(project_uuid, limit, lang) do
    project_uuid
    |> recent_keys()
    |> Enum.take(limit)
    |> rows_for(lang)
  rescue
    e in [Postgrex.Error, DBConnection.ConnectionError, Ecto.QueryError] ->
      Logger.warning("[Assignees] recent assignees failed: #{Exception.message(e)}")
      []
  end

  # `{kind, uuid}` of whom a project's (nil: any project's) tasks went to
  # lately, newest first, each once.
  defp recent_keys(project_uuid) do
    # Every assignee of the recently changed tasks (V29), newest first.
    from(r in AssignmentAssignee,
      join: a in Assignment,
      on: a.uuid == r.assignment_uuid,
      where: ^in_project_of_row(project_uuid),
      order_by: [desc: a.updated_at, asc: r.position],
      limit: 200,
      select: {r.person_uuid, r.team_uuid, r.department_uuid}
    )
    |> repo().all()
    |> Enum.map(fn
      {p, _, _} when is_binary(p) -> {"person", p}
      {_, t, _} when is_binary(t) -> {"team", t}
      {_, _, d} -> {"department", d}
    end)
    |> Enum.uniq()
  end

  @doc "The assignment field that holds an assignee of `kind`."
  @spec assignee_field(String.t()) :: atom()
  def assignee_field("person"), do: :assigned_person_uuid
  def assignee_field("team"), do: :assigned_team_uuid
  def assignee_field("department"), do: :assigned_department_uuid

  defp row_for("person", uuid, lang) do
    from(p in Person,
      left_join: u in assoc(p, :user),
      where: p.uuid == ^uuid,
      select: %{uuid: p.uuid, name: p.name, email: u.email}
    )
    |> repo().one()
    |> case do
      nil -> nil
      r -> [person_row(r)] |> with_places(lang) |> hd()
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

  # A person as the pickers list them: the name (the email when there is
  # none), and under it the email and where they work. `email` and `place`
  # stay on the row for `sublabel/1` to rebuild it.
  defp person_row(r) do
    email = if r.name not in [nil, ""], do: r.email

    %{
      kind: "person",
      uuid: r.uuid,
      label: if(r.name in [nil, ""], do: r.email || "?", else: r.name),
      sublabel: email,
      email: email,
      place: nil,
      icon: "hero-user"
    }
  end

  @doc """
  The second line of a person in the pickers (the boss, 2026-10-30: "show
  their name, email, department, whatever makes the choice easier"):
  `"ann@firm.ee · Tootmine › Paigaldus"`, either part alone, or nil. Core's
  `<.search_picker>` draws one line under the label, so the two share it.
  """
  @spec sublabel(String.t() | nil, String.t() | nil) :: String.t() | nil
  def sublabel(email, place) do
    case Enum.reject([email, place], &(&1 in [nil, ""])) do
      [] -> nil
      parts -> Enum.join(parts, " · ")
    end
  end

  # Where each listed person works — their primary department, else the
  # first team they are on (with its department) — in two reads for the
  # whole page, folded into the row's second line.
  defp with_places([], _lang), do: []

  defp with_places(rows, lang) do
    uuids = for %{kind: "person", uuid: u} <- rows, do: u
    places = places_by_person(uuids, lang)

    Enum.map(rows, fn
      %{kind: "person", uuid: u} = row ->
        place = Map.get(places, u)
        %{row | place: place, sublabel: sublabel(row.email, place)}

      row ->
        row
    end)
  rescue
    e in [Postgrex.Error, DBConnection.ConnectionError, Ecto.QueryError] ->
      Logger.warning("[Assignees] places lookup failed: #{Exception.message(e)}")
      rows
  end

  defp places_by_person([], _lang), do: %{}

  defp places_by_person(uuids, lang) do
    primary =
      from(p in Person,
        join: d in Department,
        on: d.uuid == p.primary_department_uuid,
        where: p.uuid in ^uuids,
        select: {p.uuid, d}
      )
      |> repo().all()
      |> Map.new()

    teams =
      from(m in TeamMembership,
        join: t in Team,
        on: t.uuid == m.team_uuid,
        left_join: d in Department,
        on: d.uuid == t.department_uuid,
        where: m.staff_person_uuid in ^uuids,
        order_by: [asc: t.name],
        select: {m.staff_person_uuid, t, d}
      )
      |> repo().all()
      |> Enum.group_by(&elem(&1, 0), fn {_, t, d} -> {t, d} end)

    Map.new(uuids, fn uuid ->
      path =
        case {Map.get(primary, uuid), Map.get(teams, uuid, [])} do
          {nil, [{t, d} | _]} ->
            [d, t]

          {%Department{uuid: dept} = d, list} ->
            [
              d
              | list
                |> Enum.filter(fn {_t, td} -> match?(%{uuid: ^dept}, td) end)
                |> Enum.map(&elem(&1, 0))
                |> Enum.take(1)
            ]

          _ ->
            []
        end

      {uuid,
       case Enum.reject(path, &is_nil/1) do
         [] -> nil
         parts -> Enum.map_join(parts, " › ", &(People.localized_name(&1, lang) || "?"))
       end}
    end)
  end

  # Each matched team and department followed by its people, labelled with
  # where they come from ("Finance", "Finance › Payroll"); a person already
  # listed (a direct match or an earlier group) is not listed again.
  defp with_members(teams, departments, people, lang) do
    team_uuids = Enum.map(teams, & &1.uuid)
    dept_uuids = Enum.map(departments, & &1.uuid)
    by_team = members_by(:team, team_uuids, lang)
    by_dept = members_by(:department, dept_uuids, lang)
    seen = MapSet.new(people, & &1.uuid)

    {rows, _seen} =
      Enum.flat_map_reduce(teams ++ departments, seen, fn group, seen ->
        members =
          case group.kind do
            "team" -> Map.get(by_team, group.uuid, [])
            "department" -> Map.get(by_dept, group.uuid, [])
          end
          |> Enum.reject(&MapSet.member?(seen, &1.uuid))
          |> Enum.take(@members_per_group)

        {[group | members], Enum.reduce(members, seen, &MapSet.put(&2, &1.uuid))}
      end)

    rows
  end

  defp members_by(_kind, [], _lang), do: %{}

  defp members_by(:team, uuids, lang) do
    from(m in TeamMembership,
      join: p in assoc(m, :person),
      left_join: u in assoc(p, :user),
      join: t in Team,
      on: t.uuid == m.team_uuid,
      left_join: d in Department,
      on: d.uuid == t.department_uuid,
      where: m.team_uuid in ^uuids and p.status != "trashed",
      order_by: [asc: fragment("coalesce(?, ?)", p.name, u.email)],
      select: {m.team_uuid, %{uuid: p.uuid, name: p.name, email: u.email}, t, d}
    )
    |> repo().all()
    |> Enum.group_by(&elem(&1, 0), fn {_, r, t, d} -> member_row(r, [d, t], lang) end)
  end

  defp members_by(:department, uuids, lang) do
    primary =
      from(p in Person,
        left_join: u in assoc(p, :user),
        join: d in Department,
        on: d.uuid == p.primary_department_uuid,
        where: p.primary_department_uuid in ^uuids and p.status != "trashed",
        select: {d.uuid, %{uuid: p.uuid, name: p.name, email: u.email}, d, nil}
      )

    via_teams =
      from(m in TeamMembership,
        join: t in Team,
        on: t.uuid == m.team_uuid,
        join: d in Department,
        on: d.uuid == t.department_uuid,
        join: p in assoc(m, :person),
        left_join: u in assoc(p, :user),
        where: t.department_uuid in ^uuids and p.status != "trashed",
        select: {d.uuid, %{uuid: p.uuid, name: p.name, email: u.email}, d, t}
      )

    (repo().all(primary) ++ repo().all(via_teams))
    |> Enum.uniq_by(fn {dept, r, _, _} -> {dept, r.uuid} end)
    |> Enum.sort_by(fn {_, r, _, _} -> String.downcase(r.name || r.email || "") end)
    |> Enum.group_by(&elem(&1, 0), fn {_, r, d, t} -> member_row(r, [d, t], lang) end)
  end

  # A person row whose sublabel says where they were found:
  # "Finance › Payroll" (department, then team), or just one of the two.
  defp member_row(r, path, lang) do
    where =
      path
      |> Enum.reject(&is_nil/1)
      |> Enum.map_join(" › ", &(People.localized_name(&1, lang) || "?"))

    row = person_row(r)
    %{row | place: where, sublabel: sublabel(row.email, where)}
  end

  # A user with no staff person yet: picking one makes the person
  # (`People.ensure_person_for_user/2`, after the form asks).
  defp user_row(%User{} = u) do
    %{
      kind: "user",
      uuid: u.uuid,
      label: People.new_person_name(u),
      sublabel: u.email,
      icon: "hero-user"
    }
  end

  @doc """
  A user the picker may offer as `kind: "user"` — active, not a service
  account, with no staff person (trashed or not) — as its picker row, or
  nil. The form re-looks a pick up through this.
  """
  @spec describe_user(String.t() | nil) :: map() | nil
  def describe_user(uuid) when is_binary(uuid) do
    with {:ok, uuid} <- Ecto.UUID.cast(uuid),
         %User{} = user <- repo().get(User, uuid),
         true <- People.assignable_user?(user),
         false <- repo().exists?(from(p in Person, where: p.user_uuid == ^uuid)) do
      user_row(user)
    else
      _ -> nil
    end
  rescue
    e in [Postgrex.Error, DBConnection.ConnectionError, Ecto.QueryError] ->
      Logger.warning("[Assignees] user lookup failed: #{Exception.message(e)}")
      nil
  end

  def describe_user(_uuid), do: nil

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
    # Every assignee row of the relevant tasks (V29: a task has several).
    rows =
      from(r in AssignmentAssignee,
        as: :row,
        join: a in subquery(relevant_assignments(project_uuids)),
        on: a.uuid == r.assignment_uuid
      )

    direct = where(rows, [row: r], r.person_uuid == parent_as(:person).uuid)

    # Named bindings throughout, so a join never binds the wrong table.
    via_team =
      rows
      |> join(:inner, [row: r], m in TeamMembership,
        as: :membership,
        on: m.team_uuid == r.team_uuid
      )
      |> where([membership: m], m.staff_person_uuid == parent_as(:person).uuid)

    via_primary_department =
      where(rows, [row: r], r.department_uuid == parent_as(:person).primary_department_uuid)

    via_team_department =
      rows
      |> join(:inner, [row: r], t in Team,
        as: :team,
        on: t.department_uuid == r.department_uuid
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
      where: not pr.is_template,
      select: %{uuid: a.uuid}
    )
  end

  defp relevant_assignments(uuids) when is_list(uuids) do
    from(a in Assignment, where: a.project_uuid in ^uuids, select: %{uuid: a.uuid})
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
