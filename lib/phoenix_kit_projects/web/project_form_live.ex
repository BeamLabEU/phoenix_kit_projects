defmodule PhoenixKitProjects.Web.ProjectFormLive do
  @moduledoc "Create or edit a project."

  use PhoenixKitWeb, :live_view
  use PhoenixKitWeb.Components.AITranslate.Embed
  use Gettext, backend: PhoenixKitProjects.Gettext
  use PhoenixKitProjects.Web.Components

  import PhoenixKitWeb.Components.MultilangForm

  alias PhoenixKit.Utils.Values
  alias PhoenixKitProjects.{Activity, Errors, L10n, Paths, Projects, Statuses}
  alias PhoenixKitProjects.Schemas.Project
  alias PhoenixKitProjects.Web.Helpers, as: WebHelpers
  alias PhoenixKitWeb.Components.AITranslate.FormGlue

  require Logger

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
        statuses_available: Statuses.available?(),
        status_entities: status_entity_options()
      )
      |> WebHelpers.assign_embed_state(session)
      |> WebHelpers.attach_open_embed_hook()
      |> apply_action(live_action, resolved_params)
      |> assign_assignee_state()
      |> assign_status_preview()
      |> assign_status_mode()
      |> assign_ai_translate()

    {:ok, socket}
  end

  defp assign_ai_translate(socket) do
    resource = if socket.assigns.live_action == :edit, do: socket.assigns.project, else: nil

    FormGlue.assign_ai_translation(
      socket,
      "project",
      resource,
      PhoenixKitProjects.AITranslateBinding
    )
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

  # Assignee picker state (V128). `assign_type` ("" / "team" / "department" /
  # "person") drives which staff `<.select>` shows; the staff option lists are
  # loaded once. Mirrors `AssignmentFormLive`'s assignee picker.
  defp assign_assignee_state(socket) do
    assign(socket,
      assign_type: assignee_type(socket.assigns.project),
      team_options: load_teams(),
      department_options: load_departments(),
      person_options: load_people()
    )
  end

  defp assignee_type(%Project{assigned_person_uuid: u}) when not is_nil(u), do: "person"
  defp assignee_type(%Project{assigned_team_uuid: u}) when not is_nil(u), do: "team"
  defp assignee_type(%Project{assigned_department_uuid: u}) when not is_nil(u), do: "department"
  defp assignee_type(_), do: ""

  # `rescue` so a `phoenix_kit_staff` DB hiccup degrades to an empty picker
  # rather than taking the form down (same pattern as the context's staff
  # lookups + `AssignmentFormLive`).
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

  # Null out the assignee fields that don't match the chosen `assign_type`, so
  # switching from Team to Person doesn't leave a stale team uuid set (which the
  # single-assignee CHECK would then reject).
  defp clear_other_assignees(attrs, "team"),
    do: Map.merge(attrs, %{"assigned_department_uuid" => nil, "assigned_person_uuid" => nil})

  defp clear_other_assignees(attrs, "department"),
    do: Map.merge(attrs, %{"assigned_team_uuid" => nil, "assigned_person_uuid" => nil})

  defp clear_other_assignees(attrs, "person"),
    do: Map.merge(attrs, %{"assigned_team_uuid" => nil, "assigned_department_uuid" => nil})

  defp clear_other_assignees(attrs, _),
    do:
      Map.merge(attrs, %{
        "assigned_team_uuid" => nil,
        "assigned_department_uuid" => nil,
        "assigned_person_uuid" => nil
      })

  # Grouped status-source entities for the selector (status catalogs first,
  # then any other entity). Empty when entities is unavailable — the
  # selector then shows just the "Shared default" option.
  defp status_entity_options, do: Statuses.list_status_source_entities()

  # Computes the preview of statuses that the currently-selected entity
  # would supply (the records that get cemented at start). "Shared default"
  # (nil) previews the shared catalog without provisioning it. Must run
  # after `assign_form/2` since it reads the form's current value.
  defp assign_status_preview(socket) do
    preview =
      if socket.assigns.statuses_available do
        case selected_status_entity_uuid(socket) do
          nil -> Statuses.shared_catalog_statuses()
          uuid -> Statuses.list_catalog_statuses(uuid)
        end
      else
        []
      end

    assign(socket, status_preview: preview)
  end

  defp selected_status_entity_uuid(socket) do
    case socket.assigns.form[:status_entity_uuid].value do
      v when v in [nil, ""] -> nil
      v -> to_string(v)
    end
  end

  # The 3-way status-translation control: "" = inherit global, "true" =
  # force on, "false" = force off. Tracked in an assign so it survives
  # `validate` re-renders, then folded into `settings` JSONB on save.
  defp assign_status_mode(socket),
    do: assign(socket, status_translation_mode: status_mode_string(socket.assigns.project))

  defp status_mode_string(project) do
    case Project.status_translation_override(project) do
      true -> "true"
      false -> "false"
      _ -> ""
    end
  end

  defp apply_status_mode_to_attrs(attrs, params, project) do
    base = project.settings || %{}

    settings =
      case Map.get(params, "status_translation_mode") do
        "true" -> Map.put(base, "use_status_translations", true)
        "false" -> Map.put(base, "use_status_translations", false)
        _ -> Map.delete(base, "use_status_translations")
      end

    Map.put(attrs, "settings", settings)
  end

  @impl true
  def handle_event("switch_language", %{"lang" => lang_code}, socket) do
    {:noreply, handle_switch_language(socket, lang_code)}
  end

  # AI-translate modal events handled by `use ...AITranslate.Embed`.

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
    assign_type = Map.get(params, "assign_type", socket.assigns.assign_type)
    attrs = attrs |> merge_attrs(socket) |> clear_other_assignees(assign_type)

    cs =
      Projects.change_project(socket.assigns.project, attrs,
        enforce_scheduled_date_required: false
      )

    {:noreply,
     socket
     |> assign(selected_template: selected_template, assign_type: assign_type)
     |> assign(
       status_translation_mode:
         Map.get(params, "status_translation_mode", socket.assigns.status_translation_mode)
     )
     |> assign_form(cs)
     |> assign_status_preview()}
  end

  def handle_event("save", %{"project" => attrs} = params, socket) do
    if socket.assigns.ai_in_flight == [] do
      template_uuid = Map.get(params, "template_uuid", nil) |> Values.blank_to_nil()
      assign_type = Map.get(params, "assign_type", socket.assigns.assign_type)

      attrs =
        merge_attrs(attrs, socket)
        |> clear_other_assignees(assign_type)
        |> apply_status_mode_to_attrs(params, socket.assigns.project)

      save(socket, socket.assigns.live_action, attrs, template_uuid)
    else
      # AI translation in flight on at least one lang. Block save —
      # the worker is about to write to `translations` and a save now
      # would race the worker's persist. The form's save button is
      # disabled when `@ai_in_flight != []`, but a stray
      # keyboard shortcut / `phx-key=Enter` could still submit, so this is the
      # belt-and-suspenders guard.
      {:noreply,
       put_flash(
         socket,
         :info,
         gettext("Hold on — wait for the translation to finish before saving.")
       )}
    end
  end

  # Creates a fresh default status list (`project_statuses`, auto-incrementing
  # if taken) and selects it for this project. Always a new entity — so a
  # user who has edited a previous generated list gets a clean one for the
  # next project. Reloads the selector options.
  def handle_event("generate_default_statuses", _params, socket) do
    case Statuses.create_default_status_entity(actor_uuid: Activity.actor_uuid(socket)) do
      {:ok, entity} ->
        Activity.log("projects.status_entity_provisioned",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "project",
          resource_uuid: socket.assigns.project.uuid,
          metadata: %{"entity_name" => entity.name, "scope" => "shared"}
        )

        cs =
          Projects.change_project(socket.assigns.project, %{"status_entity_uuid" => entity.uuid})

        {:noreply,
         socket
         |> assign(status_entities: status_entity_options())
         |> assign_form(cs)
         |> assign_status_preview()
         |> put_flash(:info, gettext("Default statuses entity created."))}

      {:error, _reason} ->
        {:noreply,
         put_flash(socket, :error, gettext("Could not create the default statuses entity."))}
    end
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, WebHelpers.close_or_navigate(socket, Paths.projects())}
  end

  # {:ai_translation, ...} events folded into the form by `use ...AITranslate.Embed`.

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
    # A started project's status source is frozen (cemented at start): the
    # picker is locked in the form and this strips any forced change. With the
    # source unchanged, the re-cement branch inside
    # `update_project_with_statuses/2` never fires for a started project;
    # unstarted projects (source still editable) cement at start as usual.
    attrs = Statuses.lock_status_source(attrs, socket.assigns.project)

    case Statuses.update_project_with_statuses(socket.assigns.project, attrs) do
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

          <%!-- `px-6` matches daisyUI's default `.card-body` inline
               padding so the row aligns with the input fields below.
               `-mt-2 py-1` pulls the row tight against the language
               tab strip above — boss wanted the AI button closer to
               the list of languages. --%>
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
            <%!-- daisyUI's bare `.skeleton` resolves to a ~8%-opacity
                 base-content grey, which is nearly invisible on the
                 `bg-base-100` (pure white) card we render inside —
                 user reported seeing what looked like a "blank white
                 page" during the lang-switch window. `bg-base-content/15`
                 gives a visible mid-grey on every theme + Tailwind's
                 `animate-pulse` carries the loading affordance. --%>
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

            <%!-- Assignee (V128) — same polymorphic team/department/person
                 picker tasks use. Non-translatable, so it lives outside the
                 multilang wrapper. `assign_type` chooses which staff select
                 shows; `clear_other_assignees/2` nulls the rest on change. --%>
            <.select
              name="assign_type"
              label={gettext("Assign to")}
              value={@assign_type}
              options={[
                {gettext("Nobody"), ""},
                {gettext("Department"), "department"},
                {gettext("Team"), "team"},
                {gettext("Person"), "person"}
              ]}
            />
            <%= if @assign_type == "department" do %>
              <.select field={@form[:assigned_department_uuid]} label={gettext("Department")} options={@department_options} prompt={gettext("Select department")} />
            <% end %>
            <%= if @assign_type == "team" do %>
              <.select field={@form[:assigned_team_uuid]} label={gettext("Team")} options={@team_options} prompt={gettext("Select team")} />
            <% end %>
            <%= if @assign_type == "person" do %>
              <.select field={@form[:assigned_person_uuid]} label={gettext("Person")} options={@person_options} prompt={gettext("Select person")} />
            <% end %>

            <%!-- Workflow-status list selection (entities-backed), via the
                 shared `<.workflow_status_fields>` so projects, templates and
                 sub-projects render an identical section. The source is a
                 pre-start choice — `locked` once the project has started,
                 since its statuses were cemented at `started_at`. --%>
            <.workflow_status_fields
              statuses_available={@statuses_available}
              field={@form[:status_entity_uuid]}
              status_entities={@status_entities}
              status_preview={@status_preview}
              status_translation_mode={@status_translation_mode}
              locked={Statuses.started?(@project)}
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

      <%!--
        AI translate modal lives OUTSIDE the project form on purpose
        — HTML doesn't permit nested `<form>` elements, so a `<form
        phx-change="select_ai_endpoint">` rendered inside the outer
        project form gets flattened by the browser: select changes
        end up firing the outer form's `validate` event instead.
        Rendering the modal here sidesteps that.
      --%>
      <.ai_translate_modal ai_translate={FormGlue.ai_translate_config(assigns)} />
    </div>
    """
  end
end
