defmodule PhoenixKitProjects.PeopleSource do
  @moduledoc """
  What core's people picker (`PhoenixKitWeb.Components.PeoplePicker`)
  offers in Projects: staff's teams, departments and people, and accounts
  with no staff record yet — the same search, "Recent" chips and staff
  record question as the module's own picker had (the boss, 2026-11-18:
  "make sure this component is in core because it's pretty useful").

  Keys are `{kind, uuid}`: `"person"`, `"team"`, `"department"` — what a
  task, a project or a library task is assigned to — and `"user"`, an
  account with no staff record. Picking a `"user"` asks first; on Yes the
  account's key is picked as it is, and the FORM makes the staff record
  (`AssigneeField.handle_info/3` — after asking the viewer's right to
  assign as it is now, which this source cannot see) and puts the person it
  became in its place. An account whose staff record is in the trash is
  refused with where to restore it.

  `ctx` takes `:project_uuid` (the project whose tasks Recent looks at) and
  `:source` (the activity's `source`, "task_form" by default), plus core's
  `:viewer_uuid` and `:locale`.
  """

  @behaviour PhoenixKitWeb.Components.PeoplePicker.Source

  use Gettext, backend: PhoenixKitProjects.Gettext

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitProjects.{Assignees, People}

  @kinds ~w(person team department)

  @impl true
  def groups(_ctx) do
    [
      %{key: "team", label: gettext("Teams")},
      %{key: "department", label: gettext("Departments")},
      %{key: "person", label: gettext("People")}
    ]
  end

  @impl true
  def page({:group, kind}, cursor, limit, ctx) when kind in @kinds do
    {rows, next} = Assignees.page({:browse, kind}, cursor, limit, lang(ctx))
    {rows |> Enum.map(&row/1) |> with_users(), next}
  end

  def page({:search, text}, cursor, limit, ctx) when is_binary(text) do
    {rows, next} = Assignees.page({:search, text}, cursor, limit, lang(ctx))
    {rows |> Enum.map(&row/1) |> with_users(), next}
  end

  def page(_view, _cursor, _limit, _ctx), do: {[], nil}

  @impl true
  def describe({"user", uuid}, _ctx) do
    case Assignees.describe_user(uuid) do
      %{} = r -> r |> row() |> with_user()
      nil -> trashed_account_row(uuid)
    end
  end

  def describe({kind, uuid}, ctx) when kind in @kinds,
    do: kind |> Assignees.describe(uuid, lang(ctx)) |> row() |> with_user()

  def describe(_key, _ctx), do: nil

  # A new pick: a trashed person is offered nowhere, so a pick naming one
  # takes nobody; an account asks before a staff record is made for it.
  @impl true
  def pick({"user", uuid} = key, ctx) do
    case trashed_person(uuid) do
      %{} -> {:error, trashed_message(uuid, ctx)}
      nil -> ask_staff(key, ctx)
    end
  end

  def pick({kind, uuid} = key, _ctx) when kind in @kinds do
    case Assignees.describe_pick(kind, uuid) do
      %{} -> {:ok, key}
      _ -> {:error, gettext("That person can no longer be picked.")}
    end
  end

  def pick(_key, _ctx), do: {:error, gettext("That person can no longer be picked.")}

  defp ask_staff(key, ctx) do
    case describe(key, ctx) do
      %{label: name} ->
        {:confirm,
         %{
           title: gettext("Create a staff record?"),
           text:
             gettext(
               "%{name} has an account but no staff record. Tasks are assigned to staff, so a record is made for them.",
               name: name
             ),
           confirm: gettext("Create and assign")
         }}

      _ ->
        {:error, gettext("That person can no longer be picked.")}
    end
  end

  # The Yes: the account itself is picked; the form makes its staff record
  # once it has asked the viewer's right as it is now.
  @impl true
  def confirm({"user", uuid} = key, ctx) do
    case {describe(key, ctx), trashed_person(uuid)} do
      {_, %{}} -> {:error, trashed_message(uuid, ctx)}
      {%{}, nil} -> {:ok, key}
      _ -> {:error, gettext("That person can no longer be picked.")}
    end
  end

  def confirm(_key, _ctx), do: {:error, gettext("That person can no longer be picked.")}

  # An account whose staff record is in the trash: still offered (its
  # "Assign to me" says why it cannot be assigned), never picked.
  defp trashed_person(uuid) when is_binary(uuid) do
    case People.get_person_by_user_uuid(uuid) do
      %{status: "trashed"} = person -> person
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp trashed_person(_uuid), do: nil

  defp trashed_account_row(uuid) do
    with %{} = person <- trashed_person(uuid),
         {:ok, id} <- Ecto.UUID.cast(uuid),
         %User{} = user <- RepoHelper.repo().get(User, id),
         true <- People.assignable_user?(user) do
      row(%{
        kind: "user",
        uuid: uuid,
        label: person.name || People.new_person_name(user),
        icon: "hero-user"
      })
    else
      _ -> nil
    end
  end

  defp trashed_message(uuid, ctx) do
    if uuid == ctx[:viewer_uuid],
      do:
        gettext(
          "Your staff record is in the trash; restore it under Staff → People to be assigned."
        ),
      else:
        gettext(
          "Their staff record is in the trash; restore it under Staff → People to assign them."
        )
  end

  # "Assign to me": the viewer's staff person, else their account (which
  # then asks to make the record).
  @impl true
  def me(%{viewer_uuid: viewer}) when is_binary(viewer) do
    case People.get_person_by_user_uuid(viewer) do
      %{uuid: person_uuid, status: status} when status != "trashed" -> {"person", person_uuid}
      # Trashed: the button stays and says why (`pick/2`).
      _ -> {"user", viewer}
    end
  rescue
    _ -> nil
  end

  def me(_ctx), do: nil

  @impl true
  def recent(limit, ctx) do
    ctx[:viewer_uuid]
    |> Assignees.recent_for_viewer(ctx[:project_uuid], limit, lang(ctx))
    |> Enum.map(&row/1)
    |> with_users()
  end

  @impl true
  def remember({kind, uuid}, ctx) when kind in @kinds do
    Assignees.remember_pick(ctx[:viewer_uuid], kind, uuid)
    :ok
  end

  def remember(_key, _ctx), do: :ok

  # The module's rows in core's shape: the name the avatar's letters come
  # from, a group's faces as its stack.
  defp row(%{kind: kind, uuid: uuid, label: label} = r) do
    %{
      kind: kind,
      uuid: uuid,
      label: label,
      sublabel: r[:sublabel],
      icon: r[:icon],
      name: if(kind in ~w(person user), do: label),
      # A team's or department's people follow it in a search, indented.
      member?: is_binary(r[:id]) and String.contains?(r[:id], "-person-"),
      # The row's own id: a person under two teams of a search is two rows
      # of one key, and core keys the list on this (the boss, 2026-11-19).
      id: r[:id],
      faces: faces(r[:faces])
    }
  end

  defp row(_), do: nil

  # A person's (or an account's) own account on the row, so core draws
  # their avatar — a photo, or two letters from the name shown — instead of
  # a blank icon (the boss, 2026-11-18: people "didn't have any icons").
  # One query for the whole page; a person with no account keeps the icon.
  defp with_users(rows) do
    rows = Enum.reject(rows, &is_nil/1)
    people = for %{kind: "person", uuid: u} <- rows, do: u
    accounts = for %{kind: "user", uuid: u} <- rows, do: u
    by_person = users_by_person(people)
    by_account = users_by_uuid(accounts)

    Enum.map(rows, fn
      %{kind: "person", uuid: u} = r -> put_user(r, Map.get(by_person, u))
      %{kind: "user", uuid: u} = r -> put_user(r, Map.get(by_account, u))
      r -> r
    end)
  end

  defp with_user(nil), do: nil
  defp with_user(row), do: row |> List.wrap() |> with_users() |> List.first()

  defp put_user(row, %User{} = user), do: Map.put(row, :user, user)
  defp put_user(row, _), do: row

  defp users_by_person([]), do: %{}

  defp users_by_person(uuids) do
    import Ecto.Query

    from(p in PhoenixKitProjects.People.Person,
      join: u in User,
      on: u.uuid == p.user_uuid,
      where: p.uuid in ^uuids,
      select: {p.uuid, u}
    )
    |> RepoHelper.repo().all()
    |> Map.new(fn {p, u} -> {to_string(p), u} end)
  rescue
    _ -> %{}
  end

  defp users_by_uuid([]), do: %{}

  defp users_by_uuid(uuids) do
    import Ecto.Query

    from(u in User, where: u.uuid in ^uuids)
    |> RepoHelper.repo().all()
    |> Map.new(&{to_string(&1.uuid), &1})
  rescue
    _ -> %{}
  end

  # `Assignees` faces (`%{faces: [%{name, user}], extra}`) as core's stack
  # of users; people with no account have no picture to stack.
  defp faces(%{faces: list}) when is_list(list),
    do: for(%{user: %{} = user} <- list, do: user)

  defp faces(_), do: []

  defp lang(ctx), do: ctx[:locale]
end
