defmodule PhoenixKitProjects.Web.TemplateFormLive do
  @moduledoc "Create or edit a project template."

  use PhoenixKitWeb, :live_view
  # Before the Embed: its hook enqueues translations without a permission
  # check, so the gate (and `ai_translate_allowed?/1` below) sees them first.
  on_mount(PhoenixKitProjects.Web.AITranslateGate)
  # Every write event re-checks `write_allowed?/1` against the live scope.
  on_mount(PhoenixKitProjects.Web.WriteGate)
  use PhoenixKitAI.Components.AITranslate.Embed
  use Gettext, backend: PhoenixKitProjects.Gettext
  use PhoenixKitProjects.Web.Components

  import PhoenixKitWeb.Components.MultilangForm
  import PhoenixKitProjects.Web.Components.FormParts, only: [form_header: 1, words_block: 1]

  alias PhoenixKitAI.Components.AITranslate.FormGlue
  alias PhoenixKitProjects.{Activity, L10n, Paths, Projects, Statuses}
  alias PhoenixKitProjects.Schemas.Project
  alias PhoenixKitProjects.Web.Components.DescriptionEditor
  alias PhoenixKitProjects.Web.Crumbs
  alias PhoenixKitProjects.Web.DescriptionImages

  import PhoenixKitProjects.Web.Components.DescriptionEditor,
    only: [description_editor: 1, description_value: 4]

  alias PhoenixKitProjects.Web.Helpers, as: WebHelpers
  alias PhoenixKitProjects.Web.WriteGate

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
      |> mount_multilang(open_on: if(live_action == :edit, do: :viewing_language, else: :primary))
      |> assign(
        wrapper_class: wrapper_class,
        embed_redirect_to: redirect_to,
        live_action: live_action
      )
      |> WebHelpers.assign_embed_state(session)
      |> WebHelpers.assign_embed_user(session)
      |> WebHelpers.attach_open_embed_hook()
      |> authorized_action(live_action, resolved_params)
      |> assign_status_init()
      |> assign_ai_translate()
      |> assign(dirty?: false)
      |> DescriptionImages.allow(&description_image_target/1)
      |> WebHelpers.keep_host_title()

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

  # The module key at mount, before anything is loaded — the tab alone
  # never gates an embed.
  defp authorized_action(socket, live_action, params) do
    if PhoenixKitProjects.Authz.can_use_templates?(socket.assigns[:phoenix_kit_current_scope]) do
      apply_action(socket, live_action, params)
    else
      socket
      |> assign(page_title: "", project: %Project{is_template: true}, live_action: live_action)
      |> assign_form(Projects.change_project(%Project{is_template: true}))
      |> WriteGate.refuse()
      |> WebHelpers.close_or_navigate(Paths.templates())
    end
  end

  defp apply_action(socket, :new, _params) do
    project = %Project{is_template: true}

    socket
    |> assign(Crumbs.under(:templates))
    |> assign(page_title: gettext("New template"), project: project, live_action: :new)
    |> assign_form(Projects.change_project(project))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    # Only a template: this form saves on the module key alone, which must
    # never reach a real project (that takes `:edit_settings`).
    case id |> Projects.get_project() |> only_template() do
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
        # Trail: Admin Panel / Projects / Templates / <name> / Edit — the
        # template is a linked crumb, the leaf is the page. The drawer has
        # no trail, so its heading still names the template.
        |> assign(Crumbs.under_project(project, socket.assigns[:phoenix_kit_current_scope]))
        |> assign(
          page_title: gettext("Edit"),
          heading:
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

  @doc false
  def write_events, do: ~w(save generate_default_statuses)

  @doc false
  # Templates ride the projects module permission (`Authz.can_use_templates?/1`),
  # checked here at mount and on every write (`Web.WriteGate`) rather than
  # left to the tab, which an embed never passes. On `:edit` the record is
  # re-read: only a template is edited here.
  def write_allowed?(socket) do
    PhoenixKitProjects.Authz.can_use_templates?(socket.assigns[:phoenix_kit_current_scope]) and
      case {socket.assigns[:live_action], socket.assigns[:project]} do
        {:new, _} ->
          true

        {:edit, %Project{uuid: uuid}} when is_binary(uuid) ->
          template?(Projects.get_project(uuid))

        _ ->
          false
      end
  end

  defp template?(%Project{is_template: true}), do: true
  defp template?(_), do: false

  defp only_template(%Project{is_template: true} = project), do: project
  defp only_template(_), do: nil

  @doc false
  # The AI-translate modal's events need the same (`Web.AITranslateGate`).
  def ai_translate_allowed?(socket), do: write_allowed?(socket)

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
     |> refresh_status_preview()
     |> WebHelpers.mark_dirty()}
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

  # The description editor (Leaf): its text into the form, as if the field
  # had posted it; `@` and `#` suggestions as the textarea offered them.
  @impl true
  def handle_info({:leaf_changed, _} = msg, socket) do
    case DescriptionEditor.changed(msg) do
      {"template-description", lang, markdown} ->
        {:noreply, put_description(socket, lang, markdown)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:leaf_suggest, _} = msg, socket),
    do: {:noreply, DescriptionEditor.suggest(socket, msg, nil)}

  # An image pasted into the description: kept in the template's folder
  # and placed at the cursor (the boss, 2026-10-31).
  def handle_info(
        {:leaf_paste_image, %{editor_id: "template-description--" <> _ = id} = paste},
        socket
      ),
      do: {:noreply, DescriptionImages.paste(socket, id, paste)}

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Where a picture for the description goes (`DescriptionImages`): the
  # saved template's folder; nowhere before it is saved.
  defp description_image_target(
         %{assigns: %{live_action: :edit, project: %Project{uuid: uuid} = holder}} = socket
       )
       when is_binary(uuid),
       do:
         {holder,
          DescriptionEditor.editor_id("template-description", socket.assigns[:current_lang])}

  defp description_image_target(_socket), do: nil

  defp put_description(%{assigns: %{form: form}} = socket, lang, markdown) do
    %{primary_language: primary, multilang_enabled: multi?} = socket.assigns

    if description_value(form, lang, primary, multi?) == markdown do
      socket
    else
      attrs =
        form.params
        |> Map.merge(DescriptionEditor.params(markdown, lang, primary, multi?))
        |> Map.put("is_template", "true")
        |> merge_attrs(socket)

      socket
      |> assign_form(Projects.change_project(socket.assigns.project, attrs))
      |> WebHelpers.mark_dirty()
    end
  end

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

  # The template's name as typed, in the language whose tab is open.
  defp typed_name(assigns) do
    typed =
      assigns.form.source
      |> Ecto.Changeset.apply_changes()
      |> Project.localized_name(assigns[:current_lang])

    case typed && String.trim(typed) do
      name when is_binary(name) and name != "" -> name
      _ -> ""
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class={@wrapper_class}>
      <.form_header
        id="template-form-header"
        title={typed_name(assigns)}
        untitled={@live_action != :edit && (assigns[:heading] || gettext("New template"))}
        mode={if @live_action == :edit, do: gettext("Editing")}
        close_event={@embed_mode not in [:navigate, :emit] && "cancel"}
        close_confirm={@dirty? && gettext("Discard your changes?")}
      >
        <:context>
          <.link
            :if={@embed_mode == :navigate}
            navigate={Paths.templates()}
            class="btn btn-ghost btn-sm btn-square shrink-0"
            title={gettext("Templates")}
            aria-label={gettext("Templates")}
          >
            <.icon name="hero-arrow-left" class="w-4 h-4" />
          </.link>
          <%!-- In a popup no lone "← Templates" line above the title, as in the
               project popup: the popup closes with its ✕ and Close. --%>
        </:context>
      </.form_header>

      <.form for={@form} id="template-form" phx-change="validate" phx-submit="save" phx-debounce="300" class="flex flex-col gap-4">
        <%!-- Translatable card: name + description with language tabs.
             Wrapper id keys on @current_lang so morphdom re-mounts the
             inputs when the user switches languages — that's what swaps
             primary-column inputs for JSONB-backed secondary inputs.
             Matches `ProjectFormLive`'s shape. --%>
        <.words_block
          id="template-words"
          multilang_enabled={@multilang_enabled}
          language_tabs={@language_tabs}
          current_lang={@current_lang}
          ai_translate={FormGlue.ai_translate_config(assigns)}
        >

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
              label=""
              placeholder={gettext("Template name")}
              aria-label={gettext("Template name")}
              disabled={@current_lang in @ai_in_flight}
            />

            <%!-- Pictures are intercepted (`uploads`): pasted or added with
                 the button, kept in the template's folder and placed by file
                 (`DescriptionImages`); never a `data:` address in the text. --%>
            <.description_editor
                id={DescriptionEditor.editor_id("template-description", @current_lang)}
                name={DescriptionEditor.field_name("project", @current_lang, @primary_language, @multilang_enabled)}
                value={description_value(@form, @current_lang, @primary_language, @multilang_enabled)}
                content={
                  PhoenixKitProjects.InlineImages.resolve(
                    description_value(@form, @current_lang, @primary_language, @multilang_enabled),
                    assigns[:phoenix_kit_current_scope],
                    keep_missing: true
                  )
                }
                placeholder={gettext("Description…")}
                readonly={@current_lang in @ai_in_flight}
                uploads
                image_button={false}
              />
              <DescriptionImages.button :if={@live_action == :edit} uploads={@uploads} id="template-description-image" />
        </.words_block>

        <%!-- Non-translatable settings stay outside the wrapper so they
             don't lose state when the user switches languages. --%>
        <div class="card bg-base-100 shadow">
          <div class="card-body flex flex-col gap-3">
            <.checkbox
              field={@form[:counts_weekends]}
              label={gettext("Count weekends in schedule")}
              class="checkbox-primary checkbox-sm"
            />

            <%!-- Workflow status — a template is a project, so it picks the
                 status list its cloned projects inherit (V125). --%>
            <.workflow_status_fields
              class="border-t border-base-300 mt-6 pt-6"
              statuses_available={@statuses_available}
              field={@form[:status_entity_uuid]}
              status_entities={@status_entities}
              status_preview={@status_preview}
              status_translation_mode={@status_translation_mode}
            />

            <.form_actions
              class="gap-2 mt-2"
              submit_label={if @live_action == :new, do: gettext("Create"), else: gettext("Save")}
              submitting_label={gettext("Saving…")}
              submit_class="btn btn-primary btn-sm"
              submit_disabled={@ai_in_flight != []}
            >
              <:cancel>
              <button
                type="button"
                phx-click="cancel"
                data-confirm={@dirty? && gettext("Discard your changes?")}
                class="btn btn-ghost btn-sm"
              >
                {gettext("Close")}
              </button>
          </:cancel>
            </.form_actions>
          </div>
        </div>
      </.form>

      <%!-- Modal lives outside the form — see project_form_live.ex. --%>
      <.ai_translate_modal ai_translate={FormGlue.ai_translate_config(assigns)} />
    </div>
    """
  end
end
