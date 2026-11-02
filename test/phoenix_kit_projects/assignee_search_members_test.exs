defmodule PhoenixKitProjects.AssigneeSearchMembersTest do
  @moduledoc """
  The task form's assignee search (`Assignees.search_assignees/3`): a team
  or department the text matches brings its people right under it, each
  labelled with where they come from and listed once.
  """

  use PhoenixKitProjects.DataCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.Assignees
  alias PhoenixKitProjects.Test.Repo
  alias PhoenixKitStaff.Schemas.{Department, Person, Team, TeamMembership}

  defp person!(name, attrs \\ %{}) do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "#{String.downcase(name)}-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    Repo.insert!(
      struct(Person, Map.merge(%{user_uuid: user.uuid, status: "active", name: name}, attrs))
    )
  end

  setup do
    tag = System.unique_integer([:positive])
    finance = Repo.insert!(%Department{name: "Finance #{tag}"})
    payroll = Repo.insert!(%Team{name: "Payroll #{tag}", department_uuid: finance.uuid})

    kadri = person!("Kadri", %{primary_department_uuid: finance.uuid})
    priit = person!("Priit")
    Repo.insert!(%TeamMembership{team_uuid: payroll.uuid, staff_person_uuid: priit.uuid})
    gone = person!("Gone", %{primary_department_uuid: finance.uuid, status: "trashed"})

    %{tag: tag, finance: finance, payroll: payroll, kadri: kadri, priit: priit, gone: gone}
  end

  test "a department's name finds its people under it, with where they come from", ctx do
    {rows, _more} = Assignees.search_assignees("Finance #{ctx.tag}", 50)

    labels = Enum.map(rows, &{&1.kind, &1.label, &1.sublabel})
    dept_at = Enum.find_index(rows, &(&1.kind == "department" and &1.uuid == ctx.finance.uuid))
    assert dept_at

    members = Enum.drop(rows, dept_at + 1) |> Enum.take_while(&(&1.kind == "person"))

    # Where they come from, after their email on the row's second line.
    assert {"person", "Kadri", "Finance #{ctx.tag}"} in Enum.map(
             members,
             &{&1.kind, &1.label, &1.place}
           )

    assert {"person", "Priit", "Finance #{ctx.tag} › Payroll #{ctx.tag}"} in Enum.map(
             members,
             &{&1.kind, &1.label, &1.place}
           )

    kadri = Enum.find(members, &(&1.uuid == ctx.kadri.uuid))
    assert kadri.sublabel == "#{kadri.email} · Finance #{ctx.tag}"

    refute Enum.any?(labels, fn {_, label, _} -> label == "Gone" end)
  end

  test "a team's name finds its members; each person is listed once", ctx do
    {rows, _more} = Assignees.search_assignees("#{ctx.tag}", 50)

    priits = Enum.filter(rows, &(&1.uuid == ctx.priit.uuid))
    assert length(priits) == 1

    team_at = Enum.find_index(rows, &(&1.kind == "team" and &1.uuid == ctx.payroll.uuid))
    assert Enum.at(rows, team_at + 1).uuid == ctx.priit.uuid
  end

  test "a person matching their own name is not repeated under a group", ctx do
    {rows, _more} = Assignees.search_assignees("Kadri", 50)
    assert Enum.count(rows, &(&1.uuid == ctx.kadri.uuid)) == 1
  end

  test "an empty query is browse mode: groups without their members" do
    {rows, _more} = Assignees.search_assignees("", 100)
    kinds = Enum.map(rows, & &1.kind)
    refute Enum.any?(Enum.chunk_every(kinds, 2, 1), &(&1 == ["department", "person"]))
  end
end
