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
      %{person: person} = staff_fixture()

      {rows, _has_more} = Assignees.search_people("", 50)

      row = Enum.find(rows, &(&1.uuid == person.uuid))
      assert %{kind: "person", label: "Anna Assignee", icon: "hero-user"} = row
      assert row.sublabel =~ "@example.com"

      labels = Enum.map(rows, &String.downcase(&1.label))
      assert labels == Enum.sort(labels)
    end

    test "limit+1 probes has_more and pages stay at the limit" do
      for _ <- 1..3, do: staff_fixture()

      {rows, has_more} = Assignees.search_people("", 2)
      assert length(rows) == 2
      assert has_more

      {_all, false} = Assignees.search_people("", 50)
    end

    test "matches name or email, case-insensitively" do
      %{person: person} = staff_fixture()

      {by_name, _} = Assignees.search_people("anna assign", 10)
      assert Enum.any?(by_name, &(&1.uuid == person.uuid))

      {by_email, _} = Assignees.search_people("anna-", 10)
      assert Enum.any?(by_email, &(&1.uuid == person.uuid))

      {none, _} = Assignees.search_people("zzz-no-such-person", 10)
      assert none == []
    end

    test "ILIKE wildcards in the query are escaped, not interpreted" do
      _ = staff_fixture()

      {rows, _} = Assignees.search_people("%", 10)
      assert rows == []

      {rows, _} = Assignees.search_people("_", 10)
      assert rows == []
    end

    test "a backslash in the query is escaped, not an escape prefix" do
      _ = staff_fixture()

      # Unescaped, `\%` would turn the following into a literal-% match (or
      # error); escaped, it's just a character no name contains.
      {rows, _} = Assignees.search_people("\\", 10)
      assert rows == []

      {rows, _} = Assignees.search_people("\\%", 10)
      assert rows == []
    end

    test "free-text edge inputs neither crash nor over-match" do
      %{person: person} = staff_fixture()

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
end
