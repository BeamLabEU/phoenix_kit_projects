defmodule PhoenixKitProjects.Web.TaskFormLive do
  @moduledoc "Create or edit a library task (reusable across projects), including default dependencies."

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitProjects.Gettext
  use PhoenixKitProjects.Web.Components
  # Before the Embed: its hook enqueues translations without a permission
  # check, so the gate (and `ai_translate_allowed?/1` below) sees them first.
  on_mount(PhoenixKitProjects.Web.AITranslateGate)
  use PhoenixKitAI.Components.AITranslate.Embed

  import PhoenixKitWeb.Components.MultilangForm
  import PhoenixKitProjects.Web.Components.DurationInput, only: [duration_input: 1]

  import PhoenixKitProjects.Web.Components.AssigneePicker,
    only: [assignee_multi_picker: 1, assignee_picker_outside: 1]

  import PhoenixKitProjects.Web.Components.FormParts, only: [form_header: 1, words_block: 1]

  require Logger

  alias PhoenixKitAI.Components.AITranslate.FormGlue
  alias PhoenixKitProjects.{Activity, Authz, L10n, Paths, Projects}
  alias PhoenixKitProjects.Schemas.Task
  alias PhoenixKitProjects.Web.Components.{AssigneePicker, DurationInput}
  alias PhoenixKitProjects.Web.Components.{ConfirmAction, DescriptionEditor}
  alias PhoenixKitProjects.Web.DescriptionImages

  import PhoenixKitProjects.Web.Components.DescriptionEditor,
    only: [description_editor: 1, description_value: 4]

  @picker_events AssigneePicker.events()
  alias PhoenixKitProjects.Web.Crumbs
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
      |> mount_multilang(open_on: if(live_action == :edit, do: :viewing_language, else: :primary))
      |> assign(
        wrapper_class: wrapper_class,
        embed_redirect_to: redirect_to,
        live_action: live_action
      )
      |> WebHelpers.assign_embed_state(session)
      |> WebHelpers.assign_embed_user(session)
      |> WebHelpers.attach_open_embed_hook()
      |> apply_action_if_allowed(live_action, resolved_params)
      |> assign_assignee_picker()
      |> assign_ai_translate()
      |> assign(dirty?: false)
      |> DescriptionImages.allow(&description_image_target/1, &ai_translate_allowed?/1)
      |> WebHelpers.keep_host_title()

    {:ok, socket}
  end

  defp assign_ai_translate(socket) do
    resource = if socket.assigns.live_action == :edit, do: socket.assigns.task, else: nil

    FormGlue.assign_ai_translation(
      socket,
      "task",
      resource,
      PhoenixKitProjects.AITranslateBinding
    )
  end

  # The form edits the shared library (a library task is used by every
  # project that assigned it), so it needs `projects.manage_library` — at
  # mount here and again on every write below.
  defp apply_action_if_allowed(socket, live_action, params) do
    if can_manage?(socket) do
      apply_action(socket, live_action, params)
    else
      socket
      |> assign(
        page_title: "",
        task: %Task{},
        live_action: live_action,
        task_deps: [],
        available_deps: []
      )
      |> assign_form(Projects.change_task(%Task{}))
      |> put_flash(:error, no_permission())
      |> WebHelpers.close_or_navigate(Paths.tasks())
    end
  end

  defp can_manage?(socket), do: Authz.manage_library?(socket.assigns[:phoenix_kit_current_scope])

  @doc false
  # The AI-translate modal's events need what a save needs
  # (`Web.AITranslateGate`).
  def ai_translate_allowed?(socket), do: can_manage?(socket) and may_write?(socket)

  # A one-off task belongs to the project that minted it: opening or saving
  # it here (unticking "One-off" included, which promotes it into the shared
  # library) also needs `:edit_tasks` — the right the project asks to edit a
  # task in place — on every project that uses it. The library right alone
  # does not reach into a private project. Answers nil (shown as "Task not
  # found") for a one-off the viewer may not edit.
  defp editable_task(socket, id) do
    case Projects.get_task(id) do
      %Task{ad_hoc: true} = task -> if one_off_editable?(socket, task), do: task
      other -> other
    end
  end

  defp one_off_editable?(socket, %Task{uuid: uuid}) do
    scope = socket.assigns[:phoenix_kit_current_scope]
    Enum.all?(Projects.projects_using_task(uuid), &Authz.can?(scope, &1, :edit_tasks))
  end

  # The write-time twin of `editable_task/2`, asked of the task as stored now.
  defp may_write?(socket) do
    case socket.assigns[:task] do
      %Task{uuid: uuid} when is_binary(uuid) -> editable_task(socket, uuid) != nil
      _ -> true
    end
  end

  defp no_permission, do: gettext("You don't have permission to change the task library.")

  defp apply_action(socket, :new, _params) do
    task = %Task{}

    socket
    |> assign(Crumbs.under(:tasks))
    |> assign(
      # Trail: Admin Panel / Projects / Tasks / New task — "New" creates a
      # standalone library record; a project's composer says "Add".
      page_title: gettext("New task"),
      task: task,
      live_action: :new,
      task_deps: [],
      available_deps: []
    )
    |> assign_form(Projects.change_task(task))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case editable_task(socket, id) do
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
          task_deps: [],
          available_deps: []
        )
        |> assign_form(Projects.change_task(%Task{}))
        |> put_flash(:error, gettext("Task not found."))
        |> WebHelpers.close_or_navigate(Paths.tasks())

      task ->
        socket
        # Trail: Admin Panel / Projects / Tasks / <title> / Edit — the task
        # is a text crumb (the library is its only page), the leaf is the
        # page. The drawer has no trail, so its heading still names the task.
        |> assign(Crumbs.under_task(task))
        |> assign(
          page_title: gettext("Edit"),
          heading:
            gettext("Edit %{title}",
              title: Task.localized_title(task, L10n.current_content_lang())
            ),
          task: task,
          live_action: :edit,
          task_deps: Projects.list_task_dependencies(task.uuid),
          available_deps: Projects.available_task_dependencies(task.uuid)
        )
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
      task_deps: [],
      available_deps: []
    )
    |> assign_form(Projects.change_task(%Task{}))
    |> put_flash(:error, gettext("Task not found."))
    |> WebHelpers.close_or_navigate(Paths.tasks())
  end

  defp assign_form(socket, cs) do
    socket
    |> assign(form: to_form(cs))
    |> then(
      &if(Map.has_key?(&1.assigns, :assignee_selected),
        do: refresh_assignee_chip(&1),
        else: &1
      )
    )
  end

  # ── The default assignees: the task popup's picker ─────────────────
  #
  # Who a task from the library starts with (V30: any number of people,
  # teams and departments); the picker adds, ✕ removes.

  defp assign_assignee_picker(socket) do
    socket
    |> AssigneePicker.init(nil, can_assign?: picker_allowed?(socket), source: "task_library")
    |> refresh_assignee_chip()
  end

  defp refresh_assignee_chip(%{assigns: %{form: %Phoenix.HTML.Form{source: cs}}} = socket),
    do: AssigneePicker.set_selected(socket, AssigneePicker.changeset_keys(cs))

  defp refresh_assignee_chip(socket), do: socket

  @doc false
  # `AssigneePicker` callback: who may save the library task.
  def picker_allowed?(socket), do: can_manage?(socket) and may_write?(socket)

  @doc false
  # `AssigneePicker` callback: the whole new list into the form, as if
  # posted (saved with Save).
  def picker_set(socket, keys) do
    attrs =
      (socket.assigns.form.params || %{})
      |> Map.put("assignees", AssigneePicker.posted(keys))
      |> merge_attrs(socket)

    socket
    |> assign_form(Projects.change_task(socket.assigns.task, attrs))
    |> WebHelpers.mark_dirty()
  end

  # The task's title as typed, in the language whose tab is open.
  defp typed_title(assigns) do
    typed =
      assigns.form.source
      |> Ecto.Changeset.apply_changes()
      |> Task.localized_title(assigns[:current_lang])

    case typed && String.trim(typed) do
      title when is_binary(title) and title != "" -> title
      _ -> ""
    end
  end

  # AI-translate modal events (ai_toggle_modal/ai_select_*/ai_generate_prompt/
  # ai_translate_lang) are handled by `use PhoenixKitAI.Components.AITranslate.Embed`.
  @impl true
  def handle_event("switch_language", %{"lang" => lang_code}, socket) do
    {:noreply, handle_switch_language(socket, lang_code)}
  end

  # Same `:action`-not-stamped pattern as `ProjectFormLive.validate` —
  # surfacing errors only after a failed submit so live editing never
  # red-borders untouched fields.
  def handle_event("validate", %{"task" => attrs}, socket) do
    attrs = merge_attrs(attrs, socket)
    cs = Projects.change_task(socket.assigns.task, attrs)

    {:noreply, socket |> assign_form(cs) |> WebHelpers.mark_dirty()}
  end

  # Close with unsaved changes asks first in the module's own dialog
  # (`Components.ConfirmAction`), never the browser's box; only Close may
  # be put behind it.
  def handle_event("request_confirm", params, socket),
    do: {:noreply, ConfirmAction.request(socket, params, ~w(cancel))}

  def handle_event("confirm_action_cancel", _params, socket),
    do: {:noreply, ConfirmAction.clear(socket)}

  def handle_event("confirm_action_ok", _params, socket) do
    case ConfirmAction.take(socket) do
      {%{event: "cancel" = event, params: params}, socket} -> handle_event(event, params, socket)
      {_none, socket} -> {:noreply, socket}
    end
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, WebHelpers.close_or_navigate(socket, Paths.tasks())}
  end

  # The default-assignee picker (`Web.Components.AssigneePicker`).
  def handle_event(event, params, socket) when event in @picker_events,
    do: AssigneePicker.handle_event(event, params, socket, __MODULE__)

  # The library writes re-check the sub-key against the live scope.
  def handle_event(event, params, socket) when event in ~w(save add_dep remove_dep) do
    if can_manage?(socket) and may_write?(socket),
      do: library_write(event, params, socket),
      else: {:noreply, put_flash(socket, :error, no_permission())}
  end

  defp library_write("save", %{"task" => attrs}, socket) do
    if socket.assigns.ai_in_flight == [] do
      attrs = merge_attrs(attrs, socket)

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

  defp library_write("add_dep", %{"depends_on_task_uuid" => dep_uuid}, socket)
       when dep_uuid != "" do
    case Projects.add_task_dependency(socket.assigns.task.uuid, dep_uuid) do
      {:ok, _} ->
        Activity.log("projects.task_dependency_added",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "task",
          resource_uuid: socket.assigns.task.uuid,
          metadata: %{"task" => socket.assigns.task.title, "depends_on_task_uuid" => dep_uuid}
        )

      _ ->
        Activity.log_failed("projects.task_dependency_added",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "task",
          resource_uuid: socket.assigns.task.uuid,
          metadata: %{"task" => socket.assigns.task.title, "depends_on_task_uuid" => dep_uuid}
        )
    end

    {:noreply, reload_task_deps(socket)}
  end

  defp library_write("add_dep", _params, socket), do: {:noreply, socket}

  defp library_write("remove_dep", %{"uuid" => dep_task_uuid}, socket) do
    case Projects.remove_task_dependency(socket.assigns.task.uuid, dep_task_uuid) do
      {:ok, _} ->
        Activity.log("projects.task_dependency_removed",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "task",
          resource_uuid: socket.assigns.task.uuid,
          metadata: %{
            "task" => socket.assigns.task.title,
            "depends_on_task_uuid" => dep_task_uuid
          }
        )

      _ ->
        Activity.log_failed("projects.task_dependency_removed",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "task",
          resource_uuid: socket.assigns.task.uuid,
          metadata: %{
            "task" => socket.assigns.task.title,
            "depends_on_task_uuid" => dep_task_uuid
          }
        )
    end

    {:noreply, reload_task_deps(socket)}
  end

  defp library_write(_event, _params, socket), do: {:noreply, socket}

  # {:ai_translation, ...} progress/result events are folded into the form
  # by `use PhoenixKitAI.Components.AITranslate.Embed`.

  defp merge_attrs(attrs, socket) do
    in_flight = WebHelpers.in_flight_record(socket, :form, :task)

    attrs
    # An estimate of 1.5 hours is stored as 90 minutes (a whole number).
    |> DurationInput.estimate_attrs()
    |> WebHelpers.merge_translations_attrs(in_flight, Task.translatable_fields())
  end

  # The description editor (Leaf): its text into the form, as if the field
  # had posted it; `@` and `#` suggestions as the textarea offered them.
  @impl true
  def handle_info({:leaf_changed, _} = msg, socket) do
    case DescriptionEditor.changed(msg) do
      {"task-description", lang, markdown} -> {:noreply, put_description(socket, lang, markdown)}
      _ -> {:noreply, socket}
    end
  end

  def handle_info({:leaf_suggest, _} = msg, socket),
    do: {:noreply, DescriptionEditor.suggest(socket, msg, nil)}

  # The editor's own image button: opens the description picture upload's
  # file chooser (`DescriptionImages.pick/1`).
  def handle_info(
        {:leaf_insert_request, %{editor_id: "task-description--" <> _, type: :image}},
        socket
      ),
      do: {:noreply, DescriptionImages.pick(socket)}

  # An image pasted into the description: kept in the library task's folder
  # and placed at the cursor (the boss, 2026-10-31).
  def handle_info(
        {:leaf_paste_image, %{editor_id: "task-description--" <> _ = id} = paste},
        socket
      ),
      do: {:noreply, DescriptionImages.paste(socket, id, paste)}

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Where a picture for the description goes (`DescriptionImages`): the
  # saved library task's folder; nowhere before it is saved.
  defp description_image_target(
         %{assigns: %{live_action: :edit, task: %Task{uuid: uuid} = holder}} = socket
       )
       when is_binary(uuid),
       do:
         {holder, DescriptionEditor.editor_id("task-description", socket.assigns[:current_lang])}

  defp description_image_target(_socket), do: nil

  defp put_description(%{assigns: %{form: form}} = socket, lang, markdown) do
    %{primary_language: primary, multilang_enabled: multi?} = socket.assigns

    if description_value(form, lang, primary, multi?) == markdown do
      socket
    else
      attrs =
        form.params
        |> Map.merge(DescriptionEditor.params(markdown, lang, primary, multi?))
        |> merge_attrs(socket)

      socket
      |> assign_form(Projects.change_task(socket.assigns.task, attrs))
      |> WebHelpers.mark_dirty()
    end
  end

  defp reload_task_deps(socket) do
    assign(socket,
      task_deps: Projects.list_task_dependencies(socket.assigns.task.uuid),
      available_deps: Projects.available_task_dependencies(socket.assigns.task.uuid)
    )
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

  @impl true
  def render(assigns) do
    ~H"""
    <div class={@wrapper_class}>
      <.form_header
        id="task-form-header"
        title={typed_title(assigns)}
        untitled={@live_action != :edit && gettext("New task")}
        mode={if @live_action == :edit, do: gettext("Editing")}
        close_event={@embed_mode not in [:navigate, :emit] && "cancel"}
        close_confirm={@dirty? && gettext("Discard your changes?")}
      >
        <:context>
          <.link
            :if={@embed_mode == :navigate}
            navigate={Paths.tasks()}
            class="btn btn-ghost btn-sm btn-square shrink-0"
            title={gettext("Tasks")}
            aria-label={gettext("Tasks")}
          >
            <.icon name="hero-arrow-left" class="w-4 h-4" />
          </.link>
          <%!-- In a popup no lone "← Tasks" line above the title, as in the
               project popup: the popup closes with its ✕ and Close. --%>
        </:context>
      </.form_header>

      <.form for={@form} id="task-form" phx-change="validate" phx-submit="save" phx-debounce="300" class="flex flex-col gap-3">
        <%!-- The task popup's language block: title + description per
             language, AI translate in the tab row. --%>
        <.words_block
          id="task-words"
          multilang_enabled={@multilang_enabled}
          language_tabs={@language_tabs}
          current_lang={@current_lang}
          ai_translate={FormGlue.ai_translate_config(assigns)}
        >

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
              label=""
              placeholder={gettext("Task name")}
              aria-label={gettext("Task name")}
              disabled={@current_lang in @ai_in_flight}
            />

            <%!-- Pictures are intercepted (`uploads`): pasted or added with
                 the button, kept in the library task's folder and placed by file
                 (`DescriptionImages`); never a `data:` address in the text. --%>
            <.description_editor
                id={DescriptionEditor.editor_id("task-description", @current_lang)}
                name={DescriptionEditor.field_name("task", @current_lang, @primary_language, @multilang_enabled)}
                value={description_value(@form, @current_lang, @primary_language, @multilang_enabled)}
                content={
                  PhoenixKitProjects.InlineImages.resolve(
                    description_value(@form, @current_lang, @primary_language, @multilang_enabled),
                    assigns[:phoenix_kit_current_scope],
                    keep_missing: true,
                    holder: @task
                  )
                }
                placeholder={gettext("Description…")}
                readonly={@current_lang in @ai_in_flight}
                uploads
                image_button={@live_action == :edit}
              />
              <DescriptionImages.file_input :if={@live_action == :edit} uploads={@uploads} />
        </.words_block>

        <%!-- Non-translatable settings (duration, default assignee). --%>
        <div class="card bg-base-100 shadow">
          <div class="card-body flex flex-col gap-3">
            <.duration_input
              id="task-estimate"
              amount_field={@form[:estimated_duration]}
              unit_field={@form[:estimated_duration_unit]}
              label={gettext("Estimated duration")}
            />

            <%!-- One-off (V15): quick-added tasks start hidden from the
                 library; unticking here is how one is promoted. Shown on
                 edit only — a task created from this form IS a library
                 task. --%>
            <.checkbox
              :if={@live_action == :edit}
              field={@form[:ad_hoc]}
              label={gettext("One-off task")}
              title={gettext("Hidden from the task library and its pickers; the projects using it are unaffected.")}
              class="checkbox-primary checkbox-sm"
            />

            <%!-- Whom the task goes to when it is added to a project (V30:
                 any number): the task popup's picker. --%>
            <.assignee_multi_picker
              id="task-default-assignee"
              label={gettext("Default assignment")}
              search_form="task-default-assignee-form"
              name="task[assignees][]"
              selected={@assignee_selected}
              rows={@assignee_rows}
              can_assign?={@can_assign?}
              my_person_uuid={@my_person_uuid}
              recent={@recent_assignees}
              notice={@assignee_notice}
              view={@assignee_view}
              home={@assignee_home}
              more?={not is_nil(@assignee_cursor)}
              none?={@assignee_seen == %{}}
              open?={@assignee_open?}
              streams={@streams}
            />
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
          <.form_section title={gettext("Default dependencies")}>
              <:subtitle>
                {gettext("When this task is added to a project, dependencies will be auto-created for any of these tasks already in the same project.")}
              </:subtitle>

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
          </.form_section>
        <% end %>

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
            {ConfirmAction.close("cancel", @dirty?)}
            class="btn btn-ghost btn-sm"
          >
            {gettext("Close")}
          </button>
          </:cancel>
        </.form_actions>
      </.form>

      <%!-- Modal lives outside the form — see project_form_live.ex. --%>
      <.ai_translate_modal ai_translate={FormGlue.ai_translate_config(assigns)} />
      <.assignee_picker_outside search_form="task-default-assignee-form" staff_confirm={@staff_confirm} />
      <.confirm_action_modal confirm={assigns[:confirm_action]} />
    </div>
    """
  end
end
