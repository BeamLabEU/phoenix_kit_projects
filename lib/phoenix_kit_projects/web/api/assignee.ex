defmodule PhoenixKitProjects.Web.Api.Assignee do
  @moduledoc """
  Who a task is for, over the API: reading it (`to_json/1`,
  `list_json/1`), setting it from a request's `assignee` or `assignees`
  (`attrs/2`) and filtering a list by it (`filter/3`).

  A task has any number of assignees (V29), each a staff person, a team or
  a department, all equal. `assignees` (read and write) is the whole list;
  `assignee` is kept for clients written when a task had one: it reads the
  one assignee (null for none AND for several — an old client must not
  take one of several for the owner), and writing it makes that one the
  whole list. A request naming both is refused. `"me"` is the staff person
  of the user a personal key acts for — made for them when they have none
  — and a shared agent has none.
  """

  alias PhoenixKitProjects.{AssigneeSet, Authz, People}
  alias PhoenixKitProjects.Schemas.{ApiKey, Assignment, Project}
  alias PhoenixKitProjects.Web.Api.Json

  @columns %{
    "person" => "assigned_person_uuid",
    "team" => "assigned_team_uuid",
    "department" => "assigned_department_uuid"
  }

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  @doc """
  The ONE assignee of a task as `%{kind, uuid, name}`; nil when it has none
  or several (`list_json/1` lists them).
  """
  @spec to_json(Assignment.t() | map()) :: map() | nil
  # a sub-project row carries no assignee of its own: the nested project does
  def to_json(%{child_project_uuid: uuid, child_project: %{uuid: uuid} = child})
      when is_binary(uuid),
      do: to_json(child)

  def to_json(%m{} = a) when m in [Assignment, Project] do
    case list_json(a) do
      [one] -> one
      _ -> nil
    end
  end

  def to_json(%{assigned_person_uuid: uuid} = a) when is_binary(uuid),
    do: %{kind: "person", uuid: uuid, name: person_name(Map.get(a, :assigned_person))}

  def to_json(%{assigned_team_uuid: uuid} = a) when is_binary(uuid),
    do: %{kind: "team", uuid: uuid, name: group_name(Map.get(a, :assigned_team))}

  def to_json(%{assigned_department_uuid: uuid} = a) when is_binary(uuid),
    do: %{kind: "department", uuid: uuid, name: group_name(Map.get(a, :assigned_department))}

  def to_json(_), do: nil

  @doc "Every assignee of a task as `[%{kind, uuid, name}]`, in chip order."
  @spec list_json(Assignment.t() | map()) :: [map()]
  def list_json(%{child_project_uuid: uuid, child_project: %{uuid: uuid} = child})
      when is_binary(uuid),
      do: list_json(child)

  # A task's (V29) or a project's (V30) whole set.
  def list_json(%m{assignee_links: links}) when m in [Assignment, Project] and is_list(links) do
    Enum.map(links, fn
      %{person_uuid: u} = l when is_binary(u) ->
        %{kind: "person", uuid: u, name: person_name(loaded(l.person))}

      %{team_uuid: u} = l when is_binary(u) ->
        %{kind: "team", uuid: u, name: group_name(loaded(l.team))}

      %{department_uuid: u} = l ->
        %{kind: "department", uuid: u, name: group_name(loaded(l.department))}
    end)
  end

  def list_json(%m{} = a) when m in [Assignment, Project] do
    a |> AssigneeSet.preload() |> list_json()
  end

  def list_json(other), do: List.wrap(to_json(other))

  defp loaded(%Ecto.Association.NotLoaded{}), do: nil
  defp loaded(other), do: other

  @doc "The uuid of the staff person a key acts for, or nil (a shared agent, or a user with no staff record)."
  @spec person_uuid(ApiKey.t()) :: String.t() | nil
  def person_uuid(%ApiKey{user_uuid: uuid}) when is_binary(uuid) do
    case People.get_person_by_user_uuid(uuid, preload: []) do
      %{uuid: person_uuid} -> person_uuid
      _ -> nil
    end
  end

  def person_uuid(_key), do: nil

  @doc """
  The staff person a key acts for, created when the key's user has none
  (`People.ensure_person_for_user/2`; an API call has no one to ask, so it
  does not). `{:error, :trashed_person}` when theirs is in the trash,
  `{:error, :no_user}` for a shared agent.
  """
  @spec ensure_person_uuid(ApiKey.t()) :: {:ok, String.t()} | {:error, term()}
  def ensure_person_uuid(%ApiKey{user_uuid: uuid}) when is_binary(uuid) do
    case People.ensure_person_for_user(uuid, actor_uuid: uuid, source: "api") do
      {:ok, %{uuid: person_uuid}} -> {:ok, person_uuid}
      {:error, _} = error -> error
    end
  end

  def ensure_person_uuid(_key), do: {:error, :no_user}

  @doc """
  The assignment attrs a request's `assignee` or `assignees` asks for:
  `{:ok, %{}}` when the request mentions neither, `{:ok, %{"assignees" =>
  keys}}` (the whole new list) when it does, or the refusal as `{:error,
  {status, body}}`. Needs the `assignees` feature and the `assign_tasks`
  action, checked only when a field is there. Both fields at once: 422.
  """
  @spec attrs(Plug.Conn.t(), map()) :: {:ok, map()} | {:error, {integer(), map()}}
  def attrs(conn, params) do
    case {Map.fetch(params, "assignee"), Map.fetch(params, "assignees")} do
      {:error, :error} ->
        {:ok, %{}}

      {{:ok, _}, {:ok, _}} ->
        invalid("Send `assignees` (the whole list) or `assignee` (one), not both.")

      {{:ok, value}, :error} ->
        with :ok <- allowed(conn),
             {:ok, keys} <- resolve(conn.assigns.pk_api_key, value),
             do: {:ok, %{"assignees" => keys}}

      {:error, {:ok, list}} ->
        with :ok <- allowed(conn), do: resolve_list(conn.assigns.pk_api_key, list)
    end
  end

  defp resolve_list(_key, value) when value in [nil, []], do: {:ok, %{"assignees" => []}}

  defp resolve_list(key, list) when is_list(list) and length(list) <= 50 do
    Enum.reduce_while(list, {:ok, []}, fn entry, {:ok, acc} ->
      case resolve(key, entry) do
        {:ok, [one]} -> {:cont, {:ok, acc ++ [one]}}
        {:ok, []} -> {:halt, invalid(list_message())}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, keys} -> {:ok, %{"assignees" => Enum.uniq(keys)}}
      error -> error
    end
  end

  defp resolve_list(_key, _value), do: invalid(list_message())

  defp list_message,
    do:
      "assignees is a list (at most 50) of `me`, a person's uuid, `{\"person\": uuid}`, `{\"team\": uuid}` or `{\"department\": uuid}`; [] clears it."

  defp allowed(conn) do
    %{pk_api_key: key, pk_project: project, pk_fx: fx} = conn.assigns

    cond do
      not Map.get(fx, :assignees, false) ->
        {:error,
         Json.error_body(
           403,
           "feature_disabled",
           "The assignees feature is turned off for this project.",
           %{feature: :assignees}
         )}

      not Authz.can_role?(project, key.role, :assign_tasks) ->
        {:error,
         Json.error_body(
           403,
           "forbidden",
           "A #{key.role} key may not assign_tasks on this project.",
           %{action: :assign_tasks, role: key.role}
         )}

      true ->
        :ok
    end
  end

  defp resolve(_key, value) when value in [nil, "", "none"], do: {:ok, []}

  defp resolve(key, "me") do
    case ensure_person_uuid(key) do
      {:ok, uuid} ->
        {:ok, [{"person", uuid}]}

      {:error, :trashed_person} ->
        invalid(
          "The staff record of the person this key acts for is in the trash, so `me` names no one. Restore it under Staff -> People, or pass a person's uuid from GET /people."
        )

      {:error, _} ->
        invalid(
          "This key acts for nobody who can be assigned, so `me` names no one. Pass a person's uuid from GET /people."
        )
    end
  end

  defp resolve(_key, value) when is_binary(value), do: named("person", value)

  defp resolve(_key, %{} = value) when map_size(value) == 1 do
    [{kind, uuid}] = Map.to_list(value)
    if Map.has_key?(@columns, kind), do: named(kind, uuid), else: invalid(shape_message())
  end

  defp resolve(_key, _value), do: invalid(shape_message())

  defp named(kind, uuid) when is_binary(uuid) do
    if Regex.match?(@uuid, uuid) and exists?(kind, uuid),
      do: {:ok, [{kind, String.downcase(uuid)}]},
      else: invalid("No #{kind} with that uuid. GET /people lists who a task can be for.")
  end

  defp named(_kind, _uuid), do: invalid(shape_message())

  defp exists?("person", uuid) do
    match?(%{status: status} when status != "trashed", People.get_person(uuid, preload: []))
  end

  defp exists?("team", uuid), do: Enum.any?(People.list_teams(), &(&1.uuid == uuid))
  defp exists?("department", uuid), do: Enum.any?(People.list_departments(), &(&1.uuid == uuid))

  defp shape_message,
    do:
      "assignee is `me`, a person's uuid, `{\"team\": uuid}`, `{\"department\": uuid}`, or null to clear it."

  defp invalid(message),
    do: {:error, Json.error_body(422, "validation_failed", message, %{assignee: [message]})}

  @doc """
  Narrows a task list by a `assignee` filter: `me`, `none`, or a person's
  uuid. Anything else is a refusal - a filter nobody recognises must not
  answer the whole list.
  """
  @spec filter([Assignment.t()], ApiKey.t(), String.t() | nil) ::
          {:ok, [Assignment.t()]} | {:error, {integer(), map()}}
  def filter(tasks, _key, nil), do: {:ok, tasks}

  def filter(tasks, _key, "none") do
    {:ok, Enum.filter(tasks, &(list_json(&1) == []))}
  end

  def filter(tasks, key, "me") do
    # a key that acts for nobody has no tasks of its own
    case person_uuid(key) do
      nil -> {:ok, []}
      uuid -> {:ok, with_person(tasks, uuid)}
    end
  end

  def filter(tasks, _key, value) when is_binary(value) do
    if Regex.match?(@uuid, value),
      do: {:ok, with_person(tasks, String.downcase(value))},
      else: invalid("assignee is `me`, `none`, or a person's uuid.")
  end

  def filter(_tasks, _key, _value), do: invalid("assignee is `me`, `none`, or a person's uuid.")

  @doc "A person's name for the API: their name, else the user's first and last name - never the email."
  @spec person_name(map() | nil) :: String.t() | nil
  def person_name(%{name: name}) when is_binary(name) and name != "", do: name

  def person_name(%{user: %{} = user}) when not is_struct(user, Ecto.Association.NotLoaded) do
    [Map.get(user, :first_name), Map.get(user, :last_name)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
    |> case do
      "" -> nil
      full -> full
    end
  end

  def person_name(_), do: nil

  defp group_name(%{name: name}) when is_binary(name), do: name
  defp group_name(_), do: nil

  # The person among the task's assignees (any of several; a team's or a
  # department's members are not "assigned" by this filter). A sub-project
  # row's people are its child project's (codex review), read for the whole
  # list at once.
  defp with_person(tasks, uuid) do
    held = held_keys_by(tasks)
    Enum.filter(tasks, &({"person", uuid} in Map.get(held, &1.uuid, [])))
  end

  @doc """
  Who holds each row, as `list_json/1` shows it: a task's own set, a
  sub-project row's child project's. `%{assignment_uuid => [key]}`, the
  child projects read in one query.
  """
  @spec held_keys_by([Assignment.t()]) :: %{String.t() => [AssigneeSet.key()]}
  def held_keys_by(tasks) do
    child_uuids = for %Assignment{child_project_uuid: u} when is_binary(u) <- tasks, do: u
    children = AssigneeSet.keys_by(:project, child_uuids)

    Map.new(tasks, fn
      %Assignment{uuid: id, child_project_uuid: u} when is_binary(u) ->
        {id, Map.get(children, u, [])}

      %Assignment{uuid: id} = a ->
        {id, AssigneeSet.keys(a)}

      other ->
        {Map.get(other, :uuid), []}
    end)
  end

  @doc "`held_keys_by/1` for one row."
  @spec held_keys(Assignment.t()) :: [AssigneeSet.key()]
  def held_keys(%Assignment{uuid: id} = a),
    do: a |> List.wrap() |> held_keys_by() |> Map.get(id, [])

  def held_keys(_), do: []
end
