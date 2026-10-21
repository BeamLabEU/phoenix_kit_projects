defmodule PhoenixKitProjects.Web.ApiKeysUsage do
  @moduledoc """
  The API keys page's Usage tab (Max, 2026-10-19: "give the API keys their
  own sub-tabs… the usage information is kind of like a small chunk on the
  page. So we could really expand it with graphs").

  `ApiKeysLive` loads the figures (`ApiKeysLive.load_usage/1`, through
  `PhoenixKitProjects.ApiUsage`) and hands them over as one map, `@u`; this
  module only draws them:

    * the period's figures, each against the period before it;
    * the switched figure per day, stacked by key (all keys) or by project
      (one key);
    * failed requests per day, refused ones apart;
    * the figures per key, per project, and the tasks the reported work
      went to.

  Days are UTC days, as everywhere the ledger is summed.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitProjects.Gettext

  import PhoenixKitProjects.Web.Components.VizPalette
  import PhoenixKitWeb.Components.Core.Chart, only: [bar_chart: 1]
  import PhoenixKitWeb.Components.Core.ColumnSettings, only: [column_settings_modal: 1]
  import PhoenixKitWeb.Components.Core.EmptyState, only: [empty_state: 1]
  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.NavTabs, only: [nav_tabs: 1]
  import PhoenixKitWeb.Components.Core.Select, only: [select: 1]
  import PhoenixKitWeb.Components.Core.StatCard, only: [stat_card: 1]

  import PhoenixKitWeb.Components.Core.TableDefault,
    only: [
      table_default: 1,
      table_default_body: 1,
      table_default_cell: 1,
      table_default_header: 1,
      table_default_header_cell: 1,
      table_default_row: 1
    ]

  alias PhoenixKitProjects.Hours.Format
  alias PhoenixKitProjects.{L10n, Paths}
  alias PhoenixKitProjects.Web.ListUi

  @metrics [:requests, :tokens, :cost_cents, :minutes]
  @periods [7, 30, 90]

  @doc "The figures the switch can draw, in order."
  def metrics, do: @metrics

  @doc "The periods, in days, the page offers."
  def periods, do: @periods

  attr(:u, :map, required: true)
  attr(:admin?, :boolean, default: false)
  attr(:show_column_modal, :boolean, default: false)
  attr(:figures, :list, default: [])
  attr(:task_columns, :list, default: [])

  @doc "The whole Usage tab."
  def usage_tab(assigns) do
    ~H"""
    <div class="flex flex-col gap-6" id="api-usage">
      <%!-- What to look at: whose keys (administrators), the period, one key
           or all, and the figure the main chart draws. The period, key and
           figure are in the address, so a view can be kept. --%>
      <form id="usage-filters" phx-change="usage_filter" class="flex flex-wrap items-end gap-3">
        <div class="w-44">
          <.select
            id="usage-days"
            name="days"
            label={gettext("Period")}
            value={@u.days}
            options={Enum.map(periods(), &{gettext("Last %{count} days", count: &1), &1})}
          />
        </div>
        <div class="w-56">
          <.select
            id="usage-key"
            name="key"
            label={gettext("Key")}
            value={@u.key || ""}
            prompt={gettext("All keys")}
            options={Enum.map(@u.key_options, fn {uuid, name} -> {name, uuid} end)}
          />
        </div>
        <div class="ml-auto">
          <ListUi.columns_button />
        </div>
      </form>

      <.column_settings_modal
        show={@show_column_modal}
        id="api-usage-columns"
        sections={[
          %{
            id: "figures",
            title: gettext("Figures"),
            columns: figures_spec().columns,
            selected: @figures
          },
          %{
            id: "tasks",
            title: gettext("Tasks table"),
            columns: task_columns_spec().columns,
            selected: @task_columns
          }
        ]}
      />

      <.nav_tabs
        active_tab={to_string(@u.metric)}
        tabs={
          for metric <- @u.metrics do
            %{
              id: to_string(metric),
              label: metric_label(metric),
              patch: Paths.api_keys_usage(days: @u.days, key: @u.key, metric: metric)
            }
          end
        }
      />

      <.empty_state
        :if={@u.rows == []}
        icon="hero-chart-bar"
        title={gettext("Nothing yet in the last %{count} days.", count: @u.days)}
      />

      <%!-- The period's figures, each against the one before it. --%>
      <%!-- As many columns as figures, so the row is always full. --%>
      <div :if={@u.figures != []} class="grid grid-cols-[repeat(auto-fit,minmax(11rem,1fr))] gap-3" id="usage-figures">
        <.stat_card
          :for={{label, field, fmt, icon, color} <- tiles(@u.figures)}
          color={color}
          value={fmt.(Map.fetch!(@u.now, field))}
          title={label}
          subtitle={change_text(Map.fetch!(@u.now, field), Map.fetch!(@u.before, field))}
        >
          <:icon><.icon name={icon} class="w-5 h-5" /></:icon>
        </.stat_card>
      </div>

      <%!-- The figure per day, a part per key (all keys) or per project
           (one key), each in its colour. --%>
      <section class="card bg-base-100 shadow-sm pk-hours-viz" id="usage-main">
        <div class="card-body p-4 gap-3">
          <div class="flex flex-wrap items-center justify-between gap-2">
            <h2 class="card-title text-base">
              {if @u.key,
                do: gettext("%{metric} per day, by project", metric: metric_label(@u.metric)),
                else: gettext("%{metric} per day, by key", metric: metric_label(@u.metric))}
            </h2>
            <.legend series={@u.series} slots={@u.slots} metric={@u.metric} />
          </div>
          <.day_chart
            id="usage-main-chart"
            days={@u.days_main}
            top={@u.top_main}
            metric={@u.metric}
            slots={@u.slots}
            names={@u.series_names}
            height={200}
          />
        </div>
      </section>

      <%!-- Failures: the calls that answered 4xx/5xx, the refused (403)
           ones apart — usually a key whose access is set too narrowly. --%>
      <section :if={@u.now.errors > 0} class="card bg-base-100 shadow-sm" id="usage-failures">
        <div class="card-body p-4 gap-3">
          <div class="flex flex-wrap items-center justify-between gap-2">
            <h2 class="card-title text-base">{gettext("Failed requests per day")}</h2>
            <ul class="flex gap-3 text-xs text-base-content/70">
              <li class="flex items-center gap-1"><span class="inline-block w-2.5 h-2.5 rounded-sm bg-warning"></span>{gettext("Refused (403)")}</li>
              <li class="flex items-center gap-1"><span class="inline-block w-2.5 h-2.5 rounded-sm bg-error"></span>{gettext("Other failures")}</li>
            </ul>
          </div>
          <div class="flex gap-2">
            <.axis top={@u.top_failures} metric={:requests} height="h-24" />
            <div class="flex-1 min-w-0">
              <div class="relative h-24 border-b border-base-300">
                <.bar_chart
                  id="usage-failures-chart"
                  data={@u.failure_bars}
                  y_max={@u.top_failures}
                  height={96}
                  aria_label={gettext("Failed requests per day")}
                />
              </div>
              <.date_ends days={@u.days} />
            </div>
          </div>
          <p :if={@u.now.denied > 0} class="text-xs text-base-content/60">
            {gettext("A refused call means the key's access in that project does not cover it. Check the key's access on the Keys tab, or what the agent was trying to do.")}
          </p>
        </div>
      </section>

      <div class="grid gap-4 lg:grid-cols-2">
        <.breakdown
          id="usage-by-key"
          title={gettext("By key")}
          rows={@u.by_key}
          metric={@u.metric}
          figures={@u.figures}
          slots={if @u.key, do: %{}, else: @u.slots}
        />
        <.breakdown
          id="usage-by-project"
          title={gettext("By project")}
          rows={@u.by_project}
          metric={@u.metric}
          figures={@u.figures}
          slots={if @u.key, do: @u.slots, else: %{}}
        />
      </div>

      <%!-- Where the reported work went: tasks only (work reported on a
           project as a whole is in the figures above, not here). --%>
      <section class="card bg-base-100 shadow-sm" id="usage-by-task">
        <div class="card-body p-4 gap-2">
          <h2 class="card-title text-base">{gettext("Tasks the reported work went to")}</h2>
          <p :if={@u.by_task == []} class="text-sm text-base-content/50">
            {gettext("No tokens, cost or AI time reported on a task in this period.")}
          </p>
          <.table_default :if={@u.by_task != []} size="sm" wrapper_class="overflow-x-auto">
            <.table_default_header>
              <.table_default_row>
                <.table_default_header_cell>{gettext("Task")}</.table_default_header_cell>
                <.table_default_header_cell>{gettext("Project")}</.table_default_header_cell>
                <.table_default_header_cell :for={c <- @u.task_columns} class="text-right">{metric_label(c)}</.table_default_header_cell>
              </.table_default_row>
            </.table_default_header>
            <.table_default_body>
              <.table_default_row :for={t <- @u.by_task}>
                <.table_default_cell class="max-w-72">
                  <.link :if={t.href} navigate={t.href} class="link link-hover">
                    <span :if={t.ref} class="font-mono text-xs text-base-content/50 mr-1">{t.ref}</span>{t.title}
                  </.link>
                  <span :if={!t.href} class="text-base-content/50">{gettext("(deleted task)")}</span>
                </.table_default_cell>
                <.table_default_cell class="text-base-content/70">{t.project_name}</.table_default_cell>
                <.table_default_cell :for={c <- @u.task_columns} class="text-right tabular-nums">{metric_value(c, Map.fetch!(t, c))}</.table_default_cell>
              </.table_default_row>
            </.table_default_body>
          </.table_default>
        </div>
      </section>

      <p class="text-xs text-base-content/50">
        {gettext("Requests are counted for every call. Tokens, AI time and cost are what agents report — cost only for agents paid per call through an API (on a subscription there is none — hide it with Columns). Days are UTC.")}
      </p>
    </div>
    """
  end

  # ── pieces ──

  # The change against the period before: "+12% vs previous", "new", or
  # nothing to compare.
  defp change_text(now, before) when before == 0 and now == 0,
    do: gettext("Nothing before either")

  defp change_text(_now, before) when before == 0, do: gettext("New in this period")

  defp change_text(now, before) do
    pct = round((now - before) / before * 100)

    cond do
      pct > 0 -> gettext("+%{pct}% vs previous", pct: pct)
      pct < 0 -> gettext("−%{pct}% vs previous", pct: abs(pct))
      true -> gettext("Same as previous")
    end
  end

  attr(:series, :list, required: true)
  attr(:slots, :map, required: true)
  attr(:metric, :atom, required: true)

  defp legend(assigns) do
    ~H"""
    <ul class="flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-base-content/70">
      <li :for={s <- @series} class="flex items-center gap-1">
        <span class="inline-block w-2.5 h-2.5 rounded-sm" style={viz_slot_style(Map.get(@slots, s.uuid, 0))}></span>
        {s.name}
        <span class="text-base-content/50 tabular-nums">{metric_value(@metric, s.value)}</span>
      </li>
    </ul>
    """
  end

  attr(:id, :string, required: true)
  attr(:days, :list, required: true)
  attr(:top, :any, required: true)
  attr(:metric, :atom, required: true)
  attr(:slots, :map, required: true)
  attr(:names, :map, required: true)
  attr(:height, :integer, default: 160)

  defp day_chart(assigns) do
    ~H"""
    <p :if={@top == 0} class="text-sm text-base-content/50 py-10 text-center">
      {gettext("None of this in the period.")}
    </p>
    <div :if={@top > 0} class="flex gap-2">
      <.axis top={@top} metric={@metric} height="h-48" />
      <div class="flex-1 min-w-0">
        <div class="relative h-48 border-b border-base-300">
          <div class="absolute inset-x-0 top-0 border-t border-base-content/10 pointer-events-none"></div>
          <div class="absolute inset-x-0 top-1/2 border-t border-base-content/10 pointer-events-none"></div>
          <.bar_chart
            id={@id}
            data={bars(@days, @metric, @slots, @names)}
            y_max={@top}
            height={@height}
            value_format={&metric_value(@metric, &1)}
            aria_label={metric_label(@metric)}
            class="relative"
          />
        </div>
        <.date_ends days={length(@days)} />
      </div>
    </div>
    """
  end

  attr(:top, :any, required: true)
  attr(:metric, :atom, required: true)
  attr(:height, :string, required: true)

  defp axis(assigns) do
    ~H"""
    <div class={["flex flex-col justify-between text-[10px] text-base-content/50 tabular-nums text-right", @height]}>
      <span>{metric_value(@metric, @top)}</span>
      <span>{metric_value(@metric, @top / 2)}</span>
      <span>0</span>
    </div>
    """
  end

  attr(:days, :integer, required: true)

  defp date_ends(assigns) do
    ~H"""
    <div class="flex justify-between text-[10px] text-base-content/50 mt-1">
      <span>{short_day(Date.add(Date.utc_today(), 1 - @days))}</span>
      <span :if={@days > 2}>{short_day(Date.add(Date.utc_today(), -div(@days, 2)))}</span>
      <span>{gettext("today")}</span>
    </div>
    """
  end

  attr(:id, :string, required: true)
  attr(:title, :string, required: true)
  attr(:rows, :list, required: true)
  attr(:metric, :atom, required: true)
  attr(:figures, :list, required: true)
  attr(:slots, :map, required: true)

  # One row per key or project: a bar for the switched figure, then every
  # figure in small print.
  defp breakdown(assigns) do
    assigns =
      assign(assigns,
        max: assigns.rows |> Enum.map(&Map.fetch!(&1, assigns.metric)) |> Enum.max(fn -> 0 end)
      )

    ~H"""
    <section class="card bg-base-100 shadow-sm pk-hours-viz" id={@id}>
      <div class="card-body p-4 gap-2">
        <h2 class="card-title text-base">{@title}</h2>
        <p :if={@rows == []} class="text-sm text-base-content/50">{gettext("Nothing here.")}</p>
        <ul class="flex flex-col gap-3">
          <li :for={row <- @rows} class="flex flex-col gap-1">
            <div class="flex items-baseline justify-between gap-2 text-sm">
              <span class="truncate min-w-0 flex items-center gap-1.5">
                <span :if={Map.has_key?(@slots, row.uuid)} class="inline-block w-2.5 h-2.5 rounded-sm shrink-0" style={viz_slot_style(Map.get(@slots, row.uuid, 0))}></span>
                <.link :if={row[:href]} patch={row.href} class="link link-hover truncate">{row.name}</.link>
                <span :if={!row[:href]} class="truncate">{row.name}</span>
              </span>
              <span class="shrink-0 tabular-nums font-medium">{metric_value(@metric, Map.fetch!(row, @metric))}</span>
            </div>
            <div class="h-1.5 rounded-full bg-base-200 overflow-hidden">
              <div class="h-full bg-primary/70" style={"width: #{pct(Map.fetch!(row, @metric), @max)}%"}></div>
            </div>
            <div class="text-xs text-base-content/50 tabular-nums">
              <span
                :for={{field, i} <- Enum.with_index(@figures)}
                class={[field in [:errors, :denied] and Map.fetch!(row, field) > 0 && "text-warning"]}
              >
                {if i > 0, do: " · "}{figure_text(field, row)}
              </span>
            </div>
          </li>
        </ul>
      </div>
    </section>
    """
  end

  # ── shaping ──

  # The figures the viewer shows, in their order, with icons and colours.
  defp tiles(figures) do
    Enum.map(figures, fn field ->
      {icon, color} = figure_look(field)
      {figure_label(field), field, &metric_value(field, &1), icon, color}
    end)
  end

  defp figure_look(:requests), do: {"hero-arrows-right-left", "info"}
  defp figure_look(:errors), do: {"hero-exclamation-triangle", "warning"}
  defp figure_look(:denied), do: {"hero-no-symbol", "error"}
  defp figure_look(:tokens), do: {"hero-cpu-chip", "primary"}
  defp figure_look(:cost_cents), do: {"hero-banknotes", "success"}
  defp figure_look(:minutes), do: {"hero-clock", "secondary"}

  @doc "A figure's name on a card or in a list."
  def figure_label(:errors), do: gettext("Failed")
  def figure_label(:denied), do: gettext("Refused")
  def figure_label(field), do: metric_label(field)

  @doc ~S|A figure in running text: "12 requests", "3 failed", "1.2k tokens", "$0.40", "2h".|
  def figure_text(:requests, t), do: ngettext("%{count} request", "%{count} requests", t.requests)
  def figure_text(:errors, t), do: gettext("%{count} failed", count: t.errors)
  def figure_text(:denied, t), do: gettext("%{count} refused", count: t.denied)
  def figure_text(:tokens, t), do: "#{Format.tokens(t.tokens)} #{gettext("tokens")}"
  def figure_text(:cost_cents, t), do: Format.cost(t.cost_cents)
  def figure_text(:minutes, t), do: Format.duration(t.minutes)

  @doc """
  The figures a viewer may show (core's `TableColumns`, edited with the
  Usage page's Columns): the cards, the chart switch and each key's line.
  Cost is one of them by default — useful for agents paid per call through
  an API, and one click to hide on a subscription.
  """
  def figures_spec do
    %{
      key: "projects.api_usage.figures",
      columns: [
        %{id: "requests", label: fn -> gettext("Requests") end},
        %{id: "errors", label: fn -> gettext("Failed") end},
        %{id: "denied", label: fn -> gettext("Refused") end},
        %{id: "tokens", label: fn -> gettext("AI tokens") end},
        %{id: "cost_cents", label: fn -> gettext("AI cost") end},
        %{id: "minutes", label: fn -> gettext("AI time") end}
      ],
      defaults: ["requests", "errors", "tokens", "cost_cents", "minutes"]
    }
  end

  @doc "The tasks table's figure columns (the task and project always show)."
  def task_columns_spec do
    %{
      key: "projects.api_usage.tasks",
      columns: [
        %{id: "cost_cents", label: fn -> gettext("AI cost") end},
        %{id: "tokens", label: fn -> gettext("AI tokens") end},
        %{id: "minutes", label: fn -> gettext("AI time") end}
      ],
      defaults: ["cost_cents", "tokens", "minutes"]
    }
  end

  defp bars(days, _metric, slots, names) do
    Enum.map(days, fn day ->
      %{
        label: L10n.format_date(day.date),
        parts:
          Enum.map(day.parts, fn {uuid, value} ->
            %{
              label: Map.get(names, uuid, "—"),
              value: value,
              class: viz_slot_class(Map.get(slots, uuid, 0))
            }
          end)
      }
    end)
  end

  @doc "A figure's name."
  def metric_label(:requests), do: gettext("Requests")
  def metric_label(:tokens), do: gettext("AI tokens")
  def metric_label(:cost_cents), do: gettext("AI cost")
  def metric_label(:minutes), do: gettext("AI time")

  @doc "A figure as the page prints it."
  def metric_value(:requests, v), do: to_string(round(v))
  def metric_value(:errors, v), do: to_string(round(v))
  def metric_value(:denied, v), do: to_string(round(v))
  def metric_value(:tokens, v), do: Format.tokens(v)
  def metric_value(:cost_cents, v), do: Format.cost(v)
  def metric_value(:minutes, v), do: Format.duration(v)

  @doc """
  A round top for a chart's scale above `max`: 1, 2 or 5 times a power of
  ten, so the axis reads 0 / half / top in plain figures.
  """
  @spec nice_top(number()) :: number()
  def nice_top(max) when max <= 0, do: 0

  def nice_top(max) do
    exp = :math.pow(10, Float.floor(:math.log10(max)))

    Enum.find([1, 2, 5, 10], fn m -> m * exp >= max end) * exp
  end

  defp pct(_v, max) when max <= 0, do: 0
  defp pct(v, max), do: Float.round(v / max * 100, 1)

  defp short_day(%Date{} = d), do: "#{L10n.short_month(d.month)} #{d.day}"
end
