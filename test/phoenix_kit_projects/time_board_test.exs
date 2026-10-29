defmodule PhoenixKitProjects.TimeBoardTest do
  @moduledoc """
  The Time page's data (`TimeBoard`): the planned window (explicit, walked
  back from the deadline through work hours, split across days), the
  deadline-only pin, the actual bar while in progress, a team task's plan on
  the team row with the work on its starter, and which lines a day shows.
  Pure — structs in, board out; no database.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitProjects.People.{Person, Team}
  alias PhoenixKitProjects.Schemas.{Assignment, Project, Task, WorkEntry}
  alias PhoenixKitProjects.TimeBoard

  # Wednesday.
  @day ~D[2026-10-28]
  @now ~U[2026-10-28 12:00:00Z]

  defp project,
    do: %Project{uuid: "p1", name: "Kitchen", counts_weekends: false, translations: %{}}

  defp person(name, user_uuid),
    do: %Person{uuid: "person-#{name}", name: name, user_uuid: user_uuid, user: nil}

  defp task(attrs) do
    struct(
      %Assignment{
        uuid: Ecto.UUID.generate(),
        project_uuid: "p1",
        project: project(),
        task: %Task{title: Keyword.get(attrs, :title, "A task"), translations: %{}},
        status: "todo",
        assigned_team: nil,
        assigned_department: nil,
        assigned_person: nil
      },
      Keyword.delete(attrs, :title)
    )
  end

  defp build(assignments, people, entries \\ [], opts \\ []) do
    TimeBoard.build(
      assignments,
      people,
      entries,
      Keyword.merge([from: @day, to: @day, now: @now], opts)
    )
  end

  defp lines(board, key) do
    row =
      Enum.find(board.people ++ board.groups, &(&1.key == key)) || flunk("no row #{inspect(key)}")

    row.lines
  end

  describe "walk_back/3" do
    test "fits inside the deadline's day: 17:00 less 3 h is 14:00–17:00" do
      assert TimeBoard.walk_back(~N[2026-10-28 17:00:00], 3, false) ==
               [{~N[2026-10-28 14:00:00], ~N[2026-10-28 17:00:00]}]
    end

    test "spills into the previous working day" do
      assert TimeBoard.walk_back(~N[2026-10-28 10:00:00], 3, false) == [
               {~N[2026-10-27 16:00:00], ~N[2026-10-27 17:00:00]},
               {~N[2026-10-28 08:00:00], ~N[2026-10-28 10:00:00]}
             ]
    end

    test "skips the weekend unless the task counts weekends" do
      monday = ~N[2026-10-26 09:00:00]

      assert TimeBoard.walk_back(monday, 2, false) == [
               {~N[2026-10-23 16:00:00], ~N[2026-10-23 17:00:00]},
               {~N[2026-10-26 08:00:00], ~N[2026-10-26 09:00:00]}
             ]

      assert [{~N[2026-10-25 16:00:00], ~N[2026-10-25 17:00:00]} | _] =
               TimeBoard.walk_back(monday, 2, true)
    end

    test "a deadline after the work day counts back from its end" do
      assert TimeBoard.walk_back(~N[2026-10-28 20:00:00], 1, false) ==
               [{~N[2026-10-28 16:00:00], ~N[2026-10-28 17:00:00]}]
    end
  end

  describe "planned window" do
    test "explicit planned dates and times win over the deadline" do
      a = task(start_date: @day, end_date: @day, start_time: ~T[13:00:00], end_time: ~T[15:00:00])

      assert TimeBoard.planned_window(a, ~N[2026-10-28 17:00:00], 3, false) ==
               {[{~N[2026-10-28 13:00:00], ~N[2026-10-28 15:00:00]}], :explicit}
    end

    test "planned dates without times take the work day" do
      a = task(start_date: @day, end_date: @day)

      assert {[{~N[2026-10-28 08:00:00], ~N[2026-10-28 17:00:00]}], :explicit} =
               TimeBoard.planned_window(a, nil, 0, false)
    end

    test "deadline with an estimate is walked back; deadline alone is no plan" do
      assert {[_], :deadline} =
               TimeBoard.planned_window(task([]), ~N[2026-10-28 17:00:00], 3, false)

      assert {[], nil} = TimeBoard.planned_window(task([]), ~N[2026-10-28 17:00:00], 0, false)
      assert {[], nil} = TimeBoard.planned_window(task([]), nil, 3, false)
    end
  end

  describe "build/4 — a person's lines" do
    test "the boss's example: due 17:00, 3 h estimate, done at 08:00 — both shown" do
      p = person("Ann", "u-ann")

      a =
        task(
          title: "Report",
          assigned_person_uuid: p.uuid,
          status: "done",
          deadline: ~U[2026-10-28 17:00:00Z],
          estimated_duration: 3,
          estimated_duration_unit: "hours",
          started_at: ~U[2026-10-28 08:00:00Z],
          completed_at: ~U[2026-10-28 09:00:00Z]
        )

      [line] = build([a], [p]) |> lines({:person, p.uuid})
      assert line.planned == [{~N[2026-10-28 14:00:00], ~N[2026-10-28 17:00:00]}]
      assert line.plan_source == :deadline
      assert line.actual == {~N[2026-10-28 08:00:00], ~N[2026-10-28 09:00:00]}
      assert line.deadline == ~N[2026-10-28 17:00:00]
      assert line.late == nil
      refute line.overdue?
    end

    test "deadline without an estimate is a pin only" do
      p = person("Ann", "u-ann")
      a = task(assigned_person_uuid: p.uuid, deadline: ~U[2026-10-28 15:00:00Z])

      [line] = build([a], [p]) |> lines({:person, p.uuid})
      assert line.planned == []
      assert line.deadline == ~N[2026-10-28 15:00:00]
    end

    test "in progress: the actual runs from the start to now, live" do
      p = person("Ann", "u-ann")

      a =
        task(
          assigned_person_uuid: p.uuid,
          status: "in_progress",
          started_at: ~U[2026-10-28 10:00:00Z]
        )

      [line] = build([a], [p]) |> lines({:person, p.uuid})
      assert line.actual == {~N[2026-10-28 10:00:00], ~N[2026-10-28 12:00:00]}
      assert line.live?
      assert line.rank == 0
    end

    test "finished past the deadline: the part after the pin is late" do
      p = person("Ann", "u-ann")

      a =
        task(
          assigned_person_uuid: p.uuid,
          status: "done",
          deadline: ~U[2026-10-28 10:00:00Z],
          started_at: ~U[2026-10-28 09:00:00Z],
          completed_at: ~U[2026-10-28 11:00:00Z]
        )

      [line] = build([a], [p]) |> lines({:person, p.uuid})
      assert line.late == {~N[2026-10-28 10:00:00], ~N[2026-10-28 11:00:00]}
    end

    test "logged time: a clock span is placed, a bare duration is only a total" do
      p = person("Ann", "u-ann")

      a =
        task(
          assigned_person_uuid: p.uuid,
          status: "in_progress",
          started_at: ~U[2026-10-28 09:00:00Z]
        )

      entries = [
        %WorkEntry{
          uuid: "e1",
          assignment_uuid: a.uuid,
          actor_uuid: "u-ann",
          amount: Decimal.new(60),
          started_at: ~U[2026-10-28 09:00:00Z],
          ended_at: ~U[2026-10-28 10:00:00Z],
          inserted_at: ~U[2026-10-28 10:00:00Z]
        },
        %WorkEntry{
          uuid: "e2",
          assignment_uuid: a.uuid,
          actor_uuid: "u-ann",
          amount: Decimal.new(90),
          inserted_at: ~U[2026-10-28 11:00:00Z]
        }
      ]

      [line] = build([a], [p], entries) |> lines({:person, p.uuid})

      assert [
               %{span: {~N[2026-10-28 09:00:00], ~N[2026-10-28 10:00:00]}},
               %{span: nil, minutes: 90.0}
             ] =
               line.logged
    end

    test "sort: in progress, overdue, planned, done" do
      p = person("Ann", "u-ann")

      done =
        task(
          title: "Done",
          assigned_person_uuid: p.uuid,
          status: "done",
          completed_at: ~U[2026-10-28 09:00:00Z],
          started_at: ~U[2026-10-28 08:00:00Z]
        )

      planned =
        task(title: "Planned", assigned_person_uuid: p.uuid, start_date: @day, end_date: @day)

      overdue =
        task(title: "Overdue", assigned_person_uuid: p.uuid, deadline: ~U[2026-10-27 17:00:00Z])

      running =
        task(
          title: "Running",
          assigned_person_uuid: p.uuid,
          status: "in_progress",
          started_at: ~U[2026-10-28 11:00:00Z]
        )

      titles =
        build([done, planned, overdue, running], [p])
        |> lines({:person, p.uuid})
        |> Enum.map(& &1.title)

      assert titles == ["Running", "Overdue", "Planned", "Done"]
    end
  end

  describe "build/4 — teams" do
    test "a team task's plan sits on the team row; the actual on whoever started it" do
      ann = person("Ann", "u-ann")
      bob = person("Bob", "u-bob")

      a =
        task(
          title: "Team job",
          assigned_team_uuid: "t1",
          assigned_team: %Team{uuid: "t1", name: "Crew"},
          status: "in_progress",
          deadline: ~U[2026-10-28 17:00:00Z],
          estimated_duration: 2,
          estimated_duration_unit: "hours",
          started_at: ~U[2026-10-28 09:00:00Z],
          started_by_uuid: "u-bob"
        )

      board = build([a], [ann, bob])

      assert [%{key: {:team, "t1"}, name: "Crew", lines: [plan]}] = board.groups
      assert plan.planned == [{~N[2026-10-28 15:00:00], ~N[2026-10-28 17:00:00]}]
      assert plan.actual == nil
      assert plan.worked_by == ["Bob"]

      assert [work] = lines(board, {:person, bob.uuid})
      assert work.actual == {~N[2026-10-28 09:00:00], ~N[2026-10-28 12:00:00]}
      assert work.planned == []
      assert work.via == "Crew"

      # Never cloned onto the other members.
      assert lines(board, {:person, ann.uuid}) == []
    end
  end

  describe "day relevance" do
    test "a line shows only on a day it has a reason to be on" do
      p = person("Ann", "u-ann")
      far = task(title: "Far", assigned_person_uuid: p.uuid, deadline: ~U[2026-11-10 17:00:00Z])

      old =
        task(
          title: "Old",
          assigned_person_uuid: p.uuid,
          status: "done",
          started_at: ~U[2026-10-20 08:00:00Z],
          completed_at: ~U[2026-10-20 09:00:00Z]
        )

      overdue =
        task(title: "Overdue", assigned_person_uuid: p.uuid, deadline: ~U[2026-10-27 17:00:00Z])

      assert ["Overdue"] =
               build([far, old, overdue], [p]) |> lines({:person, p.uuid}) |> Enum.map(& &1.title)

      # The next day is not today: an overdue task stays on today, its own day.
      tomorrow = ~D[2026-10-29]

      assert [] =
               build([far, old, overdue], [p], [], from: tomorrow, to: tomorrow)
               |> lines({:person, p.uuid})

      # Its deadline's own day still shows it.
      yesterday = ~D[2026-10-27]

      assert ["Overdue"] =
               build([overdue], [p], [], from: yesterday, to: yesterday)
               |> lines({:person, p.uuid})
               |> Enum.map(& &1.title)
    end

    test "idle people are listed after busy ones" do
      ann = person("Ann", "u-ann")
      zed = person("Zed", "u-zed")
      a = task(assigned_person_uuid: zed.uuid, start_date: @day, end_date: @day)

      assert [%{name: "Zed"}, %{name: "Ann", lines: []}] = build([a], [ann, zed]).people
    end

    test "the unscheduled strip counts tasks with no clock per assignee" do
      p = person("Ann", "u-ann")
      a = task(assigned_person_uuid: p.uuid)
      board = build([], [p], [], unscheduled: [a])
      assert %{{:person, "person-Ann"} => [^a]} = board.unscheduled
    end
  end

  describe "build/4 — review fixes" do
    test "an unscheduled task's assignee has a row, though no one listed them" do
      ann = person("Ann", "u-ann")
      a = task(assigned_person_uuid: ann.uuid, assigned_person: ann)

      board = build([], [], [], unscheduled: [a], include_idle?: false)

      assert [%{key: {:person, uuid}, lines: []}] = board.people
      assert uuid == ann.uuid
      assert %{{:person, ^uuid} => [^a]} = board.unscheduled
    end

    test "time logged for a staff person (by the person) is on their row" do
      ann = person("Ann", "u-ann")
      sam = person("Sam", nil)

      a =
        task(
          title: "Team job",
          assigned_team_uuid: "t1",
          assigned_team: %Team{uuid: "t1", name: "Crew"},
          deadline: ~U[2026-10-28 17:00:00Z]
        )

      entry = %WorkEntry{
        uuid: "e-sam",
        assignment_uuid: a.uuid,
        actor_kind: "staff_person",
        actor_uuid: sam.uuid,
        amount: Decimal.new(45),
        started_at: ~U[2026-10-28 09:00:00Z],
        ended_at: ~U[2026-10-28 09:45:00Z],
        inserted_at: ~U[2026-10-28 10:00:00Z]
      }

      board = build([a], [ann, sam], [entry])

      assert [%{role: :worker, logged: [%{uuid: "e-sam", minutes: 45.0}]}] =
               lines(board, {:person, sam.uuid})

      assert [%{role: :plan, logged: [], worked_by: ["Sam"]}] = lines(board, {:team, "t1"})
    end

    test "a trashed person has no row, as an assignee or listed" do
      gone = %{person("Gone", "u-gone") | status: "trashed"}
      a = task(assigned_person_uuid: gone.uuid, assigned_person: gone, start_date: @day)

      board = build([a], [gone], [], unscheduled: [task(assigned_person: gone)])

      assert board.people == []
    end

    test "work across the autumn fold keeps its length on the wall clock" do
      PhoenixKitProjects.L10n.put_viewer_zone(%{user_timezone: "Europe/Tallinn"})
      on_exit(fn -> PhoenixKitProjects.L10n.reset_viewer_zone() end)

      ann = person("Ann", "u-ann")

      # 00:45Z is 03:45 summer time, 01:15Z is 03:15 winter time: 30 minutes.
      a =
        task(
          assigned_person_uuid: ann.uuid,
          status: "done",
          started_at: ~U[2026-10-25 00:45:00Z],
          completed_at: ~U[2026-10-25 01:15:00Z]
        )

      day = ~D[2026-10-25]
      [line] = build([a], [ann], [], from: day, to: day) |> lines({:person, ann.uuid})

      assert line.actual == {~N[2026-10-25 03:45:00], ~N[2026-10-25 04:15:00]}
    end
  end
end
