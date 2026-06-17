defmodule PhoenixKitProjects.Web.TemplateFormLive do
  @moduledoc "Create or edit a project template."

  use PhoenixKitWeb, :live_view
  use PhoenixKitAI.Components.AITranslate.Embed
  use Gettext, backend: PhoenixKitProjects.Gettext
  use PhoenixKitProjects.Web.Components

  import PhoenixKitWeb.Components.MultilangForm

  alias PhoenixKitAI.Components.AITranslate.FormGlue
  alias PhoenixKitProjects.{Activity, L10n, Paths, Projects, Statuses}
  alias PhoenixKitProjects.Schemas.Project
  alias PhoenixKitProjects.Web.Helpers, as: WebHelpers

  # Default wrapper class for the standalone admin page. Embedders can
  # override via `live_render(... session: %{"wrapper_class" => "..."})`.
  @default_wrapper_class "flex flex-col mx-auto max-w-xl px-4 py-6 gap-4"

  @impl true
  def mount(params, session, socket) do
    WebHelpers.maybe_put_locale(session)

    wrapper_class = Map.get(session, "wrapper_class", @default_wrapper_class)
    redirect_to = Map.get(session, "redirect_to")
    live_action = WebHelpers.resolve_live_action(socket, session)
    resolved_params = WebHelpers.resolve_action_params(params, session)

    # `apply_action/3` loads the project on `:edit`; runs at the tail of
    # `mount/3` (not `handle_params/3`) so the LV stays embeddable via
    # `live_render`. See dev_docs/embedding_audit.md.
    socket =
      socket
      |> mount_multilang()
      |> assign(
        wrapper_class: wrapper_class,
        embed_redirect_to: redirect_to,
        live_action: live_action
      )
      |> WebHelpers.assign_embed_state(session)
      |> WebHelpers.assign_embed_user(session)
      |> WebHelpers.attach_open_embed_hook()
      |> apply_action(live_action, resolved_params)
      |> assign_status_init()
      |> assign_ai_translate()

    {:ok, socket}
  end

  defp assign_ai_translate(socket) do
    resource = if socket.assigns.live_action == :edit, do: socket.assigns.project, else: nil

    FormGlue.assign_ai_translation(
      socket,
      "template",
      resource,
      PhoenixKitProjects.AITranslateBinding
    )
  end

  # Workflow-status assigns (V125) — a template is a project, so it picks a
  # status-source list its cloned projects inherit. Shared logic via
  # `WorkflowStatusFields` (imported through `use ...Web.Components`).
  defp assign_status_init(socket) do
    available = available?()

    socket
    |> assign(
      statuses_available: available,
      status_entities: if(available, do: entity_options(), else: []),
      status_translation_mode: mode_string(socket.assigns.project),
      status_preview: []
    )
    |> refresh_status_preview()
  end

  defp refresh_status_preview(%{assigns: %{statuses_available: true}} = socket) do
    selected = selected_entity_uuid(socket.assigns.form[:status_entity_uuid])
    assign(socket, status_preview: preview_for(selected))
  end

  defp refresh_status_preview(socket), do: socket

  defp apply_action(socket, :new, _params) do
    project = %Project{is_template: true}

    socket
    |> assign(page_title: gettext("New template"), project: project, live_action: :new)
    |> assign_form(Projects.change_project(project))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case Projects.get_project(id) do
      nil ->
        # Render-safe placeholders for emit mode (see ProjectFormLive
        # for the rationale — in emit mode `close_or_navigate` doesn't
        # navigate, so the LV's render runs and needs these assigns).
        socket
        |> assign(
          page_title: "",
          project: %Project{is_template: true},
          live_action: :edit
        )
        |> assign_form(Projects.change_project(%Project{is_template: true}))
        |> put_flash(:error, gettext("Template not found."))
        |> WebHelpers.close_or_navigate(Paths.templates())

      project ->
        socket
        |> assign(
          page_title:
            gettext("Edit %{name}",
              name: Project.localized_name(project, L10n.current_content_lang())
            ),
          project: project,
          live_action: :edit
        )
        |> assign_form(Projects.change_project(project))
    end
  end

  # Fail-closed catch-all: emit-session lacking `"id"` for :edit lands
  # here. Render placeholders + flash, then close.
  defp apply_action(socket, :edit, _params) do
    socket
    |> assign(
      page_title: "",
      project: %Project{is_template: true},
      live_action: :edit
    )
    |> assign_form(Projects.change_project(%Project{is_template: true}))
    |> put_flash(:error, gettext("Template not found."))
    |> WebHelpers.close_or_navigate(Paths.templates())
  end

  defp assign_form(socket, cs), do: assign(socket, form: to_form(cs))

  @impl true
  def handle_event("switch_language", %{"lang" => lang_code}, socket) do
    {:noreply, handle_switch_language(socket, lang_code)}
  end

  # AI-translate modal events handled by `use ...AITranslate.Embed`.

  def handle_event("validate", %{"project" => attrs} = params, socket) do
    attrs = attrs |> Map.put("is_template", "true") |> merge_attrs(socket)
    cs = socket.assigns.project |> Projects.change_project(attrs) |> Map.put(:action, :validate)
    mode = Map.get(params, "status_translation_mode", socket.assigns.status_translation_mode)

    {:noreply,
     socket
     |> assign_form(cs)
     |> assign(status_translation_mode: mode)
     |> refresh_status_preview()}
  end

  # A template is a project, so it gets the same "Generate default" action (V125).
  def handle_event("generate_default_statuses", _params, socket) do
    case Statuses.create_default_status_entity(actor_uuid: Activity.actor_uuid(socket)) do
      {:ok, entity} ->
        Activity.log("projects.status_entity_provisioned",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "entity",
          resource_uuid: entity.uuid,
          metadata: %{"scope" => "template"}
        )

        cs =
          Ecto.Changeset.put_change(socket.assigns.form.source, :status_entity_uuid, entity.uuid)

        {:noreply,
         socket
         |> assign(status_entities: entity_options())
         |> assign_form(cs)
         |> refresh_status_preview()
         |> put_flash(:info, gettext("Default statuses entity created."))}

      {:error, _reason} ->
        {:noreply,
         put_flash(socket, :error, gettext("Could not create the default statuses entity."))}
    end
  end

  def handle_event("save", %{"project" => attrs} = params, socket) do
    if socket.assigns.ai_in_flight == [] do
      attrs =
        attrs
        |> Map.merge(%{"is_template" => "true", "start_mode" => "immediate"})
        |> merge_attrs(socket)
        |> apply_mode(params, socket.assigns.project)

      save(socket, socket.assigns.live_action, attrs)
    else
      {:noreply,
       put_flash(
         socket,
         :info,
         gettext("Hold on — wait for the translation to finish before saving.")
       )}
    end
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, WebHelpers.close_or_navigate(socket, Paths.templates())}
  end

  # {:ai_translation, ...} events folded into the form by `use ...AITranslate.Embed`.

  # Folds the in-flight secondary-language translation map into `attrs`
  # so the changeset writes both the primary column (when on the
  # primary tab) and the JSONB `translations` map (when on a secondary
  # tab). Mirrors `ProjectFormLive.merge_attrs/2`.
  defp merge_attrs(attrs, socket) do
    in_flight = WebHelpers.in_flight_record(socket, :form, :project)
    WebHelpers.merge_translations_attrs(attrs, in_flight, Project.translatable_fields())
  end

  defp save(socket, :new, attrs) do
    case Projects.create_project(attrs) do
      {:ok, project} ->
        Activity.log("projects.template_created",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "project_template",
          resource_uuid: project.uuid,
          metadata: %{"name" => project.name}
        )

        {:noreply,
         socket
         |> put_flash(:info, gettext("Template created. Add tasks to it now."))
         |> WebHelpers.navigate_after_save(Paths.template(project.uuid),
           kind: :template,
           record: project,
           action: :create,
           # Emit-mode chain: close the form, open the template-show so
           # the user can add tasks (matches the navigate-mode flow).
           next: {PhoenixKitProjects.Web.ProjectShowLive, %{"id" => project.uuid}}
         )}

      {:error, cs} ->
        Activity.log_failed("projects.template_created",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "project_template",
          metadata: %{"name" => Map.get(attrs, "name") || Ecto.Changeset.get_field(cs, :name)}
        )

        {:noreply, assign_form(socket, cs)}
    end
  end

  defp save(socket, :edit, attrs) do
    case Projects.update_project(socket.assigns.project, attrs) do
      {:ok, project} ->
        Activity.log("projects.template_updated",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "project_template",
          resource_uuid: project.uuid,
          metadata: %{"name" => project.name}
        )

        {:noreply,
         socket
         |> put_flash(:info, gettext("Template updated."))
         |> WebHelpers.navigate_after_save(Paths.template(project.uuid),
           kind: :template,
           record: project,
           action: :update
         )}

      {:error, cs} ->
        Activity.log_failed("projects.template_updated",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "project_template",
          resource_uuid: socket.assigns.project.uuid,
          metadata: %{"name" => socket.assigns.project.name}
        )

        {:noreply, assign_form(socket, cs)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class={@wrapper_class}>
      <.page_header title={@page_title}>
        <:back_link>
          <.smart_link
            navigate={Paths.templates()}
            emit={{PhoenixKitProjects.Web.TemplatesLive, %{}}}
            embed_mode={@embed_mode}
            class="link link-hover text-sm"
          >
            <.icon name="hero-arrow-left" class="w-4 h-4 inline" /> {gettext("Templates")}
          </.smart_link>
        </:back_link>
      </.page_header>

      <.form for={@form} id="template-form" phx-change="validate" phx-submit="save" phx-debounce="300" class="flex flex-col gap-4">
        <%!-- Translatable card: name + description with language tabs.
             Wrapper id keys on @current_lang so morphdom re-mounts the
             inputs when the user switches languages — that's what swaps
             primary-column inputs for JSONB-backed secondary inputs.
             Matches `ProjectFormLive`'s shape. --%>
        <div class="card bg-base-100 shadow">
          <.multilang_tabs
            multilang_enabled={@multilang_enabled}
            language_tabs={@language_tabs}
            current_lang={@current_lang}
          />

          <%!-- See `project_form_live.ex` for the spacing rationale. --%>
          <div class="flex items-center gap-3 px-6 -mt-2 py-1 border-b border-base-200">
            <.ai_translate_button ai_translate={FormGlue.ai_translate_config(assigns)} />
            <.ai_translate_progress ai_translate={FormGlue.ai_translate_config(assigns)} />
            <.ai_translate_hint ai_translate={FormGlue.ai_translate_config(assigns)} />
          </div>

          <.multilang_fields_wrapper
            multilang_enabled={@multilang_enabled}
            current_lang={@current_lang}
            skeleton_class="card-body pt-4 space-y-4"
            fields_class="card-body pt-4 space-y-4"
          >
            <%!-- See `project_form_live.ex` for skeleton contrast rationale. --%>
            <:skeleton>
              <div class="space-y-2">
                <div class="bg-base-content/15 rounded h-4 w-24 animate-pulse"></div>
                <div class="bg-base-content/15 rounded h-12 w-full animate-pulse"></div>
              </div>
              <div class="space-y-2">
                <div class="bg-base-content/15 rounded h-4 w-24 animate-pulse"></div>
                <div class="bg-base-content/15 rounded h-24 w-full animate-pulse"></div>
              </div>
            </:skeleton>

            <.translatable_field
              field_name="name"
              form_prefix="project"
              changeset={@form.source}
              schema_field={:name}
              multilang_enabled={@multilang_enabled}
              current_lang={@current_lang}
              primary_language={@primary_language}
              lang_data={WebHelpers.lang_data(@form, @current_lang)}
              secondary_name={"project[translations][#{@current_lang}][name]"}
              lang_data_key="name"
              label={gettext("Name")}
              disabled={@current_lang in @ai_in_flight}
              required
            />

            <.translatable_field
              field_name="description"
              form_prefix="project"
              changeset={@form.source}
              schema_field={:description}
              multilang_enabled={@multilang_enabled}
              current_lang={@current_lang}
              primary_language={@primary_language}
              lang_data={WebHelpers.lang_data(@form, @current_lang)}
              secondary_name={"project[translations][#{@current_lang}][description]"}
              lang_data_key="description"
              label={gettext("Description")}
              type="textarea"
              rows={4}
              disabled={@current_lang in @ai_in_flight}
            />
          </.multilang_fields_wrapper>
        </div>

        <%!-- Non-translatable settings stay outside the wrapper so they
             don't lose state when the user switches languages. --%>
        <div class="card bg-base-100 shadow">
          <div class="card-body flex flex-col gap-3">
            <label class="flex items-center gap-2 cursor-pointer">
              <input type="hidden" name={@form[:counts_weekends].name} value="false" />
              <input
                type="checkbox"
                name={@form[:counts_weekends].name}
                value="true"
                checked={@form[:counts_weekends].value == true or @form[:counts_weekends].value == "true"}
                class="checkbox checkbox-sm"
              />
              <span class="text-sm">{gettext("Count weekends in schedule")}</span>
            </label>

            <%!-- Workflow status — a template is a project, so it picks the
                 status list its cloned projects inherit (V125). --%>
            <.workflow_status_fields
              statuses_available={@statuses_available}
              field={@form[:status_entity_uuid]}
              status_entities={@status_entities}
              status_preview={@status_preview}
              status_translation_mode={@status_translation_mode}
            />

            <div class="flex justify-end gap-2 mt-2">
              <button type="button" phx-click="cancel" class="btn btn-ghost btn-sm">
                {gettext("Cancel")}
              </button>
              <button
                type="submit"
                phx-disable-with={gettext("Saving…")}
                disabled={@ai_in_flight != []}
                class="btn btn-primary btn-sm"
              >
                <%= if @live_action == :new, do: gettext("Create"), else: gettext("Save") %>
              </button>
            </div>
          </div>
        </div>
      </.form>

      <%!-- Modal lives outside the form — see project_form_live.ex. --%>
      <.ai_translate_modal ai_translate={FormGlue.ai_translate_config(assigns)} />
    </div>
    """
  end
end
