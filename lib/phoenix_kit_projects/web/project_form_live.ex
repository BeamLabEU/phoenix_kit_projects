defmodule PhoenixKitProjects.Web.ProjectFormLive do
  @moduledoc "Create or edit a project."

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitProjects.Gettext
  use PhoenixKitProjects.Web.Components

  import PhoenixKitWeb.Components.MultilangForm

  alias PhoenixKit.PubSub.Manager, as: PubSubManager
  alias PhoenixKit.Utils.Values
  alias PhoenixKitProjects.{Activity, Errors, L10n, Paths, Projects, Translations}
  alias PhoenixKitProjects.PubSub, as: ProjectsPubSub
  alias PhoenixKitProjects.Schemas.Project
  alias PhoenixKitProjects.Web.AITranslateFormHelpers
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

    # `apply_action/3` loads the project on `:edit` and the templates
    # list on `:new`. It runs at the tail of `mount/3` (not in
    # `handle_params/3`) because Phoenix LV refuses to mount a LV
    # exporting `handle_params/3` outside a router live route, which
    # would block embedding via `live_render`. See
    # dev_docs/embedding_audit.md.
    socket =
      socket
      |> mount_multilang()
      |> assign(
        wrapper_class: wrapper_class,
        embed_redirect_to: redirect_to,
        live_action: live_action,
        ai_translate_in_flight: [],
        ai_translate_scope: :missing,
        show_ai_translation_modal: false,
        ai_selected_endpoint_uuid: Translations.get_default_ai_endpoint_uuid(),
        ai_selected_prompt_uuid: Translations.get_default_ai_prompt_uuid(),
        ai_endpoints: Translations.list_ai_endpoints(),
        ai_prompts: Translations.list_ai_prompts(),
        ai_default_prompt_exists: Translations.default_translation_prompt_exists?()
      )
      |> WebHelpers.assign_embed_state(session)
      |> WebHelpers.attach_open_embed_hook()
      |> apply_action(live_action, resolved_params)
      |> maybe_subscribe_translations()

    {:ok, socket}
  end

  # Scope to the per-project topic — `topic_all/0` would deliver every
  # broadcast in the system (CRUD on other projects, every task/template
  # broadcast) and force the LV to filter in `handle_info`. The worker
  # already fans out project/template broadcasts to `topic_project(uuid)`,
  # so this is the narrowest topic that still receives the events we
  # care about.
  defp maybe_subscribe_translations(%{assigns: %{live_action: :new}} = socket), do: socket

  defp maybe_subscribe_translations(socket) do
    if Phoenix.LiveView.connected?(socket) and Translations.ai_translation_available?() and
         is_binary(socket.assigns.project.uuid) do
      PubSubManager.subscribe(ProjectsPubSub.topic_project(socket.assigns.project.uuid))
    end

    socket
  end

  defp apply_action(socket, :new, params) do
    template_uuid = Map.get(params, "template")
    templates = Projects.list_templates()
    project = %Project{}

    socket
    |> assign(
      page_title: gettext("New project"),
      project: project,
      live_action: :new,
      templates: templates,
      selected_template: template_uuid
    )
    |> assign_form(Projects.change_project(project))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case Projects.get_project(id) do
      nil ->
        socket
        |> assign(
          page_title: "",
          project: %Project{},
          live_action: :edit,
          templates: [],
          selected_template: nil
        )
        |> assign_form(Projects.change_project(%Project{}))
        |> put_flash(:error, gettext("Project not found."))
        |> WebHelpers.close_or_navigate(Paths.projects())

      project ->
        socket
        |> assign(
          page_title:
            gettext("Edit %{name}",
              name: Project.localized_name(project, L10n.current_content_lang())
            ),
          project: project,
          live_action: :edit,
          templates: [],
          selected_template: nil
        )
        |> assign_form(Projects.change_project(project))
    end
  end

  # Fail-closed catch-all: a tampered or partial emit-session can land
  # `:edit` here without an `"id"` key. Render placeholders + flash, then
  # `close_or_navigate/2` emits `:closed` so the host pops the modal.
  defp apply_action(socket, :edit, _params) do
    socket
    |> assign(
      page_title: "",
      project: %Project{},
      live_action: :edit,
      templates: [],
      selected_template: nil
    )
    |> assign_form(Projects.change_project(%Project{}))
    |> put_flash(:error, gettext("Project not found."))
    |> WebHelpers.close_or_navigate(Paths.projects())
  end

  defp assign_form(socket, cs), do: assign(socket, form: to_form(cs))

  @impl true
  def handle_event("switch_language", %{"lang" => lang_code}, socket) do
    {:noreply, handle_switch_language(socket, lang_code)}
  end

  def handle_event("translate_lang", %{"lang" => lang}, socket) do
    {:noreply, socket |> dispatch_ai_translate(lang) |> assign(:show_ai_translation_modal, false)}
  end

  def handle_event("toggle_ai_translation", _params, socket) do
    {:noreply,
     assign(socket, :show_ai_translation_modal, !socket.assigns.show_ai_translation_modal)}
  end

  def handle_event("select_ai_endpoint", %{"endpoint_uuid" => uuid}, socket) do
    {:noreply, assign(socket, :ai_selected_endpoint_uuid, blank_to_nil(uuid))}
  end

  def handle_event("select_ai_prompt", %{"prompt_uuid" => uuid}, socket) do
    {:noreply, assign(socket, :ai_selected_prompt_uuid, blank_to_nil(uuid))}
  end

  def handle_event("select_ai_scope", %{"scope" => scope}, socket)
      when scope in ~w(missing all current) do
    {:noreply, assign(socket, :ai_translate_scope, String.to_existing_atom(scope))}
  end

  def handle_event("select_ai_scope", _params, socket), do: {:noreply, socket}

  def handle_event("generate_default_ai_prompt", _params, socket) do
    case Translations.generate_default_translation_prompt() do
      {:ok, %{uuid: uuid}} ->
        {:noreply,
         socket
         |> assign(:ai_prompts, Translations.list_ai_prompts())
         |> assign(:ai_default_prompt_exists, true)
         |> assign(:ai_selected_prompt_uuid, uuid)
         |> put_flash(:info, gettext("Default translation prompt generated."))}

      {:error, _reason} ->
        {:noreply,
         put_flash(socket, :error, gettext("Could not generate the default translation prompt."))}
    end
  end

  # Don't stamp `:action, :validate` here. Phoenix's `to_form/1` only
  # surfaces field errors when the changeset has an action set, so leaving
  # it nil during `phx-change` keeps the form visually clean while the
  # user is still typing — errors only render after a failed submit (where
  # `Repo.insert/1` / `update/1` auto-stamps `:insert` or `:update`).
  # Without this, toggling the start-mode select would light up
  # "can't be blank" on Name and "required for scheduled projects" on the
  # just-revealed date field even though the user has touched neither.
  # The changeset is still rebuilt so reactive bits like
  # `start_mode_value(@form)` stay in sync with form state.
  def handle_event("validate", %{"project" => attrs} = params, socket) do
    selected_template = Map.get(params, "template_uuid", socket.assigns.selected_template)
    attrs = merge_attrs(attrs, socket)

    cs =
      Projects.change_project(socket.assigns.project, attrs,
        enforce_scheduled_date_required: false
      )

    {:noreply, socket |> assign(selected_template: selected_template) |> assign_form(cs)}
  end

  def handle_event("save", %{"project" => attrs} = params, socket) do
    template_uuid = Map.get(params, "template_uuid", nil) |> Values.blank_to_nil()
    save(socket, socket.assigns.live_action, merge_attrs(attrs, socket), template_uuid)
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, WebHelpers.close_or_navigate(socket, Paths.projects())}
  end

  @impl true
  def handle_info(
        {:projects, :translation_started, %{resource_uuid: uuid, target_lang: lang}},
        socket
      )
      when uuid == socket.assigns.project.uuid do
    {:noreply,
     assign(
       socket,
       :ai_translate_in_flight,
       Enum.uniq([lang | socket.assigns.ai_translate_in_flight])
     )}
  end

  def handle_info(
        {:projects, :translation_completed, %{resource_uuid: uuid, target_lang: lang}},
        socket
      )
      when uuid == socket.assigns.project.uuid do
    # Merge ONLY the new lang's translation into the form-bound project
    # — never `Projects.change_project(fresh_reload)` here, because that
    # wipes any unsaved edits the user has made while the Oban job ran
    # in the background. Refresh the underlying `socket.assigns.project`
    # too so subsequent dispatches don't re-enqueue an already-translated
    # language.
    case Projects.get_project(uuid) do
      nil ->
        {:noreply,
         assign(socket, :ai_translate_in_flight, socket.assigns.ai_translate_in_flight -- [lang])}

      reloaded ->
        new_translation = Map.get(reloaded.translations || %{}, lang, %{})

        {:noreply,
         socket
         |> assign(:project, reloaded)
         |> assign(:ai_translate_in_flight, socket.assigns.ai_translate_in_flight -- [lang])
         |> patch_form_translations(lang, new_translation)
         |> put_flash(:info, gettext("Translated to %{lang}.", lang: String.upcase(lang)))}
    end
  end

  def handle_info(
        {:projects, :translation_failed, %{resource_uuid: uuid, target_lang: lang}},
        socket
      )
      when uuid == socket.assigns.project.uuid do
    {:noreply,
     socket
     |> assign(:ai_translate_in_flight, socket.assigns.ai_translate_in_flight -- [lang])
     |> put_flash(:error, gettext("Translation to %{lang} failed.", lang: String.upcase(lang)))}
  end

  # Catch-all for unrelated PubSub events (other projects' translations,
  # CRUD broadcasts, etc.) — the form only cares about its own project.
  def handle_info({:projects, _action, _payload}, socket), do: {:noreply, socket}

  defp dispatch_ai_translate(%{assigns: %{live_action: :new}} = socket, _lang) do
    put_flash(
      socket,
      :info,
      gettext("Save the project first, then you can translate it with AI.")
    )
  end

  defp dispatch_ai_translate(socket, lang) do
    # The modal picks endpoint/prompt and stores them on the socket
    # — fall back to the configured defaults if the user never opened
    # the modal (e.g. a host-driven shortcut to enqueue).
    endpoint_uuid =
      socket.assigns.ai_selected_endpoint_uuid || Translations.get_default_ai_endpoint_uuid()

    prompt_uuid =
      socket.assigns.ai_selected_prompt_uuid || Translations.get_default_ai_prompt_uuid()

    cond do
      endpoint_uuid in [nil, ""] ->
        put_flash(socket, :error, gettext("Select an AI endpoint first."))

      prompt_uuid in [nil, ""] ->
        put_flash(socket, :error, gettext("Select a translation prompt first."))

      true ->
        do_dispatch_ai_translate(socket, lang, endpoint_uuid, prompt_uuid)
    end
  end

  # Scope sentinels: `"*"` = missing-only, `"**"` = all non-primary.
  defp do_dispatch_ai_translate(socket, scope, endpoint_uuid, prompt_uuid)
       when scope in ["*", "**"] do
    target_langs =
      case scope do
        "*" -> ai_translate_missing(socket.assigns)
        "**" -> ai_translate_all_targets(socket.assigns)
      end

    base_params = %{
      resource_type: "project",
      resource_uuid: socket.assigns.project.uuid,
      endpoint_uuid: endpoint_uuid,
      prompt_uuid: prompt_uuid,
      source_lang: socket.assigns.primary_language,
      actor_uuid: Activity.actor_uuid(socket)
    }

    case Translations.enqueue_all_missing(base_params, target_langs) do
      {:ok, %{in_flight: [_ | _] = enqueued_langs, enqueued: n, errors: errors}} ->
        socket
        |> assign(
          :ai_translate_in_flight,
          Enum.uniq(socket.assigns.ai_translate_in_flight ++ enqueued_langs)
        )
        |> maybe_flash_partial_errors(errors)
        |> put_flash(:info, gettext("Translating to %{count} languages…", count: n))

      {:ok, %{errors: [_ | _] = errors}} ->
        maybe_flash_partial_errors(socket, errors)

      {:ok, _} ->
        put_flash(socket, :info, gettext("Nothing to translate."))

      {:error, _reason} ->
        put_flash(socket, :error, gettext("Could not start translation."))
    end
  end

  defp do_dispatch_ai_translate(socket, lang, endpoint_uuid, prompt_uuid) do
    params = %{
      resource_type: "project",
      resource_uuid: socket.assigns.project.uuid,
      endpoint_uuid: endpoint_uuid,
      prompt_uuid: prompt_uuid,
      source_lang: socket.assigns.primary_language,
      target_lang: lang,
      actor_uuid: Activity.actor_uuid(socket)
    }

    case Translations.enqueue(params) do
      {:ok, %{conflict?: false}} ->
        socket
        |> assign(
          :ai_translate_in_flight,
          Enum.uniq([lang | socket.assigns.ai_translate_in_flight])
        )
        |> put_flash(:info, gettext("Translating to %{lang}…", lang: String.upcase(lang)))

      {:ok, %{conflict?: true}} ->
        put_flash(socket, :info, gettext("Translation already in progress."))

      {:error, _reason} ->
        put_flash(socket, :error, gettext("Could not start translation."))
    end
  end

  defp maybe_flash_partial_errors(socket, []), do: socket

  defp maybe_flash_partial_errors(socket, errors) do
    langs = Enum.map_join(errors, ", ", fn {lang, _} -> String.upcase(lang) end)
    put_flash(socket, :error, gettext("Could not start translation for: %{langs}", langs: langs))
  end

  defp ai_translate_missing(assigns) do
    AITranslateFormHelpers.missing_languages(
      assigns.language_tabs,
      assigns.primary_language,
      assigns.project.translations,
      Project.translatable_fields()
    )
  end

  # Every non-primary enabled language. Used for the "all" scope —
  # the worker's unique constraint dedupes per-(resource, lang) so
  # enqueuing already-translated langs just overwrites them on
  # completion.
  defp ai_translate_all_targets(assigns) do
    assigns.language_tabs
    |> Enum.map(& &1.code)
    |> Enum.reject(&(&1 == assigns.primary_language))
  end

  # Merge a freshly-translated language into the form's existing
  # `translations` field WITHOUT touching primary-column edits or other
  # secondary-lang fields the user may have typed since dispatching the
  # AI job. Reuses the changeset's existing changes via `put_change/3`.
  # Merges the AI's translated fields into the form-bound changeset
  # for `lang`, but ONLY fills fields whose current value is blank.
  # If the user switched to the target lang during the job and typed
  # something into e.g. `name`, the AI's translated name does NOT
  # win — user input always takes precedence. This addresses the
  # "translation overwrites in-flight edits" footgun that an
  # unconditional `Map.merge/2` had.
  defp patch_form_translations(socket, lang, new_lang_map) do
    cs = socket.assigns.form.source

    current_translations =
      Ecto.Changeset.get_field(cs, :translations) || %{}

    current_lang_map = Map.get(current_translations, lang, %{})

    merged_lang = AITranslateFormHelpers.merge_blank_fields_only(current_lang_map, new_lang_map)

    updated_translations = Map.put(current_translations, lang, merged_lang)

    cs
    |> Ecto.Changeset.put_change(:translations, updated_translations)
    |> then(&assign_form(socket, &1))
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp ai_translate_config(assigns) do
    cond do
      assigns.live_action == :new ->
        nil

      not Translations.ai_translation_available?() ->
        nil

      true ->
        %{
          enabled: true,
          event: "translate_lang",
          toggle_event: "toggle_ai_translation",
          select_endpoint_event: "select_ai_endpoint",
          select_prompt_event: "select_ai_prompt",
          select_scope_event: "select_ai_scope",
          generate_prompt_event: "generate_default_ai_prompt",
          missing: ai_translate_missing(assigns),
          all_langs: ai_translate_all_targets(assigns),
          in_flight: assigns.ai_translate_in_flight,
          modal_open: assigns.show_ai_translation_modal,
          endpoints: assigns.ai_endpoints,
          prompts: assigns.ai_prompts,
          selected_endpoint_uuid: assigns.ai_selected_endpoint_uuid,
          selected_prompt_uuid: assigns.ai_selected_prompt_uuid,
          scope: assigns.ai_translate_scope,
          default_prompt_exists: assigns.ai_default_prompt_exists,
          current_lang: assigns.current_lang,
          primary_lang: assigns.primary_language
        }
    end
  end

  defp merge_attrs(attrs, socket) do
    in_flight = WebHelpers.in_flight_record(socket, :form, :project)

    attrs
    |> WebHelpers.normalize_datetime_local_attrs(["scheduled_start_date"])
    |> WebHelpers.merge_translations_attrs(in_flight, Project.translatable_fields())
  end

  defp save(socket, :new, attrs, nil) do
    case Projects.create_project(attrs) do
      {:ok, project} ->
        Activity.log("projects.project_created",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "project",
          resource_uuid: project.uuid,
          metadata: %{"name" => project.name}
        )

        {:noreply,
         socket
         |> put_flash(:info, gettext("Project created."))
         |> WebHelpers.navigate_after_save(Paths.project(project.uuid),
           kind: :project,
           record: project,
           action: :create,
           # Emit-mode chain: close the form modal, open the project
           # show on top (mirrors navigate-mode's `push_navigate(to:
           # Paths.project(uuid))`).
           next: {PhoenixKitProjects.Web.ProjectShowLive, %{"id" => project.uuid}}
         )}

      {:error, cs} ->
        Activity.log_failed("projects.project_created",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "project",
          metadata: %{"name" => Map.get(attrs, "name") || Ecto.Changeset.get_field(cs, :name)}
        )

        {:noreply, on_save_error(socket, cs)}
    end
  end

  defp save(socket, :new, attrs, template_uuid) do
    case Projects.create_project_from_template(template_uuid, attrs) do
      {:ok, project} ->
        Activity.log("projects.project_created_from_template",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "project",
          resource_uuid: project.uuid,
          metadata: %{"name" => project.name, "template_uuid" => template_uuid}
        )

        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("Project created from template with all tasks and dependencies.")
         )
         |> WebHelpers.navigate_after_save(Paths.project(project.uuid),
           kind: :project,
           record: project,
           action: :create,
           next: {PhoenixKitProjects.Web.ProjectShowLive, %{"id" => project.uuid}}
         )}

      {:error, :template_not_found} ->
        Activity.log_failed("projects.project_created_from_template",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "project",
          metadata: %{"template_uuid" => template_uuid, "reason" => "template_not_found"}
        )

        {:noreply, put_flash(socket, :error, Errors.message(:template_not_found))}

      # Changeset errors that originate from the cloned project itself get
      # re-assigned to the form so the user sees inline validation.
      {:error, %Ecto.Changeset{data: %Project{}} = cs} ->
        Activity.log_failed("projects.project_created_from_template",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "project",
          metadata: %{
            "template_uuid" => template_uuid,
            "name" => Map.get(attrs, "name") || Ecto.Changeset.get_field(cs, :name)
          }
        )

        {:noreply, on_save_error(socket, cs)}

      # Changesets from deeper in the transaction (assignment / dependency
      # cloning) don't map cleanly onto the project form — surface a
      # generic error message instead.
      {:error, %Ecto.Changeset{}} ->
        Activity.log_failed("projects.project_created_from_template",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "project",
          metadata: %{"template_uuid" => template_uuid, "reason" => "cascade_changeset"}
        )

        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Could not copy the template. Please check the source and try again.")
         )}

      # Any other shape (e.g. `{:error, reason}` from a transaction that
      # caught an unexpected exception) — fail closed with a flash
      # instead of a pattern-match crash.
      {:error, other} ->
        Activity.log_failed("projects.project_created_from_template",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "project",
          metadata: %{"template_uuid" => template_uuid, "reason" => inspect(other)}
        )

        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Something went wrong while creating the project. Please try again.")
         )}
    end
  end

  defp save(socket, :edit, attrs, _template_uuid) do
    case Projects.update_project(socket.assigns.project, attrs) do
      {:ok, project} ->
        Activity.log("projects.project_updated",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "project",
          resource_uuid: project.uuid,
          metadata: %{"name" => project.name}
        )

        {:noreply,
         socket
         |> put_flash(:info, gettext("Project updated."))
         |> WebHelpers.navigate_after_save(Paths.project(project.uuid),
           kind: :project,
           record: project,
           action: :update
         )}

      {:error, cs} ->
        Activity.log_failed("projects.project_updated",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "project",
          resource_uuid: socket.assigns.project.uuid,
          metadata: %{"name" => socket.assigns.project.name}
        )

        {:noreply, on_save_error(socket, cs)}
    end
  end

  # Handles the form-error path uniformly: re-assigns the changeset, and
  # if the error sits on a primary translatable field while the user is
  # on a secondary tab, flips `:current_lang` back to primary so the
  # error becomes visible (without this, the user gets no visible
  # feedback on save failure — e.g. a unique-name conflict on a HE
  # tab session would silently no-op the form). Also flashes the first
  # error message so even users on the primary tab get a top-level
  # signal.
  defp on_save_error(socket, %Ecto.Changeset{} = cs) do
    socket
    |> assign_form(cs)
    |> WebHelpers.maybe_switch_to_primary_on_error(cs, [:name, :description])
    |> put_flash(:error, first_error_message(cs))
  end

  defp first_error_message(%Ecto.Changeset{errors: [{field, {msg, _opts}} | _]}) do
    gettext("%{field}: %{message}", field: humanize(field), message: msg)
  end

  defp first_error_message(_), do: gettext("Could not save the project.")

  defp humanize(field) do
    field |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  defp start_mode_value(form) do
    case form[:start_mode] do
      %{value: val} when is_binary(val) and val != "" -> val
      _ -> "immediate"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class={@wrapper_class}>
      <.page_header title={@page_title}>
        <:back_link>
          <.smart_link
            navigate={Paths.projects()}
            emit={{PhoenixKitProjects.Web.ProjectsLive, %{}}}
            embed_mode={@embed_mode}
            class="link link-hover text-sm"
          >
            <.icon name="hero-arrow-left" class="w-4 h-4 inline" /> {gettext("Projects")}
          </.smart_link>
        </:back_link>
      </.page_header>

      <.form for={@form} id="project-form" phx-change="validate" phx-submit="save" phx-debounce="300" class="flex flex-col gap-4">
        <%!-- Translatable card: name + description with language tabs.
             Wrapper id keys on @current_lang so morphdom re-mounts the
             inputs when the user switches languages — that's what swaps
             primary-column inputs for `lang_*` JSONB inputs. --%>
        <div class="card bg-base-100 shadow">
          <.multilang_tabs
            multilang_enabled={@multilang_enabled}
            language_tabs={@language_tabs}
            current_lang={@current_lang}
          />

          <.ai_translate_button ai_translate={ai_translate_config(assigns)} />

          <.multilang_fields_wrapper
            multilang_enabled={@multilang_enabled}
            current_lang={@current_lang}
            skeleton_class="card-body pt-4 space-y-4"
            fields_class="card-body pt-4 space-y-4"
          >
            <:skeleton>
              <div class="space-y-2">
                <div class="skeleton h-4 w-24"></div>
                <div class="skeleton h-12 w-full"></div>
              </div>
              <div class="space-y-2">
                <div class="skeleton h-4 w-24"></div>
                <div class="skeleton h-24 w-full"></div>
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
            />
          </.multilang_fields_wrapper>
        </div>

        <%!-- Non-translatable settings stay outside the wrapper so they
             don't lose state when the user switches languages. --%>
        <div class="card bg-base-100 shadow">
          <div class="card-body flex flex-col gap-3">
            <%= if @live_action == :new and @templates != [] do %>
              <.select
                name="template_uuid"
                label={gettext("From template (optional)")}
                value={@selected_template}
                options={Enum.map(@templates, &{&1.name, &1.uuid})}
                prompt={gettext("Start from scratch")}
              />
            <% end %>
            <label class="flex items-center gap-2 cursor-pointer">
              <input
                type="hidden"
                name={@form[:counts_weekends].name}
                value="false"
              />
              <input
                type="checkbox"
                name={@form[:counts_weekends].name}
                value="true"
                checked={@form[:counts_weekends].value == true or @form[:counts_weekends].value == "true"}
                class="checkbox checkbox-sm"
              />
              <span class="text-sm">{gettext("Count weekends in schedule")}</span>
            </label>
            <.select
              field={@form[:start_mode]}
              label={gettext("Start")}
              options={[{gettext("Immediately (set up tasks first)"), "immediate"}, {gettext("Scheduled date"), "scheduled"}]}
            />
            <%= if start_mode_value(@form) == "scheduled" do %>
              <.input field={@form[:scheduled_start_date]} label={gettext("Start date and time")} type="datetime-local" />
            <% end %>
            <div class="flex justify-end gap-2 mt-2">
              <button type="button" phx-click="cancel" class="btn btn-ghost btn-sm">
                {gettext("Cancel")}
              </button>
              <button type="submit" phx-disable-with={gettext("Saving…")} class="btn btn-primary btn-sm">
                <%= if @live_action == :new, do: gettext("Create"), else: gettext("Save") %>
              </button>
            </div>
          </div>
        </div>
      </.form>

      <%!--
        AI translate modal lives OUTSIDE the project form on purpose
        — HTML doesn't permit nested `<form>` elements, so a `<form
        phx-change="select_ai_endpoint">` rendered inside the outer
        project form gets flattened by the browser: select changes
        end up firing the outer form's `validate` event instead.
        Rendering the modal here sidesteps that.
      --%>
      <.ai_translate_modal ai_translate={ai_translate_config(assigns)} />
    </div>
    """
  end
end
