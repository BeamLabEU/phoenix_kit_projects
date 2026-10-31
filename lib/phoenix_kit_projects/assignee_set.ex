defmodule PhoenixKitProjects.AssigneeSet do
  @moduledoc """
  A task's assignees (chain V29): any number of staff people, teams and
  departments, all equal — one shared status, and everyone (a team's and a
  department's members too) is told. There is no main assignee.

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

  import Ecto.Query

  alias PhoenixKitProjects.Schemas.{Assignment, AssignmentAssignee}

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
      [] -> lookup(Map.get(a, :uuid))
      keys -> keys
    end
  end

  @doc "The keys of the one-assignee mirror (`assigned_*`): `[]` or one key."
  @spec legacy_keys(map()) :: [key()]
  def legacy_keys(a) do
    [
      {"person", Map.get(a, :assigned_person_uuid)},
      {"team", Map.get(a, :assigned_team_uuid)},
      {"department", Map.get(a, :assigned_department_uuid)}
    ]
    |> Enum.filter(fn {_k, uuid} -> is_binary(uuid) end)
  end

  @doc """
  The names of the task's assignees in chip order — a person's display
  name, a team's or department's name. Rows loaded with their subject
  (`assignee_links: [:team, :department, person: [:user]]`) cost nothing;
  otherwise each is read.
  """
  @spec names(map()) :: [String.t()]
  def names(%{assignee_keys: keys}) when is_list(keys), do: names_of(keys)

  def names(%{assignee_links: links}) when is_list(links) do
    Enum.map(links, fn
      %AssignmentAssignee{person: %PhoenixKitProjects.People.Person{} = p} ->
        PhoenixKitProjects.People.display_name(p)

      %AssignmentAssignee{team: %{name: n}} when is_binary(n) ->
        n

      %AssignmentAssignee{department: %{name: n}} when is_binary(n) ->
        n

      link ->
        PhoenixKitProjects.People.key_name(link_key(link))
    end)
    |> Enum.reject(&is_nil/1)
  end

  def names(a), do: a |> keys() |> names_of()

  defp names_of(keys),
    do: keys |> Enum.map(&PhoenixKitProjects.People.key_name/1) |> Enum.reject(&is_nil/1)

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

  def preload(%Assignment{} = a), do: hd(preload([a]))

  def preload(list) when is_list(list) do
    uuids = for %Assignment{uuid: uuid} <- list, is_binary(uuid), do: uuid
    by_task = rows_by_task(uuids)

    Enum.map(list, fn
      %Assignment{uuid: uuid} = a when is_binary(uuid) ->
        %{a | assignee_links: Map.get(by_task, uuid, []), assignee_keys: nil}

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
      for %Assignment{assignee_links: %Ecto.Association.NotLoaded{}, assignee_keys: nil} = a <-
            list,
          do: a

    case missing do
      [] ->
        list

      _ ->
        loaded = missing |> preload() |> Map.new(&{&1.uuid, &1})

        Enum.map(list, fn
          %Assignment{uuid: uuid} = a -> Map.get(loaded, uuid, a)
          other -> other
        end)
    end
  end

  @doc """
  The query that loads a task's assignee rows with what names them (team,
  department, person with their account) in ONE statement — for
  `preload(assignee_links: AssigneeSet.link_query())`, so a list's preload
  does not fan out into a query per subject.
  """
  @spec link_query() :: Ecto.Query.t()
  def link_query do
    from(r in AssignmentAssignee,
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
  def keys_by_task(uuids) do
    uuids
    |> Enum.uniq()
    |> rows_by_task()
    |> Map.new(fn {uuid, rows} -> {uuid, Enum.map(rows, &link_key/1)} end)
  end

  defp rows_by_task([]), do: %{}

  defp rows_by_task(uuids) do
    from(r in AssignmentAssignee,
      where: r.assignment_uuid in ^uuids,
      order_by: [asc: r.position, asc: r.inserted_at]
    )
    |> repo().all()
    |> Enum.group_by(& &1.assignment_uuid)
  end

  defp lookup(uuid) when is_binary(uuid) do
    from(r in AssignmentAssignee,
      where: r.assignment_uuid == ^uuid,
      order_by: [asc: r.position, asc: r.inserted_at]
    )
    |> repo().all()
    |> Enum.map(&link_key/1)
  rescue
    _ -> []
  end

  defp lookup(_), do: []

  defp link_key(%AssignmentAssignee{person_uuid: u}) when is_binary(u), do: {"person", u}
  defp link_key(%AssignmentAssignee{team_uuid: u}) when is_binary(u), do: {"team", u}
  defp link_key(%AssignmentAssignee{department_uuid: u}) when is_binary(u), do: {"department", u}

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
  def task_uuids(kind, uuids) when kind in @kinds do
    uuids = List.wrap(uuids)
    col = column(kind)

    from(r in AssignmentAssignee,
      where: field(r, ^col) in type(^uuids, {:array, UUIDv7}),
      select: r.assignment_uuid
    )
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
  @spec mirror([key()]) :: %{atom() => String.t() | nil}
  def mirror(keys) do
    blank = %{assigned_person_uuid: nil, assigned_team_uuid: nil, assigned_department_uuid: nil}

    case keys do
      [{"person", u}] -> %{blank | assigned_person_uuid: u}
      [{"team", u}] -> %{blank | assigned_team_uuid: u}
      [{"department", u}] -> %{blank | assigned_department_uuid: u}
      _ -> blank
    end
  end

  @doc false
  # Called from `Assignment.changeset/2`'s `prepare_changes`, inside the
  # save's transaction: the task's rows become exactly `keys`.
  @spec write_rows(module(), String.t(), [key()]) :: :ok
  def write_rows(repo, assignment_uuid, keys) when is_binary(assignment_uuid) do
    from(r in AssignmentAssignee, where: r.assignment_uuid == ^assignment_uuid)
    |> repo.delete_all()

    rows =
      keys
      |> Enum.with_index()
      |> Enum.map(fn {{kind, uuid}, i} ->
        Map.put(
          %{
            assignment_uuid: assignment_uuid,
            person_uuid: nil,
            team_uuid: nil,
            department_uuid: nil,
            position: i
          },
          column(kind),
          uuid
        )
      end)

    if rows != [], do: repo.insert_all(AssignmentAssignee, rows)
    :ok
  end

  @doc """
  The assignees added and removed between two sets: `{added, removed}`.
  """
  @spec diff([key()], [key()]) :: {[key()], [key()]}
  def diff(before, now), do: {now -- before, before -- now}

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
