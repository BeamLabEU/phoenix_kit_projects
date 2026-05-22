defmodule PhoenixKitProjects.Web.TemplateFormLive do
  @moduledoc "Create or edit a project template."

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitProjects.Gettext
  use PhoenixKitProjects.Web.Components

  import PhoenixKitWeb.Components.MultilangForm

  alias PhoenixKit.PubSub.Manager, as: PubSubManager
  alias PhoenixKitProjects.{Activity, L10n, Paths, Projects, Translations}
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
      |> AITranslateFormHelpers.assign_ai_translate_mount_state()
      |> WebHelpers.assign_embed_state(session)
      |> WebHelpers.attach_open_embed_hook()
      |> apply_action(live_action, resolved_params)
      |> maybe_subscribe_translations()

    {:ok, socket}
  end

  defp maybe_subscribe_translations(%{assigns: %{live_action: :new}} = socket), do: socket

  defp maybe_subscribe_translations(socket) do
    if Phoenix.LiveView.connected?(socket) and Translations.ai_translation_available?() and
         is_binary(socket.assigns.project.uuid) do
      PubSubManager.subscribe(ProjectsPubSub.topic_project(socket.assigns.project.uuid))
    end

    socket
  end

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

  def handle_event("validate", %{"project" => attrs}, socket) do
    attrs = attrs |> Map.put("is_template", "true") |> merge_attrs(socket)
    cs = socket.assigns.project |> Projects.change_project(attrs) |> Map.put(:action, :validate)
    {:noreply, assign_form(socket, cs)}
  end

  def handle_event("save", %{"project" => attrs}, socket) do
    if socket.assigns.ai_translate_in_flight == [] do
      attrs =
        attrs
        |> Map.merge(%{"is_template" => "true", "start_mode" => "immediate"})
        |> merge_attrs(socket)

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
        {:projects, :translation_completed, %{resource_uuid: uuid, target_lang: lang} = payload},
        socket
      )
      when uuid == socket.assigns.project.uuid do
    socket =
      socket
      |> AITranslateFormHelpers.bump_translation_completed(lang)

    if Map.get(payload, :empty, false) do
      {:noreply,
       put_flash(
         socket,
         :info,
         gettext("Nothing to translate for %{lang} — the source has no content yet.",
           lang: String.upcase(lang)
         )
       )}
    else
      case Projects.get_project(uuid) do
        nil ->
          {:noreply, socket}

        reloaded ->
          new_translation = Map.get(reloaded.translations || %{}, lang, %{})

          {:noreply,
           socket
           |> assign(:project, reloaded)
           |> patch_form_translations(lang, new_translation)
           |> put_flash(:info, gettext("Translated to %{lang}.", lang: String.upcase(lang)))}
      end
    end
  end

  def handle_info(
        {:projects, :translation_failed, %{resource_uuid: uuid, target_lang: lang}},
        socket
      )
      when uuid == socket.assigns.project.uuid do
    {:noreply,
     socket
     |> AITranslateFormHelpers.bump_translation_completed(lang)
     |> put_flash(:error, gettext("Translation to %{lang} failed.", lang: String.upcase(lang)))}
  end

  def handle_info({:projects, _action, _payload}, socket), do: {:noreply, socket}

  defp dispatch_ai_translate(%{assigns: %{live_action: :new}} = socket, _lang) do
    put_flash(
      socket,
      :info,
      gettext("Save the template first, then you can translate it with AI.")
    )
  end

  defp dispatch_ai_translate(socket, lang) do
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

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp do_dispatch_ai_translate(socket, scope, endpoint_uuid, prompt_uuid)
       when scope in ["*", "**"] do
    target_langs =
      case scope do
        "*" -> ai_translate_missing(socket.assigns)
        "**" -> ai_translate_all_targets(socket.assigns)
      end

    base_params = %{
      resource_type: "template",
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
        |> AITranslateFormHelpers.bump_translation_started(length(enqueued_langs))
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
      resource_type: "template",
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
        |> AITranslateFormHelpers.bump_translation_started(1)
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

  defp ai_translate_all_targets(assigns) do
    assigns.language_tabs
    |> Enum.map(& &1.code)
    |> Enum.reject(&(&1 == assigns.primary_language))
  end

  # AI value wins on the target lang's fields — see
  # `project_form_live.ex#patch_form_translations/3` for the rationale.
  defp patch_form_translations(socket, lang, new_lang_map) do
    cs = socket.assigns.form.source

    current_translations =
      Ecto.Changeset.get_field(cs, :translations) || %{}

    current_lang_map = Map.get(current_translations, lang, %{})
    merged_lang = Map.merge(current_lang_map, new_lang_map)
    updated_translations = Map.put(current_translations, lang, merged_lang)

    cs
    |> Ecto.Changeset.put_change(:translations, updated_translations)
    |> then(&assign_form(socket, &1))
  end

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
          translation_status: assigns.ai_translation_status,
          translation_progress: assigns.ai_translation_progress,
          translation_total: assigns.ai_translation_total,
          modal_open: assigns.show_ai_translation_modal,
          endpoints: assigns.ai_endpoints,
          prompts: assigns.ai_prompts,
          selected_endpoint_uuid: assigns.ai_selected_endpoint_uuid,
          selected_prompt_uuid: assigns.ai_selected_prompt_uuid,
          scope: assigns.ai_translate_scope,
          default_prompt_exists: assigns.ai_default_prompt_exists,
          current_lang: assigns.current_lang,
          primary_lang: assigns.primary_language,
          primary_lang_name: lookup_lang_name(assigns.language_tabs, assigns.primary_language)
        }
    end
  end

  defp lookup_lang_name(tabs, code) do
    case Enum.find(tabs || [], &(&1.code == code)) do
      %{name: name} when is_binary(name) -> name
      _ -> nil
    end
  end

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
            <.ai_translate_button ai_translate={ai_translate_config(assigns)} />
            <.ai_translate_progress ai_translate={ai_translate_config(assigns)} />
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
              disabled={@current_lang in @ai_translate_in_flight}
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
              disabled={@current_lang in @ai_translate_in_flight}
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
            <div class="flex justify-end gap-2 mt-2">
              <button type="button" phx-click="cancel" class="btn btn-ghost btn-sm">
                {gettext("Cancel")}
              </button>
              <button
                type="submit"
                phx-disable-with={gettext("Saving…")}
                disabled={@ai_translate_in_flight != []}
                class="btn btn-primary btn-sm"
              >
                <%= if @live_action == :new, do: gettext("Create"), else: gettext("Save") %>
              </button>
            </div>
          </div>
        </div>
      </.form>

      <%!-- Modal lives outside the form — see project_form_live.ex. --%>
      <.ai_translate_modal ai_translate={ai_translate_config(assigns)} />
    </div>
    """
  end
end
