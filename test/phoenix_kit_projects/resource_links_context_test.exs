defmodule PhoenixKitProjects.ResourceLinksContextTest do
  @moduledoc """
  The `#` typeahead inside a project offers that project's own records and
  its sub-projects', never another main project's (Max, 2026-10-05) — the
  field's context narrows what the searcher may already see.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{Members, Projects, ResourceLinks}

  setup do
    main = fixture_project(%{"name" => "ANDI Manager"})
    other = fixture_project(%{"name" => "ANDI Website"})

    {:ok, %{child_project: editor}} =
      Projects.create_subproject(main.uuid, %{"name" => "ANDI 3D editor"})

    for {project, title} <- [
          {main, "ANDI brief"},
          {editor, "ANDI walls"},
          {other, "ANDI landing"}
        ] do
      task = fixture_task(%{"title" => title})

      {:ok, _} =
        Projects.create_assignment(%{
          "project_uuid" => project.uuid,
          "task_uuid" => task.uuid,
          "status" => "todo"
        })
    end

    {:ok, main: main, other: other, editor: editor, scope: fake_scope()}
  end

  defp titles(results), do: results |> Enum.map(& &1.title) |> Enum.sort()

  test "without a context the admin sees every project and task", %{scope: scope} do
    all = ResourceLinks.search_resources("ANDI", scope: scope)
    assert "ANDI Website" in titles(all)
    assert "ANDI landing" in titles(all)
    assert "ANDI 3D editor" in titles(all)
  end

  test "inside a project, only that project, its sub-projects and their tasks", %{
    scope: scope,
    main: main,
    editor: editor
  } do
    inside =
      ResourceLinks.search_resources("ANDI", scope: scope, context: %{"project" => main.uuid})

    assert titles(inside) == ["ANDI 3D editor", "ANDI Manager", "ANDI brief", "ANDI walls"]

    # from the sub-project, only its own subtree
    leaf =
      ResourceLinks.search_resources("ANDI", scope: scope, context: %{"project" => editor.uuid})

    assert titles(leaf) == ["ANDI 3D editor", "ANDI walls"]
  end

  test "the context narrows but never widens: a member of another project gets nothing", %{
    main: main,
    other: other
  } do
    {:ok, user} =
      Auth.register_user(%{
        email: "member-#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    member = fake_scope(user_uuid: user.uuid, email: user.email, permissions: ["projects"])
    {:ok, _} = Members.add_member(other, user.uuid, role: "member")

    assert ResourceLinks.search_resources("ANDI",
             scope: member,
             context: %{"project" => main.uuid}
           ) == []

    theirs =
      ResourceLinks.search_resources("ANDI", scope: member, context: %{"project" => other.uuid})

    assert titles(theirs) == ["ANDI Website", "ANDI landing"]
  end

  test "a member of the root sees a grandchild's records too", %{main: main, editor: editor} do
    {:ok, %{child_project: deeper}} =
      Projects.create_subproject(editor.uuid, %{"name" => "Walls"})

    task = fixture_task(%{"title" => "ANDI plaster"})

    {:ok, a} =
      Projects.create_assignment(%{
        "project_uuid" => deeper.uuid,
        "task_uuid" => task.uuid,
        "status" => "todo"
      })

    {:ok, user} =
      Auth.register_user(%{
        email: "root-#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    member = fake_scope(user_uuid: user.uuid, email: user.email, permissions: ["projects"])
    {:ok, _} = Members.add_member(main, user.uuid, role: "member")

    # the project two levels down and its task
    assert Enum.sort(ResourceLinks.visible_resource_uuids([deeper.uuid, a.uuid], scope: member)) ==
             Enum.sort([deeper.uuid, a.uuid])
  end

  test "subtree_uuids walks down, root first", %{main: main, editor: editor} do
    {:ok, %{child_project: deeper}} =
      Projects.create_subproject(editor.uuid, %{"name" => "Walls"})

    assert Projects.subtree_uuids(main.uuid) == [main.uuid, editor.uuid, deeper.uuid]
    assert Projects.subtree_uuids(deeper.uuid) == [deeper.uuid]
  end
end
