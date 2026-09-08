# Schedule math and completion

How durations become dates, how planned vs projected end are computed, when
a project auto-completes, and the planned per-task work-hours model.

Rules for this live in [AGENTS.md](../../AGENTS.md) → Feature notes.

## Schedule math

- Durations normalized to hours via `Task.to_hours/3`. Weekdays-only mode uses
  8h/day, 40h/week; calendar mode uses 24h/day, 168h/week.
- Per-task `counts_weekends` overrides the project-level setting.
- `calculate_schedule/2` in `ProjectShowLive` computes planned vs projected end
  dates:
  - **Planned** = `started_at + sum_of_task_hours` (fixed)
  - **Projected** = `now + remaining_hours / velocity` where velocity =
    `done_hours / max(elapsed, 1h)`
- Weekend work counts toward velocity even in weekdays-only projects
  (calendar_hours used when progress > plan).
- `progress_pct` on an assignment contributes proportionally to "done hours"
  only when `track_progress` is enabled.

Duration units: `minutes`, `hours`, `days`, `weeks`, `fortnights`, `months`,
`years` — all defined on `Schemas.Task`, which also hosts `to_hours/3` with
`counts_weekends` awareness.

The Timeline and Calendar views both render the SAME schedule through the
shared `PhoenixKitProjects.ScheduleLayout` (tree flatten +
`PhoenixLiveGantt.Layout.sequential/2` walk, hour-precise, weekday/weekend
aware), so they can never disagree about a task's dates.

## Completion auto-detection

After every assignment status/progress/removal change,
`Projects.recompute_project_completion/1` checks whether all assignments are
`done` and sets `project.completed_at` accordingly. Reopening a task clears it.
Logs `projects.project_completed` / `projects.project_reopened`.

## Planned: per-task work-hours toggle + per-user work schedule

Deferred enhancement to `Project.planned_end_for/2`'s weekday-only
model. The model treats every weekday-only duration as work hours at a
3:1 calendar:work ratio (24 calendar hours = 8 work hours). This is fine
for multi-day tasks ("5 days = 5 workdays = Mon→Fri") but overshoots for
short tasks: a 2-hour minute/hour-unit task started Sat evening doesn't
really need to "wait for Monday morning" before it can be considered
late — but the proportional model says it does.

### Design

A per-task **`count_as_work_hours`** boolean decides which clock the
task's duration ticks against:

- **`false` (calendar)** — duration consumes raw calendar time,
  ignoring weekends/nights. New tasks default to `false` when the
  form unit is `minutes` or `hours`.
- **`true` (work hours)** — duration only ticks during work windows.
  New tasks default to `true` when the form unit is `days` or longer.

When the toggle is off, `Task.to_hours/3` keeps its current behaviour. When it
is on and the assignee has a non-empty `work_schedule`, planned-end math walks
that week's windows. When it is on but the assignee's `work_schedule` is empty,
math falls back to the existing 5×8 approximation in `work_hours_elapsed/2` —
a Mon–Fri 09:00–17:00 windowed helper does not exist yet and is part of this
same follow-up work.

The **work schedule** lives on `PhoenixKitStaff.Schemas.Person` as a
JSONB column `work_schedule` keyed by weekday. Shape:

```json
{
  "monday":    {"start": "09:00", "end": "17:00"},
  "tuesday":   {"start": "09:00", "end": "17:00"},
  "wednesday": {"start": "09:00", "end": "17:00"},
  "thursday":  {"start": "09:00", "end": "17:00"},
  "friday":    {"start": "09:00", "end": "17:00"},
  "saturday":  null,
  "sunday":    null
}
```

When a `count_as_work_hours: true` task has an `assigned_person_uuid`,
its planned-end calc walks calendar time consuming budget only inside
that person's windows. Fallbacks, in order: assignee's
`work_schedule` → built-in `Mon-Fri 09:00–17:00` default. Tasks
assigned to a team/department (not a single person) use the default;
multi-assignee schedule resolution is out of scope for v1.

### Why this lives on Person, not Task

The schedule is a fact about the human, not the work — parallel to
the existing `work_location` / `work_phone` fields. The staff
module's "NOT a full HRIS" caveat in `phoenix_kit_staff/AGENTS.md`
forbids PTO ledgers and payroll; static work hours are closer to
existing per-person profile data and were judged acceptable.

### Scope (when this lands)

- **Migration** (in core `phoenix_kit`):
  - `count_as_work_hours BOOLEAN NOT NULL DEFAULT false` on
    `phoenix_kit_project_tasks` and `phoenix_kit_project_assignments`
  - `work_schedule JSONB NOT NULL DEFAULT '{}'` on
    `phoenix_kit_staff_people`
- **Schemas**: add the field to `Task`, `Assignment`, `Person`.
- **Math** — refactor `planned_end_for/2` and `work_hours_elapsed/2`
  to walk per-task. The current single-sum-of-hours design must be
  replaced with a sequential walk: iterate tasks in `position` order,
  extending the running cursor by each task's calendar OR work-window
  budget. `Projects.project_summaries/1` needs to return enough
  per-task data (or a precomputed `planned_end`) instead of a single
  scalar `total_hours`.
- **UI**:
  - `task_form_live.ex` / `assignment_form_live.ex` — checkbox
    "Count as work hours" visible when unit is minutes/hours; hidden
    (always `true`) for days+.
  - `person_form_live.ex` (in staff) — 7-row schedule editor (Mon–Sun
    each with start + end time inputs; empty pair = day off).
- **No backfill** — pre-launch, so existing rows take the column
  defaults. New rows inherit the unit-driven default at create time.

The staff side ships as `Person.work_schedule` (see
`phoenix_kit_staff/AGENTS.md` → "Planned: `Person.work_schedule` (JSONB)"
for the column shape and fallback rules). The two changes ship together;
neither side has landed.

### Out of scope for v1

- Multiple assignees per task with different schedules — uses default.
- Lunch breaks / split windows per day — single window per day.
- Holidays / time-off / PTO — explicitly forbidden by the staff module.
- Per-project schedule override — schedule is always per-assignee or
  the built-in default, never per-project.

### Origin

Surfaced while fixing `planned_end_for/2`'s weekend handling (the wider
audit that produced the "calendar past planned_end forces expected_pct =
100" fix). Resolves the impedance mismatch where the proportional model
correctly handles "5 days = Mon→Fri" but overstates "52 minutes started
Saturday evening" as not-yet-due until Monday morning.
