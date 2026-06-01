defmodule PhoenixKitProjects.Web.Components.RunningCard do
  @moduledoc """
  One project in the dashboard's "Running" section, rendered as a **hierarchical
  summary** (V126): a top line with the project name + tier + progress, a
  one-line summary (`N tasks · M sub-projects`), a status breakdown
  (`X done · Y in progress · Z todo`), and then each embedded sub-project nested
  underneath as an indented sub-step with its own summary + breakdown — all the
  way down.

  Driven by the recursive node shape from `Projects.project_tree_summary/1`.
  The top node also carries `total` / `progress_pct` / `planned_end`, so the
  dashboard's tier + sort helpers read it like the old flat summary map.

  ## Example

      <.running_card node={tree} tier={running_tier(tree)} embed_mode={@embed_mode} lang={lang} />
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitProjects.Gettext

  import PhoenixKitProjects.Web.Components.TierPill
  import PhoenixKitProjects.Web.Components.SmartLink

  alias PhoenixKitProjects.{Paths, Schemas.Project}

  attr(:node, :map, required: true)
  attr(:tier, :atom, required: true, values: [:late, :near_done, :on_track, :empty])
  attr(:embed_mode, :atom, default: :navigate, values: [:navigate, :emit])
  attr(:lang, :string, default: nil)

  def running_card(assigns) do
    ~H"""
    <div class="p-3 rounded hover:bg-base-200 transition">
      <div class="flex items-center gap-2 min-w-0">
        <.smart_link
          navigate={path_for(@node)}
          emit={emit_for(@node)}
          embed_mode={@embed_mode}
          class="font-medium truncate min-w-0 hover:underline"
        >
          {Project.localized_name(@node.project, @lang)}
        </.smart_link>
        <.tier_pill tier={@tier} />
        <div class="ml-auto text-lg font-bold shrink-0">{@node.progress_pct}%</div>
      </div>

      <div class="text-xs text-base-content/60 mt-0.5">
        {started_when_label(@node.project)} · {summary_line(@node)}
      </div>
      <div :if={breakdown_line(@node)} class="text-xs text-base-content/50">
        {breakdown_line(@node)}
      </div>

      <div :if={visible_children(@node) != []} class="mt-2 flex flex-col gap-2">
        <.tree_node
          :for={child <- visible_children(@node)}
          node={child}
          lang={@lang}
          embed_mode={@embed_mode}
        />
      </div>
    </div>
    """
  end

  @doc "One nested sub-project node — recurses for its own sub-projects."
  attr(:node, :map, required: true)
  attr(:lang, :string, default: nil)
  attr(:embed_mode, :atom, default: :navigate)

  def tree_node(assigns) do
    ~H"""
    <div class="border-l-2 border-base-300 pl-3">
      <div class="flex items-center gap-2 min-w-0">
        <.smart_link
          navigate={path_for(@node)}
          emit={emit_for(@node)}
          embed_mode={@embed_mode}
          class="text-sm font-medium truncate min-w-0 hover:underline"
        >
          {Project.localized_name(@node.project, @lang)}
        </.smart_link>
        <span class="ml-auto text-xs font-semibold shrink-0">{@node.progress_pct}%</span>
      </div>
      <div class="text-xs text-base-content/60">{summary_line(@node)}</div>
      <div :if={breakdown_line(@node)} class="text-xs text-base-content/50">
        {breakdown_line(@node)}
      </div>

      <div :if={visible_children(@node) != []} class="mt-1.5 flex flex-col gap-1.5">
        <.tree_node
          :for={child <- visible_children(@node)}
          node={child}
          lang={@lang}
          embed_mode={@embed_mode}
        />
      </div>
    </div>
    """
  end

  # Hide truly-empty sub-projects (no tasks AND no sub-projects of their own) —
  # they add noise without information. A 0-task node that still has nested
  # sub-projects is kept (it has content below it).
  defp visible_children(node) do
    Enum.reject(node.children, fn c -> c.task_total == 0 and c.subproject_count == 0 end)
  end

  defp path_for(node), do: Paths.project(node.project.uuid)

  defp emit_for(node),
    do: {PhoenixKitProjects.Web.ProjectShowLive, %{"id" => node.project.uuid}}

  # "5 tasks · 1 sub-project" — sub-project segment omitted when there are none.
  defp summary_line(node) do
    tasks = ngettext("%{count} task", "%{count} tasks", node.task_total)

    if node.subproject_count > 0 do
      subs = ngettext("%{count} sub-project", "%{count} sub-projects", node.subproject_count)
      "#{tasks} · #{subs}"
    else
      tasks
    end
  end

  # "3 done · 2 in progress · 1 todo" — zero segments dropped. `nil` (so the row
  # is skipped) when this node has no direct tasks of its own.
  defp breakdown_line(%{task_total: 0}), do: nil

  defp breakdown_line(node) do
    [
      {node.task_done, gettext("done")},
      {node.task_in_progress, gettext("in progress")},
      {node.task_todo, gettext("todo")}
    ]
    |> Enum.filter(fn {n, _label} -> n > 0 end)
    |> Enum.map_join(" · ", fn {n, label} -> "#{n} #{label}" end)
    |> case do
      "" -> nil
      line -> line
    end
  end

  defp started_when_label(%{started_at: %DateTime{} = dt}) do
    days = Date.diff(DateTime.to_date(dt), Date.utc_today())
    gettext("Started %{when}", when: relative_day(days))
  end

  defp started_when_label(_), do: gettext("Not started yet")

  # Inlined here (rather than depending on a sibling LV's private helper) so the
  # component stays self-contained. Mirrors `OverviewLive.relative_day/1`.
  defp relative_day(0), do: gettext("today")
  defp relative_day(1), do: gettext("tomorrow")
  defp relative_day(-1), do: gettext("yesterday")

  defp relative_day(days) when days > 1 and days < 14,
    do: ngettext("in %{count} day", "in %{count} days", days)

  defp relative_day(days) when days > 1,
    do: gettext("in %{n} weeks", n: Float.round(days / 7, 1))

  defp relative_day(days) when days < 0 and days > -14,
    do: ngettext("%{count} day ago", "%{count} days ago", abs(days))

  defp relative_day(days),
    do: gettext("%{n} weeks ago", n: Float.round(abs(days) / 7, 1))
end
