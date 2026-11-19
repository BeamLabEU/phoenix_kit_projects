defmodule PhoenixKitProjects.PeopleSource do
  @moduledoc """
  What core's people picker (`PhoenixKitWeb.Components.PeoplePicker`)
  offers in Projects: staff's teams, departments and people, and accounts
  with no staff record yet — the same search, "Recent" chips and staff
  record question as the module's own picker had (the boss, 2026-11-18:
  "make sure this component is in core because it's pretty useful").

  Keys are `{kind, uuid}`: `"person"`, `"team"`, `"department"` — what a
  task, a project or a library task is assigned to — and `"user"`, an
  account with no staff record. Picking a `"user"` asks first and, on Yes,
  makes the staff record (`People.ensure_person_for_user/2`, logged as the
  old picker did) and picks the person it became.

  `ctx` takes `:project_uuid` (the project whose tasks Recent looks at) and
  `:source` (the activity's `source`, "task_form" by default), plus core's
  `:viewer_uuid` and `:locale`.
  """

  @behaviour PhoenixKitWeb.Components.PeoplePicker.Source

  use Gettext, backend: PhoenixKitProjects.Gettext

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
    {Enum.map(rows, &row/1), next}
  end

  def page({:search, text}, cursor, limit, ctx) when is_binary(text) do
    {rows, next} = Assignees.page({:search, text}, cursor, limit, lang(ctx))
    {Enum.map(rows, &row/1), next}
  end

  def page(_view, _cursor, _limit, _ctx), do: {[], nil}

  @impl true
  def describe({"user", uuid}, _ctx), do: uuid |> Assignees.describe_user() |> row()

  def describe({kind, uuid}, ctx) when kind in @kinds,
    do: kind |> Assignees.describe(uuid, lang(ctx)) |> row()

  def describe(_key, _ctx), do: nil

  # A new pick: a trashed person is offered nowhere, so a pick naming one
  # takes nobody; an account asks before a staff record is made for it.
  @impl true
  def pick({"user", _uuid} = key, ctx) do
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

  def pick({kind, uuid} = key, _ctx) when kind in @kinds do
    case Assignees.describe_pick(kind, uuid) do
      %{} -> {:ok, key}
      _ -> {:error, gettext("That person can no longer be picked.")}
    end
  end

  def pick(_key, _ctx), do: {:error, gettext("That person can no longer be picked.")}

  @impl true
  def confirm({"user", uuid}, ctx) do
    case People.ensure_person_for_user(uuid,
           actor_uuid: ctx[:viewer_uuid],
           source: ctx[:source] || "task_form"
         ) do
      {:ok, %{uuid: person_uuid}} -> {:ok, {"person", person_uuid}}
      {:error, :trashed_person} -> {:error, gettext("Their staff record is in the trash.")}
      {:error, _} -> {:error, gettext("Could not create the staff record.")}
    end
  end

  def confirm(_key, _ctx), do: {:error, gettext("That person can no longer be picked.")}

  # "Assign to me": the viewer's staff person, else their account (which
  # then asks to make the record).
  @impl true
  def me(%{viewer_uuid: viewer}) when is_binary(viewer) do
    case People.get_person_by_user_uuid(viewer) do
      %{uuid: person_uuid, status: status} when status != "trashed" -> {"person", person_uuid}
      %{} -> nil
      nil -> if Assignees.describe_user(viewer), do: {"user", viewer}
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
      faces: faces(r[:faces])
    }
  end

  defp row(_), do: nil

  # `Assignees` faces (`%{faces: [%{name, user}], extra}`) as core's stack
  # of users; people with no account have no picture to stack.
  defp faces(%{faces: list}) when is_list(list),
    do: for(%{user: %{} = user} <- list, do: user)

  defp faces(_), do: []

  defp lang(ctx), do: ctx[:locale]
end
