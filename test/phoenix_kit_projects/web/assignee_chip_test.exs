defmodule PhoenixKitProjects.Web.AssigneeChipTest do
  @moduledoc """
  A task's assignee reads like a tag (Max, 2026-11-25): one person with an
  account is core's person chip, which opens their card; several people
  carry `data-people`, which opens the side drawer with each of them.
  """

  use PhoenixKitProjects.DataCase, async: false

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import Phoenix.Component, only: [sigil_H: 2]

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{Assignees, Projects}
  alias PhoenixKitProjects.People.Person
  alias PhoenixKitProjects.Test.Repo
  alias PhoenixKitProjects.Web.Components.AssigneeFaces

  defp person!(name) do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "#{name}-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!",
        "first_name" => name
      })

    {:ok, person} =
      Repo.insert(%Person{
        uuid: UUIDv7.generate(),
        user_uuid: user.uuid,
        status: "active",
        name: name
      })

    {user, person}
  end

  defp task!(project, assignees) do
    {:ok, %{assignment: a}} =
      Projects.create_task_with_assignment(
        project.uuid,
        %{"title" => "Fit the doors", "ad_hoc" => true},
        %{"assignees" => assignees}
      )

    Projects.get_assignment(a.uuid)
  end

  defp shown(a) do
    faces = Assignees.faces([a]) |> Map.get(a.uuid)
    assigns = %{a: a, faces: faces}

    rendered_to_string(~H"""
    <AssigneeFaces.assignee_shown a={@a} faces={@faces} />
    """)
  end

  test "one person with an account is a person chip that opens their card" do
    {user, person} = person!("Anna")
    a = task!(fixture_project(), [{"person", person.uuid}])

    html = shown(a)
    assert html =~ ~s(data-mention-user="#{user.uuid}")
    assert html =~ "pk-person-chip"
    refute html =~ "data-people"
  end

  test "several people carry data-people for the drawer" do
    members = Enum.map(~w(Anna Ben Cam Dee Eli), &person!/1)
    a = task!(fixture_project(), Enum.map(members, fn {_, p} -> {"person", p.uuid} end))

    html = shown(a)
    assert html =~ "+1"
    [_, people] = Regex.run(~r/data-people="([^"]+)"/, html)

    assert Enum.sort(String.split(people, ",")) ==
             Enum.sort(Enum.map(members, fn {u, _} -> u.uuid end))
  end
end
