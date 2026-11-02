defmodule PhoenixKitProjects.Repeats do
  @moduledoc """
  Tasks that repeat (the boss, via Max, 2026-10-31: "checking in on the
  client … you have to do it every week"; low priority, and no clutter).

  A task's `repeat_rule` (chain V28) says how it comes back:
  `%{"every" => n, "unit" => "day" | "week" | "month"}`, nil for a task
  that does not. The panel (2 of 3 seats) chose one task per occurrence:
  when a repeating task is done, it **stays done** with its comments,
  files and logged time, and ONE new task is made for the next date —
  the same title, description, assignee and estimate, its subtasks again
  and not done, the deadline moved on by the rule from the old deadline
  (from when it was done, for a task with none). The rule moves to the
  new task, so reopening and finishing the old one again makes no second.

  A repeating SUBTASK's next occurrence goes under its parent while the
  parent is open; under a done parent it would reopen it (the completion
  rules), so it goes under the nearest open ancestor instead, right after
  the done branch (`place_for/1`). Everything this says — the
  broadcasts, the audit row — goes out after the occurrence's transaction
  has committed.

  `next/1` is called with the status changes every write announces (the
  same ones `Handoffs` reacts to). Nothing here raises into the writer: a
  status change is never lost to a repeat.
  """

  use Gettext, backend: PhoenixKitProjects.Gettext

  import Ecto.Query

  require Logger

  alias PhoenixKit.RepoHelper
  alias PhoenixKitProjects.{Activity, Outline, Projects}
  alias PhoenixKitProjects.Schemas.{Assignment, Task}

  @units ~w(day week month)
  @max_every 365

  defp repo, do: RepoHelper.repo()

  # ── The rule ───────────────────────────────────────────────────────

  @doc "The units a rule counts in."
  @spec units() :: [String.t()]
  def units, do: @units

  @doc """
  A rule as stored: `%{"every" => 1..365, "unit" => unit}`, or nil for
  anything else (no rule, a bad number, an unknown unit).

  A month rule may also carry `"day"` (1..31): the day of the month its
  deadlines keep, the first deadline's. Without it a month that is
  shorter clamps the date once and every later month inherits the clamp
  (31 Jan → 28 Feb → 28 Mar); with it each month takes the day again,
  clamped to that month alone (31 Jan → 28 Feb → 31 Mar). A day that is
  not one is dropped, never the rule.
  """
  @spec normalize(term()) :: map() | nil
  def normalize(%{} = rule) do
    with unit when unit in @units <- to_string(rule["unit"] || rule[:unit] || ""),
         {n, ""} when n in 1..@max_every <-
           Integer.parse(to_string(rule["every"] || rule[:every] || "")) do
      put_day(%{"every" => n, "unit" => unit}, rule["day"] || rule[:day])
    else
      _ -> nil
    end
  end

  def normalize(_), do: nil

  defp put_day(%{"unit" => "month"} = rule, day) when is_integer(day) and day in 1..31,
    do: Map.put(rule, "day", day)

  defp put_day(rule, _day), do: rule

  @doc """
  `rule` as the next occurrence carries it: a month rule keeps the day of
  the month it started on — its own `"day"`, else the day of `base` (the
  deadline it was moved on from).
  """
  @spec anchored(map(), DateTime.t()) :: map()
  def anchored(rule, %DateTime{} = base) do
    case normalize(rule) do
      %{"unit" => "month", "day" => _} = rule -> rule
      %{"unit" => "month"} = rule -> Map.put(rule, "day", base.day)
      rule -> rule
    end
  end

  @doc """
  The anchor day of `stored` carried over to `posted` when they are the
  same rule otherwise — a form posts the rule without it, and saving the
  task must not reset the day to the (possibly clamped) deadline it shows.
  """
  @spec keep_day(map() | nil, map() | nil) :: map() | nil
  def keep_day(%{"every" => n, "unit" => "month"} = posted, stored)
      when not is_map_key(posted, "day") do
    case normalize(stored) do
      %{"every" => ^n, "unit" => "month", "day" => day} -> Map.put(posted, "day", day)
      _ -> posted
    end
  end

  def keep_day(posted, _stored), do: posted

  @doc """
  The rule the task form's one control posts: `"repeat"` is `"none"`,
  `"week"`, `"2weeks"`, `"month"` or `"custom"` (then `"repeat_every"` and
  `"repeat_unit"`). Puts `"repeat_rule"` in `attrs` (nil: does not
  repeat) and takes the control's own keys out; attrs without the control
  pass unchanged.
  """
  @spec from_params(map()) :: map()
  def from_params(%{"repeat" => choice} = attrs) do
    rule =
      case choice do
        "week" -> %{"every" => 1, "unit" => "week"}
        "2weeks" -> %{"every" => 2, "unit" => "week"}
        "month" -> %{"every" => 1, "unit" => "month"}
        "custom" -> custom(attrs)
        _ -> nil
      end

    attrs
    |> Map.drop(["repeat", "repeat_every", "repeat_unit"])
    |> Map.put("repeat_rule", rule)
  end

  def from_params(attrs), do: attrs

  # "Every…" just picked shows "1 week" before its fields were posted, so
  # that is the rule. A number or unit it cannot read stays as posted: the
  # changeset refuses it, rather than the task silently ceasing to repeat.
  defp custom(attrs) do
    every = Map.get(attrs, "repeat_every", 1)
    unit = Map.get(attrs, "repeat_unit", "week")
    raw = %{"every" => every, "unit" => unit}
    normalize(raw) || raw
  end

  @doc "Which of the control's choices a rule is."
  @spec choice(map() | nil) :: String.t()
  def choice(%{"every" => 1, "unit" => "week"}), do: "week"
  def choice(%{"every" => 2, "unit" => "week"}), do: "2weeks"
  def choice(%{"every" => 1, "unit" => "month"}), do: "month"
  def choice(%{"every" => _, "unit" => _}), do: "custom"
  def choice(_), do: "none"

  @doc "The rule in words — the ↻'s tooltip and the control's summary."
  @spec label(map() | nil) :: String.t() | nil
  def label(rule) do
    case normalize(rule) do
      %{"every" => 1, "unit" => "day"} ->
        pgettext("repeat", "Every day")

      %{"every" => 1, "unit" => "week"} ->
        pgettext("repeat", "Every week")

      %{"every" => 1, "unit" => "month"} ->
        pgettext("repeat", "Every month")

      %{"every" => n, "unit" => "day"} ->
        pngettext("repeat", "Every %{count} day", "Every %{count} days", n)

      %{"every" => n, "unit" => "week"} ->
        pngettext("repeat", "Every %{count} week", "Every %{count} weeks", n)

      %{"every" => n, "unit" => "month"} ->
        pngettext("repeat", "Every %{count} month", "Every %{count} months", n)

      nil ->
        nil
    end
  end

  @doc """
  `at` moved on by `rule` (whole days, weeks or calendar months). A month
  rule with a `"day"` lands on that day of the month, or the month's last
  day when it has fewer.
  """
  @spec shift(DateTime.t(), map()) :: DateTime.t()
  def shift(%DateTime{} = at, rule) do
    case normalize(rule) do
      %{"every" => n, "unit" => "month", "day" => day} ->
        shifted = DateTime.shift(at, month: n)
        target = min(day, Calendar.ISO.days_in_month(shifted.year, shifted.month))
        DateTime.shift(shifted, day: target - shifted.day)

      %{"every" => n, "unit" => unit} ->
        DateTime.shift(at, [{String.to_existing_atom(unit), n}])
    end
  end

  @doc "A `Date` moved on by `rule`."
  @spec shift_date(Date.t() | nil, map()) :: Date.t() | nil
  def shift_date(nil, _rule), do: nil

  def shift_date(%Date{} = d, rule) do
    %{"every" => n, "unit" => unit} = normalize(rule)
    Date.shift(d, [{String.to_existing_atom(unit), n}])
  end

  # ── The next occurrence ────────────────────────────────────────────

  @doc """
  For each change that finished a repeating task (`to: "done"`), makes its
  next occurrence. Returns the new tasks.

  `actor_uuid` is whoever's write finished the task: the new task is
  recorded as theirs (`created_by_uuid`) and its `projects.assignment_created`
  row names them, with `metadata.repeat_of` the finished task.
  """
  @spec next([map()], binary() | nil) :: [Assignment.t()]
  def next(changes, actor_uuid \\ nil) when is_list(changes) do
    for %{uuid: uuid, to: "done", from: from} <- changes,
        from != "done",
        %Assignment{repeat_rule: %{}} = done <- [repo().get(Assignment, uuid)],
        %{} = rule <- [normalize(done.repeat_rule)],
        {:ok, made} <- [occur(done, rule, actor_uuid)] do
      made
    end
  rescue
    error ->
      Logger.warning("[Projects] repeat failed: #{inspect(error.__struct__)}")
      []
  catch
    :exit, _ -> []
  end

  defp occur(%Assignment{} = done, rule, actor_uuid) do
    # Under the project's lock (`Outline.with_project_lock/2`), so what the
    # completion rules change while the occurrence is placed is announced
    # once it has committed — and this module's own broadcasts and audit
    # row come after the commit too (`announce/3`), never before.
    result =
      Outline.with_project_lock(done.project_uuid, fn _project ->
        # Taken off the done one first, under its row lock: two writes
        # announcing the same finish make one next task, not two.
        {count, _} =
          from(a in Assignment, where: a.uuid == ^done.uuid and not is_nil(a.repeat_rule))
          |> repo().update_all(set: [repeat_rule: nil])

        if count == 1, do: copy!(done, rule, place_for(done)), else: repo().rollback(:taken)
      end)

    case result do
      {:ok, made} -> announce(made, done, actor_uuid)
      # Another write took the rule first: its occurrence is the one.
      {:error, :taken} -> {:error, :taken}
      {:error, reason} -> failed(done, reason, actor_uuid)
    end
  end

  # Said, and recorded as a create (a failure as a failed one), so the
  # finished task's History shows where the next one came from.
  defp failed(%Assignment{} = done, reason, actor_uuid) do
    Logger.warning(
      "[Projects] repeat of #{done.uuid} failed: #{inspect(if is_atom(reason), do: reason, else: :changeset)}"
    )

    Activity.log_failed("projects.assignment_created",
      actor_uuid: actor_uuid,
      resource_type: "assignment",
      resource_uuid: done.uuid,
      metadata: %{"project_uuid" => done.project_uuid, "repeat_of" => done.uuid}
    )

    {:error, reason}
  end

  defp announce(%Assignment{} = made, %Assignment{} = done, actor_uuid) do
    if actor_uuid, do: Projects.stamp_assignment(made, %{created_by_uuid: actor_uuid})

    Activity.log("projects.assignment_created",
      actor_uuid: actor_uuid,
      resource_type: "assignment",
      resource_uuid: made.uuid,
      metadata: %{
        "task" => made |> repo().preload(:task) |> Assignment.label(),
        "project_uuid" => made.project_uuid,
        "repeat_of" => done.uuid,
        "auto" => true
      }
    )

    PhoenixKitProjects.PubSub.broadcast_assignment(:assignment_created, %{
      uuid: made.uuid,
      project_uuid: made.project_uuid
    })

    PhoenixKitProjects.PubSub.broadcast_assignment(:assignment_reordered, %{
      project_uuid: made.project_uuid
    })

    {:ok, made}
  end

  # The task again, not done, with the rule (only on the top one) and its
  # dates moved on; then its subtasks, the same way, under it.
  defp copy!(%Assignment{} = a, rule, place, top? \\ true) do
    base = a.deadline || a.completed_at || DateTime.utc_now()

    # The task's rule keeps the day of the month it started on, so a month
    # that clamps the date does not move every later one (`anchored/2`).
    # A subtask's deadline has its own day: moved by plain calendar months.
    rule_on = if top?, do: anchored(rule, base), else: Map.delete(rule, "day")

    attrs =
      %{
        "project_uuid" => a.project_uuid,
        "position" => Projects.next_assignment_position(a.project_uuid),
        "task_uuid" => task_for(a),
        "status" => "todo",
        "description" => a.description,
        "translations" => a.translations,
        "priority" => a.priority,
        "estimated_duration" => a.estimated_duration,
        "estimated_duration_unit" => a.estimated_duration_unit,
        "counts_weekends" => a.counts_weekends,
        # Every assignee comes back with it (V29: several).
        "assignees" => PhoenixKitProjects.AssigneeSet.keys(a),
        "start_date" => shift_date(a.start_date, rule),
        "end_date" => shift_date(a.end_date, rule),
        "start_time" => a.start_time,
        "end_time" => a.end_time,
        "deadline" => if(top? or a.deadline, do: shift(base, rule_on))
      }

    made =
      case %Assignment{}
           |> Assignment.changeset(attrs)
           |> Ecto.Changeset.put_change(:repeat_rule, if(top?, do: rule_on))
           |> repo().insert() do
        {:ok, made} -> made
        {:error, cs} -> repo().rollback(cs)
      end

    made = place!(made, place)

    a.project_uuid
    |> project_rows()
    |> Enum.filter(&(&1.parent_uuid == a.uuid and &1.review_status == "accepted"))
    |> Enum.each(&copy!(&1, rule, {made.uuid, :last}, false))

    made
  end

  # Where the next occurrence of a SUBTASK goes. Under its parent, last
  # there, while that parent is still open. A done parent (often closed by
  # this very finish — its last subtask ticked) would be reopened by the
  # completion rules the moment an open row lands under it, undoing the
  # tick; so the occurrence climbs to the nearest open ancestor instead and
  # sits right after the done branch it came from (the top level, after
  # it, when every ancestor is done). A top-level task's occurrence stays
  # at the top level, last.
  defp place_for(%Assignment{parent_uuid: nil}), do: {nil, :last}

  defp place_for(%Assignment{} = done) do
    by_uuid = Map.new(project_rows(done.project_uuid), &{&1.uuid, &1})
    climb(by_uuid, by_uuid[done.parent_uuid], nil)
  end

  # `after` is the topmost done ancestor met so far: the occurrence goes
  # right after it, under the first open one above.
  defp climb(_by_uuid, nil, after_uuid), do: {nil, after_uuid || :last}

  defp climb(by_uuid, %Assignment{status: "done"} = parent, _after_uuid),
    do: climb(by_uuid, by_uuid[parent.parent_uuid], parent.uuid)

  defp climb(_by_uuid, %Assignment{} = open, after_uuid), do: {open.uuid, after_uuid || :last}

  defp place!(%Assignment{} = made, {nil, :last}), do: made

  defp place!(%Assignment{} = made, {parent_uuid, after_uuid}) do
    # The move runs in this transaction (its lock nests): a refused move
    # rolls the whole occurrence back, so it is said rather than ignored.
    # Its broadcast waits for the commit (`announce/3`).
    case Outline.move(Projects.get_assignment(made.uuid), parent_uuid, after_uuid,
           broadcast: false
         ) do
      {:ok, moved} -> moved
      {:error, reason} -> repo().rollback(reason)
    end
  end

  # A library task is the same task each time; a one-off one gets its own
  # copy, so renaming one occurrence never renames the others.
  defp task_for(%Assignment{task_uuid: nil}), do: nil

  defp task_for(%Assignment{task_uuid: uuid}) do
    case repo().get(Task, uuid) do
      %Task{ad_hoc: true} = t ->
        attrs = %{
          "title" => t.title,
          "description" => t.description,
          "translations" => t.translations,
          "estimated_duration" => t.estimated_duration,
          "estimated_duration_unit" => t.estimated_duration_unit,
          "ad_hoc" => true
        }

        case %Task{} |> Task.changeset(attrs) |> repo().insert() do
          {:ok, copy} -> copy.uuid
          {:error, cs} -> repo().rollback(cs)
        end

      %Task{} = t ->
        t.uuid

      nil ->
        repo().rollback(:no_task)
    end
  end

  defp project_rows(project_uuid) do
    from(a in Assignment,
      where: a.project_uuid == ^project_uuid,
      order_by: [asc: a.position, asc: a.inserted_at]
    )
    |> repo().all()
  end
end
