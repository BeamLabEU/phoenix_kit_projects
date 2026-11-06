defmodule PhoenixKitProjects.People do
  @moduledoc """
  The ONE doorway to people/team/department data for this module — the
  staff-optional seam (Phase B of the hub rework, panel-approved design).

  ## Why shadow schemas, not a bridge

  The staff DB tables belong to the `phoenix_kit_staff` package's own chain
  (core 3.x creates none of them), and this module's chain runs it first,
  because its SQL FKs point at them. So the tables exist wherever this
  module is installed, and projects can keep its `belongs_to` graph,
  preloads, authz relationship grants, and direct assignee queries by
  mapping its OWN minimal read-only schemas
  (`PhoenixKitProjects.People.{Person,Team,Department,TeamMembership}`)
  over those tables, reading them without going through staff's code.

  ## Rules

    * Read-only: no changesets, no writes — people are managed in staff.
      The one exception is `ensure_person_for_user/2`, which creates a
      bare person for a user being assigned a task, through staff's own
      `PhoenixKitStaff.Staff.create_person/1` (never an insert of ours).
    * Filter semantics COPIED from staff, not imported: soft-deleted rows
      are `status == "trashed"` and excluded from listings by default.
    * Label semantics mirrored from staff: `display_name/1` resolves
      name → user's first/last name → user email → "Unnamed";
      team/department names localize via the row's `translations` map.
    * `staff_admin_available?/0` gates ONLY admin-UI affordances (manage-
      people links, the "Me" chip's person resolution when staff adds
      value) — data reads never require the staff package.
  """

  import Ecto.Query

  use Gettext, backend: PhoenixKitProjects.Gettext

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.People.Department
  alias PhoenixKitProjects.People.Person
  alias PhoenixKitProjects.People.Team
  alias PhoenixKitProjects.People.TeamMembership

  @trashed "trashed"

  @doc """
  Whether the staff PACKAGE (the people admin surface) is installed and
  enabled — for UI affordances only; the data paths below never need it.
  """
  @spec staff_admin_available?() :: boolean()
  def staff_admin_available? do
    Code.ensure_loaded?(PhoenixKitStaff) and
      function_exported?(PhoenixKitStaff, :enabled?, 0) and
      staff_enabled?()
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  @staff_page %{"person" => :person, "team" => :team, "department" => :department}

  @doc """
  The staff admin page of a person, team or department, or nil when the
  staff module is not there to show it (`staff_admin_available?/0`) — a
  page then names the assignee without a link. Called through `apply/3`
  for the same reason as `staff_enabled?/0`.
  """
  @spec staff_page_path(String.t(), binary()) :: String.t() | nil
  def staff_page_path(kind, uuid) when is_binary(uuid) do
    fun = Map.get(@staff_page, kind, :person)

    if staff_admin_available?() and Code.ensure_loaded?(PhoenixKitStaff.Paths) and
         function_exported?(PhoenixKitStaff.Paths, fun, 1),
       do: apply(PhoenixKitStaff.Paths, fun, [uuid])
  rescue
    _ -> nil
  end

  def staff_page_path(_kind, _uuid), do: nil

  # `apply/3` is deliberate (the CRM StaffLink precedent): a direct call
  # would emit an undefined-function warning — fatal under
  # warnings-as-errors — when compiled WITHOUT_STAFF.
  defp staff_enabled? do
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    apply(PhoenixKitStaff, :enabled?, [])
  end

  @doc "A person by uuid with `[:user, :primary_department]` preloaded, or nil."
  @spec get_person(binary(), keyword()) :: Person.t() | nil
  def get_person(uuid, opts \\ []) do
    preload = Keyword.get(opts, :preload, [:user, :primary_department])

    Person
    |> preload(^preload)
    |> RepoHelper.repo().get(uuid)
  rescue
    _ -> nil
  end

  @doc """
  The person linked to a core user, or nil. STAFF-PARITY: resolves
  trashed people too (soft-delete keeps assignments/memberships live so
  restore is clean — filtering here blanked My Tasks and the Me chip for
  the whole trash→restore window; panel round). Only LISTINGS exclude
  trashed.
  """
  @spec get_person_by_user_uuid(binary(), keyword()) :: Person.t() | nil
  def get_person_by_user_uuid(user_uuid, opts \\ []) do
    preload = Keyword.get(opts, :preload, [])

    from(p in Person, where: p.user_uuid == ^user_uuid)
    |> preload(^preload)
    |> RepoHelper.repo().one()
  rescue
    _ -> nil
  end

  @doc """
  The staff person a user is assigned through, created when there is none —
  so anyone with an account can be given a task, staff record or not
  (Max, 2026-10-29: "Assign to me" and the picker refused a user with no
  staff person, and the person had to be made in Staff first).

  An existing person is returned as it is. Otherwise a bare one is created
  through `PhoenixKitStaff.Staff.create_person/1` with the user's uuid and a
  name (the user's first and last name, else the part of the email before
  the `@`), and the creation goes to the activity feed as
  `projects.staff_person_created` under `opts[:actor_uuid]`.

  A trashed person is `{:error, :trashed_person}`: it is neither restored
  nor duplicated — restoring is for Staff → People. A user that is not
  there, disabled, or a service account is `{:error, :not_assignable}`;
  a build without the staff package is `{:error, :staff_unavailable}`.
  """
  @spec ensure_person_for_user(binary(), keyword()) ::
          {:ok, Person.t()}
          | {:error, :trashed_person | :not_assignable | :staff_unavailable | term()}
  def ensure_person_for_user(user_uuid, opts \\ [])

  def ensure_person_for_user(user_uuid, opts) when is_binary(user_uuid) do
    case get_person_by_user_uuid(user_uuid) do
      %Person{status: @trashed} -> {:error, :trashed_person}
      %Person{} = person -> {:ok, person}
      nil -> create_person_for_user(user_uuid, opts)
    end
  end

  def ensure_person_for_user(_user_uuid, _opts), do: {:error, :not_assignable}

  @doc """
  Whether a user account may stand behind an assignee: it exists, is
  active, and is not a service account (`api_only`).
  """
  @spec assignable_user?(map() | nil) :: boolean()
  def assignable_user?(%{is_active: true} = user), do: Map.get(user, :api_only) != true
  def assignable_user?(_), do: false

  defp create_person_for_user(user_uuid, opts) do
    with {:ok, user} <- fetch_assignable_user(user_uuid),
         {:ok, create} <- staff_create_person() do
      attrs = %{"user_uuid" => user.uuid, "name" => new_person_name(user), "status" => "active"}

      case create.(attrs) do
        {:ok, %{uuid: uuid}} ->
          log_person_created(uuid, user.uuid, opts)
          {:ok, get_person(uuid, preload: [])}

        {:error, {:trashed_person_exists, _}} ->
          {:error, :trashed_person}

        # Two presses at once: the other one made the person (the 1:1
        # unique index on `user_uuid` refused this one), so it is theirs.
        {:error, reason} ->
          case get_person_by_user_uuid(user.uuid) do
            %Person{status: @trashed} -> {:error, :trashed_person}
            %Person{} = person -> {:ok, person}
            nil -> {:error, reason}
          end
      end
    end
  end

  defp fetch_assignable_user(user_uuid) do
    user = Auth.get_user(user_uuid)
    if assignable_user?(user), do: {:ok, user}, else: {:error, :not_assignable}
  rescue
    _ -> {:error, :not_assignable}
  end

  # `apply/3` for the reason `staff_enabled?/0` gives: the build may
  # leave the staff package out (WITHOUT_STAFF).
  defp staff_create_person do
    if Code.ensure_loaded?(PhoenixKitStaff.Staff) and
         function_exported?(PhoenixKitStaff.Staff, :create_person, 1) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      {:ok, &apply(PhoenixKitStaff.Staff, :create_person, [&1])}
    else
      {:error, :staff_unavailable}
    end
  end

  @doc """
  The name a person made for `user` gets (and the picker shows for a user
  with no person yet): first and last name, else the email's local part —
  never the whole address, since the name is shown wherever the person is.
  """
  @spec new_person_name(map()) :: String.t()
  def new_person_name(user) do
    [Map.get(user, :first_name), Map.get(user, :last_name)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
    |> String.trim()
    |> case do
      "" -> user |> Map.get(:email, "") |> to_string() |> String.split("@") |> hd()
      full -> full
    end
  end

  # No email (nor the name made from it) in the metadata.
  defp log_person_created(person_uuid, user_uuid, opts) do
    PhoenixKitProjects.Activity.log("projects.staff_person_created",
      actor_uuid: Keyword.get(opts, :actor_uuid),
      resource_type: "staff_person",
      resource_uuid: person_uuid,
      tell: false,
      metadata:
        %{"user_uuid" => user_uuid, "source" => Keyword.get(opts, :source)}
        |> Map.reject(fn {_k, v} -> is_nil(v) end)
    )
  rescue
    _ -> :ok
  end

  @doc """
  Non-trashed people ordered by display name source, `[:user]` preloaded
  (the option loaders read the user email). Mirrors staff's default
  trashed-exclusion.
  """
  @spec list_people(keyword()) :: [Person.t()]
  def list_people(opts \\ []) do
    preload = Keyword.get(opts, :preload, [:user])

    from(p in Person, where: p.status != @trashed, order_by: [asc: p.name])
    |> preload(^preload)
    |> RepoHelper.repo().all()
  rescue
    _ -> []
  end

  @doc "All teams with their department preloaded, name-ordered."
  @spec list_teams() :: [Team.t()]
  def list_teams do
    from(t in Team, order_by: [asc: t.name])
    |> preload(:department)
    |> RepoHelper.repo().all()
  rescue
    _ -> []
  end

  @doc "All departments, name-ordered."
  @spec list_departments() :: [Department.t()]
  def list_departments do
    RepoHelper.repo().all(from(d in Department, order_by: [asc: d.name]))
  rescue
    _ -> []
  end

  @doc """
  The names of a set of teams or departments in one read, `%{uuid => name}`
  — the members page labels its group grants this way (it read one row
  per grant). Unknown uuids are simply absent.
  """
  @spec names_by_uuid(:team | :department, [binary()]) :: %{binary() => String.t()}
  def names_by_uuid(_kind, []), do: %{}

  def names_by_uuid(kind, uuids) when kind in [:team, :department] and is_list(uuids) do
    schema = if kind == :team, do: Team, else: Department

    from(s in schema, where: s.uuid in ^uuids, select: {s.uuid, s.name})
    |> RepoHelper.repo().all()
    |> Map.new()
  rescue
    _ -> %{}
  end

  @doc """
  The display names of a set of people in one read, `%{uuid => name}` —
  trashed people included (an assignment keeps naming whoever holds it).
  Unknown uuids are simply absent.
  """
  @spec person_names([binary()]) :: %{binary() => String.t()}
  def person_names([]), do: %{}

  def person_names(uuids) when is_list(uuids) do
    from(p in Person, where: p.uuid in ^uuids)
    |> preload(:user)
    |> RepoHelper.repo().all()
    |> Map.new(&{&1.uuid, display_name(&1)})
  rescue
    _ -> %{}
  end

  @doc """
  The user accounts a record's assignees stand for — the people a notice
  about it reaches: a person's own account; a team's members; a
  department's people (by their primary department, and its teams'
  members). Every assignee of a task counts (V29, several and all equal),
  each account once. Trashed people and people without an account are
  left out. A project (one assignee) reads its own columns. Anything else,
  or a failed read, is `[]`.
  """
  @spec assignee_user_uuids(map()) :: [binary()]
  def assignee_user_uuids(record) when is_map(record) do
    record |> assignee_keys() |> user_uuids_for()
  end

  def assignee_user_uuids(_), do: []

  @doc """
  The user accounts a list of assignee keys (`{kind, uuid}`) stand for,
  each once — see `assignee_user_uuids/1`.
  """
  @spec user_uuids_for([{String.t(), binary()}]) :: [binary()]
  def user_uuids_for(keys) when is_list(keys) do
    keys |> Enum.flat_map(&key_user_uuids/1) |> Enum.uniq()
  end

  @doc """
  A record's assignees as `[{kind, uuid}]` — a task's, a project's or a
  library task's set (`AssigneeSet.keys/1`, V29/V30).
  """
  @spec assignee_keys(map()) :: [{String.t(), binary()}]
  def assignee_keys(record) when is_map(record),
    do: PhoenixKitProjects.AssigneeSet.keys(record)

  def assignee_keys(_), do: []

  defp key_user_uuids({"person", uuid}) do
    from(p in Person,
      where: p.uuid == ^uuid and p.status != @trashed and not is_nil(p.user_uuid),
      select: p.user_uuid
    )
    |> RepoHelper.repo().all()
  rescue
    _ -> []
  end

  defp key_user_uuids({"team", uuid}) do
    from(m in TeamMembership,
      join: p in Person,
      on: p.uuid == m.staff_person_uuid,
      where: m.team_uuid == ^uuid and p.status != @trashed and not is_nil(p.user_uuid),
      select: p.user_uuid,
      distinct: true
    )
    |> RepoHelper.repo().all()
  rescue
    _ -> []
  end

  # A department's people are those whose primary department it is AND the
  # members of its teams — the same reach as "My tasks" (`Assignees`).
  defp key_user_uuids({"department", uuid}) do
    in_teams =
      from(m in TeamMembership,
        join: t in Team,
        on: t.uuid == m.team_uuid,
        where: t.department_uuid == ^uuid,
        select: m.staff_person_uuid
      )

    from(p in Person,
      where:
        (p.primary_department_uuid == ^uuid or p.uuid in subquery(in_teams)) and
          p.status != @trashed and not is_nil(p.user_uuid),
      select: p.user_uuid,
      distinct: true
    )
    |> RepoHelper.repo().all()
  rescue
    _ -> []
  end

  defp key_user_uuids(_), do: []

  @doc """
  The names of a record's assignees — the person's, the team's or the
  department's (primary names, as audit rows keep them) — joined with
  ", " in chip order, or nil when nobody is on it.
  """
  @spec assignee_name(map()) :: String.t() | nil
  def assignee_name(record) when is_map(record) do
    case record |> assignee_keys() |> Enum.map(&key_name/1) |> Enum.reject(&is_nil/1) do
      [] -> nil
      names -> Enum.join(names, ", ")
    end
  end

  def assignee_name(_), do: nil

  @doc "The name of one assignee key (`{kind, uuid}`), or nil."
  @spec key_name({String.t(), binary()}) :: String.t() | nil
  def key_name({"person", uuid}) do
    case get_person(uuid, preload: [:user]) do
      %Person{} = p -> display_name(p)
      _ -> nil
    end
  end

  def key_name({"team", uuid}), do: name_of(Team, uuid)
  def key_name({"department", uuid}), do: name_of(Department, uuid)
  def key_name(_), do: nil

  defp name_of(schema, uuid) do
    RepoHelper.repo().one(from(x in schema, where: x.uuid == ^uuid, select: x.name))
  rescue
    _ -> nil
  end

  @doc "A person's team memberships with `team: [:department]` preloaded."
  @spec list_memberships_for_person(binary()) :: [TeamMembership.t()]
  def list_memberships_for_person(person_uuid) do
    from(m in TeamMembership, where: m.staff_person_uuid == ^person_uuid)
    |> preload(team: [:department])
    |> RepoHelper.repo().all()
  rescue
    _ -> []
  end

  # ── Label semantics (mirrored from staff, not imported) ────────────

  @doc "name → user's first/last → user email → \"Unnamed\" (staff parity)."
  @spec display_name(Person.t() | nil) :: String.t()
  def display_name(%Person{name: name}) when is_binary(name) and name != "", do: name

  def display_name(%Person{user: %{} = user}) do
    [Map.get(user, :first_name), Map.get(user, :last_name)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
    |> case do
      "" -> Map.get(user, :email) || gettext("Unnamed")
      full -> full
    end
  end

  def display_name(_), do: gettext("Unnamed")

  @doc """
  How the module names accounts, in one read for many: the account's first
  and last name, else its staff person's name, else its email —
  `%{user_uuid => name}`. A person picked or shown by name
  is never shown as an email when a name exists (the boss, 2026-10-30: time
  logs listed people by email).
  """
  @spec user_display_names([String.t()]) :: %{String.t() => String.t()}
  def user_display_names([]), do: %{}

  def user_display_names(user_uuids) when is_list(user_uuids) do
    uuids = Enum.uniq(user_uuids)

    staff =
      from(p in Person,
        where: p.user_uuid in ^uuids and p.status != ^@trashed,
        where: not is_nil(p.name) and p.name != "",
        select: {p.user_uuid, p.name}
      )
      |> RepoHelper.repo().all()
      |> Map.new()

    uuids
    |> Auth.get_users_by_uuids()
    |> Map.new(fn user ->
      {user.uuid, account_name(user) || Map.get(staff, user.uuid) || user.email}
    end)
  rescue
    _ -> %{}
  end

  defp account_name(user) do
    case Auth.User.full_name(user) do
      name when is_binary(name) and name != "" -> name
      _ -> nil
    end
  end

  @doc "A team/department's localized name: `translations[lang][\"name\"]` else the primary."
  @spec localized_name(Team.t() | Department.t() | nil, String.t() | nil) :: String.t() | nil
  def localized_name(%{name: primary, translations: translations}, lang) do
    case is_map(translations) && is_binary(lang) && get_in(translations, [lang, "name"]) do
      val when is_binary(val) and val != "" -> val
      _ -> primary
    end
  end

  def localized_name(_, _lang), do: nil
end
