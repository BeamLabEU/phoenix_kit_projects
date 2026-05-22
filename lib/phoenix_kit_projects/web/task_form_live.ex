defmodule PhoenixKitProjects.Web.TaskFormLive do
  @moduledoc "Create or edit a reusable task template, including default dependencies."

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitProjects.Gettext
  use PhoenixKitProjects.Web.Components

  import PhoenixKitWeb.Components.MultilangForm

  require Logger

  alias PhoenixKit.PubSub.Manager, as: PubSubManager
  alias PhoenixKitProjects.{Activity, L10n, Paths, Projects, Translations}
  alias PhoenixKitProjects.PubSub, as: ProjectsPubSub
  alias PhoenixKitProjects.Schemas.Task
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

    # `apply_action/3` loads the task on `:edit`; runs at the tail of
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

  # Tasks don't have a per-resource topic (a task can belong to many
  # projects via assignments), so subscribe to the tasks-wide topic.
  # That's still narrower than `topic_all/0` — it skips project / template
  # / dependency CRUD broadcasts the form doesn't care about.
  defp maybe_subscribe_translations(%{assigns: %{live_action: :new}} = socket), do: socket

  defp maybe_subscribe_translations(socket) do
    if Phoenix.LiveView.connected?(socket) and Translations.ai_translation_available?() and
         is_binary(socket.assigns.task.uuid) do
      PubSubManager.subscribe(ProjectsPubSub.topic_tasks())
    end

    socket
  end

  defp apply_action(socket, :new, _params) do
    task = %Task{}

    socket
    |> assign(
      page_title: gettext("New task"),
      task: task,
      live_action: :new,
      assign_type: "",
      task_deps: [],
      available_deps: []
    )
    |> assign_staff_options()
    |> assign_form(Projects.change_task(task))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case Projects.get_task(id) do
      nil ->
        # In navigate mode, `close_or_navigate` push-navigates and the LV
        # is replaced before render. In emit mode it broadcasts `:closed`
        # but the LV stays mounted until the host pulls down the modal —
        # so we need render-safe placeholders for the brief window between
        # emit and host-side teardown.
        socket
        |> assign(
          page_title: "",
          task: %Task{},
          live_action: :edit,
          assign_type: "",
          task_deps: [],
          available_deps: []
        )
        |> assign_staff_options()
        |> assign_form(Projects.change_task(%Task{}))
        |> put_flash(:error, gettext("Task not found."))
        |> WebHelpers.close_or_navigate(Paths.tasks())

      task ->
        assign_type =
          cond do
            task.default_assigned_person_uuid -> "person"
            task.default_assigned_team_uuid -> "team"
            task.default_assigned_department_uuid -> "department"
            true -> ""
          end

        socket
        |> assign(
          page_title:
            gettext("Edit %{title}",
              title: Task.localized_title(task, L10n.current_content_lang())
            ),
          task: task,
          live_action: :edit,
          assign_type: assign_type,
          task_deps: Projects.list_task_dependencies(task.uuid),
          available_deps: Projects.available_task_dependencies(task.uuid)
        )
        |> assign_staff_options()
        |> assign_form(Projects.change_task(task))
    end
  end

  # Fail-closed catch-all: emit-session lacking `"id"` for :edit lands
  # here. Render placeholders + flash, then close.
  defp apply_action(socket, :edit, _params) do
    socket
    |> assign(
      page_title: "",
      task: %Task{},
      live_action: :edit,
      assign_type: "",
      task_deps: [],
      available_deps: []
    )
    |> assign_staff_options()
    |> assign_form(Projects.change_task(%Task{}))
    |> put_flash(:error, gettext("Task not found."))
    |> WebHelpers.close_or_navigate(Paths.tasks())
  end

  defp assign_staff_options(socket) do
    assign(socket,
      team_options: load_teams(),
      department_options: load_departments(),
      person_options: load_people()
    )
  end

  defp load_teams do
    PhoenixKitStaff.Teams.list() |> Enum.map(&{"#{&1.name} (#{&1.department.name})", &1.uuid})
  rescue
    e in [Postgrex.Error, DBConnection.ConnectionError, Ecto.QueryError] ->
      Logger.warning("[Projects] load_teams failed: #{Exception.message(e)}")
      []
  end

  defp load_departments do
    PhoenixKitStaff.Departments.list() |> Enum.map(&{&1.name, &1.uuid})
  rescue
    e in [Postgrex.Error, DBConnection.ConnectionError, Ecto.QueryError] ->
      Logger.warning("[Projects] load_departments failed: #{Exception.message(e)}")
      []
  end

  defp load_people do
    PhoenixKitStaff.Staff.list_people()
    |> Enum.map(&{(&1.user && &1.user.email) || "—", &1.uuid})
  rescue
    e in [Postgrex.Error, DBConnection.ConnectionError, Ecto.QueryError] ->
      Logger.warning("[Projects] load_people failed: #{Exception.message(e)}")
      []
  end

  defp assign_form(socket, cs), do: assign(socket, form: to_form(cs))

  @impl true
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

  def handle_event("switch_language", %{"lang" => lang_code}, socket) do
    {:noreply, handle_switch_language(socket, lang_code)}
  end

  # Same `:action`-not-stamped pattern as `ProjectFormLive.validate` —
  # surfacing errors only after a failed submit so live editing never
  # red-borders untouched fields.
  def handle_event("validate", %{"task" => attrs} = params, socket) do
    assign_type = Map.get(params, "default_assign_type", socket.assigns.assign_type)
    attrs = merge_attrs(attrs, socket)
    cs = Projects.change_task(socket.assigns.task, attrs)
    {:noreply, socket |> assign(assign_type: assign_type) |> assign_form(cs)}
  end

  def handle_event("save", %{"task" => attrs} = params, socket) do
    if socket.assigns.ai_translate_in_flight == [] do
      assign_type = Map.get(params, "default_assign_type", "")

      attrs =
        attrs
        |> clear_other_default_assignees(assign_type)
        |> then(&merge_attrs(&1, socket))

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

  def handle_event("add_dep", %{"depends_on_task_uuid" => dep_uuid}, socket)
      when dep_uuid != "" do
    case Projects.add_task_dependency(socket.assigns.task.uuid, dep_uuid) do
      {:ok, _} ->
        Activity.log("projects.task_dependency_added",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "task",
          resource_uuid: socket.assigns.task.uuid,
          target_uuid: dep_uuid,
          metadata: %{"task" => socket.assigns.task.title}
        )

      _ ->
        Activity.log_failed("projects.task_dependency_added",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "task",
          resource_uuid: socket.assigns.task.uuid,
          target_uuid: dep_uuid,
          metadata: %{"task" => socket.assigns.task.title}
        )
    end

    {:noreply, reload_task_deps(socket)}
  end

  def handle_event("add_dep", _params, socket), do: {:noreply, socket}

  def handle_event("cancel", _params, socket) do
    {:noreply, WebHelpers.close_or_navigate(socket, Paths.tasks())}
  end

  def handle_event("remove_dep", %{"uuid" => dep_task_uuid}, socket) do
    case Projects.remove_task_dependency(socket.assigns.task.uuid, dep_task_uuid) do
      {:ok, _} ->
        Activity.log("projects.task_dependency_removed",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "task",
          resource_uuid: socket.assigns.task.uuid,
          target_uuid: dep_task_uuid,
          metadata: %{"task" => socket.assigns.task.title}
        )

      _ ->
        Activity.log_failed("projects.task_dependency_removed",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "task",
          resource_uuid: socket.assigns.task.uuid,
          target_uuid: dep_task_uuid,
          metadata: %{"task" => socket.assigns.task.title}
        )
    end

    {:noreply, reload_task_deps(socket)}
  end

  @impl true
  def handle_info(
        {:projects, :translation_started, %{resource_uuid: uuid, target_lang: lang}},
        socket
      )
      when uuid == socket.assigns.task.uuid do
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
      when uuid == socket.assigns.task.uuid do
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
      case Projects.get_task(uuid) do
        nil ->
          {:noreply, socket}

        reloaded ->
          new_translation = Map.get(reloaded.translations || %{}, lang, %{})

          {:noreply,
           socket
           |> assign(:task, reloaded)
           |> patch_form_translations(lang, new_translation)
           |> put_flash(:info, gettext("Translated to %{lang}.", lang: String.upcase(lang)))}
      end
    end
  end

  def handle_info(
        {:projects, :translation_failed, %{resource_uuid: uuid, target_lang: lang}},
        socket
      )
      when uuid == socket.assigns.task.uuid do
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
      gettext("Save the task first, then you can translate it with AI.")
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
      resource_type: "task",
      resource_uuid: socket.assigns.task.uuid,
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
      resource_type: "task",
      resource_uuid: socket.assigns.task.uuid,
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
      assigns.task.translations,
      Task.translatable_fields()
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

  defp merge_attrs(attrs, socket) do
    in_flight = WebHelpers.in_flight_record(socket, :form, :task)
    WebHelpers.merge_translations_attrs(attrs, in_flight, Task.translatable_fields())
  end

  defp reload_task_deps(socket) do
    assign(socket,
      task_deps: Projects.list_task_dependencies(socket.assigns.task.uuid),
      available_deps: Projects.available_task_dependencies(socket.assigns.task.uuid)
    )
  end

  defp clear_other_default_assignees(attrs, "team") do
    attrs
    |> Map.put("default_assigned_department_uuid", nil)
    |> Map.put("default_assigned_person_uuid", nil)
  end

  defp clear_other_default_assignees(attrs, "department") do
    attrs
    |> Map.put("default_assigned_team_uuid", nil)
    |> Map.put("default_assigned_person_uuid", nil)
  end

  defp clear_other_default_assignees(attrs, "person") do
    attrs
    |> Map.put("default_assigned_team_uuid", nil)
    |> Map.put("default_assigned_department_uuid", nil)
  end

  defp clear_other_default_assignees(attrs, _) do
    attrs
    |> Map.put("default_assigned_team_uuid", nil)
    |> Map.put("default_assigned_department_uuid", nil)
    |> Map.put("default_assigned_person_uuid", nil)
  end

  defp save(socket, :new, attrs) do
    case Projects.create_task(attrs) do
      {:ok, task} ->
        Activity.log("projects.task_created",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "task",
          resource_uuid: task.uuid,
          metadata: %{"title" => task.title}
        )

        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("Task created. You can now add default dependencies by editing it.")
         )
         |> WebHelpers.navigate_after_save(Paths.edit_task(task.uuid),
           kind: :task,
           record: task,
           action: :create,
           # Emit-mode equivalent of the navigate-mode "go to /edit so
           # the user can add dependencies": tell the host to pop the
           # current frame and open the edit form on top.
           next:
             {PhoenixKitProjects.Web.TaskFormLive, %{"live_action" => "edit", "id" => task.uuid}}
         )}

      {:error, cs} ->
        Activity.log_failed("projects.task_created",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "task",
          metadata: %{"title" => Map.get(attrs, "title") || Ecto.Changeset.get_field(cs, :title)}
        )

        {:noreply, on_save_error(socket, cs)}
    end
  end

  defp save(socket, :edit, attrs) do
    case Projects.update_task(socket.assigns.task, attrs) do
      {:ok, task} ->
        Activity.log("projects.task_updated",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "task",
          resource_uuid: task.uuid,
          metadata: %{"title" => task.title}
        )

        {:noreply,
         socket
         |> put_flash(:info, gettext("Task updated."))
         |> WebHelpers.navigate_after_save(Paths.tasks(),
           kind: :task,
           record: task,
           action: :update
         )}

      {:error, cs} ->
        Activity.log_failed("projects.task_updated",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "task",
          resource_uuid: socket.assigns.task.uuid,
          metadata: %{"title" => socket.assigns.task.title}
        )

        {:noreply, on_save_error(socket, cs)}
    end
  end

  # Same shape as ProjectFormLive — flips back to the primary tab when
  # the save error sits on a translatable primary field, otherwise the
  # secondary-tab user wouldn't see anything change.
  defp on_save_error(socket, %Ecto.Changeset{} = cs) do
    socket
    |> assign_form(cs)
    |> WebHelpers.maybe_switch_to_primary_on_error(cs, [:title, :description])
    |> put_flash(:error, first_error_message(cs))
  end

  defp first_error_message(%Ecto.Changeset{errors: [{field, {msg, _opts}} | _]}) do
    gettext("%{field}: %{message}", field: humanize(field), message: msg)
  end

  defp first_error_message(_), do: gettext("Could not save the task.")

  defp humanize(field) do
    field |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  defp duration_unit_options do
    [
      {gettext("Minutes"), "minutes"},
      {gettext("Hours"), "hours"},
      {gettext("Days"), "days"},
      {gettext("Weeks"), "weeks"},
      {gettext("Fortnights"), "fortnights"},
      {gettext("Months"), "months"},
      {gettext("Years"), "years"}
    ]
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class={@wrapper_class}>
      <.page_header title={@page_title}>
        <:back_link>
          <.smart_link
            navigate={Paths.tasks()}
            emit={{PhoenixKitProjects.Web.TasksLive, %{}}}
            embed_mode={@embed_mode}
            class="link link-hover text-sm"
          >
            <.icon name="hero-arrow-left" class="w-4 h-4 inline" /> {gettext("Task Library")}
          </.smart_link>
        </:back_link>
      </.page_header>

      <.form for={@form} id="task-form" phx-change="validate" phx-submit="save" phx-debounce="300" class="flex flex-col gap-4">
        <%!-- Translatable card: title + description with language tabs. --%>
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
              field_name="title"
              form_prefix="task"
              changeset={@form.source}
              schema_field={:title}
              multilang_enabled={@multilang_enabled}
              current_lang={@current_lang}
              primary_language={@primary_language}
              lang_data={WebHelpers.lang_data(@form, @current_lang)}
              secondary_name={"task[translations][#{@current_lang}][title]"}
              lang_data_key="title"
              label={gettext("Title")}
              disabled={@current_lang in @ai_translate_in_flight}
              required
            />

            <.translatable_field
              field_name="description"
              form_prefix="task"
              changeset={@form.source}
              schema_field={:description}
              multilang_enabled={@multilang_enabled}
              current_lang={@current_lang}
              primary_language={@primary_language}
              lang_data={WebHelpers.lang_data(@form, @current_lang)}
              secondary_name={"task[translations][#{@current_lang}][description]"}
              lang_data_key="description"
              label={gettext("Description")}
              type="textarea"
              rows={4}
              disabled={@current_lang in @ai_translate_in_flight}
            />
          </.multilang_fields_wrapper>
        </div>

        <%!-- Non-translatable settings (duration, default assignee). --%>
        <div class="card bg-base-100 shadow">
          <div class="card-body flex flex-col gap-3">
            <div class="flex gap-2">
              <div class="flex-1">
                <.input field={@form[:estimated_duration]} label={gettext("Estimated duration")} type="number" />
              </div>
              <div class="w-40">
                <.select
                  field={@form[:estimated_duration_unit]}
                  label={gettext("Unit")}
                  options={duration_unit_options()}
                />
              </div>
            </div>

            <div class="divider text-xs text-base-content/50 my-1">{gettext("Default assignment (optional)")}</div>

            <.select
              name="default_assign_type"
              label={gettext("Default assign to")}
              value={@assign_type}
              options={[{gettext("Nobody"), ""}, {gettext("Department"), "department"}, {gettext("Team"), "team"}, {gettext("Person"), "person"}]}
            />

            <%= if @assign_type == "department" do %>
              <.select field={@form[:default_assigned_department_uuid]} label={gettext("Department")} options={@department_options} prompt={gettext("Select department")} />
            <% end %>
            <%= if @assign_type == "team" do %>
              <.select field={@form[:default_assigned_team_uuid]} label={gettext("Team")} options={@team_options} prompt={gettext("Select team")} />
            <% end %>
            <%= if @assign_type == "person" do %>
              <.select field={@form[:default_assigned_person_uuid]} label={gettext("Person")} options={@person_options} prompt={gettext("Select person")} />
            <% end %>
          </div>
        </div>

        <%!-- Default dependencies (edit mode only — task must exist
             first since deps FK-reference its uuid). Lives INSIDE
             the form so it sits above the action row, matching the
             same convention used in `AssignmentFormLive`. The picker
             uses `phx-change` on the `<.select>` instead of a nested
             `<.form>` to avoid nested-form HTML invalidity. --%>
        <%= if @live_action == :edit do %>
          <% lang = L10n.current_content_lang() %>
          <div class="card bg-base-100 shadow">
            <div class="card-body">
              <h2 class="card-title text-lg">{gettext("Default dependencies")}</h2>
              <p class="text-xs text-base-content/60">
                {gettext("When this task is added to a project, dependencies will be auto-created for any of these tasks already in the same project.")}
              </p>

              <%= if @task_deps != [] do %>
                <div class="flex flex-wrap gap-2 mt-2">
                  <%= for dep <- @task_deps do %>
                    <span class="badge badge-outline gap-1">
                      {Task.localized_title(dep.depends_on_task, lang)}
                      <button
                        type="button"
                        phx-click="remove_dep"
                        phx-value-uuid={dep.depends_on_task_uuid}
                        phx-disable-with={gettext("Removing…")}
                        class="hover:text-error"
                      >
                        <.icon name="hero-x-mark" class="w-3 h-3" />
                      </button>
                    </span>
                  <% end %>
                </div>
              <% end %>

              <%= if @available_deps != [] do %>
                <.select
                  name="depends_on_task_uuid"
                  label={gettext("Add dependency")}
                  value=""
                  options={Enum.map(@available_deps, &{Task.localized_title(&1, lang), &1.uuid})}
                  prompt={gettext("Select task")}
                  phx-change="add_dep"
                />
              <% end %>

              <%= if @task_deps == [] and @available_deps == [] do %>
                <p class="text-sm text-base-content/50 mt-2">{gettext("No other tasks in the library to depend on.")}</p>
              <% end %>
            </div>
          </div>
        <% end %>

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
      </.form>

      <%!-- Modal lives outside the form — see project_form_live.ex. --%>
      <.ai_translate_modal ai_translate={ai_translate_config(assigns)} />
    </div>
    """
  end
end
