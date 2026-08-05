defmodule PhoenixKitProjects.Web.ProjectModulesLive do
  @moduledoc """
  The per-project **Modules & Features** panel — the hub's control surface.

  Level 1: extension enablement (which capabilities this project has) with
  per-instance config forms driven by each extension's `config_schema`.
  Level 2: feature flags, grouped by owning extension, with the dependency
  matrix rendered disable-and-explain (a flag whose `requires` are off shows
  WHY instead of silently not working). Plus the preset row.

  Authorization: mount gates on `Authz.can?(scope, project, :manage_modules)`
  — v1 the admin gate; deepens with members (Step 5). Every event handler
  re-checks (events must not trust a stale mount — the standing convention
  is mount-gating, but this page WRITES config, so it gets the stricter
  shape enforcement threading will roll out module-wide).

  Embeddable like every LV in this module: off-router mount reads
  `session["id"]`; no `handle_params/3`.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitProjects.Gettext
  use PhoenixKitProjects.Web.Components

  alias PhoenixKitProjects.Activity
  alias PhoenixKitProjects.{Authz, Extensions, Features, L10n, Paths, Projects}
  alias PhoenixKitProjects.PubSub, as: ProjectsPubSub
  alias PhoenixKitProjects.Schemas.Project
  alias PhoenixKitProjects.Web.Helpers, as: WebHelpers

  require Logger

  @default_wrapper_class "flex flex-col mx-auto max-w-4xl px-4 py-6 gap-6"

  # ── Mount ───────────────────────────────────────────────────────

  @impl true
  def mount(:not_mounted_at_router, %{"id" => id} = session, socket) do
    WebHelpers.maybe_put_locale(session)
    mount(%{"id" => id}, session, socket)
  end

  def mount(%{"id" => id}, session, socket) do
    WebHelpers.maybe_put_locale(session)

    socket =
      socket
      |> WebHelpers.assign_embed_state(session)
      |> WebHelpers.assign_embed_user(session)
      |> WebHelpers.attach_open_embed_hook()
      |> assign(wrapper_class: Map.get(session, "wrapper_class", @default_wrapper_class))

    with %Project{} = project <- Projects.get_project(id) || :not_found,
         true <- allowed?(socket, project) || :forbidden do
      if connected?(socket) do
        ProjectsPubSub.subscribe(ProjectsPubSub.topic_project(project.uuid))
      end

      {:ok,
       socket
       |> assign(
         page_title:
           gettext("%{name} · Modules",
             name: Project.localized_name(project, L10n.current_content_lang())
           ),
         page_section: gettext("Projects"),
         page_section_path: Paths.projects(),
         project: project
       )
       |> load_panel()}
    else
      :not_found ->
        {:ok,
         socket
         |> assign(project: nil, extensions: [], flag_groups: [], presets: [])
         |> put_flash(:error, gettext("Project not found."))
         |> WebHelpers.close_or_navigate(Paths.projects())}

      :forbidden ->
        {:ok,
         socket
         |> assign(project: nil, extensions: [], flag_groups: [], presets: [])
         |> put_flash(
           :error,
           gettext("You don't have permission to manage this project's modules.")
         )
         |> WebHelpers.close_or_navigate(Paths.projects())}
    end
  end

  # Fallback for an embed session without "id".
  def mount(_params, session, socket) do
    WebHelpers.maybe_put_locale(session)

    {:ok,
     socket
     |> WebHelpers.assign_embed_state(session)
     |> assign(
       wrapper_class: Map.get(session, "wrapper_class", @default_wrapper_class),
       project: nil,
       extensions: [],
       flag_groups: [],
       presets: []
     )
     |> put_flash(:error, gettext("Project not found."))
     |> WebHelpers.close_or_navigate(Paths.projects())}
  end

  defp allowed?(socket, project) do
    Authz.can?(socket.assigns[:phoenix_kit_current_scope], project, :manage_modules)
  end

  # ── Data ────────────────────────────────────────────────────────

  defp load_panel(socket) do
    project = socket.assigns.project
    rows = Extensions.list_rows(project.uuid)
    row_by_key = Map.new(rows, &{{&1.ext_key, &1.instance_key}, &1})

    extensions =
      Enum.map(Extensions.list_types(), fn ext ->
        row = Map.get(row_by_key, {ext.key, "default"})

        %{
          ext: ext,
          row: row,
          available: Extensions.Registry.available?(ext),
          enabled: Extensions.enabled?(project, ext.key)
        }
      end)

    flag_groups =
      Features.catalog_by_extension()
      |> Enum.filter(fn {ext, _flags} -> Extensions.enabled?(project, ext.key) end)
      |> Enum.map(fn {ext, flags} ->
        {ext,
         Enum.map(flags, fn flag ->
           unmet = Enum.reject(flag.requires, &Features.on?(project, &1))

           %{
             flag: flag,
             on: Features.on?(project, flag.key),
             unmet_requires: unmet
           }
         end)}
      end)

    assign(socket,
      extensions: extensions,
      flag_groups: flag_groups,
      presets: Features.presets()
    )
  end

  defp reload(socket) do
    case Projects.get_project(socket.assigns.project.uuid) do
      nil -> socket
      project -> socket |> assign(project: project) |> load_panel()
    end
  end

  # ── Events ──────────────────────────────────────────────────────

  @impl true
  def handle_event("toggle_ext", %{"key" => key}, socket) do
    with_authz(socket, fn ->
      project = socket.assigns.project

      result =
        if Extensions.enabled?(project, key) do
          Extensions.disable(project, key, actor_opts(socket))
        else
          Extensions.enable(project, key, actor_opts(socket))
        end

      case result do
        {:ok, _row} ->
          {:noreply, reload(socket)}

        {:error, :module_disabled} ->
          {:noreply,
           put_flash(socket, :error, gettext("Enable the backing module site-wide first."))}

        {:error, reason} ->
          Logger.warning("[Projects] toggle_ext #{key} failed: #{inspect(reason)}")
          {:noreply, put_flash(socket, :error, gettext("Could not update the module."))}
      end
    end)
  end

  def handle_event("toggle_flag", %{"key" => key}, socket) do
    with_authz(socket, fn ->
      project = socket.assigns.project
      # Toggle the RESOLVED state: what the admin sees is what flips.
      target = not Features.on?(project, key)

      case Features.set_flags(project, %{key => target}, actor_opts(socket)) do
        {:ok, project} ->
          {:noreply, socket |> assign(project: project) |> load_panel()}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Could not update the feature."))}
      end
    end)
  end

  def handle_event("apply_preset", %{"key" => key}, socket) do
    with_authz(socket, fn ->
      case Features.apply_preset(socket.assigns.project, key, actor_opts(socket)) do
        {:ok, project} ->
          {:noreply,
           socket
           |> assign(project: project)
           |> load_panel()
           |> put_flash(:info, gettext("Preset applied."))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Could not apply the preset."))}
      end
    end)
  end

  def handle_event("save_config", %{"ext" => key} = params, socket) do
    with_authz(socket, fn ->
      config = Map.get(params, "config", %{})

      case Extensions.update_config(socket.assigns.project, key, config, actor_opts(socket)) do
        {:ok, _row} ->
          {:noreply, socket |> reload() |> put_flash(:info, gettext("Settings saved."))}

        {:error, :not_enabled} ->
          {:noreply, put_flash(socket, :error, gettext("Enable the module first."))}

        {:error, reason} ->
          Logger.warning("[Projects] save_config #{key} failed: #{inspect(reason)}")
          {:noreply, put_flash(socket, :error, gettext("Could not save the settings."))}
      end
    end)
  end

  # Events re-check authorization — this page writes configuration.
  defp with_authz(socket, fun) do
    if socket.assigns.project && allowed?(socket, socket.assigns.project) do
      fun.()
    else
      {:noreply,
       put_flash(
         socket,
         :error,
         gettext("You don't have permission to manage this project's modules.")
       )}
    end
  end

  defp actor_opts(socket), do: [actor_uuid: Activity.actor_uuid(socket)]

  # ── PubSub ──────────────────────────────────────────────────────

  @impl true
  def handle_info({:projects, event, _payload}, socket)
      when event in [:project_modules_changed, :project_features_changed] do
    {:noreply, reload(socket)}
  end

  def handle_info({:projects, _event, _payload}, socket), do: {:noreply, socket}
  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── Render ──────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class={@wrapper_class}>
      <%= if @project do %>
        <.page_header
          title={gettext("Modules & features")}
          description={
            gettext("Choose what %{name} uses — from a simple to-do list to a full tracker.",
              name: Project.localized_name(@project, L10n.current_content_lang())
            )
          }
        >
          <:back_link>
            <.smart_link
              navigate={Paths.project(@project.uuid)}
              emit={{PhoenixKitProjects.Web.ProjectShowLive, %{"id" => @project.uuid}}}
              embed_mode={@embed_mode}
              class="btn btn-ghost btn-sm gap-1"
            >
              <.icon name="hero-arrow-left" class="w-4 h-4" />
              {gettext("Back to project")}
            </.smart_link>
          </:back_link>
        </.page_header>

        <%!-- Presets --%>
        <div class="flex flex-wrap items-center gap-2">
          <span class="text-sm opacity-70">{gettext("Presets:")}</span>
          <button
            :for={preset <- @presets}
            type="button"
            class="btn btn-outline btn-xs"
            phx-click="apply_preset"
            phx-value-key={preset.key}
            phx-disable-with={gettext("Applying…")}
            data-confirm={
              gettext("Apply the \"%{name}\" preset? This overwrites this project's feature toggles.",
                name: preset.name
              )
            }
            title={preset.description}
          >
            {preset.name}
          </button>
        </div>

        <%!-- Level 1 — extensions --%>
        <section class="flex flex-col gap-3">
          <h2 class="text-lg font-semibold">{gettext("Modules")}</h2>
          <div
            :for={%{ext: ext, available: available, enabled: enabled, row: row} <- @extensions}
            class={["card border bg-base-100", (available && "border-base-200") || "border-base-200 opacity-60"]}
          >
            <div class="card-body py-4 gap-3">
              <div class="flex items-start gap-3">
                <.icon name={ext.icon} class="w-6 h-6 mt-0.5 shrink-0 opacity-70" />
                <div class="min-w-0 grow">
                  <div class="flex items-center gap-2">
                    <span class="font-semibold">{ext.name}</span>
                    <span :if={ext.source == PhoenixKitProjects and ext.key == "tasks"} class="badge badge-ghost badge-xs">
                      {gettext("built-in")}
                    </span>
                  </div>
                  <p :if={ext.description} class="text-sm opacity-70">{ext.description}</p>
                  <p :if={not available} class="text-xs text-warning mt-1">
                    {gettext("Unavailable — enable the backing module in Admin › Modules first.")}
                  </p>
                </div>
                <input
                  type="checkbox"
                  class="toggle toggle-primary"
                  checked={enabled}
                  disabled={not available}
                  phx-click="toggle_ext"
                  phx-value-key={ext.key}
                  aria-label={gettext("Toggle %{name}", name: ext.name)}
                />
              </div>

              <%!-- Per-instance config (only while enabled, only with a schema) --%>
              <form
                :if={enabled and ext.config_schema != []}
                id={"ext-config-#{ext.key}"}
                phx-submit="save_config"
                class="flex flex-wrap items-end gap-2 border-t border-base-200 pt-3"
              >
                <input type="hidden" name="ext" value={ext.key} />
                <label :for={field <- ext.config_schema} class="form-control w-full max-w-xs">
                  <span class="label-text text-xs opacity-70 mb-1">{field[:label] || field.key}</span>
                  <input
                    type="text"
                    name={"config[#{field.key}]"}
                    value={config_value(row, field)}
                    class="input input-bordered input-sm"
                  />
                </label>
                <button type="submit" class="btn btn-primary btn-sm" phx-disable-with={gettext("Saving…")}>
                  {gettext("Save")}
                </button>
              </form>
            </div>
          </div>
        </section>

        <%!-- Level 2 — feature flags --%>
        <section :if={@flag_groups != []} class="flex flex-col gap-3">
          <h2 class="text-lg font-semibold">{gettext("Features")}</h2>
          <div :for={{ext, flags} <- @flag_groups} class="card border border-base-200 bg-base-100">
            <div class="card-body py-4 gap-2">
              <h3 class="text-sm font-semibold opacity-70">{ext.name}</h3>
              <div class="grid grid-cols-1 sm:grid-cols-2 gap-x-6 gap-y-2">
                <label
                  :for={%{flag: flag, on: on, unmet_requires: unmet} <- flags}
                  class={["flex items-center justify-between gap-3 py-1", unmet != [] && "opacity-50"]}
                  title={requires_hint(unmet, @flag_groups)}
                >
                  <span class="text-sm">
                    {flag.label}
                    <span :if={unmet != []} class="block text-xs text-warning">
                      {gettext("Requires: %{list}", list: requires_labels(unmet, @flag_groups))}
                    </span>
                  </span>
                  <input
                    type="checkbox"
                    class="toggle toggle-sm"
                    checked={on}
                    disabled={unmet != []}
                    phx-click="toggle_flag"
                    phx-value-key={flag.key}
                    aria-label={gettext("Toggle %{name}", name: flag.label)}
                  />
                </label>
              </div>
            </div>
          </div>
        </section>
      <% end %>
    </div>
    """
  end

  defp config_value(nil, field), do: field[:default] || ""
  defp config_value(row, field), do: Map.get(row.config || %{}, field.key, field[:default] || "")

  defp requires_labels(unmet, flag_groups) do
    labels =
      for {_ext, flags} <- flag_groups, %{flag: flag} <- flags, flag.key in unmet, do: flag.label

    case labels do
      [] -> Enum.join(unmet, ", ")
      found -> Enum.join(found, ", ")
    end
  end

  defp requires_hint([], _), do: nil

  defp requires_hint(unmet, flag_groups),
    do: gettext("Turn on %{list} first.", list: requires_labels(unmet, flag_groups))
end
