defmodule PhoenixKitProjects.Integration.ProjectMoveTest do
  @moduledoc """
  Moving a project in the tree (`Projects.move_project/2`) and what it takes
  along from the parent it leaves (`ProjectMove`).
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{ApiKeys, Extensions, Members, ProjectMove, Projects}
  alias PhoenixKitProjects.Schemas.ProjectModule
  alias PhoenixKitProjects.Test.Repo

  defp user!(tag) do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "#{tag}-#{System.unique_integer([:positive])}@example.com",
        "password" => "ActorPass123!"
      })

    user
  end

  defmodule Meetings do
    @moduledoc false
    # A stand-in for the CRM's interactions provider: where each
    # interaction was logged is whatever the test put in the process
    # dictionary of the test process (`ProjectMove.preview/2` runs there).
    def resource, do: "interactions"
    def scopes, do: %{read: "interactions:read", write: "interactions:write"}
    def action, do: :log_interaction
    def docs, do: []
    def projects_of(uuids), do: Map.take(Process.get(:logged_on, %{}), uuids)
  end

  defmodule MeetingsProvider do
    @moduledoc false
    def phoenix_kit_project_extensions do
      [
        %{
          key: "meetings",
          name: "Meetings",
          description: "A test extension with interactions",
          permission_actions: [:view, :log_interaction],
          api: PhoenixKitProjects.Integration.ProjectMoveTest.Meetings
        }
      ]
    end
  end

  defp child!(parent, name \\ "Child") do
    {:ok, %{child_project: child}} = Projects.create_subproject(parent.uuid, %{"name" => name})
    child
  end

  describe "Projects.move_project/2" do
    test "out to the top: the link row goes, the project and its tasks stay" do
      parent = fixture_project()
      child = child!(parent)
      task = fixture_task()

      {:ok, a} =
        Projects.create_assignment(%{"project_uuid" => child.uuid, "task_uuid" => task.uuid})

      assert {:ok, %{from: from, to: nil}} = Projects.move_project(child.uuid, :top)
      assert from.uuid == parent.uuid
      assert Projects.subproject_link(child.uuid) == nil
      assert Projects.parent_chain(child.uuid) == []
      assert Projects.get_assignment(a.uuid)
      assert child.uuid in Enum.map(Projects.list_projects(), & &1.uuid)
    end

    test "from one parent to another, in one step" do
      a = fixture_project()
      b = fixture_project()
      child = child!(a)

      assert {:ok, %{from: from, to: to}} = Projects.move_project(child.uuid, b.uuid)
      assert {from.uuid, to.uuid} == {a.uuid, b.uuid}
      assert [%{uuid: parent_uuid}] = Projects.parent_chain(child.uuid)
      assert parent_uuid == b.uuid
      assert Projects.child_projects(a.uuid) == []
    end

    test "a top-level project goes under another" do
      a = fixture_project()
      b = fixture_project()

      assert {:ok, %{from: nil, to: to}} = Projects.move_project(a.uuid, b.uuid)
      assert to.uuid == b.uuid
      refute a.uuid in Enum.map(Projects.list_projects(), & &1.uuid)
    end

    test "a move that would nest deeper than the tree walks is refused" do
      # a chain of nine: root and eight below it, as deep as the tree walks
      root = fixture_project()

      deepest =
        Enum.reduce(1..8, root, fn n, parent -> child!(parent, "Level #{n}") end)

      loose = fixture_project()
      assert {:error, :too_deep} = Projects.move_project(loose.uuid, deepest.uuid)
      assert Projects.subproject_link(loose.uuid) == nil

      # one level up there is room for a project with nothing under it…
      [above | _] = Enum.reverse(Projects.parent_chain(deepest.uuid))
      assert {:ok, _} = Projects.move_project(loose.uuid, above.uuid)

      # …but not for one that brings a level of its own
      tall = fixture_project()
      _under = child!(tall, "Under tall")
      assert {:error, :too_deep} = Projects.move_project(tall.uuid, above.uuid)
    end

    test "refusals leave the tree as it was" do
      root = fixture_project()
      child = child!(root)
      grandchild = child!(child, "Grandchild")

      assert {:error, :already_there} = Projects.move_project(root.uuid, :top)
      assert {:error, :already_there} = Projects.move_project(child.uuid, root.uuid)
      assert {:error, :would_create_cycle} = Projects.move_project(child.uuid, grandchild.uuid)
      assert {:error, :self_link} = Projects.move_project(child.uuid, child.uuid)
      assert {:error, :not_found} = Projects.move_project(child.uuid, Ecto.UUID.generate())
      assert {:error, :kind_mismatch} = Projects.move_project(child.uuid, fixture_template().uuid)

      # The cycle refusal rolled the delete of the old link back.
      assert [%{uuid: root_uuid}] = Projects.parent_chain(child.uuid)
      assert root_uuid == root.uuid
    end
  end

  describe "ProjectMove" do
    setup do
      owner = user!("owner")
      mate = user!("mate")
      parent = fixture_project()
      child = child!(parent, "Editor")
      {:ok, _} = Members.add_member(parent.uuid, owner.uuid, role: "owner")
      {:ok, _} = Members.add_member(parent.uuid, mate.uuid, role: "member")
      {:ok, _} = Extensions.enable(parent.uuid, "events")
      {:ok, key, _token} = ApiKeys.create(parent.uuid, %{"name" => "agent"})

      %{parent: parent, child: child, owner: owner, mate: mate, key: key, scope: fake_scope()}
    end

    test "preview says what the parent has that the project does not", ctx do
      preview = ProjectMove.preview(ctx.child, ctx.scope)

      assert preview.parent.uuid == ctx.parent.uuid

      assert Enum.sort(Enum.map(preview.members, & &1.user_uuid)) ==
               Enum.sort([ctx.owner.uuid, ctx.mate.uuid])

      assert "events" in Enum.map(preview.modules, & &1.ext_key)
      assert [key] = preview.keys
      assert key.uuid == ctx.key.uuid
      refute ctx.parent.uuid in Enum.map(preview.targets, & &1.uuid)
      refute ctx.child.uuid in Enum.map(preview.targets, & &1.uuid)
    end

    test "preview counts the task links to interactions logged outside the project", ctx do
      previous = Application.get_env(:phoenix_kit_projects, :extension_providers, [])

      Application.put_env(:phoenix_kit_projects, :extension_providers, [
        MeetingsProvider | previous
      ])

      PhoenixKitProjects.Extensions.Registry.refresh()

      on_exit(fn ->
        Application.put_env(:phoenix_kit_projects, :extension_providers, previous)
        PhoenixKitProjects.Extensions.Registry.refresh()
      end)

      {:ok, _} = Extensions.enable(ctx.parent.uuid, "meetings")

      task = fn ->
        {:ok, a} =
          Projects.create_assignment(%{
            "project_uuid" => ctx.child.uuid,
            "task_uuid" => fixture_task().uuid
          })

        a
      end

      [parents, own, gone] = for _ <- 1..3, do: Ecto.UUID.generate()
      [first, second] = [task.(), task.()]
      # Two tasks point at the parent's meeting, one at a meeting logged on
      # the project itself, one at a meeting nobody knows any more.
      for {a, i} <- [{first, parents}, {second, parents}, {first, own}, {second, gone}] do
        {:ok, _} = Projects.link_interaction(a, i, "Meeting")
      end

      Process.put(:logged_on, %{parents => ctx.parent.uuid, own => ctx.child.uuid})

      # The project has no such module of its own; the parent's can be carried.
      assert ProjectMove.preview(ctx.child, ctx.scope).links ==
               %{count: 2, own?: false, carried?: true}

      {:ok, _} = ProjectMove.run(ctx.child, :top, ctx.scope, modules: true)
      moved = Projects.get_project(ctx.child.uuid)

      assert ProjectMove.preview(moved, ctx.scope).links ==
               %{count: 2, own?: true, carried?: false}
    end

    test "run carries members with their roles, modules and the chosen key", ctx do
      assert {:ok, %{members: 2, keys: 1, modules: modules}} =
               ProjectMove.run(ctx.child, :top, ctx.scope,
                 members: true,
                 modules: true,
                 keys: [ctx.key.uuid]
               )

      assert modules >= 1
      assert Members.role_of(ctx.child.uuid, ctx.owner.uuid) == :owner
      assert Members.role_of(ctx.child.uuid, ctx.mate.uuid) == :member
      assert Extensions.enabled?(ctx.child.uuid, "events")
      # The key keeps its home and gets the same access on the moved project.
      assert ApiKeys.get(ctx.key.uuid).project_uuid == ctx.parent.uuid
      assert {:ok, _} = ApiKeys.access_for(ctx.key, ctx.child.uuid)
      assert {:ok, _} = ApiKeys.access_for(ctx.key, ctx.parent.uuid)
      # The parent keeps its own people.
      assert Members.role_of(ctx.parent.uuid, ctx.owner.uuid) == :owner
    end

    test "run with nothing ticked moves bare; an unoffered key stays put", ctx do
      other = fixture_project()
      {:ok, foreign, _} = ApiKeys.create(other.uuid, %{"name" => "foreign"})

      assert {:ok, %{members: 0, modules: 0, keys: 0}} =
               ProjectMove.run(ctx.child, :top, ctx.scope, keys: [foreign.uuid])

      assert Members.list_members(ctx.child.uuid) == []
      assert ApiKeys.get(foreign.uuid).project_uuid == other.uuid
      assert ApiKeys.get(ctx.key.uuid).project_uuid == ctx.parent.uuid
      assert {:error, :no_access} = ApiKeys.access_for(ctx.key, ctx.child.uuid)
    end

    test "a key the project's own grant shuts out is not carried there", ctx do
      {:ok, _} = ApiKeys.put_grant(ctx.key, ctx.child.uuid, %{"scopes" => []})
      refute Enum.any?(ProjectMove.preview(ctx.child, ctx.scope).keys, &(&1.uuid == ctx.key.uuid))

      assert {:ok, %{keys: 0}} = ProjectMove.run(ctx.child, :top, ctx.scope, keys: [ctx.key.uuid])
      assert {:error, :no_access} = ApiKeys.access_for(ctx.key, ctx.child.uuid)
    end

    test "a carry step that fails does not undo or hide the move", ctx do
      # a module row for an extension that no longer exists: enabling it on
      # the project is refused, the rest is carried
      Repo.insert!(%ProjectModule{
        project_uuid: ctx.parent.uuid,
        ext_key: "gone_extension",
        enabled: true
      })

      assert {:ok, %{to: nil, members: 2}} =
               ProjectMove.run(ctx.child, :top, ctx.scope, members: true, modules: true)

      assert Projects.subproject_link(ctx.child.uuid) == nil
      assert Extensions.enabled?(ctx.child.uuid, "events")
    end

    test "an owner of the sub-project alone is offered nothing of the parent's", ctx do
      solo = user!("solo")
      {:ok, _} = Members.add_member(ctx.child.uuid, solo.uuid, role: "owner")
      scope = fake_scope(user_uuid: solo.uuid, permissions: ["projects"])

      preview = ProjectMove.preview(ctx.child, scope)
      refute preview.parent_open?
      assert preview.members == []
      assert preview.modules == []
      assert preview.keys == []

      assert {:ok, %{members: 0, modules: 0, keys: 0}} =
               ProjectMove.run(ctx.child, :top, scope,
                 members: true,
                 modules: true,
                 keys: [ctx.key.uuid]
               )

      assert Members.role_of(ctx.child.uuid, ctx.owner.uuid) == nil
      assert ApiKeys.get(ctx.key.uuid).project_uuid == ctx.parent.uuid
    end

    test "a member of the parent without settings rights is refused", ctx do
      scope = fake_scope(user_uuid: ctx.mate.uuid, permissions: ["projects"])

      assert {:error, :forbidden} = ProjectMove.run(ctx.child, :top, scope, members: true)
      assert Projects.subproject_link(ctx.child.uuid)
    end

    test "the owner of the project may move it only under a project they can add tasks to",
         ctx do
      {:ok, _} = Members.add_member(ctx.child.uuid, ctx.owner.uuid, role: "owner")
      scope = fake_scope(user_uuid: ctx.owner.uuid, permissions: ["projects"])
      foreign = fixture_project()

      assert {:error, :forbidden} = ProjectMove.run(ctx.child, foreign.uuid, scope)
      refute foreign.uuid in Enum.map(ProjectMove.preview(ctx.child, scope).targets, & &1.uuid)
      assert {:ok, %{to: nil}} = ProjectMove.run(ctx.child, :top, scope)
    end
  end
end
