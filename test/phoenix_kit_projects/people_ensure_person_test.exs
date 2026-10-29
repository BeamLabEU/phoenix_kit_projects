defmodule PhoenixKitProjects.PeopleEnsurePersonTest do
  @moduledoc """
  `People.ensure_person_for_user/2` — any user can be assigned a task: an
  existing staff person is reused, a missing one is made through staff's
  own context, a trashed one is refused (never restored or duplicated) —
  and the picker's users without a person (`Assignees.search_assignees/3`).
  """

  use PhoenixKitProjects.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{Assignees, People}
  alias PhoenixKitStaff.Schemas.Person, as: StaffPerson
  alias PhoenixKitStaff.Staff

  defp user!(attrs \\ %{}) do
    {:ok, user} =
      Auth.register_user(
        Map.merge(
          %{
            "email" => "ensure-#{System.unique_integer([:positive])}@example.com",
            "password" => "ValidPassword123!"
          },
          attrs
        )
      )

    user
  end

  defp people_of(user_uuid),
    do: Repo.all(from(p in StaffPerson, where: p.user_uuid == ^user_uuid))

  test "creates a bare person named after the email's local part, logged, once" do
    user = user!()
    [local, _] = String.split(user.email, "@")

    assert {:ok, %People.Person{name: ^local, status: "active"} = person} =
             People.ensure_person_for_user(user.uuid, actor_uuid: user.uuid)

    assert person.user_uuid == user.uuid
    assert {:ok, %{uuid: same}} = People.ensure_person_for_user(user.uuid)
    assert same == person.uuid
    assert length(people_of(user.uuid)) == 1

    row = assert_activity_logged("projects.staff_person_created", resource_uuid: person.uuid)
    refute inspect(row.metadata) =~ "@"
  end

  test "uses the user's full name when there is one" do
    user = user!(%{"first_name" => "Ada", "last_name" => "Lovelace"})
    assert {:ok, %{name: "Ada Lovelace"}} = People.ensure_person_for_user(user.uuid)
  end

  test "a trashed person is refused; nothing restored or duplicated" do
    user = user!()
    {:ok, person} = Staff.create_person(%{"user_uuid" => user.uuid, "name" => "Old"})
    {:ok, _} = Staff.trash_person(person)

    assert {:error, :trashed_person} = People.ensure_person_for_user(user.uuid)
    assert [%{status: "trashed"}] = people_of(user.uuid)
    refute_activity_logged("projects.staff_person_created")
  end

  test "a disabled, unknown or service user is not assignable" do
    off = user!()
    off |> Ecto.Changeset.change(is_active: false) |> Repo.update!()

    assert {:error, :not_assignable} = People.ensure_person_for_user(off.uuid)
    assert {:error, :not_assignable} = People.ensure_person_for_user(Ecto.UUID.generate())
    assert {:error, :not_assignable} = People.ensure_person_for_user(nil)
    assert people_of(off.uuid) == []
  end

  test "the picker pages users without a person after the rest" do
    tag = "Pager#{System.unique_integer([:positive])}"
    users = for i <- 1..3, do: user!(%{"first_name" => tag, "last_name" => "U#{i}"})

    assert {[a, b], true} = Assignees.search_assignees(tag, 2)
    assert {rows, false} = Assignees.search_assignees(tag, 3)
    assert Enum.map(rows, & &1.uuid) == Enum.map(users, & &1.uuid)
    assert Enum.all?([a, b | rows], &(&1.kind == "user"))
  end
end
