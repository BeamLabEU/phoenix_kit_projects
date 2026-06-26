defmodule PhoenixKitProjects.Web.ProjectsSettingsLive do
  @moduledoc """
  Projects module settings (global, under the core Settings area).

  Two workflow-status defaults:

    * **Default status list** — the entity a project's "Shared default"
      resolves to (`projects_default_status_entity_uuid`). Nothing is
      auto-created; the admin picks it here (or generates a starter list).
    * **Show translated status titles** — the global default for displaying
      status titles in the viewer's locale (each project can override on its
      form; translations are always captured regardless).
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitProjects.Gettext
  use PhoenixKitProjects.Web.Components

  alias PhoenixKitProjects.Activity
  alias PhoenixKitProjects.GanttDisplay
  alias PhoenixKitProjects.Statuses
  alias PhoenixKitProjects.Web.Helpers, as: WebHelpers

  @default_wrapper_class "flex flex-col w-full px-4 py-6 gap-4"

  @impl true
  def mount(_params, session, socket) do
    WebHelpers.maybe_put_locale(session)
    wrapper_class = Map.get(session, "wrapper_class", @default_wrapper_class)
    available? = Statuses.available?()

    {:ok,
     socket
     |> assign(
       page_title: gettext("Project settings"),
       wrapper_class: wrapper_class,
       statuses_available: available?,
       status_entities: if(available?, do: Statuses.list_status_source_entities(), else: []),
       default_status_entity_uuid: Statuses.global_default_status_entity_uuid(),
       use_status_translations: Statuses.global_use_status_translations?(),
       gantt_display: GanttDisplay.read(),
       demo_events: demo_events(),
       demo_connectors: demo_connectors(),
       demo_range: demo_range(),
       # A fixed "today" inside the demo range so the Show-today toggle is visible
       # in the preview.
       demo_today: ~D[2026-01-15],
       # Sub-project expanded by default so the preview shows the roll-up + its
       # children + frame; the chevron toggles it (see `toggle_demo_subproject`).
       demo_expanded: MapSet.new(["buildphase"]),
       subhead_class: "text-xs font-semibold uppercase tracking-wide text-base-content/60"
     )
     |> WebHelpers.assign_embed_state(session)
     # Reconstruct the acting user across the `live_render` boundary so the
     # status-default activity log records the real actor (not nil) when this
     # settings panel is embedded off-router. No-op on the router path, where
     # core's on_mount hook already set the scope. See `assign_embed_user/2`.
     |> WebHelpers.assign_embed_user(session)}
  end

  @impl true
  def handle_event("select_default_status_entity", %{"entity_uuid" => uuid}, socket) do
    uuid = if uuid in [nil, ""], do: nil, else: uuid
    Statuses.set_default_status_entity(uuid)

    Activity.log("projects.default_status_entity_set",
      actor_uuid: Activity.actor_uuid(socket),
      resource_type: "projects_settings",
      metadata: %{"entity_uuid" => uuid}
    )

    {:noreply,
     socket
     |> assign(default_status_entity_uuid: uuid)
     |> put_flash(:info, gettext("Default status list updated."))}
  end

  def handle_event("generate_default_status_list", _params, socket) do
    case Statuses.create_default_status_entity(actor_uuid: Activity.actor_uuid(socket)) do
      {:ok, entity} ->
        Statuses.set_default_status_entity(entity.uuid)

        Activity.log("projects.status_entity_provisioned",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "projects_settings",
          metadata: %{"entity_name" => entity.name, "scope" => "global_default"}
        )

        {:noreply,
         socket
         |> assign(
           status_entities: Statuses.list_status_source_entities(),
           default_status_entity_uuid: entity.uuid
         )
         |> put_flash(:info, gettext("Default status list created."))}

      {:error, _reason} ->
        {:noreply,
         put_flash(socket, :error, gettext("Could not create the default status list."))}
    end
  end

  def handle_event("toggle_status_translations", _params, socket) do
    new_value = not socket.assigns.use_status_translations

    PhoenixKit.Settings.update_boolean_setting_with_module(
      "projects_use_status_translations",
      new_value,
      "projects"
    )

    Activity.log("projects.status_translations_toggled",
      actor_uuid: Activity.actor_uuid(socket),
      resource_type: "projects_settings",
      metadata: %{"enabled" => new_value}
    )

    {:noreply,
     socket
     |> assign(use_status_translations: new_value)
     |> put_flash(:info, gettext("Settings saved."))}
  end

  # One change to a Gantt-label setting. `_target` names the field that fired, so
  # a slider drag only writes its own key. No flash — the live demo below is the
  # feedback. Re-read so the form + demo reflect the validated/clamped value.
  def handle_event("set_gantt_label", %{"_target" => [field]} = params, socket) do
    GanttDisplay.put(field, params[field])

    Activity.log("projects.gantt_display_changed",
      actor_uuid: Activity.actor_uuid(socket),
      resource_type: "projects_settings",
      metadata: %{"field" => field, "value" => params[field]}
    )

    {:noreply, assign(socket, gantt_display: GanttDisplay.read())}
  end

  def handle_event("set_gantt_label", _params, socket), do: {:noreply, socket}

  # Flip one boolean display toggle (progress / arrows / today / tiny markers).
  def handle_event("toggle_gantt_flag", %{"field" => field}, socket) do
    new_value = not current_flag(socket.assigns.gantt_display, field)
    GanttDisplay.put_flag(field, new_value)

    Activity.log("projects.gantt_display_changed",
      actor_uuid: Activity.actor_uuid(socket),
      resource_type: "projects_settings",
      metadata: %{"field" => field, "value" => new_value}
    )

    {:noreply, assign(socket, gantt_display: GanttDisplay.read())}
  end

  # Restore every Timeline-chart setting to its default.
  def handle_event("reset_gantt_display", _params, socket) do
    GanttDisplay.reset()

    Activity.log("projects.gantt_display_reset",
      actor_uuid: Activity.actor_uuid(socket),
      resource_type: "projects_settings"
    )

    {:noreply, assign(socket, gantt_display: GanttDisplay.read())}
  end

  # Expand/collapse the demo sub-project (preview only — not a persisted setting).
  def handle_event("toggle_demo_subproject", %{"event-id" => id}, socket) do
    {:noreply, update(socket, :demo_expanded, &PhoenixLiveGantt.toggle_expanded(&1, id))}
  end

  defp current_flag(display, "show_progress"), do: display.show_progress
  defp current_flag(display, "show_connectors"), do: display.show_connectors
  defp current_flag(display, "show_today"), do: display.show_today
  defp current_flag(display, "tiny_markers"), do: display.tiny_markers
  defp current_flag(display, "avoid_collisions"), do: display.avoid_collisions
  defp current_flag(_display, _field), do: false

  # ── Gantt demo data — deliberately exercises the chart's range of pieces so
  # the preview shows how every setting lands: a sub-project (roll-up + children
  # + frame), a too-small-to-see task (the triangle marker), a milestone diamond,
  # a corner badge, varied progress, and normal / critical / labeled / backward-
  # invalid dependency arrows. ─────────────────────────────────────────────
  defp demo_events do
    [
      %PhoenixLiveGantt.Task{
        id: "discovery",
        title: gettext("Discovery"),
        start: ~D[2026-01-05],
        end: ~D[2026-01-09],
        color: "bg-primary",
        progress_pct: 100
      },
      # Sub-project parent: nil dates → rolls up to span its children.
      %PhoenixLiveGantt.Task{
        id: "buildphase",
        title: gettext("Build phase"),
        start: nil,
        end: nil,
        color: "bg-warning"
      },
      %PhoenixLiveGantt.Task{
        id: "frontend",
        title: gettext("Frontend"),
        start: ~D[2026-01-09],
        end: ~D[2026-01-13],
        color: "bg-warning",
        progress_pct: 70,
        extra: %{parent_id: "buildphase"}
      },
      %PhoenixLiveGantt.Task{
        id: "backend",
        title: gettext("Backend"),
        start: ~D[2026-01-13],
        end: ~D[2026-01-18],
        color: "bg-warning",
        progress_pct: 40,
        extra: %{parent_id: "buildphase"}
      },
      %PhoenixLiveGantt.Task{
        id: "review",
        title: gettext("Review"),
        start: ~D[2026-01-18],
        end: ~D[2026-01-21],
        color: "bg-info",
        progress_pct: 0,
        extra: %{badges: [%{content: "2", corner: :top_right, color: "bg-error"}]}
      },
      # Two-hour task → renders ~sub-pixel at week zoom → the too-small marker.
      %PhoenixLiveGantt.Task{
        id: "standup",
        title: gettext("Standup"),
        start: ~N[2026-01-21 09:00:00],
        end: ~N[2026-01-21 11:00:00],
        color: "bg-accent"
      },
      %PhoenixLiveGantt.Task{
        id: "launch",
        title: gettext("Launch"),
        start: ~D[2026-01-26],
        end: ~D[2026-01-26],
        color: "bg-success"
      }
    ]
  end

  defp demo_connectors do
    [
      %{from: "discovery", to: "buildphase"},
      %{from: "frontend", to: "backend"},
      %{from: "buildphase", to: "review", critical: true},
      %{from: "review", to: "launch", label: gettext("2d")},
      # Finish-to-finish into review's RIGHT side, which already has two outgoing
      # arrows — so that side carries both incoming and outgoing traffic, the case
      # the "Arrow attachment" setting actually reshapes.
      %{from: "backend", to: "review", type: :ff},
      # Backward / impossible: review → discovery, but discovery is far earlier →
      # drawn dashed in the invalid style.
      %{from: "review", to: "discovery"}
    ]
  end

  defp demo_range, do: Date.range(~D[2026-01-03], ~D[2026-01-28])

  # ── Form option lists ───────────────────────────────────────────
  defp position_options do
    [
      {gettext("None — clean bars"), "none"},
      {gettext("Inside the bar"), "inside"},
      {gettext("Beside the bar"), "outside"},
      {gettext("Inside, only where it fits"), "fit"},
      {gettext("Watermark (big italic beside)"), "watermark"}
    ]
  end

  defp side_options do
    [
      {gettext("Auto"), "auto"},
      {gettext("Left / start"), "left"},
      {gettext("Right / end"), "right"}
    ]
  end

  defp overflow_options do
    [
      {gettext("Truncate (…)"), "truncate"},
      {gettext("Clip"), "clip"},
      {gettext("Let it overflow"), "visible"}
    ]
  end

  defp row_height_options do
    [
      {gettext("Compact"), "compact"},
      {gettext("Normal"), "normal"},
      {gettext("Comfortable"), "comfortable"}
    ]
  end

  defp attach_mode_options do
    [
      {gettext("Smart"), "smart"},
      {gettext("Split (in / out)"), "type_zoned"},
      {gettext("Centered"), "center"}
    ]
  end

  # One boolean display toggle (a checkbox that flips its global setting).
  attr(:field, :string, required: true)
  attr(:label, :string, required: true)
  attr(:on, :boolean, required: true)

  defp gantt_toggle(assigns) do
    ~H"""
    <label class="flex items-center gap-2 cursor-pointer">
      <input
        type="checkbox"
        class="checkbox checkbox-sm"
        checked={@on}
        phx-click="toggle_gantt_flag"
        phx-value-field={@field}
      />
      <span class="text-sm">{@label}</span>
    </label>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class={@wrapper_class}>
      <.page_header
        title={gettext("Project settings")}
        description={gettext("Defaults for the projects module.")}
      />

      <div class="card bg-base-100 shadow">
        <div class="card-body gap-4">
          <h2 class="card-title text-base">{gettext("Workflow statuses")}</h2>

          <p :if={not @statuses_available} class="text-xs text-base-content/50">
            {gettext("The entities module is not enabled, so workflow statuses are currently unavailable.")}
          </p>

          <%!-- Default status list: the entity a project's "Shared default"
               draws from. Pick any entity, or generate a starter list. --%>
          <form
            :if={@statuses_available}
            phx-change="select_default_status_entity"
            class="flex flex-col gap-2"
          >
            <.select
              name="entity_uuid"
              label={gettext("Default status list")}
              value={@default_status_entity_uuid}
              options={@status_entities}
              prompt={gettext("None")}
            />
            <button
              type="button"
              phx-click="generate_default_status_list"
              phx-disable-with={gettext("Generating…")}
              class="btn btn-ghost btn-sm gap-1 self-start"
            >
              <.icon name="hero-sparkles" class="w-4 h-4" />
              {gettext("Generate default")}
            </button>
          </form>

          <label :if={@statuses_available} class="flex items-start gap-3 cursor-pointer">
            <input
              type="checkbox"
              class="checkbox checkbox-sm mt-0.5"
              checked={@use_status_translations}
              phx-click="toggle_status_translations"
            />
            <span class="flex flex-col">
              <span class="text-sm font-medium">
                {gettext("Show translated status titles by default")}
              </span>
              <span class="text-xs text-base-content/60">
                {gettext(
                  "When on, status titles display in the viewer's language where a translation exists. Each project can override this on its form. Translations are always saved regardless."
                )}
              </span>
            </span>
          </label>
        </div>
      </div>

      <%!-- Whole Gantt/Timeline appearance + a live preview. Each control writes
           one global setting (via GanttDisplay); the demo re-renders from the same
           settings so the admin sees the effect immediately. --%>
      <div class="card bg-base-100 shadow">
        <div class="card-body gap-5">
          <div class="flex items-start justify-between gap-4">
            <h2 class="card-title text-base">{gettext("Timeline chart")}</h2>
            <button
              type="button"
              class="btn btn-ghost btn-xs"
              phx-click="reset_gantt_display"
              data-confirm={gettext("Reset all Timeline chart settings to their defaults?")}
            >
              {gettext("Reset to defaults")}
            </button>
          </div>
          <p class="text-xs text-base-content/60">
            {gettext(
              "How the Gantt/Timeline view looks across every project. The preview below updates as you change these."
            )}
          </p>

          <%!-- Labels. A select per concern; the conditional knobs (alignment /
               overflow / fit / opacity) appear for the chosen style. --%>
          <section class="flex flex-col gap-2">
            <h3 class={@subhead_class}>{gettext("Labels")}</h3>
            <form
              id="gantt-labels-form"
              phx-change="set_gantt_label"
              class="grid gap-3 sm:grid-cols-2 lg:grid-cols-3"
            >
              <.select
                name="label_position"
                label={gettext("Label style")}
                value={to_string(@gantt_display.label_position)}
                options={position_options()}
              />
              <.select
                :if={@gantt_display.label_position in [:inside, :outside, :fit, :watermark]}
                name="label_side"
                label={gettext("Side / alignment")}
                value={to_string(@gantt_display.label_side)}
                options={side_options()}
              />
              <.select
                :if={@gantt_display.label_position == :inside}
                name="label_overflow"
                label={gettext("Overflow")}
                value={to_string(@gantt_display.label_overflow)}
                options={overflow_options()}
              />
              <label :if={@gantt_display.label_position == :fit} class="flex flex-col gap-1">
                <span class="text-sm font-medium">
                  {gettext("Fit threshold")}: {round(@gantt_display.label_fit_ratio * 100)}%
                </span>
                <input
                  type="range"
                  name="label_fit_ratio"
                  min="0"
                  max="1"
                  step="0.05"
                  value={@gantt_display.label_fit_ratio}
                  phx-debounce="150"
                  class="range range-sm"
                />
              </label>
              <label :if={@gantt_display.label_position == :watermark} class="flex flex-col gap-1">
                <span class="text-sm font-medium">
                  {gettext("Opacity")}: {round(@gantt_display.label_watermark_opacity * 100)}%
                </span>
                <input
                  type="range"
                  name="label_watermark_opacity"
                  min="0"
                  max="1"
                  step="0.05"
                  value={@gantt_display.label_watermark_opacity}
                  phx-debounce="150"
                  class="range range-sm"
                />
              </label>
            </form>
          </section>

          <%!-- Bars --%>
          <section class="flex flex-col gap-2">
            <h3 class={@subhead_class}>{gettext("Bars")}</h3>
            <form
              id="gantt-bars-form"
              phx-change="set_gantt_label"
              class="grid gap-3 sm:grid-cols-2 lg:grid-cols-3"
            >
              <.select
                name="row_height"
                label={gettext("Row height")}
                value={to_string(@gantt_display.row_height_choice)}
                options={row_height_options()}
              />
              <label class="flex flex-col gap-1">
                <span class="text-sm font-medium">
                  {gettext("Minimum bar width")}: {@gantt_display.min_bar_px}px
                </span>
                <input
                  type="range"
                  name="min_bar_px"
                  min="0"
                  max={GanttDisplay.min_bar_max()}
                  step="1"
                  value={@gantt_display.min_bar_px}
                  phx-debounce="150"
                  class="range range-sm"
                />
                <span class="text-xs text-base-content/60">
                  {gettext("Floor short bars so they stay visible (0 = true duration).")}
                </span>
              </label>
            </form>
          </section>

          <%!-- Show. Checkboxes (separate `phx-click` — an unchecked box isn't
               submitted in a phx-change form). --%>
          <section class="flex flex-col gap-2">
            <h3 class={@subhead_class}>{gettext("Show")}</h3>
            <div class="flex flex-wrap gap-x-6 gap-y-2">
              <.gantt_toggle
                field="show_progress"
                label={gettext("Progress fill")}
                on={@gantt_display.show_progress}
              />
              <.gantt_toggle
                field="show_connectors"
                label={gettext("Dependency arrows")}
                on={@gantt_display.show_connectors}
              />
              <.gantt_toggle
                field="show_today"
                label={gettext("Today line")}
                on={@gantt_display.show_today}
              />
              <.gantt_toggle
                field="tiny_markers"
                label={gettext("Too-small-task markers")}
                on={@gantt_display.tiny_markers}
              />
            </div>
          </section>

          <%!-- Dependency arrows — only relevant when arrows are shown. --%>
          <section :if={@gantt_display.show_connectors} class="flex flex-col gap-2">
            <h3 class={@subhead_class}>{gettext("Dependency arrows")}</h3>
            <div class="flex flex-wrap items-end gap-x-6 gap-y-3">
              <.gantt_toggle
                field="avoid_collisions"
                label={gettext("Route around bars")}
                on={@gantt_display.avoid_collisions}
              />
              <form id="gantt-deps-form" phx-change="set_gantt_label" class="min-w-48">
                <.select
                  name="bus_attach_mode"
                  label={gettext("Arrow attachment")}
                  value={to_string(@gantt_display.bus_attach_mode)}
                  options={attach_mode_options()}
                />
              </form>
            </div>
          </section>

          <%!-- Full-width live preview (sample tasks + a milestone). `enable_hooks`
               makes the bars/diamonds interactive — click one to open its popover,
               same as a real timeline. --%>
          <div class="border border-base-200 rounded-lg overflow-hidden">
            <PhoenixLiveGantt.gantt
              id="gantt-settings-demo"
              events={@demo_events}
              connectors={@demo_connectors}
              date_range={@demo_range}
              zoom={:week}
              today={@demo_today}
              expanded={@demo_expanded}
              on_toggle_expand="toggle_demo_subproject"
              enable_hooks={true}
              show_today={@gantt_display.show_today}
              show_today_edge={false}
              show_edge_indicators={false}
              show_progress={@gantt_display.show_progress}
              show_connectors={@gantt_display.show_connectors}
              tiny_bar_px={@gantt_display.tiny_bar_px}
              min_bar_px={@gantt_display.min_bar_px}
              row_height={@gantt_display.row_height}
              avoid_collisions={@gantt_display.avoid_collisions}
              bus_attach_mode={@gantt_display.bus_attach_mode}
              label_position={@gantt_display.label_position}
              label_side={@gantt_display.label_side}
              label_overflow={@gantt_display.label_overflow}
              label_fit_ratio={@gantt_display.label_fit_ratio}
              label_watermark_opacity={@gantt_display.label_watermark_opacity}
              class="max-h-80"
            />
          </div>
        </div>
      </div>
    </div>
    """
  end
end
