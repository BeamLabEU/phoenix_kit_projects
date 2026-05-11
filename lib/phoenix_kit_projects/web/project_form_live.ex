defmodule PhoenixKitProjects.Web.ProjectFormLive do
  @moduledoc "Create or edit a project."

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  import PhoenixKitWeb.Components.MultilangForm

  alias PhoenixKitProjects.{Activity, Errors, L10n, Paths, Projects}
  alias PhoenixKitProjects.Schemas.Project
  alias PhoenixKitProjects.Web.Helpers, as: WebHelpers

  @impl true
  def mount(params, _session, socket) do
    socket = mount_multilang(socket)
    {:ok, apply_action(socket, socket.assigns.live_action, params)}
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
        |> put_flash(:error, gettext("Project not found."))
        |> push_navigate(to: Paths.projects())

      project ->
        socket
        |> assign(
          page_title:
            gettext("Edit %{name}", name: Project.localized_name(project, L10n.current_content_lang())),
          project: project,
          live_action: :edit,
          templates: [],
          selected_template: nil
        )
        |> assign_form(Projects.change_project(project))
    end
  end

  defp assign_form(socket, cs), do: assign(socket, form: to_form(cs))

  @impl true
  def handle_event("switch_language", %{"lang" => lang_code}, socket) do
    {:noreply, handle_switch_language(socket, lang_code)}
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
    template_uuid = Map.get(params, "template_uuid", nil) |> blank_to_nil()
    save(socket, socket.assigns.live_action, merge_attrs(attrs, socket), template_uuid)
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
         |> push_navigate(to: Paths.project(project.uuid))}

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
         |> push_navigate(to: Paths.project(project.uuid))}

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
         |> push_navigate(to: Paths.project(project.uuid))}

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

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v

  defp start_mode_value(form) do
    case form[:start_mode] do
      %{value: val} when is_binary(val) and val != "" -> val
      _ -> "immediate"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-xl px-4 py-6 gap-4">
      <div>
        <.link navigate={Paths.projects()} class="link link-hover text-sm">
          <.icon name="hero-arrow-left" class="w-4 h-4 inline" /> {gettext("Projects")}
        </.link>
        <h1 class="text-2xl font-bold mt-1">{@page_title}</h1>
      </div>

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
              <.link navigate={Paths.projects()} class="btn btn-ghost btn-sm">{gettext("Cancel")}</.link>
              <button type="submit" phx-disable-with={gettext("Saving…")} class="btn btn-primary btn-sm">
                <%= if @live_action == :new, do: gettext("Create"), else: gettext("Save") %>
              </button>
            </div>
          </div>
        </div>
      </.form>
    </div>
    """
  end
end
