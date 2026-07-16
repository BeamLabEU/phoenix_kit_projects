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

  describe "people_options/0" do
    test "lists people as {name, uuid} sorted by name" do
      %{person: person} = staff_fixture()

      options = Assignees.people_options()
      assert {"Anna Assignee", person.uuid} in options

      names = Enum.map(options, fn {name, _} -> String.downcase(name) end)
      assert names == Enum.sort(names)
    end
  end
end
