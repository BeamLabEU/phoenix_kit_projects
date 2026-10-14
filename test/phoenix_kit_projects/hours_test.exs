defmodule PhoenixKitProjects.HoursTest do
  @moduledoc """
  `PhoenixKitProjects.Hours` — the ledger read for the Hours tab: the
  filters, the grouped summaries, one line for a person with both an
  account and a staff record, and reads that do not grow with the entries.
  """

  use PhoenixKitProjects.DataCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{Hours, Ledger, Members, Projects, QueryCounter}
  alias PhoenixKitStaff.{Departments, Staff}

  defp uniq, do: System.unique_integer([:positive])

  defp user(name \\ nil) do
    {:ok, user} =
      Auth.register_user(%{email: "hours-#{uniq()}@example.com", password: "ValidPassword123!"})

    case name do
      nil ->
        user

      name ->
        [first, last] = String.split(name, " ", parts: 2)
        {:ok, user} = Auth.update_user_profile(user, %{first_name: first, last_name: last})
        user
    end
  end

  defp staff_person(name, user_uuid) do
    {:ok, dept} = Departments.create(%{"name" => "Dept-#{uniq()}"})

    attrs =
      %{"name" => name, "employment_type" => "full_time", "primary_department_uuid" => dept.uuid}
      |> then(&if(user_uuid, do: Map.put(&1, "user_uuid", user_uuid), else: &1))

    {:ok, person} = Staff.create_person(attrs)
    person
  end

  defp task(project, title) do
    {:ok, %{assignment: a}} =
      Projects.create_task_with_assignment(
        project.uuid,
        %{"title" => title, "ad_hoc" => true},
        %{}
      )

    a
  end

  defp log(project, minutes, opts) do
    {:ok, entry} = Ledger.log_time(project.uuid, minutes, opts)
    entry
  end

  defp f(project, opts \\ []) do
    Hours.filters(Keyword.merge([project_uuids: [project.uuid]], opts))
  end

  describe "summary/2" do
    test "totals split people's time, billable time and an agent's" do
      project = fixture_project()
      ann = user()
      log(project, 60, actor_uuid: ann.uuid, billable: true)
      log(project, 30, actor_uuid: ann.uuid)
      log(project, 45, actor_kind: "ai_agent", actor_uuid: Ecto.UUID.generate(), source: "ai")
      {:ok, _} = Ledger.record_ai(project.uuid, %{tokens: 1200, cost_cents: 7})

      %{totals: t} = Hours.summary(f(project))

      assert t.minutes == 90.0
      assert t.billable_minutes == 60.0
      assert t.ai_minutes == 45.0
      assert t.tokens == 1200.0
      assert t.cost_cents == 7.0
      assert t.entries == 2
      assert t.people == 1
    end

    test "by worker, by task and by project, most time first" do
      project = fixture_project()
      ann = user("Ann Able")
      bob = user("Bob Baker")
      t1 = task(project, "Cut the panels")
      t2 = task(project, "Fit the hinges")
      log(project, 120, actor_uuid: ann.uuid, assignment_uuid: t1.uuid)
      log(project, 30, actor_uuid: bob.uuid, assignment_uuid: t2.uuid, billable: true)
      log(project, 15, actor_uuid: bob.uuid)

      s = Hours.summary(f(project))

      assert [%{worker: %{name: "Ann Able"}, minutes: 120.0}, %{worker: %{name: "Bob Baker"}} = b] =
               s.by_worker

      assert b.minutes == 45.0 and b.billable_minutes == 30.0 and b.entries == 2

      assert [
               %{task: %{title: "Cut the panels"}, minutes: 120.0},
               %{task: %{title: "Fit the hinges"}, minutes: 30.0},
               %{task: nil, minutes: 15.0}
             ] = s.by_task

      assert [%{project: %{uuid: uuid}, minutes: 165.0, entries: 3}] = s.by_project
      assert uuid == project.uuid
    end

    test "a staff record linked to an account sums into that person's line" do
      project = fixture_project()
      ann = user("Ann Able")
      person = staff_person("Ann (staff)", ann.uuid)
      # A staff record that is gone (or was never readable) still has a line.
      loose = %{uuid: Ecto.UUID.generate()}
      log(project, 60, actor_uuid: ann.uuid)
      log(project, 30, actor_kind: "staff_person", actor_uuid: person.uuid)
      log(project, 20, actor_kind: "staff_person", actor_uuid: loose.uuid)

      s = Hours.summary(f(project))

      assert [%{worker: ann_w, minutes: 90.0, entries: 2}, %{worker: fitter, minutes: 20.0}] =
               s.by_worker

      assert ann_w.key == "user:#{ann.uuid}" and ann_w.name == "Ann Able"
      assert fitter.kind == "staff_person" and fitter.name == "Someone"
      assert s.totals.people == 2

      # Choosing the person finds both of their identities.
      only = Hours.summary(f(project, workers: ["user:#{ann.uuid}"]))
      assert only.totals.minutes == 90.0

      assert Hours.summary(f(project, workers: ["staff_person:#{person.uuid}"])).totals.minutes ==
               90.0

      assert Enum.map(Hours.workers(f(project)), & &1.name) == ["Ann Able", "Someone"]
    end

    test "an agent is named after its key, and a nameless one still has a line" do
      project = fixture_project()
      key = Ecto.UUID.generate()

      log(project, 10,
        actor_kind: "ai_agent",
        actor_uuid: key,
        metadata: %{"api_key_name" => "Planner bot"}
      )

      log(project, 5, actor_kind: "ai_agent")

      names = Hours.summary(f(project)).by_worker |> Enum.map(& &1.worker.name) |> Enum.sort()
      assert names == ["AI agent", "Planner bot"]
    end

    test "the period reads when the work was done, and days follow the viewer's offset" do
      project = fixture_project()
      ann = user()
      # 22:30 UTC on the 5th is the 6th at UTC+3.
      log(project, 60, actor_uuid: ann.uuid, ended_at: ~U[2026-10-05 22:30:00Z])
      log(project, 30, actor_uuid: ann.uuid, started_at: ~U[2026-10-07 09:00:00Z])
      log(project, 15, actor_uuid: ann.uuid, ended_at: ~U[2026-09-01 09:00:00Z])

      october = f(project, from: ~U[2026-10-01 00:00:00Z], until: ~U[2026-11-01 00:00:00Z])
      assert Hours.summary(october).totals.minutes == 90.0

      utc = Hours.summary(october)

      assert Enum.map(utc.by_day, &{&1.date, &1.minutes}) == [
               {~D[2026-10-05], 60.0},
               {~D[2026-10-07], 30.0}
             ]

      plus3 = Hours.summary(%{october | offset_seconds: 3 * 3600})
      assert Enum.map(plus3.by_day, & &1.date) == [~D[2026-10-06], ~D[2026-10-07]]
      assert plus3.matrix["user:#{ann.uuid}"] == %{~D[2026-10-06] => 60.0, ~D[2026-10-07] => 30.0}

      # `until` is exclusive.
      assert Hours.summary(f(project, until: ~U[2026-10-05 22:30:00Z])).totals.minutes == 15.0
    end

    test "billable, a task and a project set narrow the read" do
      project = fixture_project()
      other = fixture_project()
      t = task(project, "Only this")
      log(project, 60, assignment_uuid: t.uuid, billable: true)
      log(project, 30, [])
      log(other, 500, [])

      assert Hours.summary(f(project, billable: true)).totals.minutes == 60.0
      assert Hours.summary(f(project, billable: false)).totals.minutes == 30.0
      assert Hours.summary(f(project, assignment_uuid: t.uuid)).totals.minutes == 60.0
      assert Hours.summary(Hours.filters(project_uuids: :all)).totals.minutes >= 590.0
      assert Hours.summary(Hours.filters(project_uuids: [])).totals.minutes == 0.0
    end

    test "a forged worker key is dropped, not run" do
      project = fixture_project()
      log(project, 60, [])
      filters = f(project, workers: ["user:not-a-uuid", "robot:#{Ecto.UUID.generate()}", 7])
      assert filters.workers == []
      assert Hours.summary(filters).totals.minutes == 60.0
    end
  end

  describe "list/2" do
    test "sorts, pages and names each row" do
      project = fixture_project(%{"name" => "Kitchen #{uniq()}"})
      ann = user("Ann Able")
      t = task(project, "Cut the panels")
      log(project, 10, actor_uuid: ann.uuid, ended_at: ~U[2026-10-01 10:00:00Z])

      log(project, 90,
        actor_uuid: ann.uuid,
        assignment_uuid: t.uuid,
        ended_at: ~U[2026-10-03 10:00:00Z]
      )

      log(project, 40, actor_uuid: ann.uuid, ended_at: ~U[2026-10-02 10:00:00Z])
      {:ok, _} = Ledger.record_ai(project.uuid, %{tokens: 5})

      %{entries: rows, total: 3} = Hours.list(f(project))
      assert Enum.map(rows, &Decimal.to_integer(&1.entry.amount)) == [90, 40, 10]
      assert hd(rows).worker.name == "Ann Able"
      assert hd(rows).task.title == "Cut the panels"
      assert hd(rows).project.name == project.name
      assert hd(rows).at == ~U[2026-10-03 10:00:00Z]
      assert List.last(rows).task == nil

      %{entries: by_amount} = Hours.list(f(project), sort_by: :amount, sort_dir: :asc)
      assert Enum.map(by_amount, &Decimal.to_integer(&1.entry.amount)) == [10, 40, 90]

      %{entries: [second], total: 3} = Hours.list(f(project), limit: 1, offset: 1)
      assert Decimal.to_integer(second.entry.amount) == 40

      %{entries: by_task} = Hours.list(f(project), sort_by: :task, sort_dir: :asc)
      assert hd(by_task).task.title == "Cut the panels"

      assert %{total: 1} = Hours.list(f(project), kinds: ["tokens"])
    end
  end

  describe "the projects a read covers" do
    test "a project alone, or with everything nested under it" do
      parent = fixture_project()

      {:ok, %{child_project: child}} =
        Projects.create_subproject(parent.uuid, %{"name" => "Child #{uniq()}"})

      log(parent, 60, [])
      log(child, 30, [])

      assert Hours.project_uuids(parent.uuid, false) == [parent.uuid]

      assert Enum.sort(Hours.project_uuids(parent.uuid, true)) ==
               Enum.sort([parent.uuid, child.uuid])

      alone = Hours.summary(Hours.filters(project_uuids: Hours.project_uuids(parent.uuid, false)))
      tree = Hours.summary(Hours.filters(project_uuids: Hours.project_uuids(parent.uuid, true)))
      assert alone.totals.minutes == 60.0
      assert tree.totals.minutes == 90.0
      assert length(tree.by_project) == 2
    end

    test "a member sees their projects and what is nested under them; an admin sees all" do
      mine = fixture_project()
      theirs = fixture_project()

      {:ok, %{child_project: child}} =
        Projects.create_subproject(mine.uuid, %{"name" => "Child #{uniq()}"})

      member = user()
      {:ok, _} = Members.add_member(mine, member.uuid, role: "member")

      scope = %PhoenixKit.Users.Auth.Scope{
        user: member,
        authenticated?: true,
        cached_roles: [],
        cached_permissions: MapSet.new(["projects"])
      }

      visible = Hours.visible_project_uuids(scope)
      assert mine.uuid in visible and child.uuid in visible
      refute theirs.uuid in visible

      admin = %{scope | cached_permissions: MapSet.new(["projects", "projects.admin_all"])}
      assert Hours.visible_project_uuids(admin) == :all
      assert Hours.visible_project_uuids(nil) == []
    end
  end

  describe "batched reads" do
    test "the summary and a page of entries cost the same for 3 entries as for 30" do
      small = fixture_project()
      big = fixture_project()

      seed = fn project, n ->
        for i <- 1..n do
          u = user()
          t = task(project, "Task #{i}")
          log(project, 10 + i, actor_uuid: u.uuid, assignment_uuid: t.uuid)
        end
      end

      seed.(small, 3)
      seed.(big, 30)

      {_, small_summary} = QueryCounter.count(fn -> Hours.summary(f(small)) end)
      {_, big_summary} = QueryCounter.count(fn -> Hours.summary(f(big)) end)
      assert small_summary == big_summary

      {_, small_list} = QueryCounter.count(fn -> Hours.list(f(small), limit: 50) end)
      {%{entries: rows}, big_list} = QueryCounter.count(fn -> Hours.list(f(big), limit: 50) end)
      assert length(rows) == 30
      assert small_list == big_list
    end
  end
end
