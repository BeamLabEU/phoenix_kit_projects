defmodule PhoenixKitProjects.BatchedTimeBoardTest do
  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKitProjects.{Authz, Extensions, Features, Members, QueryCounter, TimeBoard}

  setup do
    Extensions.Registry.refresh()
    :ok
  end

  test "deadline edit permissions use a fixed number of reads as projects grow" do
    user_uuid = embed_user_uuid!()
    scope = fake_scope(user_uuid: user_uuid, roles: [], permissions: ["projects"])

    projects =
      for _ <- 1..5 do
        project = fixture_project()
        {:ok, _} = Members.add_member(project, user_uuid, role: "member")
        project
      end

    # Warm catalog/settings caches before measuring either input size.
    TimeBoard.editable_projects(scope, projects)

    {one, one_reads} =
      QueryCounter.count(fn -> TimeBoard.editable_projects(scope, Enum.take(projects, 1)) end)

    {many, many_reads} =
      QueryCounter.count(fn -> TimeBoard.editable_projects(scope, projects) end)

    assert map_size(one) == 1
    assert map_size(many) == 5
    assert Enum.all?(Map.values(many))
    assert many_reads == one_reads
  end

  test "batched gates and deadline edit permissions match the individual rules" do
    user_uuid = embed_user_uuid!()
    member = fixture_project()
    {:ok, _} = Members.add_member(member, user_uuid, role: "member")

    open = fixture_project(%{"settings" => %{"visibility" => "everyone"}})

    restricted =
      fixture_project(%{
        "settings" => %{"visibility" => "everyone", "authz" => %{"edit_tasks" => "managers"}}
      })

    no_dates = fixture_project(%{"settings" => %{"features" => %{"dates" => false}}})
    no_tasks = fixture_project()
    {:ok, _} = Extensions.disable(no_tasks.uuid, "tasks")

    projects = [
      member,
      open,
      restricted,
      no_dates,
      no_tasks,
      fixture_project(),
      fixture_template()
    ]

    assert Features.gates(projects) == Map.new(projects, &{&1.uuid, Features.gates(&1)})

    for scope <- [fake_scope(), fake_scope(user_uuid: user_uuid, permissions: ["projects"])] do
      expected =
        Map.new(projects, fn project ->
          {project.uuid,
           not project.is_template and Authz.can?(scope, project, :edit_tasks) and
             Extensions.enabled?(project.uuid, "tasks") and Features.on?(project, "dates")}
        end)

      assert TimeBoard.editable_projects(scope, projects) == expected
    end
  end
end
