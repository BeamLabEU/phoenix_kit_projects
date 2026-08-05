defmodule PhoenixKitProjects.Integration.PeopleSeamTest do
  @moduledoc """
  The staff-optional seam (Phase B), panel-approved proof battery:

    * CONTRACT — every shadow-schema field maps to a real column on the
      core-owned staff tables (the drift backstop: if core's migrations
      ever reshape those tables, this breaks loudly before prod).
    * FUNCTIONAL — each coupling site works off rows seeded RAW (no staff
      contexts): belongs_to preloads, the authz relationship grant, the
      notification target resolution, the People doorway reads, and the
      label semantics mirrored from staff.

  Paired with the compile gate: `WITHOUT_STAFF=1 mix deps.get && mix
  compile --warnings-as-errors` proves no hard staff reference exists.
  """

  use PhoenixKitProjects.DataCase, async: false

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{Activity, Authz, People, Projects}
  alias PhoenixKitProjects.People.{Department, Person, Team, TeamMembership}

  @tables [
    {Person, "phoenix_kit_staff_people"},
    {Team, "phoenix_kit_staff_teams"},
    {Department, "phoenix_kit_staff_departments"},
    {TeamMembership, "phoenix_kit_staff_team_memberships"}
  ]

  test "CONTRACT: every shadow field is a real column (core V100+ shape)" do
    for {schema, table} <- @tables do
      columns =
        RepoHelper.repo().query!(
          "SELECT column_name FROM information_schema.columns WHERE table_name = $1",
          [table]
        ).rows
        |> List.flatten()
        |> MapSet.new()

      for field <- schema.__schema__(:fields) do
        column = to_string(field)

        assert MapSet.member?(columns, column),
               "#{inspect(schema)} maps #{column}, missing on #{table}"
      end
    end
  end

  # ── Raw fixtures: NO staff contexts anywhere below ─────────────────

  defp raw_department(name) do
    uuid = UUIDv7.generate()

    RepoHelper.repo().insert_all("phoenix_kit_staff_departments", [
      %{uuid: Ecto.UUID.dump!(uuid), name: name, inserted_at: now(), updated_at: now()}
    ])

    uuid
  end

  defp raw_team(name, department_uuid, translations \\ %{}) do
    uuid = UUIDv7.generate()

    RepoHelper.repo().insert_all("phoenix_kit_staff_teams", [
      %{
        uuid: Ecto.UUID.dump!(uuid),
        name: name,
        department_uuid: Ecto.UUID.dump!(department_uuid),
        translations: translations,
        inserted_at: now(),
        updated_at: now()
      }
    ])

    uuid
  end

  defp raw_person(attrs) do
    uuid = UUIDv7.generate()

    row =
      %{
        uuid: Ecto.UUID.dump!(uuid),
        status: "active",
        inserted_at: now(),
        updated_at: now()
      }
      |> Map.merge(Map.new(attrs))
      |> Map.update(:user_uuid, nil, fn
        nil -> nil
        v -> Ecto.UUID.dump!(v)
      end)
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    RepoHelper.repo().insert_all("phoenix_kit_staff_people", [row])
    uuid
  end

  defp raw_membership(team_uuid, person_uuid) do
    RepoHelper.repo().insert_all("phoenix_kit_staff_team_memberships", [
      %{
        uuid: Ecto.UUID.dump!(UUIDv7.generate()),
        team_uuid: Ecto.UUID.dump!(team_uuid),
        staff_person_uuid: Ecto.UUID.dump!(person_uuid),
        # This table carries inserted_at only (core V100 shape).
        inserted_at: now()
      }
    ])
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp user_fixture do
    {:ok, user} =
      Auth.register_user(%{
        email: "seam-#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    user
  end

  test "FUNCTIONAL: belongs_to preloads + authz grant + notification target off raw rows" do
    user = user_fixture()
    person_uuid = raw_person(%{user_uuid: user.uuid})

    project = fixture_project()
    task = fixture_task()

    {:ok, assignment} =
      Projects.create_assignment(%{
        "project_uuid" => project.uuid,
        "task_uuid" => task.uuid,
        "status" => "todo",
        "assigned_person_uuid" => person_uuid
      })

    # The preload graph over the SHADOW schemas.
    loaded = Projects.get_assignment(assignment.uuid)
    assert %Person{} = loaded.assigned_person
    assert loaded.assigned_person.user.email == user.email

    # Authz relationship grant reads user_uuid off the shadow preload —
    # grants AUGMENT membership (a viewer below the manager floor), they
    # don't replace it.
    {:ok, _} = PhoenixKitProjects.Members.add_member(project, user.uuid, role: "viewer")
    refute Authz.can?(user.uuid, project, :log_time)
    assert Authz.can?(user.uuid, project, :log_time, loaded)

    # Notification target resolution (the non-preloaded fallback path
    # goes through People.get_person).
    assert Activity.assignee_target_uuid(%{assigned_person_uuid: person_uuid}) == user.uuid
  end

  test "FUNCTIONAL: the People doorway reads + label semantics" do
    dept = raw_department("Engineering")

    team =
      raw_team("Platform", dept, %{"et" => %{"name" => "Platvorm"}})

    user = user_fixture()
    named = raw_person(%{name: "Jane Doe", user_uuid: user.uuid})
    nameless = raw_person(%{user_uuid: user_fixture().uuid})
    raw_membership(team, named)

    # Doorway lists (trashed excluded by default — staff parity).
    # people.user_uuid is NOT NULL (core V100) — even a trashed fixture
    # needs its user.
    _trashed = raw_person(%{name: "Ghost", status: "trashed", user_uuid: user_fixture().uuid})
    people = People.list_people()
    names = Enum.map(people, &People.display_name/1)
    assert "Jane Doe" in names
    refute "Ghost" in names

    assert [%Team{name: "Platform"} = t] = People.list_teams()
    assert t.department.name == "Engineering"
    assert [%Department{name: "Engineering"}] = People.list_departments()

    assert [membership] = People.list_memberships_for_person(named)
    assert membership.team.department.name == "Engineering"

    # Label semantics: name → user email fallback; localized names.
    assert People.display_name(People.get_person(named)) == "Jane Doe"
    nameless_loaded = People.get_person(nameless)
    assert People.display_name(nameless_loaded) == nameless_loaded.user.email
    assert People.localized_name(t, "et") == "Platvorm"
    assert People.localized_name(t, "de") == "Platform"

    # user → person reverse lookup (the "Me" chip / my-tasks path).
    assert People.get_person_by_user_uuid(user.uuid).uuid == named
  end
end
