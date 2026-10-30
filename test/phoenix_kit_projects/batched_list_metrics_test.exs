defmodule PhoenixKitProjects.BatchedListMetricsTest do
  @moduledoc """
  The projects list's columns (`ListMetrics`): each family reads the whole
  page of projects in a fixed number of statements, and answers what the
  per-project reads answer.
  """

  use PhoenixKitProjects.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{Ledger, ListMetrics, Members, ProjectEvents, Projects, QueryCounter}
  alias PhoenixKitProjects.Schemas.Assignment
  alias PhoenixKitProjects.Test.Repo

  defp user! do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "metrics-#{System.unique_integer([:positive])}@example.com",
        "password" => "ActorPass123!"
      })

    user
  end

  defp task!(project, attrs \\ %{}) do
    {:ok, a} =
      Projects.create_assignment(
        Map.merge(
          %{
            "project_uuid" => project.uuid,
            "task_uuid" => fixture_task().uuid,
            "status" => "todo"
          },
          attrs
        )
      )

    a
  end

  # A project with a bit of everything a family reads.
  defp busy_project(user) do
    project = fixture_project()
    today = Date.utc_today()

    done = task!(project)
    {:ok, _} = Projects.complete_assignment(done, nil)

    _late =
      task!(project, %{
        "deadline" =>
          DateTime.add(DateTime.utc_now(), -3 * 86_400, :second) |> DateTime.truncate(:second)
      })

    _ahead =
      task!(project, %{
        "deadline" =>
          DateTime.add(DateTime.utc_now(), 5 * 86_400, :second) |> DateTime.truncate(:second)
      })

    {:ok, _} = Members.add_member(project, user.uuid, role: "owner")
    {:ok, _} = Ledger.log_time(project.uuid, 90, billable: true)
    {:ok, _} = Ledger.log_time(project.uuid, 30)
    {:ok, _} = Ledger.log_time(project.uuid, 15, actor_kind: "ai_agent")
    {:ok, _} = Ledger.record_ai(project.uuid, %{tokens: 1200, cost_cents: 4})

    {:ok, _} =
      ProjectEvents.create(project, %{
        title: "Review",
        starts_at: DateTime.add(DateTime.utc_now(), 86_400, :second)
      })

    project
  end

  @db_families ~w(tasks due events members assignee ledger activity creators parents)a

  test "every family answers for a project with work, members, time and an event" do
    user = user!()
    project = busy_project(user)
    m = ListMetrics.load([project], @db_families)

    assert %{total: 3, done: 1, open: 2, subprojects: 0} = m.tasks[project.uuid]
    assert m.tasks[project.uuid].progress_pct == 33

    assert %{overdue: 1, next_due: next_due} = m.due[project.uuid]
    assert DateTime.to_date(next_due) == Date.add(Date.utc_today(), 5)

    assert %DateTime{} = m.events[project.uuid]

    assert %{count: 1, people: [%{uuid: uuid, role: "owner", name: name}]} =
             m.members[project.uuid]

    assert uuid == user.uuid
    assert name == user.email

    assert %{minutes: 120.0, billable_minutes: 90.0, ai_minutes: 15.0, tokens: 1200.0} =
             m.ledger[project.uuid]

    assert m.ledger[project.uuid].cost_cents == 4.0
    assert %DateTime{} = m.activity[project.uuid]
    assert m.assignee == %{}
    assert m.parents == %{}
  end

  test "a submission nobody accepted is not an overdue task" do
    project = fixture_project()

    late =
      task!(project, %{
        "deadline" =>
          DateTime.add(DateTime.utc_now(), -2 * 86_400, :second) |> DateTime.truncate(:second)
      })

    Repo.update_all(
      from(a in Assignment, where: a.uuid == ^late.uuid),
      set: [review_status: "pending"]
    )

    assert ListMetrics.load([project], [:due]).due == %{}
  end

  test "a sub-project names its parent" do
    parent = fixture_project()
    {:ok, %{child_project: child}} = Projects.create_subproject(parent.uuid, %{"name" => "Inner"})

    # A parent is named only to a viewer who may open it — here a site admin.
    admin = %PhoenixKit.Users.Auth.Scope{
      user: %Auth.User{uuid: Ecto.UUID.generate(), email: "admin@example.com"},
      authenticated?: true,
      cached_roles: ["Owner"],
      cached_permissions: MapSet.new(["projects", "projects.admin_all"])
    }

    assert %{parents: %{} = parents, tasks: tasks} =
             ListMetrics.load([parent, child], [:parents, :tasks], scope: admin)

    assert ListMetrics.load([child], [:parents]).parents == %{}

    assert parents[child.uuid].uuid == parent.uuid
    refute Map.has_key?(parents, parent.uuid)
    assert tasks[parent.uuid].subprojects == 1
  end

  test "a project with nothing is simply absent, and an empty list reads nothing" do
    project = fixture_project()
    m = ListMetrics.load([project], [:due, :events, :members, :ledger, :parents])
    assert Enum.all?(Map.values(m), &(&1 == %{}))

    {result, queries} = QueryCounter.count(fn -> ListMetrics.load([], @db_families) end)
    assert queries == 0
    assert Enum.all?(Map.values(result), &(&1 == %{}))
  end

  test "an unknown family is ignored" do
    assert ListMetrics.load([fixture_project()], [:nope, :due]) == %{due: %{}}
  end

  test "the statement count does not grow with the number of projects" do
    user = user!()
    one = [busy_project(user)]
    many = Enum.map(1..6, fn _ -> busy_project(user) end)

    for family <- @db_families do
      {_, q_one} = QueryCounter.count(fn -> ListMetrics.load(one, [family]) end)
      {_, q_many} = QueryCounter.count(fn -> ListMetrics.load(many, [family]) end)

      assert q_one == q_many,
             "#{family}: #{q_one} statements for one project, #{q_many} for six"
    end
  end
end
