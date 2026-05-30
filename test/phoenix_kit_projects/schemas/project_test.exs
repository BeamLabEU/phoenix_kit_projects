defmodule PhoenixKitProjects.Schemas.ProjectTest do
  @moduledoc """
  Pure changeset + derived_status tests for `Schemas.Project`. No DB —
  the `project_branches_test.exs` integration sibling covers the
  persistence paths.
  """

  use ExUnit.Case, async: true

  alias Ecto.Changeset
  alias PhoenixKitProjects.Schemas.Project

  describe "changeset/3 — required + length" do
    test "name is required" do
      cs = Project.changeset(%Project{}, %{})
      refute cs.valid?
      assert {:name, {_, _}} = List.keyfind(cs.errors, :name, 0)
    end

    test "name max length 255" do
      cs =
        Project.changeset(%Project{}, %{
          "name" => String.duplicate("x", 256),
          "start_mode" => "immediate"
        })

      refute cs.valid?
      assert {:name, {_, _}} = List.keyfind(cs.errors, :name, 0)
    end

    test "valid minimal input" do
      cs = Project.changeset(%Project{}, %{"name" => "Plan", "start_mode" => "immediate"})
      assert cs.valid?
    end

    test "external_id is castable and round-trips" do
      cs =
        Project.changeset(%Project{}, %{
          "name" => "Plan",
          "start_mode" => "immediate",
          "external_id" => "ext-abc-123"
        })

      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :external_id) == "ext-abc-123"
    end

    test "external_id max length 255" do
      cs =
        Project.changeset(%Project{}, %{
          "name" => "Plan",
          "start_mode" => "immediate",
          "external_id" => String.duplicate("x", 256)
        })

      refute cs.valid?
      assert {:external_id, {_, _}} = List.keyfind(cs.errors, :external_id, 0)
    end

    test "counts_weekends omitted is valid (schema default false applies)" do
      cs = Project.changeset(%Project{}, %{"name" => "Plan", "start_mode" => "immediate"})
      assert cs.valid?
    end

    test "counts_weekends explicit nil is rejected" do
      cs =
        Project.changeset(%Project{}, %{
          "name" => "Plan",
          "start_mode" => "immediate",
          "counts_weekends" => nil
        })

      refute cs.valid?
      assert {:counts_weekends, {_, _}} = List.keyfind(cs.errors, :counts_weekends, 0)
    end
  end

  describe "changeset/3 — start_mode enum + scheduled date" do
    test "rejects unknown start_mode" do
      cs = Project.changeset(%Project{}, %{"name" => "P", "start_mode" => "whenever"})
      refute cs.valid?
      assert {:start_mode, {_, _}} = List.keyfind(cs.errors, :start_mode, 0)
    end

    test "scheduled mode requires scheduled_start_date by default" do
      cs = Project.changeset(%Project{}, %{"name" => "P", "start_mode" => "scheduled"})
      refute cs.valid?
      assert {:scheduled_start_date, {_, _}} = List.keyfind(cs.errors, :scheduled_start_date, 0)
    end

    test "scheduled mode with enforce_scheduled_date_required: false skips date check" do
      cs =
        Project.changeset(
          %Project{},
          %{"name" => "P", "start_mode" => "scheduled"},
          enforce_scheduled_date_required: false
        )

      assert cs.valid?
    end

    test "scheduled mode + date is valid" do
      cs =
        Project.changeset(%Project{}, %{
          "name" => "P",
          "start_mode" => "scheduled",
          "scheduled_start_date" => DateTime.utc_now()
        })

      assert cs.valid?
    end
  end

  describe "changeset/3 — translations shape" do
    test "rejects malformed translations" do
      cs =
        Project.changeset(%Project{}, %{
          "name" => "P",
          "start_mode" => "immediate",
          "translations" => "not a map"
        })

      refute cs.valid?
      assert {:translations, {_, _}} = List.keyfind(cs.errors, :translations, 0)
    end

    test "accepts well-formed translations map" do
      cs =
        Project.changeset(%Project{}, %{
          "name" => "P",
          "start_mode" => "immediate",
          "translations" => %{"es-ES" => %{"name" => "Plan"}}
        })

      assert cs.valid?
      assert Changeset.get_change(cs, :translations) == %{"es-ES" => %{"name" => "Plan"}}
    end
  end

  describe "derived_status/2" do
    test ":archived wins over every other state" do
      p = %Project{
        archived_at: ~U[2026-01-01 00:00:00Z],
        is_template: true,
        started_at: ~U[2026-01-01 00:00:00Z]
      }

      assert Project.derived_status(p) == :archived
    end

    test ":template when not archived" do
      assert Project.derived_status(%Project{is_template: true}) == :template
    end

    test ":completed when completed_at is set" do
      p = %Project{completed_at: ~U[2026-01-01 00:00:00Z], started_at: ~U[2026-01-01 00:00:00Z]}
      assert Project.derived_status(p) == :completed
    end

    test ":running when started but not completed" do
      assert Project.derived_status(%Project{started_at: ~U[2026-01-01 00:00:00Z]}) == :running
    end

    test ":overdue when scheduled date has passed" do
      past = DateTime.add(DateTime.utc_now(), -3600, :second)
      p = %Project{start_mode: "scheduled", scheduled_start_date: past}
      assert Project.derived_status(p) == :overdue
    end

    test ":scheduled when scheduled date is still in the future" do
      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      p = %Project{start_mode: "scheduled", scheduled_start_date: future}
      assert Project.derived_status(p) == :scheduled
    end

    test ":setup when immediate-mode and not started" do
      assert Project.derived_status(%Project{start_mode: "immediate"}) == :setup
    end
  end

  describe "planned_end_for/2 + eta_from/3" do
    test "planned_end_for returns nil for unstarted projects" do
      assert Project.planned_end_for(%Project{}, 24) == nil
    end

    test "planned_end_for returns nil for zero/negative hours" do
      p = %Project{started_at: ~U[2026-01-01 00:00:00Z], counts_weekends: true}
      assert Project.planned_end_for(p, 0) == nil
      assert Project.planned_end_for(p, -5) == nil
    end

    test "counts_weekends: true is straight calendar add" do
      start = ~U[2026-01-01 00:00:00Z]
      p = %Project{started_at: start, counts_weekends: true}
      # 48 hours = 2 calendar days later
      assert Project.planned_end_for(p, 48) == DateTime.add(start, 2 * 24 * 3600, :second)
    end

    test "eta_from with hours <= 0 is nil" do
      assert Project.eta_from(%Project{counts_weekends: true}, DateTime.utc_now(), 0) == nil
    end
  end

  describe "translatable_fields/0 + start_modes/0" do
    test "translatable_fields returns name + description" do
      fields = Project.translatable_fields()
      assert "name" in fields
      assert "description" in fields
    end

    test "start_modes lists immediate + scheduled" do
      assert "immediate" in Project.start_modes()
      assert "scheduled" in Project.start_modes()
    end
  end
end
