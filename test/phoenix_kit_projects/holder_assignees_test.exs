defmodule PhoenixKitProjects.HolderAssigneesTest do
  @moduledoc """
  Several assignees everywhere (V30, the boss, 2026-11-03: "let's make
  sure that we can assign multiple people everywhere"): a project's — a
  sub-project's too — and a library task's default, the same way as a
  task's (V29). The set is the rows; the holder's own single columns mirror
  it while it has exactly one. Copies carry the whole set.
  """

  use PhoenixKitProjects.DataCase, async: false

  import Ecto.Query

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{AssigneeSet, ListMetrics, People, Projects, TaskConversion}
  alias PhoenixKitProjects.Migrations.Schema
  alias PhoenixKitProjects.Schemas.{Project, ProjectAssignee, TaskDefaultAssignee}
  alias PhoenixKitProjects.Test.Repo
  alias PhoenixKitProjects.Web.Api.Json
  alias PhoenixKitStaff.Schemas.{Department, Person, Team, TeamMembership}

  defp uniq, do: System.unique_integer([:positive])

  defp person!(name) do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "#{String.downcase(name)}-#{uniq()}@example.com",
        "password" => "ValidPassword123!"
      })

    Repo.insert!(%Person{user_uuid: user.uuid, status: "active", name: name})
  end

  setup do
    tag = uniq()
    dept = Repo.insert!(%Department{name: "Finance #{tag}"})
    team = Repo.insert!(%Team{name: "Fitters #{tag}", department_uuid: dept.uuid})
    ann = person!("Ann")
    tom = person!("Tom")
    Repo.insert!(%TeamMembership{team_uuid: team.uuid, staff_person_uuid: tom.uuid})
    %{team: team, ann: ann, tom: tom}
  end

  defp project_rows(p),
    do:
      Repo.all(from(r in ProjectAssignee, where: r.project_uuid == ^p.uuid, order_by: r.position))

  describe "a project's set" do
    test "several, mixed: the rows in order, the mirror empty", ctx do
      {:ok, p} =
        Projects.create_project(%{
          "name" => "Kitchen #{uniq()}",
          "assignees" => [{"person", ctx.ann.uuid}, {"team", ctx.team.uuid}]
        })

      assert [%{person_uuid: a}, %{team_uuid: t}] = project_rows(p)
      assert {a, t} == {ctx.ann.uuid, ctx.team.uuid}
      p = Repo.get!(Project, p.uuid)
      assert {p.assigned_person_uuid, p.assigned_team_uuid} == {nil, nil}
      assert AssigneeSet.keys(p) == [{"person", ctx.ann.uuid}, {"team", ctx.team.uuid}]
    end

    test "one: the row and the mirror; the old single field still names the set", ctx do
      {:ok, p} =
        Projects.create_project(%{
          "name" => "Hall #{uniq()}",
          "assigned_person_uuid" => ctx.ann.uuid
        })

      assert [%{person_uuid: a}] = project_rows(p)
      assert a == ctx.ann.uuid
      assert Repo.get!(Project, p.uuid).assigned_person_uuid == ctx.ann.uuid
    end

    test "everyone on it is reached: a person and a team's members", ctx do
      {:ok, p} =
        Projects.create_project(%{
          "name" => "Bath #{uniq()}",
          "assignees" => [{"person", ctx.ann.uuid}, {"team", ctx.team.uuid}]
        })

      users = p |> Repo.reload!() |> People.assignee_user_uuids() |> MapSet.new()
      assert MapSet.equal?(users, MapSet.new([ctx.ann.user_uuid, ctx.tom.user_uuid]))
    end

    test "the project list and the API name them all", ctx do
      {:ok, p} =
        Projects.create_project(%{
          "name" => "Porch #{uniq()}",
          "assignees" => [{"person", ctx.ann.uuid}, {"team", ctx.team.uuid}]
        })

      p = Repo.get!(Project, p.uuid)
      %{assignee: shown} = ListMetrics.load([p], [:assignee])
      assert %{kind: :several, label: label} = shown[p.uuid]
      assert label =~ "Ann" and label =~ ctx.team.name

      json = Json.project(p)
      assert json.assignee == nil
      assert Enum.map(json.assignees, & &1.uuid) == [ctx.ann.uuid, ctx.team.uuid]
    end
  end

  describe "a library task's default set" do
    test "is the new task's set", ctx do
      {:ok, task} =
        Projects.create_task(%{
          "title" => "Measure #{uniq()}",
          "assignees" => [{"person", ctx.ann.uuid}, {"team", ctx.team.uuid}]
        })

      assert Repo.aggregate(
               from(r in TaskDefaultAssignee, where: r.task_uuid == ^task.uuid),
               :count
             ) ==
               2

      project = fixture_project(%{"start_mode" => "immediate"})

      {:ok, a} =
        Projects.create_assignment_from_template(task.uuid, %{"project_uuid" => project.uuid})

      assert AssigneeSet.keys(Repo.reload!(a)) == [
               {"person", ctx.ann.uuid},
               {"team", ctx.team.uuid}
             ]
    end
  end

  describe "copies carry the whole set" do
    test "a task made a sub-project and back keeps all its assignees", ctx do
      project = fixture_project(%{"start_mode" => "immediate"})

      {:ok, %{assignment: row}} =
        Projects.create_task_with_assignment(
          project.uuid,
          %{"title" => "Doors #{uniq()}", "ad_hoc" => true},
          %{"assignees" => [{"person", ctx.ann.uuid}, {"team", ctx.team.uuid}]}
        )

      {:ok, _} = TaskConversion.to_subproject(Projects.get_assignment(row.uuid))
      child = Repo.get!(Project, Projects.get_assignment(row.uuid).child_project_uuid)
      assert AssigneeSet.keys(child) == [{"person", ctx.ann.uuid}, {"team", ctx.team.uuid}]
    end
  end

  test "the chain is at V30" do
    assert Schema.current_version() >= 30
  end
end
