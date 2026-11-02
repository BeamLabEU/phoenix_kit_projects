defmodule PhoenixKitProjects.Web.DurationInputTest do
  @moduledoc """
  Every amount of time is a number and a unit — minutes, hours or days, a
  day being 8 hours — never text to parse (the boss, 2026-10-30: "1 час"
  was refused and the hint was English only).
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKitProjects.{Ledger, Projects}
  alias PhoenixKitProjects.Web.Components.DurationInput

  describe "reading a number and a unit" do
    test "minutes, hours, days of 8 hours, and decimals with a point or a comma" do
      assert DurationInput.to_minutes(%{"amount" => "45", "unit" => "minutes"}) == {:ok, 45}
      assert DurationInput.to_minutes(%{"amount" => "1.5", "unit" => "hours"}) == {:ok, 90}
      assert DurationInput.to_minutes(%{"amount" => "1,5", "unit" => "hours"}) == {:ok, 90}
      assert DurationInput.to_minutes(%{"amount" => "1", "unit" => "days"}) == {:ok, 480}
    end

    test "refuses text, nothing, zero, an unknown unit and a bare string" do
      for bad <- [
            %{"amount" => "1 час", "unit" => "hours"},
            %{"amount" => "", "unit" => "hours"},
            %{"amount" => "0", "unit" => "hours"},
            %{"amount" => "2", "unit" => "fortnights"},
            "1h 30m",
            nil
          ] do
        assert DurationInput.to_minutes(bad) == :error, inspect(bad)
      end
    end

    test "an estimate with a decimal becomes a whole number of a smaller unit" do
      assert DurationInput.estimate_attrs(%{
               "estimated_duration" => "1.5",
               "estimated_duration_unit" => "hours"
             }) == %{"estimated_duration" => "90", "estimated_duration_unit" => "minutes"}

      assert DurationInput.estimate_attrs(%{
               "estimated_duration" => "1,5",
               "estimated_duration_unit" => "days"
             }) == %{"estimated_duration" => "12", "estimated_duration_unit" => "hours"}

      assert DurationInput.estimate_attrs(%{
               "estimated_duration" => "3",
               "estimated_duration_unit" => "days"
             }) == %{"estimated_duration" => "3", "estimated_duration_unit" => "days"}
    end

    test "minutes are shown as the largest whole unit" do
      assert DurationInput.from_minutes(960) == {2, "days"}
      assert DurationInput.from_minutes(120) == {2, "hours"}
      assert DurationInput.from_minutes(90) == {1.5, "hours"}
      assert DurationInput.from_minutes(45) == {45, "minutes"}
    end
  end

  describe "the task form" do
    setup %{conn: conn} do
      me = embed_user_uuid!()
      project = fixture_project(%{"start_mode" => "immediate"})

      {:ok, %{assignment: a}} =
        Projects.create_task_with_assignment(
          project.uuid,
          %{"title" => "Glue the edges", "ad_hoc" => true},
          %{}
        )

      {:ok, conn: put_test_scope(conn, fake_scope(user_uuid: me)), project: project, a: a}
    end

    defp edit(ctx),
      do: live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}/assignments/#{ctx.a.uuid}/edit")

    test "logs time as a number and a unit", ctx do
      {:ok, view, html} = edit(ctx)
      refute html =~ "1h 30m, 1:30"
      assert has_element?(view, "select[name='duration[unit]'] option[value=days]")

      view
      |> form("[id^='assignment-log-form-']", %{
        "duration" => %{"amount" => "1,5", "unit" => "hours"}
      })
      |> render_submit()

      assert [entry] = Ledger.list_entries(ctx.project.uuid)
      assert Decimal.to_integer(entry.amount) == 90
    end

    test "an estimate of 1.5 hours is kept as 90 minutes", ctx do
      {:ok, view, _html} = edit(ctx)

      view
      |> form("#assignment-form",
        assignment: %{estimated_duration: "1.5", estimated_duration_unit: "hours"}
      )
      |> render_submit()

      a = Projects.get_assignment(ctx.a.uuid)
      assert {a.estimated_duration, a.estimated_duration_unit} == {90, "minutes"}
    end
  end
end
