defmodule PhoenixKitProjects.Web.Components.HistoryFeed do
  @moduledoc """
  A project's history as people read it (`PhoenixKitProjects.History`): one
  sentence per line — "Kadri reopened Measure the room" — the comment or the
  reason quoted under it, who was told and whether they have seen it, grouped
  by the viewer's day, newest first. The project's History tab draws it in
  full; the task drawer draws one task's lines with `compact`.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitProjects.Gettext

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  alias PhoenixKit.Mentions.Token
  alias PhoenixKitProjects.{L10n, Paths}

  attr(:entries, :list, required: true)
  attr(:project, :map, required: true)
  attr(:id, :string, required: true)
  attr(:compact, :boolean, default: false, doc: "one task's lines: no task names, no day headers")
  attr(:links, :boolean, default: true, doc: "task names as links (false in an emit-mode embed)")

  def history_feed(assigns) do
    assigns = assign(assigns, :days, group_by_day(assigns.entries))

    ~H"""
    <div id={@id} class="flex flex-col gap-4">
      <section :for={{day, lines} <- @days} class="flex flex-col gap-1">
        <h3 :if={not @compact} class="text-xs font-semibold uppercase tracking-wide text-base-content/60 sticky top-0 bg-base-100 py-1 z-10">
          {day_label(day)}
        </h3>
        <ol class="flex flex-col">
          <li
            :for={e <- lines}
            id={"#{@id}-#{e.id}"}
            class="flex gap-3 py-2 border-b border-base-200 last:border-b-0"
          >
            <%!-- A fixed square, the icon centred: the icon is inline, so a
                 padded box took the line's height and came out oval. --%>
            <div class={[
              "mt-0.5 shrink-0 self-start flex items-center justify-center w-7 h-7 rounded-full",
              tone(e)
            ]}>
              <.icon name={icon_for(e)} class="w-4 h-4 block" />
            </div>
            <div class="min-w-0 flex-1">
              <div class="flex flex-wrap items-baseline gap-x-2">
                <span class="text-sm">
                  <span :if={e.auto != true and actor_first?(e)} class="font-medium">{e.actor || gettext("Someone")}</span>
                  {if @compact, do: compact_sentence(e), else: sentence(e)}
                  <span :if={e.task && not @compact && e.task[:gone]} class="font-medium line-through decoration-base-content/40">{e.task.label}</span>
                  <span :if={e.task && not @compact && !e.task[:gone] && not @links} class="font-medium">{e.task.label}</span>
                  <.link
                    :if={e.task && not @compact && !e.task[:gone] && @links}
                    navigate={Paths.task(@project, %{uuid: e.task.uuid})}
                    class="link link-hover font-medium"
                  >
                    {e.task.label}
                  </.link><span :if={e.task && not @compact}>{tail(e)}</span>
                </span>
                <time
                  class="text-xs text-base-content/50 ml-auto shrink-0"
                  datetime={DateTime.to_iso8601(e.at)}
                  title={L10n.format_datetime(e.at)}
                >
                  {if @compact, do: L10n.format_month_day_time(e.at), else: L10n.local_time(e.at)}
                </time>
              </div>
              <blockquote
                :if={quote_text(e)}
                class="mt-1 border-l-2 border-base-300 pl-3 text-sm text-base-content/80 whitespace-pre-line break-words"
              >{quote_text(e)}</blockquote>
              <p :if={e.told != []} class="mt-1 text-xs text-base-content/60 flex flex-wrap gap-x-3">
                <span :for={t <- e.told} class="inline-flex items-center gap-1">
                  <.icon name="hero-bell" class="w-3 h-3" />
                  <%= if t.seen_at do %>
                    {gettext("%{name} was told · seen %{when}",
                      name: t.name || gettext("someone"),
                      when: L10n.format_month_day_time(t.seen_at)
                    )}
                  <% else %>
                    {gettext("%{name} was told · not seen yet", name: t.name || gettext("someone"))}
                  <% end %>
                </span>
              </p>
            </div>
          </li>
        </ol>
      </section>
    </div>
    """
  end

  # ── Days ────────────────────────────────────────────────────────────

  defp group_by_day(entries) do
    entries
    |> Enum.chunk_by(&L10n.local_date(&1.at))
    |> Enum.map(fn [first | _] = lines -> {L10n.local_date(first.at), lines} end)
  end

  defp day_label(%Date{} = day) do
    today = L10n.local_date(DateTime.utc_now())

    cond do
      day == today -> gettext("Today")
      day == Date.add(today, -1) -> gettext("Yesterday")
      true -> gettext("%{weekday}, %{date}", weekday: weekday(day), date: L10n.format_date(day))
    end
  end

  defp weekday(day) do
    case Date.day_of_week(day) do
      1 -> gettext("Monday")
      2 -> gettext("Tuesday")
      3 -> gettext("Wednesday")
      4 -> gettext("Thursday")
      5 -> gettext("Friday")
      6 -> gettext("Saturday")
      7 -> gettext("Sunday")
    end
  end

  # ── One task's lines (the drawer): the task is implied, so no sentence
  # may end waiting for its name. ──────────────────────────────────────

  defp compact_sentence(%{kind: :comment} = e),
    do: if(e[:reply], do: gettext("replied"), else: gettext("commented"))

  defp compact_sentence(%{kind: :note}), do: gettext("wrote a note")

  defp compact_sentence(%{kind: :time} = e),
    do: gettext("logged %{time}", time: duration(e[:minutes]))

  defp compact_sentence(%{kind: :activity} = e), do: compact_activity(e.action, e)

  defp compact_activity("projects.assignment_created", _), do: gettext("added the task")

  defp compact_activity("projects.assignment_started", %{auto: true}),
    do: gettext("Work started under it")

  defp compact_activity("projects.assignment_started", _), do: gettext("started")

  defp compact_activity("projects.assignment_completed", %{auto: true}),
    do: gettext("Everything under it is done")

  defp compact_activity("projects.assignment_completed", _), do: gettext("finished")

  defp compact_activity("projects.assignment_reopened", %{auto: true}),
    do: gettext("Open again, because work under it was reopened")

  defp compact_activity("projects.assignment_reopened", %{quote: q})
       when is_binary(q) and q != "",
       do: gettext("reopened it, because:")

  defp compact_activity("projects.assignment_reopened", _), do: gettext("reopened")

  defp compact_activity("projects.assignment_made_ready", _),
    do: gettext("marked it as can be started")

  defp compact_activity("projects.assignment_made_idle", _), do: gettext("kept it idle")

  defp compact_activity("projects.assignment_ready", %{meta: %{"resume" => true}}),
    do: gettext("It can go on again")

  defp compact_activity("projects.assignment_ready", _), do: gettext("It can start now")

  defp compact_activity("projects.assignment_on_hold", _),
    do: gettext("On hold, because work before it was reopened")

  defp compact_activity(action, %{meta: %{"waiting_on" => w}})
       when action in ["projects.assignment_waiting", "projects.assignment_updated"] and
              is_binary(w) and w != "",
       do: gettext("is waiting on “%{what}”", what: w)

  defp compact_activity(action, %{meta: %{"waiting_on" => _}})
       when action in ["projects.assignment_waiting", "projects.assignment_updated"],
       do: gettext("is no longer waiting")

  defp compact_activity("projects.assignment_reassigned", %{meta: %{"to" => to}})
       when is_binary(to) and to != "",
       do: gettext("handed it to %{who}", who: to)

  defp compact_activity("projects.assignment_reassigned", _),
    do: gettext("took it off its assignee")

  defp compact_activity("projects.work_amended", %{meta: %{"kind" => "time"} = m}),
    do:
      gettext("changed logged time from %{was} to %{now}",
        was: duration(minutes(m["amount_was"])),
        now: duration(minutes(m["amount"]))
      )

  defp compact_activity("projects.work_amended", _), do: gettext("corrected a usage entry")

  defp compact_activity("projects.work_removed", %{meta: %{"kind" => "time"} = m}),
    do: gettext("removed %{time} of logged time", time: duration(minutes(m["amount"])))

  defp compact_activity("projects.work_removed", _), do: gettext("removed a usage entry")

  defp compact_activity("projects.assignment_removed", _), do: gettext("removed the task")
  defp compact_activity(_action, _), do: gettext("changed it")

  # ── The sentence ────────────────────────────────────────────────────
  #
  # Drawn as: [actor] <sentence> [task link]<tail>. A sentence that does not
  # start with its actor ("Measure the room can start now") sets
  # `actor_first?` false and carries the names itself.

  defp actor_first?(%{kind: :activity, action: action})
       when action in ~w(projects.assignment_ready projects.assignment_on_hold
                         projects.project_completed projects.project_reopened),
       do: false

  defp actor_first?(_), do: true

  defp sentence(%{kind: :comment, task: nil} = e),
    do:
      if(e[:reply],
        do: gettext("replied on the project"),
        else: gettext("commented on the project")
      )

  defp sentence(%{kind: :comment} = e),
    do: if(e[:reply], do: gettext("replied on"), else: gettext("commented on"))

  defp sentence(%{kind: :note, task: nil}), do: gettext("wrote a project note")
  defp sentence(%{kind: :note}), do: gettext("wrote a note on")

  defp sentence(%{kind: :time, task: nil} = e),
    do: gettext("logged %{time}", time: duration(e[:minutes]))

  defp sentence(%{kind: :time} = e), do: gettext("logged %{time} on", time: duration(e[:minutes]))

  defp sentence(%{kind: :activity} = e), do: activity_sentence(e.action, e)

  defp activity_sentence("projects.project_created", _), do: gettext("created the project")
  defp activity_sentence("projects.project_started", _), do: gettext("started the project")
  defp activity_sentence("projects.project_completed", _), do: gettext("The project is complete")
  defp activity_sentence("projects.project_reopened", _), do: gettext("The project is open again")

  defp activity_sentence("projects.project_updated", _),
    do: gettext("changed the project's settings")

  defp activity_sentence("projects.project_archived", _), do: gettext("archived the project")

  defp activity_sentence("projects.project_unarchived", _),
    do: gettext("brought the project back from the archive")

  defp activity_sentence("projects.member_added", e),
    do: gettext("added %{who} to the project", who: e[:target] || gettext("someone"))

  defp activity_sentence("projects.member_removed", e),
    do: gettext("removed %{who} from the project", who: e[:target] || gettext("someone"))

  defp activity_sentence("projects.member_role_changed", e),
    do: gettext("changed %{who}'s role", who: e[:target] || gettext("someone"))

  defp activity_sentence("projects.assignment_created", %{task: nil}), do: gettext("added a task")
  defp activity_sentence("projects.assignment_created", _), do: gettext("added")

  defp activity_sentence("projects.assignment_started", %{auto: true}),
    do: gettext("Work started under")

  defp activity_sentence("projects.assignment_started", _), do: gettext("started")

  defp activity_sentence("projects.assignment_completed", %{auto: true}),
    do: gettext("Everything under it is done:")

  defp activity_sentence("projects.assignment_completed", _), do: gettext("finished")

  defp activity_sentence("projects.assignment_reopened", %{auto: true}),
    do: gettext("Open again, because work under it was reopened:")

  defp activity_sentence("projects.assignment_reopened", _), do: gettext("reopened")
  defp activity_sentence("projects.assignment_removed", _), do: gettext("removed the task")

  defp activity_sentence(action, e)
       when action in ["projects.assignment_waiting", "projects.assignment_updated"] do
    case Map.fetch(e.meta, "waiting_on") do
      {:ok, w} when is_binary(w) and w != "" -> gettext("is waiting on “%{what}” for", what: w)
      {:ok, _} -> gettext("is no longer waiting on")
      :error -> gettext("edited")
    end
  end

  defp activity_sentence("projects.assignment_made_ready", _),
    do: gettext("marked as can be started:")

  defp activity_sentence("projects.assignment_made_idle", _), do: gettext("kept idle:")

  defp activity_sentence("projects.assignment_ready", %{meta: %{"resume" => true}}),
    do: gettext("Can go on again:")

  defp activity_sentence("projects.assignment_ready", _), do: gettext("Ready to start:")

  defp activity_sentence("projects.assignment_on_hold", _),
    do: gettext("On hold, because work before it was reopened:")

  defp activity_sentence("projects.assignment_progress_updated", _),
    do: gettext("updated the progress of")

  defp activity_sentence("projects.assignment_duration_changed", _),
    do: gettext("changed the estimate of")

  defp activity_sentence("projects.dependency_added", _), do: gettext("set what comes before")
  defp activity_sentence("projects.dependency_removed", _), do: gettext("removed a step before")
  defp activity_sentence("projects.task_list_edited", _), do: gettext("edited the task list")
  defp activity_sentence("projects.subproject_" <> _, _), do: gettext("changed a sub-project")
  defp activity_sentence("projects.event_created", _), do: gettext("added an event")
  defp activity_sentence("projects.event_updated", _), do: gettext("changed an event")
  defp activity_sentence("projects.event_deleted", _), do: gettext("removed an event")
  defp activity_sentence("projects.health_updated", _), do: gettext("set the project's health")
  defp activity_sentence("projects.assignment_reassigned", _), do: gettext("handed")

  defp activity_sentence("projects.work_amended", %{meta: %{"kind" => "time"}, task: nil} = e),
    do:
      gettext("changed logged time from %{was} to %{now}",
        was: duration(minutes(e.meta["amount_was"])),
        now: duration(minutes(e.meta["amount"]))
      )

  defp activity_sentence("projects.work_amended", %{meta: %{"kind" => "time"}}),
    do: gettext("changed the time logged on")

  defp activity_sentence("projects.work_amended", _), do: gettext("corrected a usage entry")

  defp activity_sentence("projects.work_removed", %{meta: %{"kind" => "time"}, task: nil} = e),
    do: gettext("removed %{time} of logged time", time: duration(minutes(e.meta["amount"])))

  defp activity_sentence("projects.work_removed", %{meta: %{"kind" => "time"}}),
    do: gettext("removed logged time from")

  defp activity_sentence("projects.work_removed", _), do: gettext("removed a usage entry")

  defp activity_sentence(_action, %{task: nil}), do: gettext("changed the project")
  defp activity_sentence(_action, _), do: gettext("changed")

  # The words after the task name, when the sentence needs any.
  defp tail(%{kind: :activity, action: "projects.assignment_reopened", auto: false, quote: q})
       when is_binary(q) and q != "",
       do: gettext(" — because:")

  defp tail(%{kind: :activity, action: "projects.assignment_ready", meta: %{"more" => n}})
       when is_integer(n) and n > 0,
       do: ngettext(" and 1 more task", " and %{count} more tasks", n)

  defp tail(%{
         kind: :activity,
         action: "projects.work_amended",
         meta: %{"kind" => "time"} = m,
         task: %{}
       }),
       do:
         gettext(" from %{was} to %{now}",
           was: duration(minutes(m["amount_was"])),
           now: duration(minutes(m["amount"]))
         )

  defp tail(%{
         kind: :activity,
         action: "projects.work_removed",
         meta: %{"kind" => "time"} = m,
         task: %{}
       }),
       do: gettext(" (%{time})", time: duration(minutes(m["amount"])))

  defp tail(%{kind: :activity, action: "projects.assignment_reassigned", meta: %{"to" => to}})
       when is_binary(to) and to != "",
       do: gettext(" to %{who}", who: to)

  defp tail(%{kind: :activity, action: "projects.assignment_reassigned"}),
    do: gettext(" to nobody")

  defp tail(_), do: ""

  # A reopen's reason, a comment, a note's text or a time entry's note.
  defp quote_text(%{kind: kind, quote: q})
       when kind in [:comment, :note, :time] and is_binary(q) and q != "",
       do: q |> Token.to_plain_text() |> String.trim()

  defp quote_text(%{kind: :activity, quote: q}) when is_binary(q) and q != "", do: String.trim(q)
  defp quote_text(_), do: nil

  # A ledger amount as the row keeps it (a plain decimal string).
  defp minutes(n) when is_number(n), do: n

  defp minutes(s) when is_binary(s) do
    case Float.parse(s) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp minutes(_), do: nil

  defp duration(nil), do: "—"

  defp duration(minutes) when is_number(minutes) do
    total = round(minutes)
    h = div(total, 60)
    m = rem(total, 60)

    cond do
      h == 0 -> gettext("%{m} min", m: m)
      m == 0 -> gettext("%{h} h", h: h)
      true -> gettext("%{h} h %{m} min", h: h, m: m)
    end
  end

  # ── Look ────────────────────────────────────────────────────────────

  defp icon_for(%{kind: :comment}), do: "hero-chat-bubble-left"
  defp icon_for(%{kind: :note}), do: "hero-document-text"
  defp icon_for(%{kind: :time}), do: "hero-clock"
  defp icon_for(%{action: "projects.assignment_completed"}), do: "hero-check"
  defp icon_for(%{action: "projects.assignment_reopened"}), do: "hero-arrow-uturn-left"
  defp icon_for(%{action: "projects.assignment_started"}), do: "hero-play"
  defp icon_for(%{action: "projects.assignment_ready"}), do: "hero-arrow-right"
  defp icon_for(%{action: "projects.assignment_made_ready"}), do: "hero-arrow-right-circle"
  defp icon_for(%{action: "projects.assignment_made_idle"}), do: "hero-pause-circle"
  defp icon_for(%{action: "projects.assignment_on_hold"}), do: "hero-pause"
  defp icon_for(%{action: "projects.assignment_waiting"}), do: "hero-hand-raised"
  defp icon_for(%{action: "projects.assignment_reassigned"}), do: "hero-arrows-right-left"
  defp icon_for(%{action: "projects.work_" <> _}), do: "hero-clock"

  defp icon_for(%{action: "projects.assignment_updated", meta: %{"waiting_on" => _}}),
    do: "hero-hand-raised"

  defp icon_for(%{action: "projects.project_" <> _}), do: "hero-flag"
  defp icon_for(%{action: "projects.member_" <> _}), do: "hero-user-plus"
  defp icon_for(_), do: "hero-pencil"

  defp tone(%{kind: :comment}), do: "bg-info/15 text-info"
  defp tone(%{kind: :note}), do: "bg-info/15 text-info"
  defp tone(%{kind: :time}), do: "bg-base-200 text-base-content/70"
  defp tone(%{action: "projects.assignment_completed"}), do: "bg-success/15 text-success"
  defp tone(%{action: "projects.project_completed"}), do: "bg-success/15 text-success"

  defp tone(%{action: "projects.assignment_reopened", auto: false}),
    do: "bg-warning/20 text-warning"

  defp tone(%{action: "projects.assignment_on_hold"}), do: "bg-warning/20 text-warning"
  defp tone(%{action: "projects.assignment_ready"}), do: "bg-primary/15 text-primary"
  defp tone(%{action: "projects.assignment_made_ready"}), do: "bg-info/15 text-info"
  defp tone(_), do: "bg-base-200 text-base-content/70"
end
