defmodule PhoenixKitProjects.AssigneeSetTest do
  @moduledoc """
  Several assignees on one task (V29, the boss's second list, 2026-10-31):
  people, teams and departments mixed, all equal. The set is the rows; the
  task's own `assigned_*` columns mirror it while it has exactly one.
  Everyone on it is told and finds it among their tasks, and the picker's
  lists page without repeating anyone.
  """

  use PhoenixKitProjects.DataCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{Activity, Assignees, AssigneeSet, Members, Notices, People, Projects}
  alias PhoenixKitProjects.Schemas.{Assignment, AssignmentAssignee}
  alias PhoenixKitProjects.Test.Repo
  alias PhoenixKitProjects.Web.Helpers
  alias PhoenixKitStaff.Schemas.{Department, Person, Team, TeamMembership}

  defp uniq, do: System.unique_integer([:positive])

  defp person!(name, attrs \\ %{}) do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "#{String.downcase(name)}-#{uniq()}@example.com",
        "password" => "ValidPassword123!"
      })

    Repo.insert!(
      struct(Person, Map.merge(%{user_uuid: user.uuid, status: "active", name: name}, attrs))
    )
  end

  defp task!(project, attrs) do
    {:ok, %{assignment: a}} =
      Projects.create_task_with_assignment(
        project.uuid,
        %{"title" => "Fit the doors #{uniq()}", "ad_hoc" => true},
        attrs
      )

    a
  end

  defp rows(a), do: Repo.all(from(r in AssignmentAssignee, where: r.assignment_uuid == ^a.uuid))

  setup do
    tag = uniq()
    dept = Repo.insert!(%Department{name: "Finance #{tag}"})
    team = Repo.insert!(%Team{name: "Fitters #{tag}", department_uuid: dept.uuid})
    ann = person!("Ann")
    bob = person!("Bob")
    tom = person!("Tom")
    Repo.insert!(%TeamMembership{team_uuid: team.uuid, staff_person_uuid: tom.uuid})

    %{
      project: fixture_project(%{"start_mode" => "immediate"}),
      dept: dept,
      team: team,
      ann: ann,
      bob: bob,
      tom: tom
    }
  end

  describe "writing a set" do
    test "several, mixed: the rows in order, the mirror empty", ctx do
      keys = [{"person", ctx.ann.uuid}, {"team", ctx.team.uuid}, {"department", ctx.dept.uuid}]
      a = task!(ctx.project, %{"assignees" => keys})

      assert length(rows(a)) == 3
      fresh = Projects.get_assignment(a.uuid)
      assert AssigneeSet.keys(fresh) == keys
      assert is_nil(fresh.assigned_person_uuid) and is_nil(fresh.assigned_team_uuid)
    end

    test "one: the row and the mirror", ctx do
      a = task!(ctx.project, %{"assignees" => ["person:#{ctx.ann.uuid}"]})
      fresh = Projects.get_assignment(a.uuid)

      assert fresh.assigned_person_uuid == ctx.ann.uuid
      assert AssigneeSet.keys(fresh) == [{"person", ctx.ann.uuid}]
    end

    test "the old single fields name the whole set", ctx do
      a =
        task!(ctx.project, %{"assignees" => [{"person", ctx.ann.uuid}, {"person", ctx.bob.uuid}]})

      {:ok, _} =
        a.uuid
        |> Projects.get_assignment()
        |> then(&Projects.update_assignment_form(&1, %{"assigned_team_uuid" => ctx.team.uuid}))

      assert AssigneeSet.keys(Projects.get_assignment(a.uuid)) == [{"team", ctx.team.uuid}]
    end

    test "an empty list clears it; the same list writes nothing", ctx do
      a =
        task!(ctx.project, %{"assignees" => [{"person", ctx.ann.uuid}, {"team", ctx.team.uuid}]})

      fresh = Projects.get_assignment(a.uuid)

      same =
        Assignment.changeset(fresh, %{
          "assignees" => ["", "person:#{ctx.ann.uuid}", "team:#{ctx.team.uuid}"]
        })

      refute Map.has_key?(same.changes, :assignee_keys)

      {:ok, _} = Projects.update_assignment_form(fresh, %{"assignees" => [""]})
      assert rows(a) == []
      assert AssigneeSet.keys(Projects.get_assignment(a.uuid)) == []
    end

    test "a list that is not one is refused", ctx do
      cs =
        Assignment.changeset(%Assignment{project_uuid: ctx.project.uuid}, %{
          "assignees" => ["robot:1"]
        })

      refute cs.valid?
    end

    test "a deleted person leaves the others", ctx do
      a =
        task!(ctx.project, %{"assignees" => [{"person", ctx.bob.uuid}, {"team", ctx.team.uuid}]})

      Repo.delete!(ctx.bob)
      assert AssigneeSet.keys(Projects.get_assignment(a.uuid)) == [{"team", ctx.team.uuid}]
    end
  end

  describe "reading a set" do
    test "everyone on it is reached once: a person, a team's members", ctx do
      a =
        task!(ctx.project, %{
          "assignees" => [
            {"person", ctx.ann.uuid},
            {"team", ctx.team.uuid},
            {"person", ctx.tom.uuid}
          ]
        })

      users = People.assignee_user_uuids(Projects.get_assignment(a.uuid))

      assert Enum.sort(users) == Enum.sort([ctx.ann.user_uuid, ctx.tom.user_uuid])
    end

    test "a task names the person among several: my tasks, the scope match", ctx do
      a =
        task!(ctx.project, %{"assignees" => [{"team", ctx.team.uuid}, {"person", ctx.bob.uuid}]})

      assert Enum.any?(
               Projects.list_assignments_for_user(ctx.bob.user_uuid),
               &(&1.uuid == a.uuid)
             )

      scope = Assignees.scope_for_person(ctx.bob.uuid)
      assert Assignees.match(Projects.get_assignment(a.uuid), scope) == :direct

      tom_scope = Assignees.scope_for_person(ctx.tom.uuid)
      assert {:team, _} = Assignees.match(Projects.get_assignment(a.uuid), tom_scope)
    end

    test "only a task with exactly one person names a target; the rest fan out", ctx do
      one = task!(ctx.project, %{"assignees" => [{"person", ctx.ann.uuid}]})

      two =
        task!(ctx.project, %{"assignees" => [{"person", ctx.ann.uuid}, {"person", ctx.bob.uuid}]})

      assert Activity.assignee_target_uuid(Projects.get_assignment(one.uuid)) == ctx.ann.user_uuid
      assert Activity.assignee_target_uuid(Projects.get_assignment(two.uuid)) == nil
    end

    test "faces show everyone, once", ctx do
      a =
        task!(ctx.project, %{
          "assignees" => [
            {"person", ctx.tom.uuid},
            {"team", ctx.team.uuid},
            {"person", ctx.ann.uuid}
          ]
        })

      %{faces: faces} = Assignees.faces([Projects.get_assignment(a.uuid)])[a.uuid]

      assert Enum.map(faces, & &1.name) == ["Tom", "Ann"]
    end

    test "the label names them all", ctx do
      a =
        task!(ctx.project, %{"assignees" => [{"person", ctx.ann.uuid}, {"team", ctx.team.uuid}]})

      label = Helpers.assignee_label(Projects.get_assignment(a.uuid))

      assert label == "Ann, #{ctx.team.name}"
    end
  end

  describe "handing a task on" do
    test "adding a second person tells only the new one", ctx do
      for p <- [ctx.ann, ctx.bob],
          do: {:ok, _} = Members.add_member(ctx.project, p.user_uuid, role: "member")

      a = task!(ctx.project, %{"assignees" => [{"person", ctx.ann.uuid}]})
      was = Projects.get_assignment(a.uuid)

      {:ok, _} =
        Projects.update_assignment_form(was, %{
          "assignees" => [{"person", ctx.ann.uuid}, {"person", ctx.bob.uuid}]
        })

      now = Projects.get_assignment(a.uuid)

      assert Notices.reassigned(was, now, nil)

      told = fn user_uuid ->
        Repo.exists?(
          from(e in PhoenixKit.Activity.Entry,
            where: e.target_uuid == ^user_uuid and e.action == "projects.assignment_reassigned"
          )
        )
      end

      assert told.(ctx.bob.user_uuid)
      refute told.(ctx.ann.user_uuid)
    end
  end

  describe "the picker's pages" do
    test "browse pages through people with no one twice or missed", ctx do
      people = for i <- 1..7, do: person!("Zed#{ctx.dept.uuid |> binary_part(0, 4)}#{i}")
      wanted = MapSet.new(people, & &1.uuid)

      {seen, _} =
        Enum.reduce_while(1..200, {[], nil}, fn _, {acc, cursor} ->
          {rows, next} = Assignees.page({:browse, "person"}, cursor, 3)
          acc = acc ++ Enum.map(rows, & &1.uuid)
          if next, do: {:cont, {acc, next}}, else: {:halt, {acc, nil}}
        end)

      assert Enum.uniq(seen) == seen
      assert MapSet.subset?(wanted, MapSet.new(seen))
    end

    test "a search lists a matched team followed by its people", ctx do
      {rows, _} = Assignees.page({:search, ctx.team.name}, nil, 20)
      at = Enum.find_index(rows, &(&1.kind == "team" and &1.uuid == ctx.team.uuid))

      assert at
      assert Enum.at(rows, at + 1).uuid == ctx.tom.uuid
      assert rows |> Enum.map(& &1.id) |> Enum.uniq() |> length() == length(rows)
    end
  end
end
