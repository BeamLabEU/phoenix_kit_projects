defmodule PhoenixKitProjects.People do
  @moduledoc """
  The ONE doorway to people/team/department data for this module — the
  staff-optional seam (Phase B of the hub rework, panel-approved design).

  ## Why shadow schemas, not a bridge

  The staff DB tables are created by CORE's migrations (V100), not by the
  `phoenix_kit_staff` package — staff ships no migrations; it is the
  admin UI + context over core-owned tables. So the tables (and projects'
  SQL FKs to them) exist on every install, and projects can keep its
  `belongs_to` graph, preloads, authz relationship grants, and direct
  assignee queries by mapping its OWN minimal read-only schemas
  (`PhoenixKitProjects.People.{Person,Team,Department,TeamMembership}`)
  over those tables. The staff PACKAGE is optional: it is the people
  ADMIN surface, not the data's owner.

  ## Rules

    * Read-only: no changesets, no writes — people are managed in staff.
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

  @doc "The person linked to a core user, or nil."
  @spec get_person_by_user_uuid(binary(), keyword()) :: Person.t() | nil
  def get_person_by_user_uuid(user_uuid, opts \\ []) do
    preload = Keyword.get(opts, :preload, [])

    from(p in Person, where: p.user_uuid == ^user_uuid and p.status != @trashed)
    |> preload(^preload)
    |> RepoHelper.repo().one()
  rescue
    _ -> nil
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
