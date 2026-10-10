defmodule PhoenixKitProjects.HoursReportTest do
  @moduledoc """
  The pure parts of the Hours pages: how a duration is written and read
  back, how a period preset becomes instants, and the report as text and
  as CSV.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitProjects.Hours.{Format, Period, Report}
  alias PhoenixKitProjects.Schemas.WorkEntry

  describe "Format" do
    test "writes minutes the way the project page does" do
      assert Format.duration(45) == "45m"
      assert Format.duration(120) == "2h"
      assert Format.duration(125.4) == "2h 05m"
      assert Format.duration(0) == "0m"
      assert Format.decimal_hours(90) == "1.50"
      assert Format.tokens(950) == "950"
      assert Format.tokens(3_400) == "3.4k"
      assert Format.tokens(1_200_000) == "1.2M"
      assert Format.cost(1234) == "$12.34"
    end

    test "reads what a person types" do
      for {text, minutes} <- [
            {"90", 90},
            {" 90m ", 90},
            {"45 min", 45},
            {"1h", 60},
            {"1h 30m", 90},
            {"1h30", 90},
            {"1 h 30 min", 90},
            {"2H 05M", 125},
            {"1.5h", 90},
            {"1,5 h", 90},
            {"0.25 hours", 15},
            {"1:30", 90},
            {"0:45", 45}
          ] do
        assert Format.parse_duration(text) == {:ok, minutes}, text
      end
    end

    test "refuses nothing, nonsense, zero and more than an entry holds" do
      for text <- ["", "   ", "soon", "-5", "0", "0h", "1:75", "1h 30m 5s", "h", nil, 90] do
        assert Format.parse_duration(text) == :error, inspect(text)
      end

      assert Format.parse_duration("#{WorkEntry.max_minutes()}") == {:ok, WorkEntry.max_minutes()}
      assert Format.parse_duration("#{WorkEntry.max_minutes() + 1}") == :error
    end
  end

  describe "Period" do
    @wed ~D[2026-10-07]

    test "presets resolve against the viewer's today" do
      assert %{from_date: @wed, to_date: @wed} = Period.resolve("today", "", "", @wed, "0")

      assert %{from_date: ~D[2026-10-05], to_date: ~D[2026-10-11]} =
               Period.resolve("week", "", "", @wed, "0")

      assert %{from_date: ~D[2026-09-28], to_date: ~D[2026-10-04]} =
               Period.resolve("last_week", "", "", @wed, "0")

      assert %{from_date: ~D[2026-10-01], to_date: ~D[2026-10-31]} =
               Period.resolve("month", "", "", @wed, "0")

      assert %{from_date: ~D[2026-09-01], to_date: ~D[2026-09-30]} =
               Period.resolve("last_month", "", "", @wed, "0")

      assert %{from_date: ~D[2026-01-01], to_date: ~D[2026-12-31]} =
               Period.resolve("year", "", "", @wed, "0")

      assert %{from: nil, until: nil, label: "All time"} =
               Period.resolve("all", "", "", @wed, "0")

      assert %{preset: "all", from: nil} = Period.resolve("bogus", "", "", @wed, "0")
    end

    test "the instants are the viewer's midnights, and `until` is the day after the last" do
      p = Period.resolve("today", "", "", @wed, "3")
      assert p.from == ~U[2026-10-06 21:00:00Z]
      assert p.until == ~U[2026-10-07 21:00:00Z]

      utc = Period.resolve("today", "", "", @wed, "0")
      assert utc.from == ~U[2026-10-07 00:00:00Z] and utc.until == ~U[2026-10-08 00:00:00Z]
    end

    test "a custom period takes either end, and a reversed pair the right way round" do
      assert %{from_date: ~D[2026-10-01], to_date: nil, until: nil, label: "From Oct 1, 2026"} =
               Period.resolve("custom", "2026-10-01", "", @wed, "0")

      assert %{from_date: nil, to_date: ~D[2026-10-03], label: "Until Oct 3, 2026"} =
               Period.resolve("custom", "nope", "2026-10-03", @wed, "0")

      assert %{
               from_date: ~D[2026-10-01],
               to_date: ~D[2026-10-03],
               label: "Oct 1, 2026 – Oct 3, 2026"
             } =
               Period.resolve("custom", "2026-10-03", "2026-10-01", @wed, "0")

      assert %{label: "Oct 7, 2026"} = Period.resolve("today", "", "", @wed, "0")
    end

    test "today and the offset follow the viewer's zone" do
      assert Period.today("3", ~U[2026-10-07 22:30:00Z]) == ~D[2026-10-08]
      assert Period.today("-5", ~U[2026-10-07 02:00:00Z]) == ~D[2026-10-06]
      assert Period.offset_seconds("3") == 10_800
      assert Period.offset_seconds("0") == 0
      assert Period.week_start(~D[2026-10-11]) == ~D[2026-10-05]
    end
  end

  describe "Report" do
    defp row(minutes, opts) do
      %{
        entry: %WorkEntry{
          amount: Decimal.new(minutes),
          billable: Keyword.get(opts, :billable, false),
          note: Keyword.get(opts, :note),
          source: "manual"
        },
        at: Keyword.get(opts, :at, ~U[2026-10-05 22:30:00Z]),
        worker: %{
          key: "user:1",
          kind: "user",
          uuid: "1",
          name: Keyword.get(opts, :who, "Ann Able")
        },
        task: Keyword.get(opts, :task, %{uuid: "t", title: "Cut the panels"}),
        project: %{uuid: "p", name: "Kitchen"}
      }
    end

    defp report(extra \\ []) do
      Report.build(
        Keyword.merge(
          [
            title: "Hours — Kitchen",
            period: "Oct 1, 2026 – Oct 31, 2026",
            generated_at: ~U[2026-10-10 08:00:00Z],
            filters: [{"Person", "Ann Able"}],
            totals: %{
              minutes: 150.0,
              billable_minutes: 90.0,
              ai_minutes: 20.0,
              tokens: 1200.0,
              cost_cents: 250.0,
              entries: 2,
              people: 1
            },
            by_worker: [
              %{worker: %{name: "Ann Able"}, minutes: 150.0, billable_minutes: 90.0, entries: 2}
            ],
            by_task: [
              %{
                task: %{uuid: "t", title: "Cut the panels"},
                project: %{name: "Kitchen"},
                minutes: 90.0,
                billable_minutes: 90.0,
                entries: 1
              },
              %{
                task: nil,
                project: %{name: "Kitchen"},
                minutes: 60.0,
                billable_minutes: 0.0,
                entries: 1
              }
            ],
            by_project: [
              %{project: %{name: "Kitchen"}, minutes: 150.0, billable_minutes: 90.0, entries: 2}
            ],
            entries: [
              row(90, billable: true, note: "First\n pass"),
              row(60, task: nil, at: ~U[2026-10-06 09:00:00Z])
            ],
            offset: "3"
          ],
          extra
        )
      )
    end

    test "the text names the period, the totals, each person, each task and each entry" do
      text = Report.text(report())

      assert text =~ "# Hours — Kitchen\n"
      assert text =~ "Period: Oct 1, 2026 – Oct 31, 2026"
      assert text =~ "Person: Ann Able"
      assert text =~ "Total: 2h 30m (2.50 h)"
      assert text =~ "Billable: 1h 30m (1.50 h)"
      assert text =~ "AI time: 20m"
      assert text =~ "AI tokens: 1.2k"
      assert text =~ "AI cost: $2.50"
      assert text =~ "## By person\n\n- Ann Able: 2h 30m (1h 30m billable)"
      assert text =~ "- Cut the panels: 1h 30m (1h 30m billable)"
      assert text =~ "- The project itself: 1h"
      # one project: no "By project" section
      refute text =~ "## By project"
      # the viewer's clock (UTC+3), the note on one line
      assert text =~
               "- 2026-10-06 01:30 · Ann Able · Cut the panels · 1h 30m [billable] — First pass"

      assert text =~ "- 2026-10-06 12:00 · Ann Able · The project itself · 1h\n"
      assert String.ends_with?(text, "\n")

      refute Report.text(report(), entries: false) =~ "## Entries"
    end

    test "a cut entry list says so; several projects get their own section" do
      cut = report(total_entries: 5000)
      assert Report.truncated?(cut)
      assert Report.text(cut) =~ "The first 2 of 5000 entries."
      refute Report.truncated?(report())

      two =
        report(
          by_project: [
            %{project: %{name: "Kitchen"}, minutes: 100.0, billable_minutes: 0.0, entries: 1},
            %{project: %{name: nil}, minutes: 50.0, billable_minutes: 0.0, entries: 1}
          ]
        )

      assert Report.text(two) =~ "## By project\n\n- Kitchen: 1h 40m\n- —: 50m"
    end

    test "an empty report is still a report" do
      text = Report.text(Report.build(%{}))
      assert text =~ "# Hours"
      assert text =~ "Total: 0m (0.00 h)"
      refute text =~ "##"
    end

    test "the CSV has a header, one row per entry, quoted where it must be" do
      csv = Report.csv(report())
      [header, first, second, ""] = String.split(csv, "\r\n") |> rejoin_quoted()

      assert header == "Date,Time,Person,Project,Task,Minutes,Hours,Billable,Note,Source"

      assert first ==
               ~s|2026-10-06,01:30,Ann Able,Kitchen,Cut the panels,90,1.50,yes,"First\n pass",manual|

      assert second == "2026-10-06,12:00,Ann Able,Kitchen,,60,1.00,no,,manual"
    end

    test "a cell that would run as a formula is written as text; quotes are doubled" do
      csv =
        Report.csv(
          report(
            entries: [
              row(10, note: "=HYPERLINK(\"x\")", who: "+Ann"),
              row(10, note: "say \"hi\", ok", who: "@bob")
            ]
          )
        )

      assert csv =~ ~s|'+Ann|
      assert csv =~ ~s|"'=HYPERLINK(""x"")"|
      assert csv =~ ~s|'@bob|
      assert csv =~ ~s|"say ""hi"", ok"|
    end

    test "the download: a data URL with a byte-order mark, and a file name" do
      "data:text/csv;charset=utf-8;base64," <> encoded = Report.csv_data_url(report())
      assert <<0xEF, 0xBB, 0xBF, rest::binary>> = Base.decode64!(encoded)
      assert rest == Report.csv(report())

      assert Report.filename(report()) == "hours-hours-kitchen-2026-10-10.csv"

      assert Report.filename(report(title: "Часы — Кухня №1"), "txt") ==
               "hours-часы-кухня-1-2026-10-10.txt"

      assert Report.filename(report(title: "!!!")) == "hours-2026-10-10.csv"
    end
  end

  # A quoted cell may hold a line break; put such rows back together.
  defp rejoin_quoted(lines) do
    Enum.reduce(lines, [], fn line, acc ->
      case acc do
        [open | rest] ->
          if odd_quotes?(open), do: [open <> "\r\n" <> line | rest], else: [line | acc]

        [] ->
          [line]
      end
    end)
    |> Enum.reverse()
  end

  defp odd_quotes?(line), do: rem(length(String.split(line, "\"")) - 1, 2) == 1
end
