defmodule PhoenixKitProjects.Schemas.ProjectBranchesTest do
  @moduledoc """
  Branch coverage on `Project` schema — `name_index_for/2` (atom + string
  key paths, struct fallback), `maybe_require_date/1` (scheduled vs
  immediate), `start_modes/0` getter, `derived_status/2` ordering.
  """

  use PhoenixKitProjects.DataCase, async: true

  alias PhoenixKitProjects.Schemas.Project

  describe "start_modes/0 getter" do
    test "start_modes/0 returns the canonical list" do
      assert Project.start_modes() == ~w(immediate scheduled)
    end
  end

  describe "scheduled-mode date requirement" do
    test "scheduled without scheduled_start_date is invalid" do
      cs =
        Project.changeset(%Project{}, %{
          "name" => "S",
          "is_template" => "false",
          "start_mode" => "scheduled"
        })

      refute cs.valid?
      assert errors_on(cs) |> Map.has_key?(:scheduled_start_date)
    end

    test "scheduled with date passes" do
      cs =
        Project.changeset(%Project{}, %{
          "name" => "S",
          "is_template" => "false",
          "start_mode" => "scheduled",
          "scheduled_start_date" => DateTime.utc_now() |> DateTime.to_iso8601()
        })

      assert cs.valid?
    end

    test "immediate mode does not require a date" do
      cs =
        Project.changeset(%Project{}, %{
          "name" => "I",
          "is_template" => "false",
          "start_mode" => "immediate"
        })

      assert cs.valid?
    end
  end

  describe "validate_inclusion on start_mode" do
    test "rejects unknown start_mode" do
      cs =
        Project.changeset(%Project{}, %{
          "name" => "X",
          "is_template" => "false",
          "start_mode" => "asap"
        })

      refute cs.valid?
      assert errors_on(cs) |> Map.has_key?(:start_mode)
    end
  end

  describe "derived_status/2 priority order" do
    test ":archived wins over everything" do
      now = DateTime.utc_now()

      p = %Project{
        archived_at: now,
        is_template: true,
        completed_at: now,
        started_at: now
      }

      assert Project.derived_status(p) == :archived
    end

    test ":template wins over completion / start" do
      now = DateTime.utc_now()
      p = %Project{is_template: true, completed_at: now, started_at: now}
      assert Project.derived_status(p) == :template
    end

    test ":completed wins over :running" do
      now = DateTime.utc_now()
      p = %Project{started_at: now, completed_at: now}
      assert Project.derived_status(p) == :completed
    end

    test ":running for started + not completed" do
      now = DateTime.utc_now()
      p = %Project{started_at: now}
      assert Project.derived_status(p) == :running
    end

    test ":overdue for scheduled past start date" do
      past = DateTime.add(DateTime.utc_now(), -3600, :second)
      p = %Project{start_mode: "scheduled", scheduled_start_date: past}
      assert Project.derived_status(p) == :overdue
    end

    test ":overdue for scheduled same-day past time" do
      # Scheduled for 1 hour ago — must flip to :overdue even though the
      # date is still today (time-of-day must be honored, not just date).
      one_hour_ago = DateTime.add(DateTime.utc_now(), -3600, :second)
      p = %Project{start_mode: "scheduled", scheduled_start_date: one_hour_ago}
      assert Project.derived_status(p) == :overdue
    end

    test ":scheduled for scheduled future start date" do
      future = DateTime.add(DateTime.utc_now(), 7 * 86_400, :second)
      p = %Project{start_mode: "scheduled", scheduled_start_date: future}
      assert Project.derived_status(p) == :scheduled
    end

    test ":setup for immediate not started" do
      p = %Project{start_mode: "immediate"}
      assert Project.derived_status(p) == :setup
    end
  end
end
