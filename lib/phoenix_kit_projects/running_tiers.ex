defmodule PhoenixKitProjects.RunningTiers do
  @moduledoc """
  The "Running" ordering the Overview dashboard used, lifted out so the
  `projects.running` dashboard widget (see `DashboardWidgets`) and the
  embeddable `Web.OverviewLive` rank projects identically.

  Input is a tree summary (`Projects.project_tree_summary/1`) per active
  project; `tag/2` stamps `:tier` + `:late` on it, `prioritize/4` sorts and
  caps. Four tiers, in order:

  - `:late` — past `planned_end` (started_at + summed estimated durations)
    with progress < 100; with no durations at all, started ≥ 14 days ago.
    Most overdue first.
  - `:near_done` — progress ≥ 75 %. Highest progress first.
  - `:on_track` — the rest with tasks. Most recently started first.
  - `:empty` — no tasks. Sinks to the bottom regardless of age: nothing to
    measure, and recency alone would rank them above real work.
  """

  # Fallback "late" threshold (days since `started_at`) when a project has
  # no estimated durations — without a sum of durations there is no real
  # planned_end to compare against. Projects with durations use
  # planned_end directly, the same way the project show page does.
  @late_fallback_days 14
  # Progress percentage (>=) for the "near done" tier.
  @near_done_threshold_pct 75
  # How many running projects the Overview shows; the widget takes its own
  # limit from its settings.
  @default_display_limit 10

  @type tier :: :late | :near_done | :on_track | :empty

  @doc "The Overview's default cap on displayed running projects."
  @spec default_display_limit() :: pos_integer()
  def default_display_limit, do: @default_display_limit

  @doc "Stamps `:tier` and `:late` on a tree summary."
  @spec tag(map(), DateTime.t()) :: map()
  def tag(summary, %DateTime{} = now) do
    tier = tier(summary, now)
    summary |> Map.put(:tier, tier) |> Map.put(:late, tier == :late)
  end

  @doc """
  Sorts tagged summaries by tier (see the moduledoc) and caps them.
  Returns `{capped_list, total_count}`.
  """
  @spec prioritize([map()], Date.t(), DateTime.t(), pos_integer()) :: {[map()], non_neg_integer()}
  def prioritize(summaries, %Date{} = today, %DateTime{} = now, limit \\ @default_display_limit) do
    sorted = Enum.sort_by(summaries, &sort_key(&1, today, now))

    {Enum.take(sorted, limit), length(summaries)}
  end

  @doc "The tier of one summary at `now`."
  @spec tier(map(), DateTime.t()) :: tier()
  def tier(summary, %DateTime{} = now) do
    %{project: project, progress_pct: pct, total: total, planned_end: planned_end} = summary

    cond do
      total == 0 -> :empty
      late?(planned_end, project, now, pct) -> :late
      pct >= @near_done_threshold_pct -> :near_done
      true -> :on_track
    end
  end

  defp late?(_planned_end, _project, _now, pct) when pct >= 100, do: false

  defp late?(%DateTime{} = planned_end, _project, now, _pct),
    do: DateTime.compare(now, planned_end) == :gt

  defp late?(nil, %{started_at: %DateTime{} = started_at}, now, _pct),
    do: DateTime.diff(now, started_at, :second) / 86_400 >= @late_fallback_days

  defp late?(_, _, _, _), do: false

  defp sort_key(summary, today, now) do
    %{project: project, progress_pct: pct, tier: tier} = summary

    days_running =
      case project.started_at do
        %DateTime{} = dt -> Date.diff(today, DateTime.to_date(dt))
        _ -> 0
      end

    case tier do
      # Most overdue first: seconds past planned_end (or age, without one),
      # negated for the ascending sort.
      :late -> {0, -overdue_seconds(summary, now), project.uuid}
      :near_done -> {1, -pct, project.uuid}
      :on_track -> {2, days_running, project.uuid}
      :empty -> {3, days_running, project.uuid}
    end
  end

  defp overdue_seconds(%{planned_end: %DateTime{} = planned_end}, now),
    do: DateTime.diff(now, planned_end, :second)

  defp overdue_seconds(%{project: %{started_at: %DateTime{} = started_at}}, now),
    do: DateTime.diff(now, started_at, :second)

  defp overdue_seconds(_, _now), do: 0
end
