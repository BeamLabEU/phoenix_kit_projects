defmodule PhoenixKitProjects.AssigneeSet do
  @moduledoc """
  A task's assignees (chain V29) — and a project's and a library task's
  default ones (V30): any number of staff people, teams and departments,
  all equal — one shared status, and everyone (a team's and a
  department's members too) is told. There is no main assignee.

  The three holders (`holder/1`): an `%Assignment{}` (rows in
  `AssignmentAssignee`, mirror `assigned_*`), a `%Project{}`
  (`ProjectAssignee`, mirror `assigned_*`) and a library `%Task{}`
  (`TaskDefaultAssignee`, mirror `default_assigned_*`). A plain map is
  read as a task's.

  A set is a list of keys, `{kind, uuid}` with `kind` one of `"person"`,
  `"team"`, `"department"`, in chip order. It is stored as
  `Schemas.AssignmentAssignee` rows and written only through
  `Assignment.changeset/2` (`"assignees"` — see `fetch_param/1`), which also
  keeps the task's three `assigned_*` columns as a one-assignee mirror:
  the assignee while there is exactly one, all empty otherwise.

  Read a set with `keys/1`. Loaded rows (`preload/1`) are used as they
  are; without them a filled mirror IS the set, and an empty mirror (none,
  or several) is looked up — so a reader is never wrong, only slower,
  when a caller forgot the preload. SQL filters use `subject_exists/2`.
  """

  use Gettext, backend: PhoenixKitProjects.Gettext

  import Ecto.Query

  alias PhoenixKitProjects.Schemas.{
    Assignment,
    AssignmentAssignee,
    Project,
    ProjectAssignee,
    Task,
    TaskDefaultAssignee
  }

  @type kind :: String.t()
  @type key :: {kind(), String.t()}

  @kinds ~w(person team department)

  @doc "The three kinds an assignee can be."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  # ── Reading ────────────────────────────────────────────────────────

  @doc """
  The task's assignees as `[{kind, uuid}]`, in chip order. Takes an
  `%Assignment{}` or any map carrying `:uuid` and the three `assigned_*`
  fields (a plain-map query result).
  """
  @spec keys(map() | nil) :: [key()]
  def keys(nil), do: []

  # Just written: the changeset's own set (a saved struct keeps the rows it
  # was loaded with, which the save has replaced).
  def keys(%{assignee_keys: keys}) when is_list(keys), do: keys

  def keys(%{assignee_links: links}) when is_list(links), do: Enum.map(links, &link_key/1)

  def keys(%{} = a) do
    case legacy_keys(a) do
      [] -> lookup(holder(a), Map.get(a, :uuid))
      keys -> keys
    end
  end

  @doc "The keys of the one-assignee mirror (`assigned_*`): `[]` or one key."
  @spec legacy_keys(map()) :: [key()]
  def legacy_keys(%Task{} = t) do
    [
      {"person", t.default_assigned_person_uuid},
      {"team", t.default_assigned_team_uuid},
      {"department", t.default_assigned_department_uuid}
    ]
    |> Enum.filter(fn {_k, uuid} -> is_binary(uuid) end)
  end

  def legacy_keys(a) do
    [
      {"person", Map.get(a, :assigned_person_uuid)},
      {"team", Map.get(a, :assigned_team_uuid)},
      {"department", Map.get(a, :assigned_department_uuid)}
    ]
    |> Enum.filter(fn {_k, uuid} -> is_binary(uuid) end)
  end

  # ── Holders ────────────────────────────────────────────────────────

  @typedoc "Whose assignees: a task, a project, a library task's default."
  @type holder :: :assignment | :project | :task

  @doc "Which holder a record is (a plain map is a task's)."
  @spec holder(map()) :: holder()
  def holder(%Project{}), do: :project
  def holder(%Task{}), do: :task
  def holder(_), do: :assignment

  @doc false
  # The row schema and the column naming the holder.
  def rows_of(:assignment), do: {AssignmentAssignee, :assignment_uuid}
  def rows_of(:project), do: {ProjectAssignee, :project_uuid}
  def rows_of(:task), do: {TaskDefaultAssignee, :task_uuid}

  @doc "The holder's one-assignee mirror columns, person / team / department."
  @spec mirror_fields(holder()) :: [atom()]
  def mirror_fields(:task),
    do: [
      :default_assigned_person_uuid,
      :default_assigned_team_uuid,
      :default_assigned_department_uuid
    ]

  def mirror_fields(_),
    do: [:assigned_person_uuid, :assigned_team_uuid, :assigned_department_uuid]

  @doc """
  The names of the task's assignees in chip order — a person's display
  name, a team's or department's name. Rows loaded with their subject
  (`assignee_links: [:team, :department, person: [:user]]`) cost nothing;
  otherwise each is read.
  """
  @spec names(map()) :: [String.t()]
  def names(a), do: a |> named() |> Enum.map(&elem(&1, 1)) |> Enum.reject(&is_nil/1)

  @doc """
  Each assignee's key with its own name (nil for a subject that is gone),
  in chip order — a list of links never pairs a key with another's name.
  """
  @spec named(map()) :: [{key(), String.t() | nil}]
  def named(%{assignee_keys: keys}) when is_list(keys),
    do: Enum.map(keys, &{&1, PhoenixKitProjects.People.key_name(&1)})

  def named(%{assignee_links: links}) when is_list(links) do
    Enum.map(links, fn link -> {link_key(link), link_name(link)} end)
  end

  def named(a), do: a |> keys() |> Enum.map(&{&1, PhoenixKitProjects.People.key_name(&1)})

  defp link_name(link) do
    case link do
      %{person: %PhoenixKitProjects.People.Person{} = p} ->
        PhoenixKitProjects.People.display_name(p)

      %{team: %{name: n}} when is_binary(n) ->
        n

      %{department: %{name: n}} when is_binary(n) ->
        n

      link ->
        PhoenixKitProjects.People.key_name(link_key(link))
    end
  end

  @doc "True when the task has nobody on it."
  @spec empty?(map()) :: boolean()
  def empty?(a), do: keys(a) == []

  @doc "The uuids of one kind in the set."
  @spec of_kind([key()], kind()) :: [String.t()]
  def of_kind(keys, kind), do: for({^kind, uuid} <- keys, do: uuid)

  @doc """
  The tasks with their assignee rows loaded (one query for the lot), so
  `keys/1` reads no more. Accepts one task, a list, or `nil`.
  """
  @spec preload(Assignment.t() | [Assignment.t()] | nil) ::
          Assignment.t() | [Assignment.t()] | nil
  def preload(nil), do: nil
  def preload([]), do: []

  def preload(%{__struct__: _} = record), do: hd(preload([record]))

  def preload(list) when is_list(list) do
    rows =
      list
      |> Enum.filter(
        &match?(
          %{__struct__: m, uuid: u} when m in [Assignment, Project, Task] and is_binary(u),
          &1
        )
      )
      |> Enum.group_by(&holder/1, & &1.uuid)
      |> Map.new(fn {h, uuids} -> {h, rows_by(h, uuids)} end)

    Enum.map(list, fn
      %{__struct__: m, uuid: uuid} = r
      when m in [Assignment, Project, Task] and is_binary(uuid) ->
        %{
          r
          | assignee_links: rows |> Map.get(holder(r), %{}) |> Map.get(uuid, []),
            assignee_keys: nil
        }

      other ->
        other
    end)
  end

  @doc """
  `preload/1` for the tasks of a list that do not carry their set yet;
  anything else in the list is left as it is. For a reader handed tasks
  from anywhere.
  """
  @spec ensure_loaded([term()]) :: [term()]
  def ensure_loaded(list) when is_list(list) do
    missing =
      for %{__struct__: m, assignee_links: %Ecto.Association.NotLoaded{}, assignee_keys: nil} = a
          when m in [Assignment, Project, Task] <- list,
          do: a

    case missing do
      [] ->
        list

      _ ->
        loaded = missing |> preload() |> Map.new(&{&1.uuid, &1})

        Enum.map(list, fn
          %{__struct__: m, uuid: uuid} = a when m in [Assignment, Project, Task] ->
            Map.get(loaded, uuid, a)

          other ->
            other
        end)
    end
  end

  @doc """
  The query that loads a task's assignee rows with what names them (team,
  department, person with their account) in ONE statement — for
  `preload(assignee_links: AssigneeSet.link_query())`, so a list's preload
  does not fan out into a query per subject.
  """
  @spec link_query(holder()) :: Ecto.Query.t()
  def link_query(holder \\ :assignment) do
    {schema, _fk} = rows_of(holder)

    from(r in schema,
      left_join: t in assoc(r, :team),
      left_join: d in assoc(r, :department),
      left_join: p in assoc(r, :person),
      left_join: u in assoc(p, :user),
      order_by: [asc: r.position, asc: r.inserted_at],
      preload: [team: t, department: d, person: {p, user: u}]
    )
  end

  @doc "The keys of many tasks at once: `%{task_uuid => [key]}` (absent = none)."
  @spec keys_by_task([String.t()]) :: %{String.t() => [key()]}
  def keys_by_task(uuids), do: keys_by(:assignment, uuids)

  @doc "The keys of many holders of one kind at once: `%{uuid => [key]}` (absent = none)."
  @spec keys_by(holder(), [String.t()]) :: %{String.t() => [key()]}
  def keys_by(holder, uuids) do
    holder
    |> rows_by(Enum.uniq(uuids))
    |> Map.new(fn {uuid, rows} -> {uuid, Enum.map(rows, &link_key/1)} end)
  end

  defp rows_by(_holder, []), do: %{}

  defp rows_by(holder, uuids) do
    {schema, fk} = rows_of(holder)

    from(r in schema,
      where: field(r, ^fk) in ^uuids,
      order_by: [asc: r.position, asc: r.inserted_at]
    )
    |> repo().all()
    |> Enum.group_by(&Map.fetch!(&1, fk))
  end

  defp lookup(holder, uuid) when is_binary(uuid) do
    {schema, fk} = rows_of(holder)

    from(r in schema,
      where: field(r, ^fk) == ^uuid,
      order_by: [asc: r.position, asc: r.inserted_at]
    )
    |> repo().all()
    |> Enum.map(&link_key/1)
  rescue
    _ -> []
  end

  defp lookup(_holder, _), do: []

  defp link_key(%{person_uuid: u}) when is_binary(u), do: {"person", u}
  defp link_key(%{team_uuid: u}) when is_binary(u), do: {"team", u}
  defp link_key(%{department_uuid: u}) when is_binary(u), do: {"department", u}

  # ── Querying ───────────────────────────────────────────────────────

  @doc """
  A `dynamic` true for a task (the query's first binding) that has `kind`
  `uuid` — or one of a list of uuids — among its assignees. A semi-join
  (`IN (subquery)`), so a filter never multiplies rows.
  """
  @spec subject_exists(kind(), String.t() | [String.t()]) :: Ecto.Query.dynamic_expr()
  def subject_exists(kind, uuids) when kind in @kinds do
    dynamic([a], a.uuid in subquery(task_uuids(kind, uuids)))
  end

  @doc "The uuids of the tasks having `kind` `uuids` among their assignees, as a query."
  @spec task_uuids(kind(), String.t() | [String.t()]) :: Ecto.Query.t()
  def task_uuids(kind, uuids) when kind in @kinds, do: holder_uuids(:assignment, kind, uuids)

  @doc """
  The uuids of the holders (tasks, projects, library tasks) having `kind`
  `uuids` among their assignees, as a query.
  """
  @spec holder_uuids(holder(), kind(), String.t() | [String.t()]) :: Ecto.Query.t()
  def holder_uuids(holder, kind, uuids) when kind in @kinds do
    uuids = List.wrap(uuids)
    col = column(kind)
    {schema, fk} = rows_of(holder)

    from(r in schema,
      where: field(r, ^col) in type(^uuids, {:array, UUIDv7}),
      select: field(r, ^fk)
    )
  end

  @doc "A `dynamic` true for a holder (the query's first binding) with `kind` `uuids` on it."
  @spec holder_subject_exists(holder(), kind(), String.t() | [String.t()]) ::
          Ecto.Query.dynamic_expr()
  def holder_subject_exists(holder, kind, uuids) when kind in @kinds do
    dynamic([h], h.uuid in subquery(holder_uuids(holder, kind, uuids)))
  end

  @doc "A `dynamic` true for a task (the first binding) with anyone on it."
  @spec any_exists() :: Ecto.Query.dynamic_expr()
  def any_exists do
    dynamic([a], a.uuid in subquery(from(r in AssignmentAssignee, select: r.assignment_uuid)))
  end

  @doc "A `dynamic` true for a task (the first binding) with nobody on it."
  @spec none_exists() :: Ecto.Query.dynamic_expr()
  def none_exists do
    dynamic([a], a.uuid not in subquery(from(r in AssignmentAssignee, select: r.assignment_uuid)))
  end

  @doc "The row column a kind is kept in."
  @spec column(kind()) :: atom()
  def column("person"), do: :person_uuid
  def column("team"), do: :team_uuid
  def column("department"), do: :department_uuid

  # ── Writing ────────────────────────────────────────────────────────

  @doc """
  The `"assignees"` (or `:assignees`) param of a changeset: `{:ok, keys}`,
  `:none` when absent, `:error` when it is not a list of assignees. Each
  entry is `{kind, uuid}`, `%{"kind" => _, "uuid" => _}` or `"kind:uuid"`;
  an empty string or list clears the set. Duplicates are dropped, the
  first place kept.
  """
  @spec fetch_param(map()) :: {:ok, [key()]} | :none | :error
  def fetch_param(attrs) when is_map(attrs) do
    case Map.fetch(attrs, "assignees") do
      {:ok, value} -> normalize(value)
      :error -> if Map.has_key?(attrs, :assignees), do: normalize(attrs.assignees), else: :none
    end
  end

  @doc "A list of assignees in any accepted shape as keys, or `:error`."
  @spec normalize(term()) :: {:ok, [key()]} | :error
  def normalize(value) when value in [nil, ""], do: {:ok, []}

  def normalize(%{} = indexed) when not is_struct(indexed) do
    # A form posts a list as `%{"0" => …, "1" => …}`.
    indexed
    |> Enum.sort_by(fn {k, _} -> sort_index(k) end)
    |> Enum.map(&elem(&1, 1))
    |> normalize()
  end

  def normalize(list) when is_list(list) do
    # A form posts an empty first entry, so a cleared list still arrives.
    keys = list |> Enum.reject(&(&1 in [nil, ""])) |> Enum.map(&entry/1)

    if Enum.all?(keys, &match?({_, _}, &1)),
      do: {:ok, Enum.uniq(keys)},
      else: :error
  end

  def normalize(_), do: :error

  defp sort_index(k) do
    case Integer.parse(to_string(k)) do
      {n, ""} -> n
      _ -> 0
    end
  end

  defp entry({kind, uuid}), do: key(kind, uuid)
  defp entry(%{"kind" => kind, "uuid" => uuid}), do: key(kind, uuid)
  defp entry(%{kind: kind, uuid: uuid}), do: key(kind, uuid)

  defp entry(text) when is_binary(text) do
    case String.split(text, ":", parts: 2) do
      [kind, uuid] -> key(kind, uuid)
      _ -> nil
    end
  end

  defp entry(_), do: nil

  defp key(kind, uuid) when kind in @kinds and is_binary(uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, uuid} -> {kind, uuid}
      :error -> nil
    end
  end

  defp key(_, _), do: nil

  @doc """
  The one-assignee mirror for a set: `%{assigned_person_uuid: _, …}` with
  the one assignee's column filled, or all `nil` for none or several.
  """
  @spec mirror([key()], holder()) :: %{atom() => String.t() | nil}
  def mirror(keys, holder \\ :assignment) do
    [person, team, department] = mirror_fields(holder)
    blank = %{person => nil, team => nil, department => nil}

    case keys do
      [{"person", u}] -> %{blank | person => u}
      [{"team", u}] -> %{blank | team => u}
      [{"department", u}] -> %{blank | department => u}
      _ -> blank
    end
  end

  @doc false
  # Called from `Assignment.changeset/2`'s `prepare_changes`, inside the
  # save's transaction: the task's rows become exactly `keys`.
  @spec write_rows(module(), holder(), String.t(), [key()]) :: :ok
  def write_rows(repo, holder \\ :assignment, holder_uuid, keys) when is_binary(holder_uuid) do
    {schema, fk} = rows_of(holder)

    # The holder's row first, locked: two saves of one record replace its
    # set one after the other, never interleaved into a merge of both
    # (codex review). A new record has no row yet — nothing to wait for.
    lock_holder(repo, holder, holder_uuid)

    from(r in schema, where: field(r, ^fk) == ^holder_uuid)
    |> repo.delete_all()

    rows =
      keys
      |> Enum.with_index()
      |> Enum.map(fn {{kind, uuid}, i} ->
        Map.put(
          %{
            fk => holder_uuid,
            person_uuid: nil,
            team_uuid: nil,
            department_uuid: nil,
            position: i
          },
          column(kind),
          uuid
        )
      end)

    if rows != [], do: repo.insert_all(schema, rows)
    :ok
  end

  @doc false
  def lock_holder(repo, holder, holder_uuid) do
    from(h in holder_schema(holder),
      where: h.uuid == ^holder_uuid,
      select: h.uuid,
      lock: "FOR UPDATE"
    )
    |> repo.all()

    :ok
  end

  defp holder_schema(:assignment), do: Assignment
  defp holder_schema(:project), do: Project
  defp holder_schema(:task), do: Task

  # ── Changesets ─────────────────────────────────────────────────────

  @doc """
  A holder's changeset takes its set (V29/V30): from `"assignees"` (any
  shape `fetch_param/1` accepts) or — old forms and the API — from the
  holder's three single fields, which then name the whole set. Either way
  the three fields end up as the mirror (the one assignee, or all empty)
  and `:assignee_keys` carries the set for `write_changeset/2`. `error_field`
  is where a bad list is reported.
  """
  @spec put_changeset(Ecto.Changeset.t(), map(), holder()) :: Ecto.Changeset.t()
  def put_changeset(%Ecto.Changeset{} = changeset, attrs, holder) when is_map(attrs) do
    fields = mirror_fields(holder)

    case fetch_param(attrs) do
      {:ok, keys} ->
        # The same list again (a form posts it with every change): nothing
        # to write — unless the single fields beside it changed it.
        if keys == keys(changeset.data) do
          changeset |> legacy_changeset(holder) |> repair_mirror(keys, holder)
        else
          mirror = mirror(keys, holder)

          fields
          |> Enum.reduce(changeset, &Ecto.Changeset.put_change(&2, &1, mirror[&1]))
          |> Ecto.Changeset.put_change(:assignee_keys, keys)
        end

      :error ->
        Ecto.Changeset.add_error(changeset, hd(fields), gettext("is not a list of assignees"))

      :none ->
        legacy_changeset(changeset, holder)
    end
  end

  def put_changeset(changeset, _attrs, _holder), do: changeset

  # The same set posted again still puts the mirror right when it went
  # stale (a staff record deleted out of a two-member set leaves the one
  # survivor with an empty mirror — codex review).
  defp repair_mirror(changeset, keys, holder) do
    if Ecto.Changeset.get_change(changeset, :assignee_keys) do
      changeset
    else
      mirror = mirror(keys, holder)

      Enum.reduce(mirror_fields(holder), changeset, fn field, cs ->
        if Map.get(cs.data, field) == mirror[field],
          do: cs,
          else: Ecto.Changeset.put_change(cs, field, mirror[field])
      end)
    end
  end

  defp legacy_changeset(changeset, holder) do
    fields = mirror_fields(holder)

    if Enum.any?(fields, &Map.has_key?(changeset.changes, &1)) do
      [person, team, department] = Enum.map(fields, &Ecto.Changeset.get_field(changeset, &1))

      keys =
        Enum.filter(
          [{"person", person}, {"team", team}, {"department", department}],
          fn {_k, u} -> is_binary(u) end
        )

      Ecto.Changeset.put_change(changeset, :assignee_keys, keys)
    else
      changeset
    end
  end

  @doc """
  Writes a changeset's set (`:assignee_keys`) in the save's own
  transaction; a new record gets its uuid here, so its rows can be written
  just before it (their holder reference is deferred).
  """
  @spec write_changeset(Ecto.Changeset.t(), holder()) :: Ecto.Changeset.t()
  def write_changeset(%Ecto.Changeset{valid?: true} = changeset, holder) do
    case Ecto.Changeset.get_change(changeset, :assignee_keys) do
      keys when is_list(keys) ->
        changeset =
          if is_nil(changeset.data.uuid) and is_nil(Ecto.Changeset.get_change(changeset, :uuid)),
            do: Ecto.Changeset.put_change(changeset, :uuid, UUIDv7.generate()),
            else: changeset

        Ecto.Changeset.prepare_changes(changeset, fn cs ->
          write_rows(cs.repo, holder, Ecto.Changeset.get_field(cs, :uuid), keys)
          cs
        end)

      _ ->
        changeset
    end
  end

  def write_changeset(changeset, _holder), do: changeset

  @doc """
  The assignees added and removed between two sets: `{added, removed}`.
  """
  @spec diff([key()], [key()]) :: {[key()], [key()]}
  def diff(before, now), do: {now -- before, before -- now}

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
