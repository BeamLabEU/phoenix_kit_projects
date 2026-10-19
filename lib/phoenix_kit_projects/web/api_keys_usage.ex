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

  alias PhoenixKitProjects.Hours.Format
  alias PhoenixKitProjects.{L10n, Paths}

  @metrics [:requests, :tokens, :cost_cents, :minutes]
  @periods [7, 30, 90]

  @doc "The figures the switch can draw, in order."
  def metrics, do: @metrics

  @doc "The periods, in days, the page offers."
  def periods, do: @periods

  attr(:u, :map, required: true)

  @doc "The whole Usage tab."
  def usage_tab(assigns) do
    ~H"""
    <div class="flex flex-col gap-6" id="api-usage">
      <%!-- What to look at: the period, one key or all, and the figure the
           main chart draws. Each is in the address, so a view can be kept. --%>
      <div class="flex flex-wrap items-end gap-3">
        <form id="usage-filters" phx-change="usage_filter" class="flex flex-wrap items-end gap-3">
          <label class="flex flex-col gap-1 text-xs text-base-content/60">
            {gettext("Period")}
            <select name="days" class="select select-sm">
              <option :for={d <- periods()} value={d} selected={@u.days == d}>
                {gettext("Last %{count} days", count: d)}
              </option>
            </select>
          </label>
          <label class="flex flex-col gap-1 text-xs text-base-content/60">
            {gettext("Key")}
            <select name="key" class="select select-sm min-w-48">
              <option value="" selected={is_nil(@u.key)}>{gettext("All keys")}</option>
              <option :for={{uuid, name} <- @u.key_options} value={uuid} selected={@u.key == uuid}>{name}</option>
            </select>
          </label>
        </form>
        <div class="join ml-auto" role="group" aria-label={gettext("What the charts show")}>
          <.link
            :for={metric <- metrics()}
            patch={Paths.api_keys_usage(days: @u.days, key: @u.key, metric: metric)}
            class={["join-item btn btn-sm", if(@u.metric == metric, do: "btn-primary", else: "btn-ghost")]}
            aria-current={@u.metric == metric && "true"}
          >
            {metric_label(metric)}
          </.link>
        </div>
      </div>

      <p :if={@u.rows == []} class="text-sm text-base-content/60">
        {gettext("Nothing yet in the last %{count} days.", count: @u.days)}
      </p>

      <%!-- The period's figures, each against the one before it. --%>
      <div class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-6 gap-2" id="usage-figures">
        <div :for={{label, field, fmt} <- tiles()} class="rounded-box border border-base-200 bg-base-100 p-3">
          <div class="text-xs text-base-content/60">{label}</div>
          <div class={["text-2xl font-bold tabular-nums", field in [:errors, :denied] and Map.fetch!(@u.now, field) > 0 && "text-warning"]}>
            {fmt.(Map.fetch!(@u.now, field))}
          </div>
          <.change now={Map.fetch!(@u.now, field)} before={Map.fetch!(@u.before, field)} worse_up={field in [:errors, :denied]} />
        </div>
      </div>

      <%!-- The figure per day, a part per key (all keys) or per project
           (one key), each in its colour. --%>
      <section class="card bg-base-100 border border-base-200 shadow-sm pk-hours-viz" id="usage-main">
        <div class="card-body p-4 gap-3">
          <div class="flex flex-wrap items-center justify-between gap-2">
            <h3 class="text-sm font-semibold">
              {if @u.key,
                do: gettext("%{metric} per day, by project", metric: metric_label(@u.metric)),
                else: gettext("%{metric} per day, by key", metric: metric_label(@u.metric))}
            </h3>
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
      <section :if={@u.now.errors > 0} class="card bg-base-100 border border-base-200 shadow-sm" id="usage-failures">
        <div class="card-body p-4 gap-3">
          <div class="flex flex-wrap items-center justify-between gap-2">
            <h3 class="text-sm font-semibold">{gettext("Failed requests per day")}</h3>
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
          slots={if @u.key, do: %{}, else: @u.slots}
        />
        <.breakdown
          id="usage-by-project"
          title={gettext("By project")}
          rows={@u.by_project}
          metric={@u.metric}
          slots={if @u.key, do: @u.slots, else: %{}}
        />
      </div>

      <%!-- Where the reported work went: tasks only (work reported on a
           project as a whole is in the figures above, not here). --%>
      <section class="card bg-base-100 border border-base-200 shadow-sm" id="usage-by-task">
        <div class="card-body p-4 gap-2">
          <h3 class="text-sm font-semibold">{gettext("Tasks the reported work went to")}</h3>
          <p :if={@u.by_task == []} class="text-sm text-base-content/50">
            {gettext("No tokens, cost or AI time reported on a task in this period.")}
          </p>
          <div :if={@u.by_task != []} class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>{gettext("Task")}</th>
                  <th>{gettext("Project")}</th>
                  <th class="text-right">{gettext("AI cost")}</th>
                  <th class="text-right">{gettext("AI tokens")}</th>
                  <th class="text-right">{gettext("AI time")}</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={t <- @u.by_task}>
                  <td class="max-w-72">
                    <.link :if={t.href} navigate={t.href} class="link link-hover">
                      <span :if={t.ref} class="font-mono text-xs text-base-content/50 mr-1">{t.ref}</span>{t.title}
                    </.link>
                    <span :if={!t.href} class="text-base-content/50">{gettext("(deleted task)")}</span>
                  </td>
                  <td class="text-base-content/70">{t.project_name}</td>
                  <td class="text-right tabular-nums">{Format.cost(t.cost_cents)}</td>
                  <td class="text-right tabular-nums">{Format.tokens(t.tokens)}</td>
                  <td class="text-right tabular-nums">{Format.duration(t.minutes)}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </section>

      <p class="text-xs text-base-content/50">
        {gettext("Requests are counted for every call. Tokens, cost and AI time are what agents report — an agent that does not report shows requests only. Days are UTC.")}
      </p>
    </div>
    """
  end

  # ── pieces ──

  attr(:now, :any, required: true)
  attr(:before, :any, required: true)
  attr(:worse_up, :boolean, default: false)

  # The change against the period before: "+12%", "−3%", "new", or
  # nothing when both are zero. Up is good unless it counts failures.
  defp change(assigns) do
    ~H"""
    <div :if={@now > 0 or @before > 0} class={["text-xs tabular-nums", change_class(@now, @before, @worse_up)]}>
      {change_text(@now, @before)}
      <span class="text-base-content/40">{gettext("vs previous")}</span>
    </div>
    """
  end

  defp change_text(_now, before) when before == 0, do: gettext("new")

  defp change_text(now, before) do
    pct = round((now - before) / before * 100)

    cond do
      pct > 0 -> "+#{pct}%"
      pct < 0 -> "−#{abs(pct)}%"
      true -> "±0%"
    end
  end

  defp change_class(now, before, worse_up) do
    cond do
      now == before -> "text-base-content/50"
      now > before != worse_up -> "text-success"
      true -> "text-warning"
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
  attr(:slots, :map, required: true)

  # One row per key or project: a bar for the switched figure, then every
  # figure in small print.
  defp breakdown(assigns) do
    assigns =
      assign(assigns,
        max: assigns.rows |> Enum.map(&Map.fetch!(&1, assigns.metric)) |> Enum.max(fn -> 0 end)
      )

    ~H"""
    <section class="card bg-base-100 border border-base-200 shadow-sm pk-hours-viz" id={@id}>
      <div class="card-body p-4 gap-2">
        <h3 class="text-sm font-semibold">{@title}</h3>
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
              {ngettext("%{count} request", "%{count} requests", row.requests)}
              <span :if={row.errors > 0} class="text-warning">· {gettext("%{count} failed", count: row.errors)}</span>
              · {Format.tokens(row.tokens)} {gettext("tokens")}
              · {Format.cost(row.cost_cents)}
              · {Format.duration(row.minutes)}
            </div>
          </li>
        </ul>
      </div>
    </section>
    """
  end

  # ── shaping ──

  defp tiles do
    [
      {gettext("Requests"), :requests, &to_string/1},
      {gettext("Failed"), :errors, &to_string/1},
      {gettext("Refused"), :denied, &to_string/1},
      {gettext("AI tokens"), :tokens, &Format.tokens/1},
      {gettext("AI cost"), :cost_cents, &Format.cost/1},
      {gettext("AI time"), :minutes, &Format.duration/1}
    ]
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
