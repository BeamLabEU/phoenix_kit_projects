defmodule PhoenixKitProjects.CalendarDisplayTest do
  use ExUnit.Case, async: true

  alias PhoenixKitProjects.CalendarDisplay
  alias PhoenixKitProjects.Schemas.{Assignment, Project}
  alias PhoenixKitProjects.Schemas.Task, as: TaskSchema

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

    test "with the ring marker a late project wears the ring instead of the tail" do
      p = project(%{uuid: "late", name: "Late", started_at: ~U[2026-06-01 09:00:00Z]})
      summary = %{project: p, planned_end: ~U[2026-06-05 17:00:00Z], progress_pct: 30, late: true}

      [e] =
        CalendarDisplay.events([summary], [], [], nil, @today, "0", late_marker: "ring")

      assert e.class =~ "ring-error"
      refute Map.has_key?(e.extra, :highlight)
      # Late bars keep the top-slot grouping either way.
      assert e.extra.slot_priority == 0

      # On-time bars stay unmarked under the ring marker.
      ok = %{
        project: project(%{uuid: "ok", name: "OK", started_at: ~U[2026-06-01 09:00:00Z]}),
        planned_end: ~U[2026-06-25 17:00:00Z],
        progress_pct: 30,
        late: false
      }

      [oe] = CalendarDisplay.events([ok], [], [], nil, @today, "0", late_marker: "ring")
      refute oe.class
    end

    test "with the marker off a late project draws nothing but keeps its slot grouping" do
      p = project(%{uuid: "late", name: "Late", started_at: ~U[2026-06-01 09:00:00Z]})
      summary = %{project: p, planned_end: ~U[2026-06-05 17:00:00Z], progress_pct: 30, late: true}

      [e] = CalendarDisplay.events([summary], [], [], nil, @today, "0", late_marker: "none")

      refute e.class
      refute Map.has_key?(e.extra, :highlight)
      assert e.extra.slot_priority == 0
    end

    test "with the marker off a late task keeps late meta but no class" do
      pr = project(%{name: "P"})
      todo = task_item(pr, %{status: "todo"})
      s = span(~N[2026-06-10 08:00:00], ~N[2026-06-10 10:00:00])
      now = ~N[2026-06-12 09:00:00]

      {[e], meta} =
        CalendarDisplay.task_events([{todo, s}], nil, "0",
          now: now,
          late_class: CalendarDisplay.late_marker_class(%{late_marker: "none"})
        )

      refute e.class
      assert meta[e.id].late
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

    test "wave mode slides the stripes horizontally — visibly, with valid fallbacks" do
      css = CalendarDisplay.animation_css(@wave)

      assert css =~ "@keyframes pk-overdue-stripe-slide"
      assert css =~ "animation: pk-overdue-stripe-slide 7s linear infinite"
      # Four whole 56.57px periods per cycle — one period per cycle crawled
      # imperceptibly at the default speed.
      assert css =~ "calc(var(--pk-bg-x, 0px) + 226.28px)"
      # Unitless 0 inside calc() is invalid CSS and killed the keyframe
      # wherever the alignment hook hadn't set the vars.
      refute css =~ "var(--pk-bg-x, 0)"
      refute css =~ "var(--pk-bg-y, 0)"
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

    test "the configured stripe opacity drives the overlay (default 1)" do
      # Maps without :opacity (older configs) fall back to fully opaque.
      assert CalendarDisplay.animation_css(@wave) =~ "opacity: 1;"

      css = CalendarDisplay.animation_css(Map.put(@wave, :opacity, 0.4))
      assert css =~ "opacity: 0.4;"

      # Flash scales its brightness pulse around the configured opacity —
      # low = 0.5 × 0.78, peak = 0.5 × 1.18 — rounded to valid CSS floats.
      flash = CalendarDisplay.animation_css(%{@wave | mode: "flash"} |> Map.put(:opacity, 0.5))
      assert flash =~ "opacity: 0.39;"
      assert flash =~ "opacity: 0.59;"
    end

    test "late_marker_class/1 maps ring/pattern/none (pattern is the default)" do
      assert CalendarDisplay.late_marker_class(%{late_marker: "ring"}) =~ "ring-error"
      assert CalendarDisplay.late_marker_class(%{late_marker: "pattern"}) == "pk-overdue"
      # Off: no class at all — the late DATA (meta, filters) is unaffected.
      assert CalendarDisplay.late_marker_class(%{late_marker: "none"}) == nil
      # Missing/unknown follows the default: synced with the projects look.
      assert CalendarDisplay.late_marker_class(%{}) == "pk-overdue"
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

  describe "task_events/3 — Tasks mode" do
    defp task_item(project, attrs) do
      assignment =
        struct(
          Assignment,
          Map.merge(
            %{
              uuid: "a-#{System.unique_integer([:positive])}",
              status: "todo",
              translations: %{},
              task:
                struct(TaskSchema, %{
                  uuid: "t-#{System.unique_integer([:positive])}",
                  title: "Task",
                  translations: %{}
                })
            },
            attrs
          )
        )

      %{uuid: assignment.uuid, assignment: assignment, project: project, parent_uuid: nil}
    end

    defp span(s, e), do: %{start: s, end: e}

    test "maps a span to an all-day event with the project's identity color" do
      p = project(%{uuid: "proj-1", name: "Cleaning"})

      item =
        task_item(p, %{task: struct(TaskSchema, %{title: "Scrub floors", translations: %{}})})

      {[e], meta} =
        CalendarDisplay.task_events(
          [{item, span(~N[2026-06-10 09:00:00], ~N[2026-06-12 17:00:00])}],
          nil
        )

      assert e.title == "Scrub floors"
      assert e.all_day
      assert e.start == ~D[2026-06-10]
      # Ends 17:00 on the 12th -> occupies the 12th -> exclusive end the 13th.
      assert e.end == ~D[2026-06-13]
      assert {e.color, e.text_color} == CalendarDisplay.color_for("proj-1")

      assert %{project_uuid: "proj-1", project_name: "Cleaning", status: "todo"} =
               meta[e.id]
    end

    test "a span ending exactly at midnight does not occupy that day" do
      p = project(%{name: "P"})
      item = task_item(p, %{})

      {[e], _meta} =
        CalendarDisplay.task_events(
          [{item, span(~N[2026-06-10 08:00:00], ~N[2026-06-12 00:00:00])}],
          nil
        )

      assert e.end == ~D[2026-06-12]
    end

    test "a zero-length span still shows as a one-day chip" do
      p = project(%{name: "P"})
      item = task_item(p, %{})

      {[e], _meta} =
        CalendarDisplay.task_events(
          [{item, span(~N[2026-06-10 08:00:00], ~N[2026-06-10 08:00:00])}],
          nil
        )

      assert e.start == ~D[2026-06-10]
      assert e.end == ~D[2026-06-11]
    end

    test "shifts spans to the viewer's timezone offset" do
      p = project(%{name: "P"})
      item = task_item(p, %{})

      # 23:00 UTC on the 10th is already the 11th at +3.
      {[e], _meta} =
        CalendarDisplay.task_events(
          [{item, span(~N[2026-06-10 23:00:00], ~N[2026-06-10 23:30:00])}],
          nil,
          "+3"
        )

      assert e.start == ~D[2026-06-11]
      assert e.end == ~D[2026-06-12]
    end

    test "tasks of one project share its color; different projects differ in id" do
      p1 = project(%{uuid: "p-a", name: "A"})
      p2 = project(%{uuid: "p-b", name: "B"})
      s = span(~N[2026-06-10 08:00:00], ~N[2026-06-10 10:00:00])

      {[e1, e2, e3], _meta} =
        CalendarDisplay.task_events(
          [{task_item(p1, %{}), s}, {task_item(p1, %{}), s}, {task_item(p2, %{}), s}],
          nil
        )

      assert e1.color == e2.color
      {p2_bg, _} = CalendarDisplay.color_for("p-b")
      assert e3.color == p2_bg
    end

    test "flags a not-done task past its span as late (ring class + meta)" do
      p = project(%{name: "P"})
      todo = task_item(p, %{status: "todo"})
      done = task_item(p, %{status: "done"})
      s = span(~N[2026-06-10 08:00:00], ~N[2026-06-10 10:00:00])
      now = ~N[2026-06-12 09:00:00]

      {[late_e, done_e], meta} =
        CalendarDisplay.task_events([{todo, s}, {done, s}], nil, "0", now: now)

      assert late_e.class =~ "ring-error"
      assert meta[late_e.id].late

      refute done_e.class
      refute meta[done_e.id].late
    end

    test "the :late_class opt swaps the late marker (settings-driven pattern)" do
      p = project(%{name: "P"})
      todo = task_item(p, %{status: "todo"})
      s = span(~N[2026-06-10 08:00:00], ~N[2026-06-10 10:00:00])
      now = ~N[2026-06-12 09:00:00]

      {[e], _meta} =
        CalendarDisplay.task_events([{todo, s}], nil, "0", now: now, late_class: "pk-overdue")

      assert e.class == "pk-overdue"
    end

    test "a task still inside its span is not late" do
      p = project(%{name: "P"})
      item = task_item(p, %{status: "in_progress"})
      s = span(~N[2026-06-10 08:00:00], ~N[2026-06-14 10:00:00])

      {[e], meta} =
        CalendarDisplay.task_events([{item, s}], nil, "0", now: ~N[2026-06-12 09:00:00])

      refute e.class
      refute meta[e.id].late
    end

    test "falls back to the untitled label when the assignment has no resolvable title" do
      # A sub-project link whose child_project isn't loaded resolves no label;
      # the mapper must degrade to "(untitled task)" rather than crash. (The
      # Overview filters sub-project containers out, but the mapper is pure and
      # shouldn't depend on that.)
      p = project(%{name: "P"})
      item = task_item(p, %{task: nil, child_project_uuid: "cp-1", child_project: nil})

      {[e], _meta} =
        CalendarDisplay.task_events(
          [{item, span(~N[2026-06-10 08:00:00], ~N[2026-06-10 10:00:00])}],
          nil
        )

      assert e.title =~ "untitled"
    end
  end

  describe "shared calendar primitives (both calendars consume these)" do
    test "events_on/2 keeps only spans covering the date, soonest-starting first" do
      mk = fn id, s, e -> PhoenixLiveCalendar.event(id, s, end: e, title: id, all_day: true) end

      spanning = mk.("spanning", ~D[2026-06-09], ~D[2026-06-12])
      same_day = mk.("same-day", ~D[2026-06-10], ~D[2026-06-11])
      before = mk.("before", ~D[2026-06-08], ~D[2026-06-10])
      after_ = mk.("after", ~D[2026-06-11], ~D[2026-06-12])

      rows = CalendarDisplay.events_on([after_, same_day, before, spanning], ~D[2026-06-10])

      # `end` is exclusive: "before" ends the 10th so it does NOT cover it.
      assert Enum.map(rows, & &1.id) == ["spanning", "same-day"]
    end

    test "task_late?/3 flags not-done past-end, and nothing without a now" do
      a_todo = struct(Assignment, %{status: "todo"})
      a_done = struct(Assignment, %{status: "done"})
      span = %{start: ~N[2026-06-01 08:00:00], end: ~N[2026-06-02 08:00:00]}

      assert CalendarDisplay.task_late?(a_todo, span, ~N[2026-06-03 00:00:00])
      refute CalendarDisplay.task_late?(a_done, span, ~N[2026-06-03 00:00:00])
      refute CalendarDisplay.task_late?(a_todo, span, ~N[2026-06-01 12:00:00])
      refute CalendarDisplay.task_late?(a_todo, span, nil)
    end

    test "exclusive_end_date/3 in the UTC frame: midnight ends don't occupy the day" do
      # Ends 17:00 on the 12th -> occupies the 12th -> exclusive end the 13th.
      assert CalendarDisplay.exclusive_end_date(~D[2026-06-10], ~N[2026-06-12 17:00:00]) ==
               ~D[2026-06-13]

      # Ends midnight on the 12th -> the 11th is the last occupied day.
      assert CalendarDisplay.exclusive_end_date(~D[2026-06-10], ~N[2026-06-12 00:00:00]) ==
               ~D[2026-06-12]

      # Zero-length span still floors to a one-day chip.
      assert CalendarDisplay.exclusive_end_date(~D[2026-06-10], ~N[2026-06-10 00:00:00]) ==
               ~D[2026-06-11]
    end

    test "exclusive_end_date/3 with an offset evaluates midnight in the viewer's frame" do
      # 21:00 UTC on the 11th is midnight on the 12th in UTC+3 — the local
      # frame frees the 12th, so the exclusive end is the 12th.
      assert CalendarDisplay.exclusive_end_date(~D[2026-06-10], ~N[2026-06-11 21:00:00], "+3") ==
               ~D[2026-06-12]

      # One second later occupies the local 12th.
      assert CalendarDisplay.exclusive_end_date(~D[2026-06-10], ~N[2026-06-11 21:00:01], "+3") ==
               ~D[2026-06-13]
    end

    test "the per-day caps are positive and chips cap tighter than bars" do
      assert CalendarDisplay.max_events() >= 1
      assert CalendarDisplay.max_multiday() >= CalendarDisplay.max_events()
    end
  end
end
