defmodule PhoenixKitProjects.Web.Api.Assignee do
  @moduledoc """
  Who a task is for, over the API: reading it (`to_json/1`), setting it
  from a request's `assignee` (`attrs/2`) and filtering a list by it
  (`filter/3`).

  A task has ONE assignee, a staff person, a team or a department (the
  schema's single-assignee rule), so a request names one and the other
  two columns are cleared with it. `"me"` is the staff person of the user
  a personal key acts for — made for them when they have none — and a
  shared agent has none.
  """

  alias PhoenixKitProjects.{Authz, People}
  alias PhoenixKitProjects.Schemas.{ApiKey, Assignment}
  alias PhoenixKitProjects.Web.Api.Json

  @columns %{
    "person" => "assigned_person_uuid",
    "team" => "assigned_team_uuid",
    "department" => "assigned_department_uuid"
  }

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  @doc "The assignee of a task as `%{kind, uuid, name}`, or nil when it has none."
  @spec to_json(Assignment.t() | map()) :: map() | nil
  # a sub-project row carries no assignee of its own: the nested project does
  def to_json(%{child_project_uuid: uuid, child_project: %{uuid: uuid} = child})
      when is_binary(uuid),
      do: to_json(child)

  def to_json(%{assigned_person_uuid: uuid} = a) when is_binary(uuid),
    do: %{kind: "person", uuid: uuid, name: person_name(Map.get(a, :assigned_person))}

  def to_json(%{assigned_team_uuid: uuid} = a) when is_binary(uuid),
    do: %{kind: "team", uuid: uuid, name: group_name(Map.get(a, :assigned_team))}

  def to_json(%{assigned_department_uuid: uuid} = a) when is_binary(uuid),
    do: %{kind: "department", uuid: uuid, name: group_name(Map.get(a, :assigned_department))}

  def to_json(_), do: nil

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
  The assignment attrs a request's `assignee` asks for: `{:ok, %{}}` when
  the request does not mention it, the three columns when it does, or the
  refusal as `{:error, {status, body}}`. Needs the `assignees` feature and
  the `assign_tasks` action, checked only when the field is there.
  """
  @spec attrs(Plug.Conn.t(), map()) :: {:ok, map()} | {:error, {integer(), map()}}
  def attrs(conn, params) do
    case Map.fetch(params, "assignee") do
      :error -> {:ok, %{}}
      {:ok, value} -> with :ok <- allowed(conn), do: resolve(conn.assigns.pk_api_key, value)
    end
  end

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

  defp resolve(_key, value) when value in [nil, "", "none"], do: {:ok, columns(nil, nil)}

  defp resolve(key, "me") do
    case ensure_person_uuid(key) do
      {:ok, uuid} ->
        {:ok, columns("person", uuid)}

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
      do: {:ok, columns(kind, uuid)},
      else: invalid("No #{kind} with that uuid. GET /people lists who a task can be for.")
  end

  defp named(_kind, _uuid), do: invalid(shape_message())

  defp exists?("person", uuid) do
    match?(%{status: status} when status != "trashed", People.get_person(uuid, preload: []))
  end

  defp exists?("team", uuid), do: Enum.any?(People.list_teams(), &(&1.uuid == uuid))
  defp exists?("department", uuid), do: Enum.any?(People.list_departments(), &(&1.uuid == uuid))

  defp columns(kind, uuid) do
    Map.new(@columns, fn {k, column} -> {column, if(k == kind, do: uuid)} end)
  end

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
    {:ok, Enum.filter(tasks, &is_nil(to_json(&1)))}
  end

  def filter(tasks, key, "me") do
    # a key that acts for nobody has no tasks of its own
    case person_uuid(key) do
      nil -> {:ok, []}
      uuid -> {:ok, Enum.filter(tasks, &(&1.assigned_person_uuid == uuid))}
    end
  end

  def filter(tasks, _key, value) when is_binary(value) do
    if Regex.match?(@uuid, value),
      do: {:ok, Enum.filter(tasks, &(&1.assigned_person_uuid == value))},
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
end
