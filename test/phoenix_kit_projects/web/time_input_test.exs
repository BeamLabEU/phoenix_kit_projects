defmodule PhoenixKitProjects.Web.TimeInputTest do
  @moduledoc """
  Times follow the site's clock (core's `time_format`: `"H:i"` or `"h:i A"`)
  everywhere: printed through `L10n.format_time/1` and typed through the
  `TimeInput` picker — a date, an hour, a minute, and AM/PM only on a
  12-hour site — never the browser's `datetime-local` / `time` fields, which
  draw the device's clock (an iPad showed AM/PM on a 24-hour site; the boss,
  2026-10-30).
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitProjects.{L10n, Projects}
  alias PhoenixKitProjects.Web.Components.{FormParts, TimeInput}

  setup %{conn: conn} do
    me = embed_user_uuid!()
    project = fixture_project(%{"start_mode" => "immediate"})

    {:ok, %{assignment: a}} =
      Projects.create_task_with_assignment(
        project.uuid,
        %{"title" => "Deliver the worktop", "ad_hoc" => true},
        %{}
      )

    on_exit(fn -> L10n.reset_viewer_zone() end)
    {:ok, conn: put_test_scope(conn, fake_scope(user_uuid: me)), project: project, a: a}
  end

  defp twelve_hour! do
    {:ok, _} = Settings.update_setting("time_format", "h:i A")
    L10n.reset_viewer_zone()
  end

  describe "folding the posted parts" do
    test "a day and a time, a time alone, and nothing" do
      assert TimeInput.fold(%{"date" => "2026-10-31", "hour" => "17", "minute" => "5"}) ==
               "2026-10-31T17:05"

      assert TimeInput.fold(%{"date" => "", "hour" => "17", "minute" => "5"}) == ""
      assert TimeInput.fold(%{"hour" => "9", "minute" => "30"}) == "09:30"
      assert TimeInput.fold(%{"hour" => "", "minute" => "30"}) == ""
    end

    test "the 12-hour clock: 12 AM is midnight, 12 PM noon" do
      assert TimeInput.fold(%{"hour" => "12", "minute" => "0", "half" => "am"}) == "00:00"
      assert TimeInput.fold(%{"hour" => "12", "minute" => "0", "half" => "pm"}) == "12:00"
      assert TimeInput.fold(%{"hour" => "5", "minute" => "30", "half" => "pm"}) == "17:30"
      assert TimeInput.fold(%{"hour" => "5", "minute" => "30", "half" => "am"}) == "05:30"
    end

    test "normalize/2 leaves strings and other fields alone" do
      attrs = %{
        "deadline" => %{"date" => "2026-11-02", "hour" => "8", "minute" => "15"},
        "start_time" => "10:00",
        "title" => "x"
      }

      assert TimeInput.normalize(attrs, ~w(deadline start_time end_time)) == %{
               "deadline" => "2026-11-02T08:15",
               "start_time" => "10:00",
               "title" => "x"
             }
    end

    test "a value is read back into its parts" do
      assert TimeInput.parts(~T[07:45:00]) == %{date: "", hour: 7, minute: 45}
      assert TimeInput.parts("2026-10-31T17:05") == %{date: "2026-10-31", hour: 17, minute: 5}
      assert TimeInput.parts(nil) == %{date: "", hour: nil, minute: nil}
    end
  end

  describe "printing a time" do
    test "24 hours by default" do
      L10n.reset_viewer_zone()
      assert L10n.format_time(~T[17:05:00]) == "17:05"
      assert L10n.format_clock(9, 0) == "09:00"
    end

    test "the 12-hour clock when the site says so" do
      twelve_hour!()
      assert L10n.format_time(~T[17:05:00]) == "5:05 PM"
      assert L10n.format_time(~T[00:10:00]) == "12:10 AM"
      assert L10n.format_clock(12, 0) == "12:00 PM"
    end
  end

  describe "a short date" do
    test "no year this year, the full date another" do
      L10n.reset_viewer_zone()
      this_year = L10n.local_date(DateTime.utc_now()).year
      assert L10n.format_short_date(Date.new!(this_year, 10, 27)) == "Oct 27"
      assert L10n.format_short_date(~D[2020-10-27]) == L10n.format_date(~D[2020-10-27])
      assert L10n.format_short_date(nil) == nil
    end
  end

  # The boss, 2026-11-02: one typed field, not an hour and a minute select.
  describe "typing a time" do
    test "the forms people type" do
      assert TimeInput.parse_clock("17:30") == {17, 30}
      assert TimeInput.parse_clock("17.30") == {17, 30}
      assert TimeInput.parse_clock("1730") == {17, 30}
      assert TimeInput.parse_clock("930") == {9, 30}
      assert TimeInput.parse_clock("17") == {17, 0}
      assert TimeInput.parse_clock("5:30 pm") == {17, 30}
      assert TimeInput.parse_clock("5pm") == {17, 0}
      assert TimeInput.parse_clock("12 am") == {0, 0}
      assert TimeInput.parse_clock("12:15 PM") == {12, 15}
      assert TimeInput.parse_clock("5:30 p.m.") == {17, 30}
    end

    test "what is no time" do
      assert TimeInput.parse_clock("") == nil
      assert TimeInput.parse_clock("25:00") == nil
      assert TimeInput.parse_clock("13 pm") == nil
      assert TimeInput.parse_clock("7:61") == nil
      assert TimeInput.parse_clock("soon") == nil
      # Another script's digits (a CJK input method's full-width ones,
      # Arabic-Indic) are no time — they used to match and then raise.
      assert TimeInput.parse_clock("１７") == nil
      assert TimeInput.parse_clock("٥:٣٠") == nil
    end

    test "a crafted nested part reads as nothing, never a crash" do
      assert TimeInput.fold(%{"date" => %{"x" => "1"}, "time" => "9:30"}) == ""
      assert TimeInput.fold(%{"time" => %{"x" => "1"}}) == ""
      assert TimeInput.fold(%{"hour" => ["1"], "minute" => "5"}) == ""
    end

    test "folded with its day" do
      assert TimeInput.fold(%{"date" => "2026-10-31", "time" => "1705"}) == "2026-10-31T17:05"
      assert TimeInput.fold(%{"time" => "9:30"}) == "09:30"
      assert TimeInput.fold(%{"time" => ""}) == ""
    end
  end

  describe "the task form" do
    test "asks for a time with one typed field in the site's clock, not the device's pickers",
         ctx do
      {:ok, view, html} =
        live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}/assignments/#{ctx.a.uuid}/edit")

      refute html =~ ~s(type="datetime-local")
      refute html =~ ~s(type="time")
      assert has_element?(view, "input[name='assignment[deadline][time]']")
      assert has_element?(view, "input[name='assignment[start_time][time]']")
      refute has_element?(view, "select[name='assignment[deadline][hour]']")
      assert html =~ "Today 17:00"
    end

    test "on a 12-hour site the time reads 5:00 PM, and 5:30 pm typed is saved as 17:30", ctx do
      twelve_hour!()

      {:ok, view, html} =
        live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}/assignments/#{ctx.a.uuid}/edit")

      assert html =~ "Today 5:00 PM"

      view
      |> form("#assignment-form",
        assignment: %{deadline: %{date: "2027-03-04", time: "5:30 pm"}}
      )
      |> render_submit()

      L10n.put_viewer_zone(nil)
      deadline = Projects.get_assignment(ctx.a.uuid).deadline
      assert L10n.local_date(deadline) == ~D[2027-03-04]
      assert L10n.local(deadline).hour == 17 and L10n.local(deadline).minute == 30
    end
  end
end
