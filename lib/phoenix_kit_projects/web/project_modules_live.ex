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
  alias PhoenixKitProjects.{Authz, Extensions, Features, L10n, Labels, Paths, Projects}
  alias PhoenixKitProjects.PubSub, as: ProjectsPubSub
  alias PhoenixKitProjects.Schemas.Label
  alias PhoenixKitProjects.Schemas.Project
  alias PhoenixKitProjects.Web.Crumbs
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
      |> assign(
        wrapper_class: Map.get(session, "wrapper_class", @default_wrapper_class),
        embedded_in_form: Map.get(session, "embedded_in_form", false)
      )

    with %Project{} = project <- Projects.get_project(id) || :not_found,
         true <- allowed?(socket, project) || :forbidden do
      if connected?(socket) do
        ProjectsPubSub.subscribe(ProjectsPubSub.topic_project(project.uuid))
      end

      {:ok,
       socket
       |> assign(
         # Trail: Admin Panel / Projects / <parents…> / <project> / Modules —
         # the project is a linked crumb, the sub-page the leaf (see `Web.Crumbs`).
         page_title: gettext("Modules"),
         page_section: gettext("Projects"),
         page_section_path: Paths.projects(),
         page_crumbs: Crumbs.project(project, L10n.current_content_lang()),
         project: project
       )
       |> load_panel()}
    else
      :not_found ->
        refuse(socket, gettext("Project not found."))

      :forbidden ->
        refuse(
          socket,
          gettext("You don't have permission to manage this project's modules.")
        )
    end
  end

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

  # As a PAGE, a refusal navigates away with a flash. As a SECTION inside
  # the edit form it must not: a redirect from a child LiveView takes the
  # whole host page with it, so one panel the viewer can't have would
  # bounce them out of editing the project's name. Embedded, it simply
  # renders nothing — the host already decided whether to show it, and the
  # gate here is the backstop.
  defp refuse(socket, message) do
    # Every assign load_panel/1 would have set: with no project the
    # template short-circuits, but HEEx still needs the keys to exist.
    socket =
      assign(socket,
        project: nil,
        extensions: [],
        flag_groups: [],
        presets: [],
        labels: [],
        labels_on: false,
        label_colors: [],
        portal: nil,
        board_exposure: 0
      )

    if socket.assigns.embedded_in_form do
      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, message)
       |> WebHelpers.close_or_navigate(Paths.projects())}
    end
  end

  # Fallback for an embed session without "id".

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
      presets: Features.presets(),
      labels: Labels.list_for_project(project.uuid),
      labels_on: Features.on?(project, "labels"),
      label_colors: Label.colors(),
      portal: PhoenixKitProjects.Portal.get_portal(project.uuid),
      board_exposure: PhoenixKitProjects.Portal.board_exposure_count(project.uuid)
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

  def handle_event("set_portal_access_mode", %{"mode" => mode}, socket) do
    with_authz(socket, fn ->
      do_set_access_mode(socket, mode)
    end)
  end

  def handle_event("set_portal_slug", %{"slug" => slug}, socket) do
    with_authz(socket, fn -> do_set_slug(socket, slug) end)
  end

  def handle_event("set_portal_participation", params, socket) do
    with_authz(socket, fn -> do_set_participation(socket, params) end)
  end

  def handle_event("rotate_portal_link", _params, socket) do
    with_authz(socket, fn ->
      case PhoenixKitProjects.Portal.rotate_slug(
             socket.assigns.project.uuid,
             actor_uuid: Activity.actor_uuid(socket)
           ) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, gettext("Portal link rotated — the old link no longer works."))
           |> reload()}

        _ ->
          {:noreply, put_flash(socket, :error, gettext("Could not rotate the link."))}
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

  # ── Labels registry (Phase C) — the project-config home manages the
  # label catalog; assignment forms only PICK from it. Gated on the
  # labels flag (the section hides AND the events refuse when off).

  def handle_event("add_label", %{"name" => name} = params, socket) do
    with_authz(socket, fn -> do_add_label(name, params, socket) end)
  end

  def handle_event("delete_label", %{"uuid" => uuid}, socket) do
    with_authz(socket, fn -> do_delete_label(uuid, socket) end)
  end

  defp do_delete_label(uuid, socket) do
    with true <- socket.assigns.labels_on,
         %{} = label <- Enum.find(socket.assigns.labels, &(&1.uuid == uuid)),
         :ok <- Labels.delete(label, actor_uuid: Activity.actor_uuid(socket)) do
      {:noreply, socket |> reload() |> put_flash(:info, gettext("Label removed."))}
    else
      false ->
        {:noreply,
         put_flash(socket, :error, gettext("This feature is turned off for this project."))}

      _ ->
        {:noreply, socket}
    end
  end

  defp do_add_label(name, params, socket) do
    if socket.assigns.labels_on do
      case Labels.create(
             socket.assigns.project,
             %{name: name, color: params["color"] || "badge-neutral"},
             actor_uuid: Activity.actor_uuid(socket)
           ) do
        {:ok, _} ->
          {:noreply, socket |> reload() |> put_flash(:info, gettext("Label added."))}

        {:error, %Ecto.Changeset{} = changeset} ->
          msg =
            case changeset.errors[:name] do
              {m, _} -> gettext("Label name %{problem}.", problem: m)
              _ -> gettext("Could not add the label.")
            end

          {:noreply, put_flash(socket, :error, msg)}
      end
    else
      {:noreply,
       put_flash(socket, :error, gettext("This feature is turned off for this project."))}
    end
  end

  # Events re-check authorization — this page writes configuration.
  defp do_set_access_mode(socket, mode) do
    project = socket.assigns.project

    # `publish_existing: false` is not a default to be lazy about — it IS
    # the guard. Tasks flagged `public` were flagged for whoever holds the
    # link; putting them on the open web is a separate decision, taken
    # per task afterwards.
    case PhoenixKitProjects.Portal.set_access_mode(project.uuid, mode,
           actor_uuid: Activity.actor_uuid(socket),
           slug: suggested_slug(mode, project)
         ) do
      {:ok, _portal} ->
        {:noreply,
         socket
         |> put_flash(:info, access_mode_flash(mode))
         |> reload()}

      {:error, _} ->
        {:noreply,
         put_flash(socket, :error, gettext("Could not change who can reach the portal."))}
    end
  end

  defp do_set_slug(socket, slug) do
    case PhoenixKitProjects.Portal.set_access_mode(socket.assigns.project.uuid, "public",
           slug: String.trim(slug),
           actor_uuid: Activity.actor_uuid(socket)
         ) do
      {:ok, _portal} ->
        {:noreply, socket |> put_flash(:info, gettext("Board address updated.")) |> reload()}

      {:error, _} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext(
             "That address is taken or not allowed — lowercase letters, numbers and hyphens."
           )
         )}
    end
  end

  defp do_set_participation(socket, params) do
    case PhoenixKitProjects.Portal.set_participation(
           socket.assigns.project.uuid,
           Map.take(params, ["submit_access", "comment_access"]),
           actor_uuid: Activity.actor_uuid(socket)
         ) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, gettext("Participation updated.")) |> reload()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not update participation."))}
    end
  end

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

  def handle_info({:projects, :project_labels_changed, _payload}, socket) do
    # Another session edited the label registry — refresh the panel
    # (ZAI panel round: co-editors saw stale label lists).
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
        <%!-- Inside the edit form this page is a SECTION, not a page: the
             form already names the project and owns the way back, so a
             second title and a second back link would read as a page
             nested in a page. --%>
        <div :if={@embedded_in_form}>
          <h2 class="text-sm font-semibold">{gettext("Modules & features")}</h2>
          <p class="text-xs opacity-60">
            {gettext("Choose what this project uses — from a simple to-do list to a full tracker.")}
          </p>
        </div>

        <.page_header
          :if={not @embedded_in_form}
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
                <div :for={field <- ext.config_schema} class="w-full max-w-xs">
                  <.select
                    :if={field.type == :select}
                    name={"config[#{field.key}]"}
                    value={config_value(row, field)}
                    label={field[:label] || field.key}
                    class="select-sm"
                    prompt={gettext("—")}
                    options={
                      for opt <- select_options(field, config_value(row, field)),
                          do: {opt.label, opt.value}
                    }
                  />
                  <.input
                    :if={field.type != :select}
                    type="text"
                    name={"config[#{field.key}]"}
                    value={config_value(row, field)}
                    label={field[:label] || field.key}
                    class="input-sm"
                  />
                </div>
                <button type="submit" class="btn btn-primary btn-sm" phx-disable-with={gettext("Saving…")}>
                  {gettext("Save")}
                </button>
              </form>

              <%!-- Portal: the private link + rotate (revoke). The slug IS
              the access grant, so rotation is the kill switch. --%>
              <div
                :if={ext.key == "portal" and enabled and @portal}
                class="flex flex-col gap-3 border-t border-base-200 pt-3"
              >
                <div class="flex flex-wrap items-center gap-2">
                  <code class="rounded bg-base-200 px-2 py-1 text-xs">
                    /portal/{@portal.slug}
                  </code>
                  <button
                    type="button"
                    phx-click="rotate_portal_link"
                    data-confirm={gettext("Rotate the portal link? The current link stops working immediately.")}
                    class="btn btn-ghost btn-sm gap-1"
                  >
                    <span class="hero-arrow-path w-4 h-4"></span> {gettext("Rotate link")}
                  </button>
                </div>

                <%!-- Who may reach the page at all. Three radios rather than
                     a pair of switches: "secret slug that search engines
                     index" and "human-readable address where possession is
                     the authorization" are both nonsense, and checkboxes
                     let an admin build them. --%>
                <div>
                  <h4 class="mb-1 text-xs font-semibold uppercase opacity-50">
                    {gettext("Who can reach it")}
                  </h4>
                  <div class="flex flex-col gap-2">
                    <label
                      :for={{mode, title, hint} <- access_mode_choices()}
                      class="flex cursor-pointer items-start gap-2 rounded-lg border border-base-300 p-2 transition-colors has-[:checked]:border-primary has-[:checked]:bg-primary/5"
                    >
                      <input
                        type="radio"
                        name="portal_access_mode"
                        value={mode}
                        checked={@portal.access_mode == mode}
                        phx-click="set_portal_access_mode"
                        phx-value-mode={mode}
                        data-confirm={access_mode_confirm(mode, @portal, @board_exposure)}
                        class="radio radio-primary radio-xs mt-0.5 shrink-0"
                      />
                      <span class="min-w-0">
                        <span class="block text-sm font-medium">{title}</span>
                        <span class="block text-xs opacity-60">{hint}</span>
                      </span>
                    </label>
                  </div>
                </div>

                <%!-- A public board's address is a NAME people type and
                     read, so it is chosen rather than generated. --%>
                <form
                  :if={@portal.access_mode == "public"}
                  phx-submit="set_portal_slug"
                  class="flex flex-wrap items-end gap-2"
                >
                  <label class="fieldset grow max-w-xs">
                    <span class="fieldset-legend text-xs opacity-70 mb-1">{gettext("Board address")}</span>
                    <input
                      type="text"
                      name="slug"
                      value={@portal.slug}
                      class="input input-sm font-mono"
                    />
                  </label>
                  <button type="submit" class="btn btn-sm">{gettext("Rename")}</button>
                </form>

                <div>
                  <h4 class="mb-1 text-xs font-semibold uppercase opacity-50">
                    {gettext("Who can take part")}
                  </h4>
                  <form phx-change="set_portal_participation" class="flex flex-wrap gap-3">
                    <label class="fieldset">
                      <span class="fieldset-legend text-xs opacity-70 mb-1">{gettext("Submit issues")}</span>
                      <select name="submit_access" class="select select-sm">
                        <option
                          :for={{value, label} <- participation_choices()}
                          value={value}
                          selected={@portal.submit_access == value}
                        >{label}</option>
                      </select>
                    </label>
                    <label class="fieldset">
                      <span class="fieldset-legend text-xs opacity-70 mb-1">{gettext("Comment")}</span>
                      <select name="comment_access" class="select select-sm">
                        <option
                          :for={{value, label} <- participation_choices()}
                          value={value}
                          selected={@portal.comment_access == value}
                        >{label}</option>
                      </select>
                    </label>
                  </form>
                  <p :if={@portal.comment_access == "anyone"} class="mt-1 text-xs opacity-60">
                    {PhoenixKitProjects.Portal.comment_access_note()}
                  </p>
                </div>
              </div>
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

      <%!-- Labels registry (Phase C): the config home for the project's
           label catalog. Renders only while the labels flag is on. --%>
      <section :if={@labels_on} class="card bg-base-100 border border-base-200">
        <div class="card-body gap-3">
          <h2 class="card-title text-base">{gettext("Labels")}</h2>
          <p class="text-xs text-base-content/60">
            {gettext("Tags tasks can wear — pick them on the task form.")}
          </p>

          <div :if={@labels != []} class="flex flex-wrap gap-2">
            <span
              :for={label <- @labels}
              class={["badge gap-1", label.color]}
            >
              {label.name}
              <button
                type="button"
                phx-click="delete_label"
                phx-value-uuid={label.uuid}
                data-confirm={gettext("Remove the \"%{name}\" label from this project?", name: label.name)}
                aria-label={gettext("Remove %{name}", name: label.name)}
                class="cursor-pointer opacity-60 hover:opacity-100"
              >
                <.icon name="hero-x-mark" class="w-3 h-3" />
              </button>
            </span>
          </div>

          <form phx-submit="add_label" class="flex items-end gap-2">
            <label class="fieldset flex-1 max-w-52">
              <span class="fieldset-legend text-xs opacity-70 mb-1">{gettext("New label")}</span>
              <input
                type="text"
                name="name"
                required
                maxlength="60"
                class="input input-sm"
                placeholder={gettext("e.g. frontend")}
              />
            </label>
            <label class="fieldset w-40">
              <span class="fieldset-legend text-xs opacity-70 mb-1">{gettext("Color")}</span>
              <select name="color" class="select select-sm">
                <option :for={color <- @label_colors} value={color}>
                  {String.replace_prefix(color, "badge-", "")}
                </option>
              </select>
            </label>
            <button type="submit" phx-disable-with={gettext("Adding…")} class="btn btn-primary btn-sm">
              {gettext("Add")}
            </button>
          </form>
        </div>
      </section>
    </div>
    """
  end

  defp config_value(nil, field), do: field[:default] || ""
  defp config_value(row, field), do: Map.get(row.config || %{}, field.key, field[:default] || "")

  # Option resolution moved to the shared Extensions.ConfigOptions when
  # the creation form grew inline extension config.
  defp select_options(field, current), do: Extensions.ConfigOptions.resolve(field, current)

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

  # ── Portal access presentation ──────────────────────────────────

  defp access_mode_choices do
    [
      {"link", gettext("Anyone with the link"),
       gettext("The address is the key. Not indexed, and rotating it revokes access.")},
      {"members", gettext("Signed-in users"),
       gettext("Anyone with an account on this site. Still not indexed.")},
      {"public", gettext("Anyone on the internet"),
       gettext("A findable, indexable board with an address you choose.")}
    ]
  end

  defp participation_choices do
    [
      {"anyone", gettext("Anyone")},
      {"members", gettext("Signed-in users")},
      {"nobody", gettext("Nobody")}
    ]
  end

  # The one-way-door warning. Going public is the only transition that can
  # expose work retroactively, so it is the only one that stops to say so —
  # and it names the number, because "some tasks" is not a thing anyone can
  # make a decision about.
  defp access_mode_confirm("public", portal, exposure) when portal.access_mode != "public" do
    base =
      gettext(
        "Make this board public? It gets a findable address and search engines may index it."
      )

    if exposure > 0 do
      base <>
        "\n\n" <>
        ngettext(
          "%{count} task is currently marked public for link-holders. It will NOT be published to the board — you publish tasks to a public board one at a time.",
          "%{count} tasks are currently marked public for link-holders. They will NOT be published to the board — you publish tasks to a public board one at a time.",
          exposure,
          count: exposure
        )
    else
      base
    end
  end

  defp access_mode_confirm("link", portal, _exposure) when portal.access_mode == "public" do
    gettext(
      "Go back to a private link? The current public address stops working and cannot be reused as a secret."
    )
  end

  defp access_mode_confirm(_mode, _portal, _exposure), do: nil

  defp access_mode_flash("public"),
    do: gettext("This board is public. Publish individual tasks to put them on it.")

  defp access_mode_flash("members"), do: gettext("Signed-in users can now reach this portal.")
  defp access_mode_flash(_), do: gettext("The portal is back to a private link.")

  # Only public boards need a chosen address; the other modes mint their own
  # unguessable one.
  defp suggested_slug("public", project) do
    PhoenixKitProjects.Schemas.Portal.suggest_public_slug(project.name)
  end

  defp suggested_slug(_mode, _project), do: nil
end
