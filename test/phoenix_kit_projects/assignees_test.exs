defmodule PhoenixKitProjects.AssigneesTest do
  @moduledoc """
  Unit tests for the effective-assignee resolver — the single source of
  "whose work is this?" semantics behind the Overview calendar's filter.
  Pins the one-level inheritance scope (person + their teams + the teams'
  departments + their primary department), the match provenance, and the
  fail-safe nil returns.
  """

  use PhoenixKitProjects.DataCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.Assignees
  alias PhoenixKitProjects.Schemas.Assignment
  alias PhoenixKitStaff.{Departments, Staff, Teams}

  defp uniq, do: System.unique_integer([:positive])

  defp staff_fixture do
    {:ok, dept_a} = Departments.create(%{"name" => "DeptA-#{uniq()}"})
    {:ok, dept_b} = Departments.create(%{"name" => "DeptB-#{uniq()}"})

    {:ok, team} =
      Teams.create(%{"name" => "Team-#{uniq()}", "department_uuid" => dept_a.uuid})

    {:ok, user} =
      Auth.register_user(%{
        "email" => "anna-#{uniq()}@example.com",
        "password" => "ActorPass123!"
      })

    {:ok, person} =
      Staff.create_person(%{
        "user_uuid" => user.uuid,
        "name" => "Anna Assignee",
        "employment_type" => "full_time",
        "primary_department_uuid" => dept_b.uuid
      })

    %{person: person, team: team, dept_a: dept_a, dept_b: dept_b}
  end

  # `create_person` requires a linked auth user; membership added separately.
  defp with_membership(%{person: person, team: team} = fx) do
    {:ok, _} = Staff.add_team_person(team.uuid, person.uuid)
    fx
  end

  # One assignment on a fresh project with the given assignee attrs
  # ("assigned_person_uuid" / "assigned_team_uuid" / "assigned_department_uuid",
  # or none). Returns the project.
  defp assignment_on_fresh_project(assignee_attrs, project_attrs \\ %{}) do
    project = fixture_project(project_attrs)
    task = fixture_task()

    {:ok, _} =
      PhoenixKitProjects.Projects.create_assignment(
        Map.merge(
          %{"project_uuid" => project.uuid, "task_uuid" => task.uuid},
          assignee_attrs
        )
      )

    project
  end

  # The picker only offers people at least one real assignment points at, so
  # picker-contract fixtures need one. Returns fx with :project.
  defp relevant(%{person: person} = fx) do
    Map.put(fx, :project, assignment_on_fresh_project(%{"assigned_person_uuid" => person.uuid}))
  end

  defp uuids(rows), do: MapSet.new(rows, & &1.uuid)

  describe "scope_for_person/2" do
    test "collects the person, their teams, the teams' departments, and the primary department" do
      %{person: person, team: team, dept_a: dept_a, dept_b: dept_b} =
        with_membership(staff_fixture())

      scope = Assignees.scope_for_person(person.uuid)

      assert scope.person_uuid == person.uuid
      assert Map.has_key?(scope.team_names, team.uuid)
      # Team's own department AND the (different) primary department.
      assert Map.has_key?(scope.department_names, dept_a.uuid)
      assert Map.has_key?(scope.department_names, dept_b.uuid)
    end

    test "unknown person resolves to nil" do
      assert Assignees.scope_for_person(Ecto.UUID.generate()) == nil
    end
  end

  describe "scope_for_user/2" do
    test "resolves auth user -> staff person -> scope; nil without a person" do
      %{person: _} = staff_fixture()

      {:ok, user} =
        Auth.register_user(%{
          "email" => "assignee-#{uniq()}@example.com",
          "password" => "ActorPass123!"
        })

      # No staff person linked yet.
      assert Assignees.scope_for_user(user.uuid, nil) == nil
      assert Assignees.scope_for_user(nil, nil) == nil

      {:ok, linked} =
        Staff.create_person(%{
          "user_uuid" => user.uuid,
          "first_name" => "Linked",
          "last_name" => "User",
          "employment_type" => "full_time"
        })

      scope = Assignees.scope_for_user(user.uuid, nil)
      assert scope.person_uuid == linked.uuid
    end
  end

  describe "match/2 + unassigned?/1" do
    test "direct, team, department provenance and misses" do
      %{person: person, team: team, dept_b: dept_b} = with_membership(staff_fixture())
      scope = Assignees.scope_for_person(person.uuid)

      assert Assignees.match(%Assignment{assigned_person_uuid: person.uuid}, scope) == :direct

      assert {:team, _name} =
               Assignees.match(%Assignment{assigned_team_uuid: team.uuid}, scope)

      assert {:department, _name} =
               Assignees.match(%Assignment{assigned_department_uuid: dept_b.uuid}, scope)

      assert Assignees.match(%Assignment{assigned_person_uuid: Ecto.UUID.generate()}, scope) ==
               nil

      assert Assignees.match(%Assignment{}, scope) == nil

      assert Assignees.unassigned?(%Assignment{})
      refute Assignees.unassigned?(%Assignment{assigned_team_uuid: team.uuid})
    end
  end

  describe "search_people/2 (picker contract)" do
    test "empty query is browse mode: first page, name-sorted, DB-limited" do
      %{person: person} = relevant(staff_fixture())

      {rows, _has_more} = Assignees.search_people("", 50)

      row = Enum.find(rows, &(&1.uuid == person.uuid))
      assert %{kind: "person", label: "Anna Assignee", icon: "hero-user"} = row
      assert row.sublabel =~ "@example.com"

      labels = Enum.map(rows, &String.downcase(&1.label))
      assert labels == Enum.sort(labels)
    end

    test "limit+1 probes has_more and pages stay at the limit" do
      for _ <- 1..3, do: relevant(staff_fixture())

      {rows, has_more} = Assignees.search_people("", 2)
      assert length(rows) == 2
      assert has_more

      {_all, false} = Assignees.search_people("", 50)
    end

    test "matches name or email, case-insensitively" do
      %{person: person} = relevant(staff_fixture())

      {by_name, _} = Assignees.search_people("anna assign", 10)
      assert Enum.any?(by_name, &(&1.uuid == person.uuid))

      {by_email, _} = Assignees.search_people("anna-", 10)
      assert Enum.any?(by_email, &(&1.uuid == person.uuid))

      {none, _} = Assignees.search_people("zzz-no-such-person", 10)
      assert none == []
    end

    test "ILIKE wildcards in the query are escaped, not interpreted" do
      _ = relevant(staff_fixture())

      {rows, _} = Assignees.search_people("%", 10)
      assert rows == []

      {rows, _} = Assignees.search_people("_", 10)
      assert rows == []
    end

    test "a backslash in the query is escaped, not an escape prefix" do
      _ = relevant(staff_fixture())

      # Unescaped, `\%` would turn the following into a literal-% match (or
      # error); escaped, it's just a character no name contains.
      {rows, _} = Assignees.search_people("\\", 10)
      assert rows == []

      {rows, _} = Assignees.search_people("\\%", 10)
      assert rows == []
    end

    test "free-text edge inputs neither crash nor over-match" do
      %{person: person} = relevant(staff_fixture())

      # Unicode (CJK + emoji) — parameterized ILIKE, no encoding crash.
      {rows, _} = Assignees.search_people("检索🙂", 10)
      assert rows == []

      # Very long query.
      {rows, _} = Assignees.search_people(String.duplicate("x", 300), 10)
      assert rows == []

      # nil coerces to browse mode ("" via to_string) rather than raising.
      {rows, _} = Assignees.search_people(nil, 10)
      assert Enum.any?(rows, &(&1.uuid == person.uuid))
    end
  end

  describe "search_people/3 relevance (only people scheduled work can point at)" do
    test "a person no assignment points at is not offered — browse or typed" do
      %{person: person} = staff_fixture()

      {browse, _} = Assignees.search_people("", 50)
      refute MapSet.member?(uuids(browse), person.uuid)

      {typed, _} = Assignees.search_people("anna", 50)
      refute MapSet.member?(uuids(typed), person.uuid)
    end

    test "a fresh install (no projects at all) offers nobody" do
      _ = staff_fixture()
      {rows, has_more} = Assignees.search_people("", 50)
      assert rows == []
      refute has_more
    end

    test "direct, via-team, via-primary-department, and via-team's-department all count" do
      direct = staff_fixture()
      _ = assignment_on_fresh_project(%{"assigned_person_uuid" => direct.person.uuid})

      %{person: tp, team: team} = with_membership(staff_fixture())
      _ = assignment_on_fresh_project(%{"assigned_team_uuid" => team.uuid})

      %{person: dp, dept_b: dept_b} = staff_fixture()
      _ = assignment_on_fresh_project(%{"assigned_department_uuid" => dept_b.uuid})

      # Assignment on the DEPARTMENT of a team the person belongs to.
      %{person: tdp, dept_a: dept_a} = with_membership(staff_fixture())
      _ = assignment_on_fresh_project(%{"assigned_department_uuid" => dept_a.uuid})

      {rows, _} = Assignees.search_people("", 50)
      offered = uuids(rows)

      for p <- [direct.person, tp, dp, tdp] do
        assert MapSet.member?(offered, p.uuid)
      end
    end

    test "an unassigned task or a template assignment does not make anyone relevant" do
      %{person: person} = fx = staff_fixture()
      _ = assignment_on_fresh_project(%{})

      template = fixture_template()
      task = fixture_task()

      {:ok, _} =
        PhoenixKitProjects.Projects.create_assignment(%{
          "project_uuid" => template.uuid,
          "task_uuid" => task.uuid,
          "assigned_person_uuid" => person.uuid
        })

      {rows, _} = Assignees.search_people("", 50)
      refute MapSet.member?(uuids(rows), person.uuid)

      # The same person becomes relevant the moment a REAL project points
      # at them.
      _ = relevant(fx)
      {rows, _} = Assignees.search_people("", 50)
      assert MapSet.member?(uuids(rows), person.uuid)
    end

    test "project_uuids narrows relevance to the given tree" do
      a = relevant(staff_fixture())
      b = relevant(staff_fixture())

      {rows, _} = Assignees.search_people("", 50, project_uuids: [a.project.uuid])
      offered = uuids(rows)

      assert MapSet.member?(offered, a.person.uuid)
      refute MapSet.member?(offered, b.person.uuid)
    end

    test "a scope that IS a template offers its default assignees verbatim" do
      # Deliberate asymmetry with the unscoped template exclusion: scoped
      # relevance mirrors exactly what the scoped calendar renders, and a
      # template's own calendar (direct URL / host embed) shows its tasks —
      # so its default assignees are offerable there, and only there.
      %{person: person} = staff_fixture()
      template = fixture_template()
      task = fixture_task()

      {:ok, _} =
        PhoenixKitProjects.Projects.create_assignment(%{
          "project_uuid" => template.uuid,
          "task_uuid" => task.uuid,
          "assigned_person_uuid" => person.uuid
        })

      {scoped, _} = Assignees.search_people("", 50, project_uuids: [template.uuid])
      assert MapSet.member?(uuids(scoped), person.uuid)

      {global, _} = Assignees.search_people("", 50)
      refute MapSet.member?(uuids(global), person.uuid)
    end
  end
end
