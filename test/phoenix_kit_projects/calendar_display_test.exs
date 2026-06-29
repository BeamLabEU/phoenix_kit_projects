defmodule PhoenixKitProjects.CalendarDisplayTest do
  use ExUnit.Case, async: true

  alias PhoenixKitProjects.CalendarDisplay
  alias PhoenixKitProjects.Schemas.Project

  @today ~D[2026-06-15]
  @palette_bgs ~w(bg-blue-600 bg-cyan-500 bg-emerald-600 bg-lime-500 bg-amber-400 bg-orange-600 bg-fuchsia-600 bg-violet-600)
  @palette_texts ~w(text-white text-neutral-900)

  defp project(attrs) do
    struct(
      Project,
      Map.merge(%{uuid: "u-#{System.unique_integer([:positive])}", translations: %{}}, attrs)
    )
  end

  describe "events/5 — spans & structure" do
    test "on-track project spans start -> planned_end (end exclusive)" do
      p = project(%{uuid: "run", name: "Run", started_at: ~U[2026-06-10 09:00:00Z]})
      summary = %{project: p, planned_end: ~U[2026-06-20 17:00:00Z], progress_pct: 40}

      [e] = CalendarDisplay.events([summary], [], [], nil, @today)

      assert e.id == "run"
      assert e.title == "Run"
      assert e.all_day == true
      assert e.start == ~D[2026-06-10]
      # planned end 2026-06-20 inclusive -> exclusive end is +1
      assert e.end == ~D[2026-06-21]
    end

    test "a running project past its planned end still reaches today (ongoing)" do
      p = project(%{uuid: "late", name: "Late", started_at: ~U[2026-06-01 09:00:00Z]})
      summary = %{project: p, planned_end: ~U[2026-06-05 17:00:00Z], progress_pct: 30}

      [e] = CalendarDisplay.events([summary], [], [], nil, @today)
      assert e.end == Date.add(@today, 1)
    end

    test "running project with no planned_end still spans start -> today" do
      p = project(%{uuid: "noend", name: "NoEnd", started_at: ~U[2026-06-10 09:00:00Z]})
      summary = %{project: p, planned_end: nil, progress_pct: 0}

      [e] = CalendarDisplay.events([summary], [], [], nil, @today)
      assert e.start == ~D[2026-06-10]
      assert e.end == Date.add(@today, 1)
    end

    test "running project without a started_at is dropped" do
      p = project(%{uuid: "nostart", name: "NoStart", started_at: nil})
      summary = %{project: p, planned_end: nil, progress_pct: 0}

      assert CalendarDisplay.events([summary], [], [], nil, @today) == []
    end

    test "completed project spans start -> completion" do
      p =
        project(%{
          uuid: "fin",
          name: "Fin",
          started_at: ~U[2026-06-02 09:00:00Z],
          completed_at: ~U[2026-06-09 12:00:00Z]
        })

      [e] = CalendarDisplay.events([], [p], [], nil, @today)

      assert e.start == ~D[2026-06-02]
      assert e.end == ~D[2026-06-10]
    end

    test "scheduled project is a one-day marker at the scheduled start" do
      p = project(%{uuid: "soon", name: "Soon", scheduled_start_date: ~U[2026-06-25 09:00:00Z]})

      [e] = CalendarDisplay.events([], [], [p], nil, @today)

      assert e.start == ~D[2026-06-25]
      assert e.end == ~D[2026-06-26]
    end

    test "places bars on the viewer-local day per the timezone offset" do
      # 22:30 UTC on the 10th is already the 11th at UTC+3.
      p = project(%{uuid: "tz", name: "TZ", started_at: ~U[2026-06-10 22:30:00Z]})
      summary = %{project: p, planned_end: nil, progress_pct: 0}

      [utc] = CalendarDisplay.events([summary], [], [], nil, ~D[2026-06-15], "0")
      assert utc.start == ~D[2026-06-10]

      [local] = CalendarDisplay.events([summary], [], [], nil, ~D[2026-06-15], "3")
      assert local.start == ~D[2026-06-11]
    end

    test "merges all three groups and keeps ids unique" do
      run = %{
        project: project(%{uuid: "a", name: "A", started_at: ~U[2026-06-10 09:00:00Z]}),
        planned_end: ~U[2026-06-20 17:00:00Z],
        progress_pct: 50
      }

      done =
        project(%{
          uuid: "b",
          name: "B",
          started_at: ~U[2026-06-01 09:00:00Z],
          completed_at: ~U[2026-06-05 09:00:00Z]
        })

      soon = project(%{uuid: "c", name: "C", scheduled_start_date: ~U[2026-06-28 09:00:00Z]})

      events = CalendarDisplay.events([run], [done], [soon], nil, @today)
      assert events |> Enum.map(& &1.id) |> Enum.sort() == ["a", "b", "c"]
    end
  end

  describe "per-project color" do
    test "every event gets a palette bg + a readable text color" do
      summaries =
        for i <- 1..5 do
          %{
            project:
              project(%{uuid: "p#{i}", name: "P#{i}", started_at: ~U[2026-06-10 09:00:00Z]}),
            planned_end: ~U[2026-06-20 17:00:00Z],
            progress_pct: 10
          }
        end

      for e <- CalendarDisplay.events(summaries, [], [], nil, @today) do
        assert e.color in @palette_bgs
        assert e.text_color in @palette_texts
      end
    end

    test "color_for/1 is stable per id and drawn from the palette" do
      {bg, text} = CalendarDisplay.color_for("same-id")
      assert bg in @palette_bgs
      assert text in @palette_texts
      assert {bg, text} == CalendarDisplay.color_for("same-id")
    end

    test "a project's bar color matches color_for/1 for its id" do
      p = project(%{uuid: "colorcheck", name: "C", started_at: ~U[2026-06-10 09:00:00Z]})

      [e] =
        CalendarDisplay.events(
          [%{project: p, planned_end: nil, progress_pct: 0}],
          [],
          [],
          nil,
          @today
        )

      {bg, text} = CalendarDisplay.color_for("colorcheck")
      assert e.color == bg
      assert e.text_color == text
    end
  end

  describe "overdue highlight" do
    # The blink is limited to the overdue stretch via extra.highlight, so the red
    # length shows how late. Gated on the caller's `:late` tag (same tier logic
    # as the card "late" badge) AND a planned end in the past.
    test "a late summary highlights the overdue stretch (planned_end+1 .. today)" do
      p = project(%{uuid: "late", name: "Late", started_at: ~U[2026-06-01 09:00:00Z]})
      summary = %{project: p, planned_end: ~U[2026-06-05 17:00:00Z], progress_pct: 30, late: true}

      [e] = CalendarDisplay.events([summary], [], [], nil, @today)
      # from = planned_end+1, to = today+1 (exclusive) bounds the overdue stretch.
      assert e.extra.highlight == %{from: ~D[2026-06-06], to: ~D[2026-06-16], class: "pk-overdue"}
    end

    test "a late summary whose planned end is still in the future has no highlight" do
      p = project(%{uuid: "fut", name: "Fut", started_at: ~U[2026-06-10 09:00:00Z]})
      summary = %{project: p, planned_end: ~U[2026-06-25 17:00:00Z], progress_pct: 30, late: true}

      [e] = CalendarDisplay.events([summary], [], [], nil, @today)
      refute Map.has_key?(e.extra, :highlight)
    end

    test "a non-late summary has no highlight" do
      p = project(%{uuid: "ok", name: "OK", started_at: ~U[2026-06-01 09:00:00Z]})

      summary = %{
        project: p,
        planned_end: ~U[2026-06-05 17:00:00Z],
        progress_pct: 30,
        late: false
      }

      [e] = CalendarDisplay.events([summary], [], [], nil, @today)
      refute Map.has_key?(e.extra, :highlight)
    end

    test "completed and scheduled projects have no highlight" do
      done =
        project(%{
          uuid: "c",
          name: "C",
          started_at: ~U[2026-06-01 09:00:00Z],
          completed_at: ~U[2026-06-05 09:00:00Z]
        })

      soon = project(%{uuid: "s", name: "S", scheduled_start_date: ~U[2026-06-28 09:00:00Z]})

      events = CalendarDisplay.events([], [done], [soon], nil, @today)
      assert Enum.all?(events, &(not Map.has_key?(&1.extra, :highlight)))
    end
  end

  describe "slot grouping" do
    test "late projects get slot_priority 0 (top), everything else 1" do
      late = %{
        project: project(%{uuid: "l", name: "L", started_at: ~U[2026-06-01 09:00:00Z]}),
        planned_end: ~U[2026-06-05 17:00:00Z],
        progress_pct: 30,
        late: true
      }

      ontime = %{
        project: project(%{uuid: "o", name: "O", started_at: ~U[2026-06-10 09:00:00Z]}),
        planned_end: ~U[2026-06-25 17:00:00Z],
        progress_pct: 30,
        late: false
      }

      done =
        project(%{
          uuid: "d",
          name: "D",
          started_at: ~U[2026-06-01 09:00:00Z],
          completed_at: ~U[2026-06-05 09:00:00Z]
        })

      soon = project(%{uuid: "s", name: "S", scheduled_start_date: ~U[2026-06-28 09:00:00Z]})

      events = CalendarDisplay.events([late, ontime], [done], [soon], nil, @today)
      priority = Map.new(events, &{&1.id, &1.extra.slot_priority})

      assert priority["l"] == 0
      assert priority["o"] == 1
      assert priority["d"] == 1
      assert priority["s"] == 1
    end
  end

  describe "overdue animation CSS" do
    @wave %{
      pattern: "stripes",
      mode: "wave",
      speed: 7.0,
      brightness_min: 0.78,
      brightness_max: 1.18,
      wave_step: 0.16
    }

    test "every mode paints inverse-colour 45° stripes (difference blend)" do
      for mode <- ~w(wave flash off) do
        css = CalendarDisplay.animation_css(%{@wave | mode: mode})
        assert css =~ ".pk-overdue::after"
        assert css =~ "repeating-linear-gradient(45deg"
        assert css =~ "mix-blend-mode: difference"
      end
    end

    test "wave mode slides the stripes" do
      css = CalendarDisplay.animation_css(@wave)

      assert css =~ "@keyframes pk-overdue-stripe-slide"
      assert css =~ "animation: pk-overdue-stripe-slide 7s linear infinite"
      assert css =~ "calc(var(--pk-bg-x, 0) + 56.57px)"
    end

    test "flash mode pulses the striped overlay" do
      css = CalendarDisplay.animation_css(%{@wave | mode: "flash"})

      assert css =~ "@keyframes pk-overdue-stripe-flash"
      assert css =~ "animation: pk-overdue-stripe-flash 7s ease-in-out infinite"
      # opacity pulse uses the (clamped) brightness range
      assert css =~ "opacity: 0.78"
    end

    test "off mode is static stripes with no animation" do
      css = CalendarDisplay.animation_css(%{@wave | mode: "off"})

      refute css =~ "@keyframes"
      # only the reduced-motion safety rule mentions animation
      refute css =~ "animation: pk-overdue"
      assert css =~ "repeating-linear-gradient(45deg"
    end

    test "integers render without a trailing .0 (valid CSS)" do
      css = CalendarDisplay.animation_css(%{@wave | speed: 10.0})
      assert css =~ "pk-overdue-stripe-slide 10s"
      refute css =~ "10.0s"
    end

    test "solid pattern fills with the inverse colour (filter: invert), no stripes" do
      css = CalendarDisplay.animation_css(%{@wave | pattern: "solid"})

      assert css =~ "filter: invert(1)"
      assert css =~ "@keyframes pk-overdue-wave"
      assert css =~ "animation-delay: calc(var(--pk-hl-day, 0) * -0.16s)"
      refute css =~ "repeating-linear-gradient"
    end

    test "solid + off is a static inverse fill, no animation" do
      css = CalendarDisplay.animation_css(%{@wave | pattern: "solid", mode: "off"})

      assert css =~ "filter: invert(1) brightness("
      refute css =~ "@keyframes"
      refute css =~ "repeating-linear-gradient"
    end

    test "animation_style/1 wraps the CSS in a <style> tag" do
      style = CalendarDisplay.animation_style(@wave)

      assert String.starts_with?(style, "<style>")
      assert String.ends_with?(style, "</style>")
      assert style =~ "repeating-linear-gradient"
      # labels keep per-bar black/white but get an opposite-colour halo for
      # legibility over the stripes (not the colourful difference blend)
      refute style =~ "mix-blend-mode: difference; }\n.cal-multiday-bar span"
      assert style =~ ".cal-multiday-bar.text-white span { text-shadow:"
      assert style =~ ".cal-multiday-bar.text-neutral-900 span { text-shadow:"
    end

    test "anim_modes/0, anim_patterns/0 and anim_range/1 back the settings form" do
      assert CalendarDisplay.anim_modes() == ~w(wave flash off)
      assert CalendarDisplay.anim_patterns() == ~w(stripes solid)
      assert {lo, hi} = CalendarDisplay.anim_range("speed")
      assert lo < hi
    end
  end
end
