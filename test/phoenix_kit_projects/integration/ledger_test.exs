defmodule PhoenixKitProjects.Integration.LedgerTest do
  @moduledoc """
  Step 10 work ledger: the V4 `phoenix_kit_project_work_entries` table via
  `PhoenixKitProjects.Ledger` — human time, AI usage (tokens + cost pairs),
  totals rollups, and the activity trail.
  """

  use PhoenixKitProjects.DataCase, async: false

  import PhoenixKitProjects.ActivityLogAssertions

  alias PhoenixKitProjects.{Ledger, Projects}
  alias PhoenixKitProjects.Schemas.WorkEntry

  setup do
    project = fixture_project()
    task = fixture_task()

    {:ok, assignment} =
      Projects.create_assignment(%{
        "project_uuid" => project.uuid,
        "task_uuid" => task.uuid,
        "status" => "todo"
      })

    {:ok, project: project, assignment: assignment}
  end

  describe "log_time/3" do
    test "creates a time entry with activity trail", %{project: project, assignment: a} do
      actor = Ecto.UUID.generate()

      assert {:ok, entry} =
               Ledger.log_time(project, 45,
                 assignment_uuid: a.uuid,
                 note: "Design pass",
                 billable: true,
                 actor_uuid: actor
               )

      assert entry.kind == "time"
      assert Decimal.equal?(entry.amount, Decimal.new(45))
      assert entry.actor_kind == "user"
      assert entry.source == "manual"
      assert entry.billable

      assert_activity_logged("projects.work_logged",
        resource_uuid: project.uuid,
        metadata_has: %{"kind" => "time", "actor_kind" => "user"}
      )
    end

    test "rejects a non-positive amount", %{project: project} do
      assert {:error, changeset} = Ledger.log_time(project, 0)
      assert %{amount: _} = errors_on(changeset)
    end

    test "rejects an unknown assignment (FK)", %{project: project} do
      assert {:error, changeset} =
               Ledger.log_time(project, 30, assignment_uuid: Ecto.UUID.generate())

      assert %{assignment_uuid: _} = errors_on(changeset)
    end
  end

  describe "record_ai/3" do
    test "writes a tokens entry plus a cost entry sharing metadata",
         %{project: project, assignment: a} do
      agent = Ecto.UUID.generate()

      assert {:ok, [tokens_entry, cost_entry]} =
               Ledger.record_ai(
                 project,
                 %{tokens: 12_500, cost_cents: 34, model: "claude-fable-5", agent_uuid: agent},
                 assignment_uuid: a.uuid
               )

      assert tokens_entry.kind == "tokens"
      assert Decimal.equal?(tokens_entry.amount, Decimal.new(12_500))
      assert cost_entry.kind == "cost"
      assert Decimal.equal?(cost_entry.amount, Decimal.new(34))

      for entry <- [tokens_entry, cost_entry] do
        assert entry.actor_kind == "ai_agent"
        assert entry.actor_uuid == agent
        assert entry.source == "ai"
        assert entry.metadata["model"] == "claude-fable-5"
        assert entry.assignment_uuid == a.uuid
      end
    end

    test "tokens without cost writes a single entry", %{project: project} do
      assert {:ok, [entry]} = Ledger.record_ai(project, %{tokens: 900})
      assert entry.kind == "tokens"
    end

    test "an empty usage map is refused", %{project: project} do
      assert {:error, :nothing_to_record} = Ledger.record_ai(project, %{model: "x"})
      assert Ledger.list_entries(project.uuid) == []
    end

    # Panel round (Gemini): 0 is TRUTHY in Elixir — a free/cached call
    # (`cost_cents: 0`) must skip the cost entry, not build a zero-amount
    # one that fails validation after the tokens row already committed.
    test "zero cost is skipped, not an error", %{project: project} do
      assert {:ok, [entry]} = Ledger.record_ai(project, %{tokens: 1_000, cost_cents: 0})
      assert entry.kind == "tokens"
      assert [_only] = Ledger.list_entries(project.uuid)
    end

    test "all-zero usage is refused with nothing written", %{project: project} do
      assert {:error, :nothing_to_record} = Ledger.record_ai(project, %{tokens: 0, cost_cents: 0})
      assert Ledger.list_entries(project.uuid) == []
    end
  end

  describe "totals" do
    test "totals_for_project sums per kind with billable split",
         %{project: project, assignment: a} do
      {:ok, _} = Ledger.log_time(project, 60, assignment_uuid: a.uuid, billable: true)
      {:ok, _} = Ledger.log_time(project, 30)
      {:ok, _} = Ledger.record_ai(project, %{tokens: 1_000, cost_cents: 25})

      totals = Ledger.totals_for_project(project.uuid)

      assert totals.time_minutes == 90.0
      assert totals.billable_minutes == 60.0
      assert totals.tokens == 1_000.0
      assert totals.cost_cents == 25.0
    end

    test "empty project rolls up to zeros", %{project: project} do
      assert Ledger.totals_for_project(project.uuid) ==
               %{time_minutes: 0.0, tokens: 0.0, cost_cents: 0.0, billable_minutes: 0.0}
    end

    test "time_for_assignments groups only the requested time entries",
         %{project: project, assignment: a} do
      {:ok, _} = Ledger.log_time(project, 20, assignment_uuid: a.uuid)
      {:ok, _} = Ledger.log_time(project, 15, assignment_uuid: a.uuid)
      # Project-level time and AI tokens must not leak into the map.
      {:ok, _} = Ledger.log_time(project, 99)
      {:ok, _} = Ledger.record_ai(project, %{tokens: 500}, assignment_uuid: a.uuid)

      assert Ledger.time_for_assignments([a.uuid]) == %{a.uuid => 35.0}
      assert Ledger.time_for_assignments([]) == %{}
    end
  end

  test "changeset validates the closed vocabularies" do
    base = %{project_uuid: Ecto.UUID.generate(), kind: "time", amount: 10}

    for {field, bad} <- [actor_kind: "robot", kind: "money", source: "webhook"] do
      changeset = WorkEntry.changeset(%WorkEntry{}, Map.put(base, field, bad))
      refute changeset.valid?, "expected #{field}=#{bad} to be invalid"
    end

    assert WorkEntry.changeset(%WorkEntry{}, Map.put(base, :actor_kind, "staff_person")).valid?
  end
end
