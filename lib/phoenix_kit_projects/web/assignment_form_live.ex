defmodule PhoenixKitProjects.Web.AssignmentFormLive do
  @moduledoc """
  Add a task to a project or edit an existing assignment.
  Supports picking from library or creating new. Manages assignment
  dependencies (which tasks in this project must finish first).
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitProjects.Gettext
  use PhoenixKitProjects.Web.Components
  # The typeahead's server half + the access-request events. Injected
  # rather than hand-written so this form can't drift from every other
  # surface that offers mentions.
  use PhoenixKitProjects.Web.Mentions
  # Before the Embed: its hook enqueues translations without a permission
  # check, so the gate (and `ai_translate_allowed?/1` below) sees them first.
  on_mount(PhoenixKitProjects.Web.AITranslateGate)
  # Every write event re-checks `write_allowed?/1` against the live scope.
  on_mount(PhoenixKitProjects.Web.WriteGate)
  use PhoenixKitAI.Components.AITranslate.Embed

  import PhoenixKitWeb.Components.Core.SearchPicker, only: [search_picker: 1]
  import PhoenixKitWeb.Components.MultilangForm
  import PhoenixKitProjects.Web.Components.TimeInput, only: [datetime_input: 1, clock_input: 1]
  import PhoenixKitProjects.Web.Components.DurationInput, only: [duration_input: 1]

  import PhoenixKitProjects.Web.Components.AssigneePicker,
    only: [assignee_picker: 1, assignee_multi_picker: 1, assignee_picker_outside: 1]

  import PhoenixKitProjects.Web.Components.FormParts
  import PhoenixKitProjects.Web.Components.TaskFiles, only: [task_files: 1]

  import PhoenixKitProjects.Web.Components.DescriptionEditor,
    only: [description_editor: 1, description_value: 4]

  require Logger

  alias Phoenix.LiveView.JS
  alias PhoenixKit.Mentions
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitAI.Components.AITranslate.FormGlue

  alias PhoenixKitProjects.{
    Activity,
    Assignees,
    Attachments,
    Authz,
    Features,
    L10n,
    Labels,
    LibrarySearch,
    MoveLock,
    Outline,
    Paths,
    Projects,
    RefText,
    Statuses
  }

  alias PhoenixKitProjects.Schemas.{Assignment, Project, Task}

  alias PhoenixKitProjects.InlineImages
  alias PhoenixKitProjects.Repeats

  alias PhoenixKitProjects.Web.Components.{
    AssigneePicker,
    AssignmentStatusBadge,
    ConfirmAction,
    DescriptionEditor,
    DurationInput,
    TimeInput
  }

  alias PhoenixKitProjects.Web.Components.WorkflowStatusFields, as: WSF
  alias PhoenixKitProjects.Web.Crumbs
  alias PhoenixKitProjects.Web.DescriptionImages
  alias PhoenixKitProjects.Web.Helpers, as: WebHelpers
  alias PhoenixKitProjects.Web.WriteGate
  alias PhoenixKitWeb.Components.Core.FormFieldLabel

  # Default wrapper class for the standalone admin page. Embedders can
  # override via `live_render(... session: %{"wrapper_class" => "..."})`.
  @default_wrapper_class "flex flex-col mx-auto max-w-xl px-4 py-6 gap-4"

  # The form's tabs (`@form_pane`).
  @panes ~w(task planning connections more subproject schedule settings)

  @picker_events PhoenixKitProjects.Web.Components.AssigneePicker.events()

  @impl true
  def mount(params, session, socket) do
    WebHelpers.maybe_put_locale(session)

    wrapper_class = Map.get(session, "wrapper_class", @default_wrapper_class)
    # This form can be stacked (`PopupHostLive`, a host's two frames): the
    # ids other elements point at carry the record, or this mount's own key
    # for a task not saved yet (`dom_key/1`).
    socket =
      assign(socket,
        dom_seed: "new#{System.unique_integer([:positive])}",
        # What a sub-project's edit hands on to the project form it opens.
        embed_session: session
      )

    redirect_to = Map.get(session, "redirect_to")
    live_action = WebHelpers.resolve_live_action(socket, session)
    resolved_params = WebHelpers.resolve_action_params(params, session)

    # `apply_action/3` fetches project / assignment / task list /
    # closure tree. Runs at the tail of `mount/3` (not
    # `handle_params/3`) so the LV stays embeddable via `live_render`.
    # See dev_docs/embedding_audit.md.
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
      |> assign_from_view(session)
      # `form_seq` re-keys the title's wrapper after "Add & next" so a fresh
      # element mounts and `phx-mounted` refocuses it; `add_next?` is the
      # submit's intent (the "then=next" submitter), read at save time.
      |> assign(form_seq: 0, add_next?: false)
      # Which of the form's tabs shows (Task · Planning · Connections ·
      # More). Every tab's fields stay in the one form, only hidden, so a
      # switch loses nothing typed.
      |> assign(form_pane: "task")
      |> assign(
        save_state: :idle,
        save_error: nil,
        pending_params: nil,
        autosave_timer: nil,
        pending_file_removals: []
      )
      |> apply_action(live_action, resolved_params)
      |> assign_fx()
      |> assign_logged_minutes()
      |> assign_log_people()
      |> assign_edit_title()
      |> assign_times_form()
      |> assign_assignee_picker()
      |> assign_outline(resolved_params)
      |> assign_ai_translate()
      |> assign_task_files()
      |> allow_subproject_images()
      |> assign_billable()
      # Unsaved edits? Flipped by the first change event; the host's
      # dialog (emit mode) stops closing on Esc/backdrop while true and
      # Cancel asks first. See `mark_dirty/1`.
      |> assign(dirty?: false)
      |> WebHelpers.keep_host_title()

    {:ok, socket}
  end

  # The Create-new title is a real `Task` changeset so it goes through the
  # same `<.translatable_field>` as every other translatable column —
  # `task[title]` on the primary tab, `task[translations][<lang>][title]`
  # on the others. Nothing is inserted until Save.
  # Opened from the task's view in the same drawer (its "Edit"): leaving
  # the form goes back to that view instead of closing the drawer.
  defp assign_from_view(socket, session) do
    assign(socket,
      from_view?:
        socket.assigns.embed_mode == :emit and Map.get(session, "from_view") in ["1", true],
      # The view's host runs its next step (`AssignmentViewLive`): handed
      # back with it, or the view it swaps back to offers a link instead.
      view_step_intents?: Map.get(session, "step_intents") in ["1", true]
    )
  end

  # Leaves the form: back to the task's view when the form was opened from
  # it, otherwise closed (a drawer) or navigated away (a page).
  defp leave_form(socket, fallback) do
    case {socket.assigns[:from_view?], socket.assigns[:assignment]} do
      {true, %Assignment{uuid: uuid, project_uuid: project_uuid}} when is_binary(uuid) ->
        session = %{"project_id" => project_uuid, "id" => uuid}

        session =
          if socket.assigns[:view_step_intents?],
            do: Map.put(session, "step_intents", "1"),
            else: session

        WebHelpers.emit_swap(socket, PhoenixKitProjects.Web.AssignmentViewLive, session)

        socket

      _ ->
        WebHelpers.close_or_navigate(socket, fallback)
    end
  end

  defp new_task_form(attrs), do: to_form(Projects.change_task(%Task{}, attrs), as: :task)

  defp prefill_title(params) do
    case Map.get(params, "title") do
      title when is_binary(title) -> title |> String.trim() |> String.slice(0, 255)
      _ -> ""
    end
  end

  defp prefill_description(params) do
    case Map.get(params, "description") do
      text when is_binary(text) -> text |> String.trim() |> String.slice(0, 2000)
      _ -> nil
    end
  end

  # Whose time the log line records: the viewer's unless a person was
  # picked — and a picked one must be among those the form offered.
  defp log_actor(%{assigns: %{log_person: %{key: key}}} = socket) do
    if Enum.any?(socket.assigns[:log_people] || [], fn {_name, k} -> k == key end) do
      [kind, uuid] = String.split(key, ":", parts: 2)
      {:ok, [actor_kind: kind, actor_uuid: uuid]}
    else
      false
    end
  end

  defp log_actor(socket) do
    case Activity.actor_uuid(socket) do
      uuid when is_binary(uuid) -> {:ok, [actor_kind: "user", actor_uuid: uuid]}
      _ -> false
    end
  end

  defp log_note(note) when is_binary(note) do
    case String.trim(note) do
      "" -> nil
      text -> String.slice(text, 0, 500)
    end
  end

  defp log_note(_), do: nil

  # The people time may be logged for besides the viewer: the project's
  # other members, then the staff people with no account among them —
  # only for someone who runs the project's plan (`:edit_tasks`), as on
  # the Hours page. `[{name, "user:<uuid>" | "staff_person:<uuid>"}]`.
  defp assign_log_people(
         %{assigns: %{live_action: :edit, project: %Project{uuid: project_uuid} = project}} =
           socket
       )
       when is_binary(project_uuid) do
    scope = socket.assigns[:phoenix_kit_current_scope]

    people =
      if PhoenixKitProjects.Authz.can?(scope, project, :log_time_for_others) do
        my_uuid = Activity.actor_uuid(socket)

        members =
          project_uuid
          |> PhoenixKitProjects.Members.list_members()
          |> Enum.reject(&(&1.user_uuid == my_uuid))

        # By name — the account's, else its staff person's — never by
        # email when a name exists.
        names = PhoenixKitProjects.People.user_display_names(Enum.map(members, & &1.user_uuid))

        members =
          Enum.map(
            members,
            &{Map.get(names, &1.user_uuid) || log_member_name(&1), "user:#{&1.user_uuid}"}
          )

        listed = MapSet.new([my_uuid | Enum.map(members, fn {_n, "user:" <> uuid} -> uuid end)])

        staff =
          PhoenixKitProjects.People.list_people()
          |> Enum.reject(&MapSet.member?(listed, &1.user_uuid))
          |> Enum.map(&{PhoenixKitProjects.People.display_name(&1), "staff_person:#{&1.uuid}"})

        members ++ staff
      else
        []
      end

    assign(socket, log_people: people, log_person: nil, log_seq: 0)
  rescue
    _ -> assign(socket, log_people: [], log_person: nil, log_seq: 0)
  end

  defp assign_log_people(socket), do: assign(socket, log_people: [], log_person: nil, log_seq: 0)

  defp log_member_name(%{user: %{} = user}) do
    case User.full_name(user) do
      name when is_binary(name) and name != "" -> name
      _ -> user.email
    end
  end

  defp log_member_name(_), do: gettext("Someone")

  # What is logged on the task being edited, for the form's "Log time" line.
  defp assign_logged_minutes(
         %{assigns: %{live_action: :edit, assignment: %Assignment{uuid: uuid}}} = socket
       )
       when is_binary(uuid) do
    # People's time and an agent's apart, with the agent's tokens and cost:
    # the same figures the Hours page shows, for this one task.
    totals =
      PhoenixKitProjects.Hours.summary(
        PhoenixKitProjects.Hours.filters(
          project_uuids: [socket.assigns.assignment.project_uuid],
          assignment_uuid: uuid
        )
      ).totals

    assign(socket, logged: totals, ai_summary: ai_summary(uuid))
  rescue
    _ -> assign(socket, logged: nil, ai_summary: nil)
  end

  defp assign_logged_minutes(socket), do: assign(socket, logged: nil, ai_summary: nil)

  # The summary of the agent's latest note on the task, if it wrote one.
  defp ai_summary(assignment_uuid) do
    with true <- PhoenixKitProjects.TaskNotes.available?(),
         %{agent: %{metadata: %{"summary" => summary}}} when is_binary(summary) and summary != "" <-
           PhoenixKitProjects.TaskNotes.latest(assignment_uuid) do
      summary
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # The task's own name, edited at the top of its form like the new task's:
  # a `Task` changeset under the language tabs (`task[title]` on the primary
  # tab, `task[translations][<lang>][title]` on the others). Anyone who may
  # edit the task may rename a one-off task; a library task's name is shared,
  # which the field says (`title_shared?`). Without the right to rename, the
  # field is not drawn (`title_field?`) and the header shows the saved name.
  defp assign_edit_title(
         %{assigns: %{live_action: :edit, assignment: %Assignment{task: %Task{} = task}}} = socket
       ) do
    # A library task's name is shared by every project that uses it, so
    # only a `projects.manage_library` holder may rename it from here.
    assign(socket,
      edit_title: task.title,
      title_task: task,
      task_form: to_form(Projects.change_task(task, %{}), as: :task),
      title_editable?:
        task.ad_hoc == true or
          Authz.manage_library?(socket.assigns[:phoenix_kit_current_scope]),
      title_shared?: task.ad_hoc != true
    )
  end

  defp assign_edit_title(socket),
    do:
      assign(socket,
        edit_title: nil,
        title_task: nil,
        title_editable?: false,
        title_shared?: false
      )

  # The title (and its translations) the form posted, kept in `@task_form`
  # — the header above the tabs reads it, so it follows what is typed.
  defp take_task_params(socket, %{"task" => %{} = task_params}) do
    form = task_form_for(socket, merge_task_attrs(task_params, socket))
    title = Ecto.Changeset.get_field(form.source, :title) || ""

    socket
    |> assign(task_form: form, new_task_title: title)
    |> then(fn s ->
      if s.assigns.live_action == :edit, do: assign(s, :edit_title, title), else: s
    end)
  end

  defp take_task_params(socket, _params), do: socket

  # The library's tasks whose title matches what is being typed as a new
  # task's title (the boss's "suggest tasks, auto-complete style"; library
  # tasks only, never another project's). Ignored, the typed task is
  # created as before.
  defp assign_title_suggestions(
         %{assigns: %{live_action: :new, fx: %{library: true}}} = socket,
         params
       ) do
    suggestions =
      if Map.get(params, "task_mode", socket.assigns.task_mode) == "new",
        do: PhoenixKitProjects.LibrarySearch.suggest(socket.assigns[:new_task_title], limit: 6),
        else: []

    assign(socket, :title_suggestions, suggestions)
  end

  defp assign_title_suggestions(socket, _params), do: assign(socket, :title_suggestions, [])

  defp task_form_for(socket, attrs),
    do: to_form(Projects.change_task(socket.assigns[:title_task] || %Task{}, attrs), as: :task)

  # A task renamed in its form: written to the task after the assignment's
  # own save, and only when the name (or a translation of it) really changed.
  # A rename the task refuses (too long, say) comes back as `{:error, cs}`,
  # so the form keeps what was typed and says why instead of "Saved".
  defp save_edit_title(socket, %Assignment{task_uuid: task_uuid}) do
    with {:changed, title, titles} <- title_change(socket),
         %Task{} = task <- Projects.get_task(task_uuid),
         # Asked again at the write, of the live scope: a library task's
         # rename is `projects.manage_library`'s.
         true <-
           task.ad_hoc == true or
             Authz.manage_library?(socket.assigns[:phoenix_kit_current_scope]) do
      # Only the title keys are replaced: a one-off task's description
      # translations live in the same map and are written on their own.
      translations =
        task.translations
        |> Map.new(fn {lang, fields} -> {lang, Map.delete(fields || %{}, "title")} end)
        |> Map.merge(titles, fn _lang, old, new -> Map.merge(old, new) end)
        |> Enum.reject(fn {_lang, fields} -> fields == %{} end)
        |> Map.new()

      case Projects.update_task(task, %{"title" => title, "translations" => translations}) do
        {:error, %Ecto.Changeset{} = cs} -> {:error, cs}
        _ -> :ok
      end
    else
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  # `{:changed, title, %{lang => %{"title" => …}}}` when the form's title
  # differs from the task's, else `:same`.
  defp title_change(socket) do
    with true <- socket.assigns[:title_editable?] == true,
         %Task{} = shown <- socket.assigns[:title_task],
         %Phoenix.HTML.Form{source: %Ecto.Changeset{} = cs} <- socket.assigns[:task_form],
         edited = Ecto.Changeset.apply_changes(cs),
         title when title != "" <- String.trim(edited.title || ""),
         titles = title_translations(edited.translations),
         true <- title != shown.title or titles != title_translations(shown.translations) do
      {:changed, title, titles}
    else
      _ -> :same
    end
  end

  defp title_translations(translations) when is_map(translations) do
    for {lang, %{"title" => text}} <- translations, text not in [nil, ""], into: %{} do
      {lang, %{"title" => text}}
    end
  end

  defp title_translations(_), do: %{}

  # The name at the top of the form, as typed: the new task's title, the
  # library task picked, or the task being edited — in the language whose
  # tab is open, the primary's where that one has none.
  defp header_title(assigns) do
    case typed_title(assigns) do
      title when is_binary(title) and title != "" -> title
      # Emptied while typing: the header says so ("Untitled"), it does not
      # keep the last text (the boss, 2026-10-31).
      _ -> ""
    end
  end

  defp typed_title(%{live_action: :new, task_mode: "existing"} = assigns) do
    Enum.find_value(assigns.task_options, fn {label, uuid} ->
      uuid == assigns.selected_task_uuid && label
    end)
  end

  defp typed_title(%{live_action: action} = assigns)
       when action == :new or :erlang.map_get(:title_editable?, assigns) == true do
    assigns.task_form.source
    |> Ecto.Changeset.apply_changes()
    |> Task.localized_title(assigns[:current_lang])
    |> trimmed()
  end

  defp typed_title(%{assignment: %Assignment{task: %Task{} = task}} = assigns),
    do: task |> Task.localized_title(assigns[:current_lang]) |> trimmed()

  defp typed_title(_assigns), do: nil

  defp trimmed(text) when is_binary(text), do: String.trim(text)
  defp trimmed(_), do: nil

  defp assign_fx(socket) do
    case socket.assigns[:project] do
      %Project{uuid: uuid} = project when is_binary(uuid) ->
        assign(socket, fx: Features.gates(project))

      _ ->
        assign(socket, fx: Features.default_gates())
    end
  end

  # ── Whose the task is ─────────────────────────────────────────────
  #
  # One picker for people, teams and departments together, as the CRM's
  # "Involved parties" (the boss, 2026-10-29: picking the kind first and then
  # a second select swapped fields below without a word). What it holds is
  # the form's own three assignee fields — posted as hidden inputs, so a
  # pick saves like any other field — and `@assignee_chip` shows it.

  # The shared picker (`Web.Components.AssigneePicker`): the viewer's staff
  # person, the Recent chips (their own picks first) and the right to assign.
  defp assign_assignee_picker(socket) do
    socket
    |> AssigneePicker.init(socket.assigns[:project],
      can_assign?: can_assign?(socket),
      source: "task_form",
      # A task has any number of assignees (V29); a sub-project is a
      # project, which has one.
      multi: socket.assigns[:kind] != "subproject"
    )
    |> refresh_assignee_chip()
  end

  defp can_assign?(%{assigns: %{project: %Project{uuid: uuid} = project}} = socket)
       when is_binary(uuid),
       do:
         PhoenixKitProjects.Authz.can?(
           socket.assigns[:phoenix_kit_current_scope],
           project,
           :assign_tasks
         )

  defp can_assign?(_socket), do: false

  # Every assignee the task's form holds now (V29), in chip order: the set
  # just chosen, else the task's own.
  defp form_assignee_keys(%Phoenix.HTML.Form{source: %Ecto.Changeset{} = cs}) do
    case Ecto.Changeset.get_change(cs, :assignee_keys) do
      keys when is_list(keys) -> keys
      _ -> PhoenixKitProjects.AssigneeSet.keys(cs.data)
    end
  end

  defp form_assignee_keys(_form), do: []

  # `{kind, uuid}` of the assignee the form holds now, or nil.
  defp form_assignee(form),
    do: AssigneePicker.key_of(&form[Assignees.assignee_field(Atom.to_string(&1))].value)

  # The chip of the chosen assignee (label and faces), looked up only when
  # the choice changed. The sub-project form holds its own (`@sp_form`).
  defp refresh_assignee_chip(
         %{assigns: %{kind: "subproject", sp_form: %Phoenix.HTML.Form{} = f}} = socket
       ),
       do: AssigneePicker.refresh_chip(socket, form_assignee(f))

  defp refresh_assignee_chip(
         %{assigns: %{assignee_multi?: true, form: %Phoenix.HTML.Form{} = f}} = socket
       ),
       do: AssigneePicker.set_selected(socket, form_assignee_keys(f))

  defp refresh_assignee_chip(%{assigns: %{form: %Phoenix.HTML.Form{} = f}} = socket),
    do: AssigneePicker.refresh_chip(socket, form_assignee(f))

  defp refresh_assignee_chip(socket), do: socket

  # The three assignee fields for one choice: exactly one set, the other
  # two cleared (the changeset refuses two at once).
  @assignee_names %{
    person: "assigned_person_uuid",
    team: "assigned_team_uuid",
    department: "assigned_department_uuid"
  }

  @doc false
  # `AssigneePicker` callback: the choice into the form being shown — the
  # task's (saved as it is changed) or the sub-project's.
  def picker_choose(%{assigns: %{kind: "subproject"}} = socket, kind, uuid) do
    attrs = AssigneePicker.field_attrs(@assignee_names, kind, uuid)
    sp_attrs = Map.merge(socket.assigns.sp_form.params || %{}, attrs)

    socket
    |> assign(
      sp_form: to_form(Projects.change_project(sp_source(socket), sp_attrs), as: :subproject)
    )
    |> assign(:assign_type, kind || "")
    |> WebHelpers.mark_dirty()
    |> refresh_assignee_chip()
  end

  def picker_choose(socket, kind, uuid) do
    socket
    |> put_form_attrs(AssigneePicker.field_attrs(@assignee_names, kind, uuid), %{
      "assign_type" => kind || ""
    })
    |> assign(:assign_type, kind || "")
  end

  @doc false
  # `AssigneePicker` callback (several assignees): the whole new list into
  # the task's form — saved as it is changed, as any field.
  def picker_set(socket, keys) do
    values = [""] ++ Enum.map(keys, fn {kind, uuid} -> "#{kind}:#{uuid}" end)
    attrs = Map.put(socket.assigns.form.params || %{}, "assignees", values)
    cs = Projects.change_assignment(socket.assigns.assignment, merge_attrs(attrs, socket))
    cs = Map.put(cs, :action, socket.assigns.form.source.action)
    pending = socket.assigns[:pending_params] || %{}

    params =
      Map.put(
        pending,
        "assignment",
        Map.merge(Map.get(pending, "assignment", %{}), %{"assignees" => values})
      )

    socket
    |> assign(form: to_form(cs))
    |> WebHelpers.mark_dirty()
    |> schedule_autosave(params)
  end

  @doc false
  # `AssigneePicker` callback: asked of the project as it is now.
  def picker_allowed?(socket) do
    with %Project{uuid: uuid} <- socket.assigns[:project],
         %Project{} = project <- Projects.get_project(uuid) do
      Features.on?(project, "assignees") and
        Authz.can?(socket.assigns[:phoenix_kit_current_scope], project, :assign_tasks)
    else
      _ -> false
    end
  end

  # A value set by a button rather than typed (an assignee, a deadline
  # preset): cast onto the form as it stands, and — on a task being edited
  # — saved with whatever else is waiting, as a typed change would be.
  # `attrs` are shaped as the browser posts them (a deadline as the
  # viewer's wall clock).
  defp put_form_attrs(socket, attrs, extra_params \\ %{}) do
    cs =
      socket.assigns.form.source
      |> Ecto.Changeset.cast(
        normalize_form_attrs(attrs),
        Map.keys(attrs) |> Enum.map(&String.to_existing_atom/1)
      )
      |> Map.put(:action, socket.assigns.form.source.action)

    pending = socket.assigns[:pending_params] || %{}

    params =
      pending
      |> Map.merge(extra_params)
      |> Map.put("assignment", Map.merge(Map.get(pending, "assignment", %{}), attrs))

    socket
    |> assign_form(cs)
    |> WebHelpers.mark_dirty()
    |> schedule_autosave(params)
  end

  # The project's `billable` Tasks flag (off by default): the log line's
  # Billable box, and the saved value, only with it on.
  defp assign_billable(%{assigns: %{project: %Project{uuid: uuid} = project}} = socket)
       when is_binary(uuid),
       do: assign(socket, :billable_on?, Features.on?(project, "billable"))

  defp assign_billable(socket), do: assign(socket, :billable_on?, false)

  # ── The task's files (V27) ──────────────────────────────────────────

  @task_file_max_mb 25
  @inline_image_max_mb 10

  # Uploads into a task being edited, for someone who may edit it and
  # upload files in its project; the files it holds, for the More tab.
  defp assign_task_files(
         %{assigns: %{live_action: :edit, kind: "task", assignment: %Assignment{uuid: u}}} =
           socket
       )
       when is_binary(u) do
    if Map.get(socket.assigns.project, :is_template, false) do
      assign(socket, can_attach?: false, task_files: [], task_file_urls: %{})
    else
      socket
      |> assign(can_attach?: attach_allowed?(socket))
      |> allow_upload(:task_files,
        accept: :any,
        max_entries: 10,
        max_file_size: @task_file_max_mb * 1_048_576,
        auto_upload: true,
        progress: &handle_progress/3
      )
      |> allow_upload(:description_images,
        accept: ~w(image/*),
        max_entries: 5,
        max_file_size: @inline_image_max_mb * 1_048_576,
        auto_upload: true,
        progress: &handle_progress/3
      )
      |> load_task_files()
    end
  end

  defp assign_task_files(socket),
    do: assign(socket, can_attach?: false, task_files: [], task_file_urls: %{})

  defp load_task_files(socket) do
    rows = Attachments.list_task_files(socket.assigns.assignment.uuid)

    assign(socket,
      task_files: rows,
      task_file_urls: Attachments.download_urls(Enum.map(rows, & &1.file))
    )
  end

  # Asked of the live scope and of the project as it is now: editing the
  # task, and uploading files in its project.
  defp attach_allowed?(%{assigns: %{project: %Project{uuid: uuid}}} = socket)
       when is_binary(uuid) do
    WriteGate.allowed?(socket) and
      case Projects.get_project(uuid) do
        %Project{} = project ->
          Authz.can?(socket.assigns[:phoenix_kit_current_scope], project, :upload_files)

        _ ->
          false
      end
  rescue
    _ -> false
  end

  defp attach_allowed?(_socket), do: false

  # Each upload stored as it finishes: a file of the task, or an image put
  # into the description at the cursor.
  defp handle_progress(upload, entry, socket) when upload in [:task_files, :description_images] do
    cond do
      not entry.done? ->
        {:noreply, socket}

      not attach_allowed?(socket) ->
        {:noreply,
         socket
         |> cancel_upload(upload, entry.ref)
         |> put_flash(:error, gettext("You don't have permission to manage files here."))}

      true ->
        inline? = upload == :description_images

        result =
          consume_uploaded_entry(socket, entry, fn %{path: path} ->
            {:ok, store_upload(socket, path, entry, inline?)}
          end)

        {:noreply, after_upload(socket, result, inline?)}
    end
  end

  defp store_upload(socket, path, entry, inline?) do
    size =
      case Elixir.File.stat(path) do
        {:ok, %{size: size}} -> size
        _ -> entry.client_size
      end

    Attachments.store_task_file(
      socket.assigns.assignment,
      path,
      [
        filename: safe_filename(entry.client_name),
        content_type: entry.client_type || "application/octet-stream",
        size_bytes: size,
        inline: inline?
      ],
      Activity.actor_uuid(socket)
    )
  end

  defp after_upload(socket, {:ok, file}, inline?) do
    log_task_file(socket, "projects.task_file_added", file.uuid, file.original_file_name)

    if inline? do
      DescriptionEditor.insert_image(
        DescriptionEditor.editor_id("assignment-description", socket.assigns.current_lang),
        inline_src(socket, file),
        to_string(file.original_file_name)
      )
    end

    load_task_files(socket)
  end

  defp after_upload(socket, _error, _inline?) do
    log_task_file_failed(socket, "projects.task_file_added", nil)
    put_flash(socket, :error, gettext("Upload failed. Please try again."))
  end

  # A pasted image arrives as a data URL; its bytes are written to a
  # temporary file and stored like an upload. Only an image, at most the
  # inline limit, and only for someone who may attach.
  # A task not saved yet has nowhere to keep a picture (its files hang off
  # its row): said, rather than refused as if it were a permission.
  defp store_pasted_image(%{assigns: %{live_action: :new}} = socket, _id, _paste),
    do: put_flash(socket, :error, gettext("Save the task first to add images."))

  defp store_pasted_image(socket, editor_id, %{data_url: "data:" <> rest} = paste) do
    with true <- attach_allowed?(socket) || :forbidden,
         [meta, b64] <- String.split(rest, ",", parts: 2),
         [mime | _] <- String.split(meta, ";"),
         true <- String.starts_with?(mime, "image/") and String.ends_with?(meta, ";base64"),
         true <- byte_size(b64) <= div(@inline_image_max_mb * 1_048_576 * 4, 3) + 4,
         {:ok, bytes} <- Base.decode64(b64, ignore: :whitespace) do
      path = Path.join(System.tmp_dir!(), "pkp-paste-#{System.unique_integer([:positive])}")
      Elixir.File.write!(path, bytes)

      result =
        Attachments.store_task_file(
          socket.assigns.assignment,
          path,
          [
            filename: safe_filename(paste[:name] || "pasted-image"),
            content_type: mime,
            size_bytes: byte_size(bytes),
            inline: true
          ],
          Activity.actor_uuid(socket)
        )

      Elixir.File.rm(path)

      case result do
        {:ok, file} ->
          log_task_file(socket, "projects.task_file_added", file.uuid, file.original_file_name)
          DescriptionEditor.insert_image(editor_id, inline_src(socket, file), "")
          load_task_files(socket)

        _ ->
          log_task_file_failed(socket, "projects.task_file_added", nil)
          put_flash(socket, :error, gettext("Upload failed. Please try again."))
      end
    else
      :forbidden ->
        put_flash(socket, :error, gettext("You don't have permission to manage files here."))

      _ ->
        put_flash(socket, :error, gettext("Upload failed. Please try again."))
    end
  end

  defp store_pasted_image(socket, _editor_id, _paste), do: socket

  # The address the editor shows a stored picture at: one this viewer may
  # open (a private library's is a time-window one). The text keeps the
  # file, not the address (`InlineImages`, the changeset).
  defp inline_src(socket, file),
    do: to_string(InlineImages.url(file, socket.assigns[:phoenix_kit_current_scope]))

  # The description as the editor is handed it: its pictures by an address
  # the viewer may open, one it cannot kept as it is.
  defp editor_content(text, scope), do: InlineImages.resolve(text, scope, keep_missing: true)

  defp remove_file_now(socket, file_uuid, shown, inline?) do
    case Attachments.remove_task_file(
           socket.assigns.assignment,
           file_uuid,
           Activity.actor_uuid(socket)
         ) do
      :ok ->
        log_task_file(
          socket,
          "projects.task_file_removed",
          file_uuid,
          shown && shown.file.original_file_name
        )

        socket = if inline?, do: strip_inline_image(socket, file_uuid), else: socket
        socket |> load_task_files() |> put_flash(:info, gettext("File removed."))

      {:error, _} ->
        log_task_file_failed(socket, "projects.task_file_removed", file_uuid)
        put_flash(socket, :error, gettext("Could not remove the file."))
    end
  end

  # The description pictures taken out of the text, removed with Save —
  # asked again whether this person may still manage the task's files: the
  # right can be taken away between the click and the Save (panel review,
  # list 3). Refused, the files stay on the task; only the text changes.
  defp remove_pending_files(socket) do
    case Map.get(socket.assigns, :pending_file_removals, []) do
      [] ->
        socket

      pending ->
        if attach_allowed?(socket) do
          pending
          |> Enum.reduce(socket, fn {file_uuid, shown}, acc ->
            remove_file_now(acc, file_uuid, shown, false)
          end)
          |> assign(:pending_file_removals, [])
        else
          socket
          |> assign(:pending_file_removals, [])
          |> put_flash(:error, gettext("You don't have permission to manage files here."))
        end
    end
  end

  # A picture taken off the task leaves its description too — every
  # language's — and the open editor is handed the text without it; saved
  # with the rest (`put_form_attrs/3`).
  defp strip_inline_image(socket, file_uuid) do
    %{form: form, primary_language: primary, current_lang: lang} = socket.assigns
    description = Ecto.Changeset.get_field(form.source, :description)
    translations = Ecto.Changeset.get_field(form.source, :translations) || %{}

    stripped_description = InlineImages.strip(description, file_uuid)

    stripped_translations =
      Map.new(translations, fn
        {code, %{"description" => text} = fields} ->
          {code, %{fields | "description" => InlineImages.strip(text, file_uuid)}}

        other ->
          other
      end)

    attrs =
      %{}
      |> then(
        &if(stripped_description != description,
          do: Map.put(&1, "description", stripped_description),
          else: &1
        )
      )
      |> then(
        &if(stripped_translations != translations,
          do: Map.put(&1, "translations", stripped_translations),
          else: &1
        )
      )

    if attrs == %{} do
      socket
    else
      socket = put_form_attrs(socket, attrs)

      shown =
        description_value(
          socket.assigns.form,
          lang,
          primary,
          socket.assigns.multilang_enabled
        )

      send_update(Leaf,
        id: DescriptionEditor.editor_id("assignment-description", lang),
        action: :set_content,
        content: editor_content(shown || "", socket.assigns[:phoenix_kit_current_scope])
      )

      socket
    end
  end

  # A browser-supplied filename reaches storage and download headers: path
  # separators and control characters come out (as the comments' upload).
  defp safe_filename(name) when is_binary(name) do
    name
    |> Path.basename()
    |> String.replace(~r/[\x00-\x1f\/\\]/, "")
    |> String.slice(0, 200)
    |> case do
      "" -> "attachment"
      cleaned -> cleaned
    end
  end

  defp safe_filename(_), do: "attachment"

  defp upload_error_text(:too_large),
    do: gettext("Too large (at most %{mb} MB).", mb: @task_file_max_mb)

  defp upload_error_text(:not_accepted), do: gettext("This kind of file is not accepted.")
  defp upload_error_text(:too_many_files), do: gettext("Too many files at once.")
  defp upload_error_text(_), do: gettext("Upload failed. Please try again.")

  # The file's name rides along (the history names and links the file).
  defp log_task_file(socket, action, file_uuid, name) do
    meta = %{"file_uuid" => file_uuid, "project_uuid" => socket.assigns.project.uuid}

    Activity.log(action,
      actor_uuid: Activity.actor_uuid(socket),
      resource_type: "assignment",
      resource_uuid: socket.assigns.assignment.uuid,
      metadata:
        if(is_binary(name) and name != "", do: Map.put(meta, "file_name", name), else: meta)
    )
  end

  # The attempt is recorded when the write fails too (the audit covers what
  # the person asked for, not only what landed).
  defp log_task_file_failed(socket, action, file_uuid) do
    Activity.log_failed(action,
      actor_uuid: Activity.actor_uuid(socket),
      resource_type: "assignment",
      resource_uuid: socket.assigns.assignment.uuid,
      metadata: %{"file_uuid" => file_uuid, "project_uuid" => socket.assigns.project.uuid}
    )
  end

  # A description typed in the editor, as if the field had posted it: on a
  # task being edited, saved with the rest (`put_form_attrs/3`). Nothing
  # when it says what the form already holds.
  defp put_description(%{assigns: %{form: form}} = socket, lang, markdown) do
    %{current_lang: _, primary_language: primary, multilang_enabled: multi?} = socket.assigns
    # The editor shows pictures by address; the text keeps them by file, so
    # an editor reading back what it was handed is no change.
    markdown = InlineImages.to_refs(markdown)

    if InlineImages.to_refs(description_value(form, lang, primary, multi?)) == markdown do
      socket
    else
      attrs =
        case DescriptionEditor.params(markdown, lang, primary, multi?) do
          %{"translations" => %{^lang => fields}} ->
            current = Ecto.Changeset.get_field(form.source, :translations) || %{}

            %{
              "translations" => Map.update(current, lang, fields, &Map.merge(&1 || %{}, fields))
            }

          plain ->
            plain
        end

      put_form_attrs(socket, attrs)
    end
  end

  defp put_sp_description(%{assigns: %{sp_form: %Phoenix.HTML.Form{} = f}} = socket, lang, md) do
    %{primary_language: primary, multilang_enabled: multi?} = socket.assigns

    if description_value(f, lang, primary, multi?) == md do
      socket
    else
      attrs =
        f.params
        |> Map.merge(DescriptionEditor.params(md, lang, primary, multi?))
        |> sp_translations(socket)

      socket
      |> assign(
        sp_form: to_form(Projects.change_project(sp_source(socket), attrs), as: :subproject)
      )
      |> WebHelpers.mark_dirty()
    end
  end

  defp put_sp_description(socket, _lang, _md), do: socket

  # Browsers post a `datetime-local` value as the viewer's wall clock.
  defp normalize_form_attrs(attrs),
    do: WebHelpers.normalize_datetime_local_attrs(attrs, ["deadline"])

  # The deadline presets: a wall clock in the viewer's zone, as if typed.
  defp deadline_preset(preset) do
    now = DateTime.utc_now() |> L10n.local() |> DateTime.to_naive()
    today = NaiveDateTime.to_date(now)

    at =
      case preset do
        "hour" -> now |> NaiveDateTime.add(3600) |> Map.put(:second, 0)
        "today" -> NaiveDateTime.new!(today, ~T[17:00:00])
        "tomorrow" -> NaiveDateTime.new!(Date.add(today, 1), ~T[09:00:00])
        _ -> nil
      end

    at &&
      at |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_iso8601() |> String.slice(0, 16)
  end

  # Wires the AI-translate modal/buttons for the assignment's `description`.
  # Only the task-assignment case is translatable here (sub-project links edit
  # the child project elsewhere), so the resource is the assignment only when
  # editing a task row. Events are handled by `use ...AITranslate.Embed`.
  defp assign_ai_translate(socket) do
    resource =
      if socket.assigns[:live_action] == :edit and socket.assigns[:kind] == "task",
        do: socket.assigns[:assignment],
        else: nil

    FormGlue.assign_ai_translation(
      socket,
      "assignment",
      resource,
      PhoenixKitProjects.AITranslateBinding
    )
  end

  # Recursive function component for the closure-pull tree. Renders
  # one node + its children indented underneath. The root has the
  # checkbox disabled (the user picks the root via the task dropdown,
  # not by un-ticking it here); already-in-project nodes render as
  # static "already there" markers. Cycle nodes terminate with a
  # warning glyph instead of recursing.
  #
  # `:ancestor_excluded?` cascades down the tree: when an ancestor is
  # in `excluded_uuids`, every descendant gets locked out (checkbox
  # disabled, label greyed, struck through). The user can still
  # re-tick the ancestor to bring the whole subtree back — only
  # explicit per-node clicks live in `excluded_uuids`.
  attr(:node, :map, required: true)
  attr(:excluded_uuids, :any, required: true)
  attr(:is_root, :boolean, default: false)
  attr(:ancestor_excluded?, :boolean, default: false)
  attr(:lang, :string, default: nil)

  defp closure_node(assigns) do
    self_excluded? = MapSet.member?(assigns.excluded_uuids, assigns.node.task.uuid)

    assigns =
      assigns
      |> assign(:self_excluded?, self_excluded?)
      |> assign(:effective_excluded?, assigns.ancestor_excluded? or self_excluded?)

    ~H"""
    <li class="flex flex-col">
      <div class="flex items-start gap-2 py-0.5">
        <%= cond do %>
          <% @node.cycle? -> %>
            <span class="text-warning text-sm" title={gettext("Cycle detected — traversal stopped here")}>↻</span>
            <span class="text-sm text-base-content/60 italic">
              {Task.localized_title(@node.task, @lang)}
            </span>
          <% @node.already_in_project? -> %>
            <.icon name="hero-check-circle" class="w-4 h-4 text-success shrink-0 mt-0.5" />
            <span class="text-sm">
              {Task.localized_title(@node.task, @lang)}
              <span class="text-xs text-base-content/50">{gettext("(already in project)")}</span>
            </span>
          <% true -> %>
            <input
              type="checkbox"
              phx-click="toggle_closure_task"
              phx-value-uuid={@node.task.uuid}
              checked={not @effective_excluded?}
              disabled={@is_root or @ancestor_excluded?}
              class="checkbox checkbox-primary checkbox-sm shrink-0 mt-0.5"
            />
            <span class={["text-sm", @effective_excluded? && "line-through text-base-content/40"]}>
              {Task.localized_title(@node.task, @lang)}
              <%= cond do %>
                <% @is_root -> %>
                  <span class="text-xs text-base-content/50">{gettext("(this task)")}</span>
                <% @ancestor_excluded? -> %>
                  <span class="text-xs text-base-content/50">{gettext("(parent unchecked)")}</span>
                <% true -> %>
              <% end %>
            </span>
        <% end %>
      </div>

      <%= if @node.children != [] do %>
        <ul class="ml-6 border-l border-base-300 pl-3 space-y-1 mt-0.5">
          <.closure_node
            :for={child <- @node.children}
            node={child}
            excluded_uuids={@excluded_uuids}
            is_root={false}
            ancestor_excluded?={@effective_excluded?}
            lang={@lang}
          />
        </ul>
      <% end %>
    </li>
    """
  end

  # Minimal assigns required so the render path can paint a flash + empty
  # frame after `close_or_navigate/2` emits :closed in emit mode (where
  # the LV stays mounted until the host pulls it down). In navigate mode
  # `push_navigate` replaces the LV before render so these are harmless.
  defp assign_not_found_placeholders(socket) do
    placeholder_project = %{uuid: "", name: ""}
    # `task: nil` so the render template's `@assignment.task && ...`
    # short-circuits cleanly. The default `%Assignment{}` would have
    # `task: %Ecto.Association.NotLoaded{}` which is truthy and would
    # crash `Task.localized_title/2`.
    placeholder_assignment = %Assignment{task: nil}

    socket
    |> assign(
      page_title: "",
      kind: "task",
      sp_form: to_form(Projects.change_project(%Project{}), as: :subproject),
      sp_mode: "new",
      link_options: [],
      project: placeholder_project,
      assignment: placeholder_assignment,
      live_action: :new,
      task_mode: "new",
      assign_type: "",
      selected_task_uuid: nil,
      new_task_title: "",
      task_form: new_task_form(%{}),
      add_to_library: false,
      assignment_deps: [],
      available_assignment_deps: [],
      unlocks: [],
      pending_dep_uuids: [],
      pending_dep_options: [],
      closure_tree: nil,
      excluded_closure_uuids: MapSet.new()
    )
    |> assign_options()
    |> assign_form(Projects.change_assignment(placeholder_assignment))
    |> assign_status_init(%Project{})
  end

  # The write gate this form never had.
  #
  # `ProjectShowLive` gates :view and `ProjectFormLive(:edit)` gates
  # :edit_settings, both because the module permission stopped meaning
  # "administer every project" — but this form, the one that actually
  # CREATES and EDITS a project's tasks, kept riding the route alone. So
  # anyone who could reach the module could open
  # `/admin/projects/<any-uuid>/assignments/new` and write into a
  # private project they belong to nothing of, with the project's own
  # create/edit floors never consulted.
  #
  # Templates are exempt for the same reason `template_or_viewable?/2`
  # exempts them: library objects have no membership rows for a per-project
  # resolution to work against.
  #
  # A refusal returns nil so the caller's existing not-found branch handles
  # it — the refusal has to be shaped exactly like "no such project",
  # because existence is itself information.
  defp permitted_project(socket, project_id, action) do
    scope = socket.assigns[:phoenix_kit_current_scope]

    case Projects.get_project(project_id) do
      %Project{is_template: true} = template ->
        if PhoenixKitProjects.Authz.can_use_templates?(scope), do: template

      %Project{} = project ->
        # The task list is a per-project extension now (a project can be
        # only its whiteboards, 2026-09-05): with it off, the project has
        # no tasks to add to or edit, however the page was reached — the
        # show page hides every way in; this closes the URL.
        if PhoenixKitProjects.Authz.can?(scope, project, action) and
             PhoenixKitProjects.Extensions.enabled?(project, "tasks"),
           do: project

      other ->
        other
    end
  end

  defp apply_action(socket, :new, %{"project_id" => project_id} = params) do
    case permitted_project(socket, project_id, :create_tasks) do
      nil ->
        # In navigate mode, `close_or_navigate` push-navigates and the LV is
        # replaced before render. In emit mode it broadcasts `:closed` but
        # the LV stays mounted until the host pulls down the modal — so
        # we need safe placeholders for the render path between emit and
        # host-side teardown.
        socket
        |> assign_not_found_placeholders()
        |> put_flash(:error, gettext("Project not found."))
        |> WebHelpers.close_or_navigate(Paths.projects())

      project ->
        # `kind: "subproject"` (V127) routes the same add page into
        # sub-project mode — feature-gated per project: with the
        # `subprojects` flag off, a crafted `?kind=subproject` URL falls
        # back to the plain task form (Step 4 enforcement).
        kind =
          if Map.get(params, "kind") == "subproject" and Features.on?(project, "subprojects"),
            do: "subproject",
            else: "task"

        assignment = %Assignment{project_uuid: project.uuid}
        existing_assignments = Projects.list_assignments(project.uuid)

        # Trail: Admin Panel / Projects / <parents…> / <project> / Add task —
        # the project is the linked crumb, so the leaf no longer repeats
        # its name ("Add task to Test" was the boss's example of a trail
        # that had lost its way; see `Web.Crumbs`). "Add" because the task
        # is attached to the project; the library's form says "New".
        title =
          if kind == "subproject",
            do: gettext("Add sub-project"),
            else: gettext("Add task")

        socket
        |> assign(Crumbs.under_project(project, socket.assigns[:phoenix_kit_current_scope]))
        |> assign(
          page_title: title,
          kind: kind,
          sp_form: to_form(Projects.change_project(%Project{}), as: :subproject),
          # Sub-project add modes (V127): "new" creates a fresh child, "existing"
          # nests an existing standalone project. `link_options` is the eligible
          # set (cycle-safe, same kind).
          sp_mode: "new",
          link_options:
            if(kind == "subproject",
              do: nestable_projects(project, socket.assigns[:phoenix_kit_current_scope]),
              else: []
            ),
          project: project,
          assignment: assignment,
          portal_review_images: [],
          live_action: :new,
          # Create new is the default (most tasks are one-offs); From
          # library is the deliberate second choice. A `title` param (an
          # emit-session `"title"` from a host) prefills the new task's
          # title — nothing is created until Save.
          task_mode: "new",
          assign_type: "",
          selected_task_uuid: nil,
          new_task_title: prefill_title(params),
          task_form: new_task_form(%{"title" => prefill_title(params)}),
          add_to_library: false,
          assignment_deps: [],
          available_assignment_deps: [],
          unlocks: [],
          # `:new` mode can't create real Dependency rows yet (no
          # assignment uuid). Track the user's selections in
          # `pending_dep_uuids` and create them post-insert in `save_new`
          # / `create_assignment_for_new_task`. `pending_dep_options`
          # is the candidate list (every other assignment in this
          # project — none are this one since it doesn't exist yet).
          pending_dep_uuids: [],
          pending_dep_options: existing_assignments,
          # Closure-pull tree (template task → its transitive
          # dependencies). Loaded on task selection in
          # `prefill_from_template/3`. `excluded_closure_uuids` is the
          # set of tasks the user unticked in the prune UI; a task in
          # this set is dropped from the save-time closure-create
          # batch (its template-edge wiring is also skipped). The
          # root is always kept (the user's explicit pick) — they
          # delete the assignment afterward if they change their mind.
          closure_tree: nil,
          excluded_closure_uuids: MapSet.new()
        )
        |> assign_options()
        # A `description` param (the CRM's "add a task from this meeting"
        # hands over the meeting's `#` chip) prefills the description the
        # way `title` prefills the title — nothing is saved until Save.
        |> assign_form(
          Projects.change_assignment(assignment, %{"description" => prefill_description(params)})
        )
        |> assign_status_init(%Project{})
    end
  end

  defp apply_action(socket, :edit, %{"project_id" => project_id, "id" => id}) do
    project = permitted_project(socket, project_id, :edit_tasks)
    assignment = Projects.get_assignment(id)

    # The assignment is re-scoped to the project named in the params. These
    # were fetched independently and never compared, so pairing any
    # project_id with any assignment uuid loaded a FOREIGN task into the
    # edit form — the project gate said yes about one project while the
    # form edited another's row.
    assignment =
      if assignment && project && assignment.project_uuid == project.uuid,
        do: assignment,
        else: nil

    case {project, assignment} do
      {nil, _} ->
        socket
        |> assign_not_found_placeholders()
        |> put_flash(:error, gettext("Project not found."))
        |> WebHelpers.close_or_navigate(Paths.projects())

      {_, nil} ->
        socket
        |> assign_not_found_placeholders()
        |> put_flash(:error, gettext("Assignment not found."))
        |> WebHelpers.close_or_navigate(Paths.project(project_id))

      {project, %Assignment{child_project_uuid: child_uuid} = assignment}
      when is_binary(child_uuid) ->
        # Sub-project linking row (V127): edit the CHILD project's name +
        # assignee, plus this row's dependencies. The assignee lives on the
        # child, so `assign_type` + `sp_form` come from it.
        # Short refs in the edit box (`#ACME-42`), tokens in the row.
        child =
          RefText.collapse_fields(
            Projects.get_project_with_assignee(child_uuid) || %Project{},
            [:description]
          )

        child_name = Project.localized_name(child, L10n.current_content_lang())

        socket
        # Trail: … / <project> / <child> / Edit — the child has a page of its
        # own, so its crumb links there; the leaf is the page.
        |> assign(
          Crumbs.under_project(
            project,
            socket.assigns[:phoenix_kit_current_scope],
            child_crumbs(child, child_name)
          )
        )
        |> assign(
          page_title: gettext("Edit"),
          heading: gettext("Edit %{name}", name: child_name),
          kind: "subproject",
          sp_form: to_form(Projects.change_project(child), as: :subproject),
          sp_mode: "new",
          link_options: [],
          project: project,
          assignment: assignment,
          portal_review_images: PhoenixKitProjects.Portal.review_images(assignment.uuid),
          live_action: :edit,
          assign_type: assignee_kind(child),
          assignment_deps: Projects.list_dependencies(assignment.uuid),
          available_assignment_deps:
            Projects.available_dependencies(project.uuid, assignment.uuid),
          unlocks: [],
          pending_dep_uuids: [],
          pending_dep_options: [],
          task_mode: "new",
          selected_task_uuid: nil,
          new_task_title: "",
          task_form: new_task_form(%{}),
          add_to_library: false,
          closure_tree: nil,
          excluded_closure_uuids: MapSet.new()
        )
        |> assign_options()
        |> assign_form(Projects.change_assignment(assignment))
        |> assign_status_init(child)
        |> nest_project_form(child, assignment)

      {project, assignment} ->
        task_name =
          assignment.task && Task.localized_title(assignment.task, L10n.current_content_lang())

        # The record the form edits holds short refs (`#ACME-42`) where the
        # row holds tokens: an untouched description is then no change, and
        # a changed one is expanded again when it is written.
        # A one-off task written over the API (or by the quick-add composer
        # and reworded there) keeps its description on the task row; the
        # box shows that text, and a save writes it back where it lives.
        {assignment, desc_on_task?} = own_description(assignment)
        assignment = RefText.collapse_fields(assignment, [:description])

        socket
        |> assign(:desc_on_task?, desc_on_task?)
        # Trail: … / <project> / <task> / Edit — the assignment has no page
        # of its own, so its task is a text crumb; the leaf is the page. The
        # drawer has no trail, so its heading still names the task.
        |> assign(
          Crumbs.under_project(
            project,
            socket.assigns[:phoenix_kit_current_scope],
            task_crumbs(task_name)
          )
        )
        |> assign(edit_titles(task_name))
        |> assign(
          # `ACME-42`, beside the heading: the name to quote for this task.
          task_ref: PhoenixKitProjects.Refs.task_ref(project.key, assignment.number),
          kind: "task",
          sp_form: to_form(Projects.change_project(%Project{}), as: :subproject),
          sp_mode: "new",
          link_options: [],
          project: project,
          assignment: assignment,
          portal_review_images: PhoenixKitProjects.Portal.review_images(assignment.uuid),
          live_action: :edit,
          task_mode: "new",
          assign_type: assignee_kind(assignment),
          selected_task_uuid: assignment.task_uuid,
          new_task_title: "",
          task_form: new_task_form(%{}),
          add_to_library: false,
          assignment_deps: Projects.list_dependencies(assignment.uuid),
          available_assignment_deps:
            Projects.available_dependencies(project.uuid, assignment.uuid),
          unlocks: unlocks(project, assignment),
          pending_dep_uuids: [],
          pending_dep_options: [],
          # Edit mode doesn't render the closure UI (closure-pull is
          # a creation-time concept); keep the assigns present so the
          # template's pattern-matching doesn't crash.
          closure_tree: nil,
          excluded_closure_uuids: MapSet.new()
        )
        |> assign_options()
        |> assign_form(Projects.change_assignment(assignment))
        |> assign_status_init(%Project{})
    end
  end

  # Fail-closed catch-all. Triggers when the host emits `{:projects,
  # :opened, %{lv: AssignmentFormLive, session: %{}}}` without the
  # required `project_id` (or `id` for :edit). Without this clause the
  # apply_action/3 dispatch raises `FunctionClauseError` before mount
  # completes. Per the embedding contract we render placeholders + flash,
  # then `close_or_navigate/2` emits `:closed` so the host can pop the
  # modal.
  defp apply_action(socket, action, _params) when action in [:new, :edit] do
    socket
    |> assign_not_found_placeholders()
    |> put_flash(:error, gettext("Project not found."))
    |> WebHelpers.close_or_navigate(Paths.projects())
  end

  # The edit trail's leaf crumb: the record the form is about. A linked
  # sub-project has a page of its own, so its crumb links there (an
  # unresolved child — deleted under the row — has none); an assignment's
  # task is text, since the assignment has no page.
  defp child_crumbs(%Project{uuid: nil}, _name), do: []
  defp child_crumbs(%Project{} = child, name), do: [%{label: name, path: Paths.project(child)}]

  defp task_crumbs(nil), do: []
  defp task_crumbs(task_name), do: [%{label: task_name}]

  # The routed header titles the page "Edit" under the task crumb; the
  # drawer has no trail, so its heading names the task.
  defp edit_titles(nil),
    do: [page_title: gettext("Edit assignment"), heading: gettext("Edit assignment")]

  defp edit_titles(task_name),
    do: [page_title: gettext("Edit"), heading: gettext("Edit %{name}", name: task_name)]

  # Which assignee `<select>` is active for a record carrying the polymorphic
  # assignee fields (an Assignment or a Project).
  defp assignee_kind(%{assigned_person_uuid: u}) when not is_nil(u), do: "person"
  defp assignee_kind(%{assigned_team_uuid: u}) when not is_nil(u), do: "team"
  defp assignee_kind(%{assigned_department_uuid: u}) when not is_nil(u), do: "department"
  defp assignee_kind(_), do: ""

  # Workflow-status assigns for sub-project mode (V125) — a sub-project is a
  # project, so it gets the same status-source picker. Delegates to the shared
  # `WorkflowStatusFields` logic. Harmless in task mode (the section isn't
  # rendered there).
  defp assign_status_init(socket, record) do
    available = WSF.available?()

    socket
    |> assign(
      statuses_available: available,
      status_entities: if(available, do: WSF.entity_options(), else: []),
      status_translation_mode: WSF.mode_string(record),
      status_preview: []
    )
    |> refresh_status_preview()
  end

  defp refresh_status_preview(%{assigns: %{statuses_available: true, sp_form: sp_form}} = socket) do
    selected = WSF.selected_entity_uuid(sp_form[:status_entity_uuid])
    assign(socket, status_preview: WSF.preview_for(selected))
  end

  defp refresh_status_preview(socket), do: socket

  defp assign_options(socket) do
    lang = L10n.current_content_lang()

    library_tasks = Projects.list_tasks()

    assign(socket,
      task_options: Enum.map(library_tasks, &{Task.localized_title(&1, lang), &1.uuid}),
      # The "From library" picker (item 27): the whole library, what was
      # typed in its search, and the tasks ticked, in the order ticked.
      library_tasks: library_tasks,
      library_q: "",
      library_picked: [],
      library_recent: [],
      library_often: [],
      team_options: load_teams(),
      department_options: load_departments(),
      person_options: load_people(),
      project_labels: load_project_labels(socket),
      selected_labels: current_label_uuids(socket)
    )
  end

  defp load_project_labels(socket) do
    case socket.assigns[:project] do
      %{uuid: uuid} -> Labels.list_for_project(uuid)
      _ -> []
    end
  end

  defp current_label_uuids(socket) do
    case socket.assigns[:assignment] do
      %{uuid: uuid} ->
        [uuid]
        |> Labels.labels_for_assignments()
        |> Map.get(uuid, [])
        |> Enum.map(& &1.uuid)

      _ ->
        []
    end
  end

  defp load_teams do
    PhoenixKitProjects.People.list_teams()
    |> Enum.map(&{"#{&1.name} (#{&1.department.name})", &1.uuid})
  rescue
    e in [Postgrex.Error, DBConnection.ConnectionError, Ecto.QueryError] ->
      Logger.warning("[Projects] load_teams failed: #{Exception.message(e)}")
      []
  end

  defp load_departments do
    PhoenixKitProjects.People.list_departments() |> Enum.map(&{&1.name, &1.uuid})
  rescue
    e in [Postgrex.Error, DBConnection.ConnectionError, Ecto.QueryError] ->
      Logger.warning("[Projects] load_departments failed: #{Exception.message(e)}")
      []
  end

  defp load_people do
    PhoenixKitProjects.People.list_people()
    |> Enum.map(&{(&1.user && &1.user.email) || "—", &1.uuid})
  rescue
    e in [Postgrex.Error, DBConnection.ConnectionError, Ecto.QueryError] ->
      Logger.warning("[Projects] load_people failed: #{Exception.message(e)}")
      []
  end

  # When the work really began and ended — stamped by Start and Done,
  # corrected here (a late "Done" moved back to when it happened). Their own
  # changeset (`Assignment.times_changeset/2`): the form's never casts them.
  defp assign_times_form(
         %{assigns: %{live_action: :edit, kind: "task", assignment: %Assignment{uuid: u} = a}} =
           socket
       )
       when is_binary(u),
       do: assign(socket, :times_form, to_form(Assignment.times_changeset(a, %{}), as: :times))

  defp assign_times_form(socket), do: assign(socket, :times_form, nil)

  defp take_times_params(%{assigns: %{times_form: %Phoenix.HTML.Form{}}} = socket, %{
         "times" => %{} = times
       }) do
    a = socket.assigns.assignment

    attrs =
      times
      |> Map.take(["started_at", "completed_at"])
      |> TimeInput.normalize(["started_at", "completed_at"])
      |> drop_unchanged_wall(a, ["started_at", "completed_at"])
      |> WebHelpers.normalize_datetime_local_attrs(["started_at", "completed_at"])

    cs = a |> Assignment.times_changeset(attrs) |> Map.put(:action, :validate)
    assign(socket, :times_form, to_form(cs, as: :times))
  end

  defp take_times_params(socket, _params), do: socket

  # Corrected times are written after the row's own save, to the row as it
  # now is. `:none` when nothing was changed.
  defp save_times(%{assigns: %{times_form: %Phoenix.HTML.Form{source: cs}}}, updated) do
    # Checked again against the row as saved, not the one the boxes were
    # filled against: a status changed to done in the same save may take a
    # finish time.
    if cs.changes == %{},
      do: :none,
      else: Projects.correct_assignment_times(updated, cs.changes)
  end

  defp save_times(_socket, _updated), do: :none

  # The assignment's fields as the changeset takes them: a `datetime-local`
  # read in the viewer's zone, and one posted back exactly as it was shown
  # left out — the box shows minutes, so a stored second must not be lost
  # to a save of some other field.
  defp form_attrs(attrs, socket) do
    attrs
    # The time pickers post their parts (`TimeInput`); folded back into the
    # values the browser's own inputs posted.
    |> TimeInput.normalize(~w(deadline start_time end_time))
    # An estimate of 1.5 hours is stored as 90 minutes (a whole number).
    |> DurationInput.estimate_attrs()
    |> drop_unchanged_wall(socket.assigns[:assignment], ["deadline"])
    |> normalize_form_attrs()
    # "Does not repeat ▾" posts a choice; the task keeps a rule (`Repeats`).
    |> Repeats.from_params()
  end

  defp drop_unchanged_wall(attrs, record, fields) do
    Enum.reduce(fields, attrs, fn field, acc ->
      with raw when is_binary(raw) <- Map.get(acc, field),
           %{} <- record,
           %DateTime{} = at <- Map.get(record, String.to_existing_atom(field)),
           true <- raw == local_input_value(at) do
        Map.delete(acc, field)
      else
        _ -> acc
      end
    end)
  end

  # A stored instant as a `datetime-local` value: the viewer's wall clock,
  # to the minute. The changeset's params hold what was cast — a UTC ISO
  # string once normalised — which the box would not take, so that is
  # shown as a wall clock too; anything else (a raw value that did not
  # cast) as it is.
  defp local_input_value(%DateTime{} = dt) do
    dt
    |> L10n.local()
    |> DateTime.to_naive()
    |> NaiveDateTime.to_iso8601()
    |> String.slice(0, 16)
  end

  defp local_input_value(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> local_input_value(dt)
      _ -> value
    end
  end

  defp local_input_value(other), do: other

  defp assign_form(socket, cs),
    do: socket |> assign(form: to_form(cs)) |> refresh_assignee_chip()

  # ── Validate ────────────────────────────────────────────────────

  @impl true
  # Opening a cued section (History, Discussion, AI notes are
  # `<.accordion cue>`) reports it as seen. This form never cues anything,
  # so there is nothing to clear — but without a clause the event raised
  # FunctionClauseError and took the whole form down (tim-dev, 2026-10-27).
  def handle_event("pk_cue_seen", _params, socket), do: {:noreply, socket}

  # A file's removal, the task's deletion and a Close with unsaved changes
  # ask first, through the module's one confirm dialog
  # (`Components.ConfirmAction`); only these events may be put behind it.
  def handle_event("request_confirm", params, socket),
    do:
      {:noreply,
       ConfirmAction.request(socket, params, ~w(remove_task_file delete_task close_form cancel))}

  def handle_event("confirm_action_cancel", _params, socket),
    do: {:noreply, ConfirmAction.clear(socket)}

  def handle_event("confirm_action_ok", _params, socket) do
    case ConfirmAction.take(socket) do
      {nil, socket} ->
        {:noreply, socket}

      # The confirmed event runs past the write hook (a direct call), so
      # it is gated here, one event at a time: a write is re-asked, a
      # Close is not, so a person who lost the right can still leave.
      {%{event: event, params: params}, socket} ->
        case WriteGate.gate(event, params, socket) do
          {:halt, socket} -> {:noreply, socket}
          {:cont, socket} -> handle_event(event, params, socket)
        end
    end
  end

  # Close on a task being edited: leaves WITHOUT saving (the button asks
  # first while something is unsaved — `ConfirmAction.close/2`).
  def handle_event("close_form", _params, socket) do
    fallback =
      case socket.assigns[:project] do
        %{uuid: uuid} -> Paths.project(uuid)
        _ -> Paths.projects()
      end

    {:noreply, socket |> cancel_autosave() |> leave_form(fallback)}
  end

  def handle_event("cancel", _params, socket) do
    fallback =
      case socket.assigns[:project] do
        %{uuid: uuid} -> Paths.project(uuid)
        _ -> Paths.projects()
      end

    {:noreply, leave_form(socket, fallback)}
  end

  def handle_event("switch_language", %{"lang" => lang_code}, socket) do
    {:noreply, handle_switch_language(socket, lang_code)}
  end

  # Tab strip for "From library" vs "Create new" task source. Sets the
  # `task_mode` assign so the conditional template branches re-render;
  # the hidden form input picks up the new value on the next
  # `phx-change` so `validate`/`save` see it via params (no separate
  # socket-assign read path needed).
  # A library suggestion under the new task's title, picked: the task is
  # added from the library as the "From library" tab adds it — its title,
  # description, estimate and default assignee. Only a row the form offered.
  def handle_event("pick_title_suggestion", %{"uuid" => uuid}, socket) do
    offered? = Enum.any?(socket.assigns[:title_suggestions] || [], &(&1.uuid == uuid))

    if offered? and socket.assigns.fx.library and socket.assigns.live_action == :new do
      attrs = socket.assigns.form.params || %{}

      {:noreply,
       socket
       |> assign(task_mode: "existing", title_suggestions: [], library_picked: [uuid])
       |> assign_library_blocks()
       |> prefill_from_template(uuid, attrs)
       |> WebHelpers.mark_dirty()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("set_task_mode", %{"tab" => mode}, socket)
      when mode in ~w(existing new) do
    # The library tab only exists while the project's library flag is on;
    # a stale or forged switch to it is ignored.
    cond do
      mode == "existing" and not socket.assigns.fx.library ->
        {:noreply, socket}

      mode == "existing" ->
        {:noreply, socket |> assign(task_mode: mode) |> assign_library_blocks()}

      true ->
        {:noreply, assign(socket, task_mode: mode)}
    end
  end

  # ── The "From library" picker (item 27) ─────────────────────────────
  #
  # Search first (diacritic-insensitive, title then description), then the
  # viewer's Recent adds, the site's Often used, and everything A–Z under
  # letter headings; ticked tasks are added in the order ticked. One tick
  # is the form's own library pick (its details, its pulled-in tasks);
  # several are added each with its library defaults.

  def handle_event("library_search", params, socket) do
    q = params |> Map.get("library_q", socket.assigns[:library_q] || "") |> to_string()
    {:noreply, assign(socket, library_q: String.slice(q, 0, 200))}
  end

  def handle_event("library_toggle", %{"uuid" => uuid}, socket) do
    known? = Enum.any?(socket.assigns[:library_tasks] || [], &(&1.uuid == uuid))

    if known? and socket.assigns.fx.library and socket.assigns.live_action == :new do
      picked = socket.assigns.library_picked

      picked = if uuid in picked, do: List.delete(picked, uuid), else: picked ++ [uuid]

      {:noreply,
       socket
       |> assign(library_picked: picked)
       |> sync_library_pick()
       |> WebHelpers.mark_dirty()}
    else
      {:noreply, socket}
    end
  end

  # Pending-dep buffer for `:new` mode. The Dependency row can only be
  # created post-insert (it FK-references the new assignment's uuid),
  # so track the user's selections in socket state and flush them in
  # `save_new` / `create_assignment_for_new_task` after the assignment
  # row exists. Uses a list (not a MapSet) so the rendered order
  # mirrors the user's add order; the `if dep_uuid in current` guard
  # below skips dupes when the same uuid is added twice.
  # Pending deps are flushed into REAL dependency rows on save — they get
  # the same dependencies gate as the live add/remove pair, or a forged
  # pending-add on a dependencies-off project persists rows (panel R3-3).
  def handle_event("add_pending_dep", %{"depends_on_uuid" => dep_uuid}, socket)
      when dep_uuid != "" do
    if socket.assigns.fx.dependencies do
      {:noreply,
       socket
       |> update(:pending_dep_uuids, fn current ->
         if dep_uuid in current, do: current, else: current ++ [dep_uuid]
       end)
       |> WebHelpers.mark_dirty()}
    else
      {:noreply,
       put_flash(socket, :error, gettext("This feature is turned off for this project."))}
    end
  end

  def handle_event("add_pending_dep", _params, socket), do: {:noreply, socket}

  def handle_event("remove_pending_dep", %{"uuid" => dep_uuid}, socket) do
    {:noreply,
     socket |> update(:pending_dep_uuids, &List.delete(&1, dep_uuid)) |> WebHelpers.mark_dirty()}
  end

  # Closure-pull tree node toggle. The root task can't be excluded — it's
  # the user's explicit pick, and excluding it via this UI would leave a
  # logically-empty form. Already-in-project nodes also can't be toggled
  # (they're displayed as static "✓ already there" markers and their
  # state has no effect on save: the project already has the assignment).
  def handle_event("toggle_closure_task", %{"uuid" => task_uuid}, socket) do
    cond do
      is_nil(socket.assigns.closure_tree) ->
        {:noreply, socket}

      task_uuid == socket.assigns.closure_tree.task.uuid ->
        # Root: silently ignored; the task picker is the way to "untick" the root.
        {:noreply, socket}

      true ->
        {:noreply,
         socket
         |> update(:excluded_closure_uuids, fn excluded ->
           if MapSet.member?(excluded, task_uuid),
             do: MapSet.delete(excluded, task_uuid),
             else: MapSet.put(excluded, task_uuid)
         end)
         |> WebHelpers.mark_dirty()}
    end
  end

  def handle_event("subtask_add", %{"title" => title}, socket) do
    title = title |> to_string() |> String.trim()

    with %Assignment{} = parent <- socket.assigns[:assignment],
         true <- title != "",
         true <- may?(socket, :create_tasks),
         {:ok, %{assignment: a}} <-
           Projects.create_task_with_assignment(
             socket.assigns.project.uuid,
             %{"title" => title, "ad_hoc" => true},
             %{}
           ) do
      Projects.stamp_assignment(a, %{created_by_uuid: Activity.actor_uuid(socket)})
      log_subtask_act(socket, "projects.assignment_created", a.uuid, %{"parent" => parent.uuid})
      _ = Outline.move(a, parent.uuid, :last)

      {:noreply,
       socket
       |> assign_outline(%{})
       |> assign(:subtask_seq, (socket.assigns[:subtask_seq] || 0) + 1)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("delete_task", _params, socket) do
    with %Assignment{} = a <- socket.assigns[:assignment],
         %Assignment{} = fresh <- Projects.get_assignment(a.uuid),
         true <- can_delete?(socket, fresh) do
      socket = cancel_autosave(socket)

      case PhoenixKitProjects.Notices.removing(fresh, Activity.actor_uuid(socket), fn ->
             Projects.delete_assignment(fresh)
           end) do
        {:ok, _} ->
          log_subtask_act(socket, "projects.assignment_removed", fresh.uuid, %{
            "task" => Assignment.label(fresh)
          })

          fallback = Paths.project(socket.assigns.project.uuid)

          {:noreply,
           socket
           |> WebHelpers.notify_deleted(:assignment, fresh.uuid)
           |> WebHelpers.close_or_navigate(fallback)}

        {:error, _} ->
          log_subtask_act(socket, "projects.assignment_removed", fresh.uuid, %{}, :failed)
          {:noreply, put_flash(socket, :error, gettext("Could not remove task."))}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("subtask_toggle", %{"uuid" => uuid}, socket) do
    with %Assignment{} = parent <- socket.assigns[:assignment],
         %Assignment{parent_uuid: p} = sub when p == parent.uuid <- Projects.get_assignment(uuid),
         true <- may?(socket, :update_status) do
      {action, result} =
        if sub.status == "done",
          do: {"projects.assignment_reopened", Projects.reopen_assignment(sub)},
          else:
            {"projects.assignment_completed",
             Projects.complete_assignment(sub, Activity.actor_uuid(socket))}

      outcome = if match?({:ok, _}, result), do: :ok, else: :failed
      log_subtask_act(socket, action, sub.uuid, %{}, outcome)
      # No page around the form to settle the project: a last leaf ticked
      # here completes it, as it would from the list.
      Projects.recompute_project_completion(socket.assigns.project.uuid)

      fresh = Projects.get_assignment(parent.uuid)
      {:noreply, socket |> assign(assignment: fresh || parent) |> assign_outline(%{})}
    else
      _ -> {:noreply, socket}
    end
  end

  # The task's files (`Attachments`, V27): the upload's own form validates
  # nothing, the bytes are stored as each one finishes (`handle_progress/3`).
  def handle_event("task_files_validate", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_task_upload", %{"ref" => ref, "upload" => upload}, socket)
      when upload in ~w(task_files description_images),
      do: {:noreply, cancel_upload(socket, String.to_existing_atom(upload), ref)}

  def handle_event("remove_task_file", %{"uuid" => file_uuid}, socket) do
    if attach_allowed?(socket) do
      shown =
        Enum.find(socket.assigns[:task_files] || [], &(to_string(&1.file.uuid) == file_uuid))

      inline? = match?(%{inline: true}, shown)

      if inline? and socket.assigns.live_action == :edit do
        # A picture of the description goes with the text it is in: out of
        # the text now, and the file itself only on Save — Close keeps both
        # (the panel, 2026-11-02: no saved text naming a removed file).
        {:noreply,
         socket
         |> strip_inline_image(file_uuid)
         |> update(:pending_file_removals, &Enum.uniq(&1 ++ [{file_uuid, shown}]))}
      else
        {:noreply, remove_file_now(socket, file_uuid, shown, inline?)}
      end
    else
      {:noreply,
       put_flash(socket, :error, gettext("You don't have permission to manage files here."))}
    end
  end

  def handle_event("set_form_pane", %{"pane" => pane}, socket) when pane in @panes,
    do: {:noreply, assign(socket, :form_pane, pane)}

  def handle_event("set_form_pane", _params, socket), do: {:noreply, socket}

  # The assignee picker (`Web.Components.AssigneePicker`): its search, picks,
  # Recent, "Assign to me" and the staff-record question.
  def handle_event(event, params, socket) when event in @picker_events,
    do: AssigneePicker.handle_event(event, params, socket, __MODULE__)

  def handle_event("deadline_preset", %{"preset" => preset}, socket) do
    case {socket.assigns.fx[:dates] != false, deadline_preset(preset)} do
      {true, at} when is_binary(at) -> {:noreply, put_form_attrs(socket, %{"deadline" => at})}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("deadline_clear", _params, socket),
    do: {:noreply, put_form_attrs(socket, %{"deadline" => ""})}

  def handle_event("validate", %{"assignment" => attrs} = params, socket) do
    socket =
      socket
      |> take_task_params(params)
      |> take_times_params(params)
      |> maybe_move(params)
      |> assign_title_suggestions(params)

    # The repeat choice as picked, so "Custom" keeps its number and unit
    # open while they are typed.
    socket =
      case attrs do
        %{"repeat" => choice} -> assign(socket, :repeat_choice, choice)
        _ -> socket
      end

    attrs = form_attrs(attrs, socket)
    assign_type = Map.get(params, "assign_type", socket.assigns.assign_type)
    task_mode = Map.get(params, "task_mode", socket.assigns.task_mode)

    add_to_library =
      case Map.get(params, "add_to_library") do
        nil -> socket.assigns.add_to_library
        value -> value == "true"
      end

    socket =
      if task_mode == "existing" && socket.assigns.live_action == :new do
        task_uuid = attrs["task_uuid"]

        if task_uuid != "" && task_uuid != socket.assigns.selected_task_uuid do
          prefill_from_template(socket, task_uuid, attrs)
        else
          cs =
            socket.assigns.assignment
            |> Projects.change_assignment(merge_attrs(attrs, socket))

          assign_form(socket, cs) |> assign(selected_task_uuid: task_uuid)
        end
      else
        cs = Projects.change_assignment(socket.assigns.assignment, merge_attrs(attrs, socket))
        assign_form(socket, cs)
      end

    {:noreply,
     socket
     |> assign(
       assign_type: assign_type,
       task_mode: task_mode,
       add_to_library: add_to_library
     )
     |> WebHelpers.mark_dirty()
     |> schedule_autosave(params)}
  end

  # ── Dependency management (edit mode) ───────────────────────────

  def handle_event("add_assignment_dep", %{"depends_on_uuid" => dep_uuid}, socket)
      when dep_uuid != "" do
    if socket.assigns.fx.dependencies do
      do_add_assignment_dep(dep_uuid, socket)
    else
      {:noreply,
       put_flash(socket, :error, gettext("This feature is turned off for this project."))}
    end
  end

  def handle_event("add_assignment_dep", _params, socket), do: {:noreply, socket}

  def handle_event("remove_assignment_dep", %{"uuid" => dep_uuid}, socket) do
    if socket.assigns.fx.dependencies do
      do_remove_assignment_dep(dep_uuid, socket)
    else
      {:noreply,
       put_flash(socket, :error, gettext("This feature is turned off for this project."))}
    end
  end

  # ── Save ────────────────────────────────────────────────────────

  # Save on a task being edited: everything the form holds, through the
  # steps the autosave took (gates re-read, times corrected, words and the
  # title on the task, labels, the history's change list); on success the
  # popup closes as Close does, on an error it stays open on it.
  def handle_event(
        "save",
        %{"assignment" => _} = params,
        %{assigns: %{live_action: :edit, kind: "task"}} = socket
      ) do
    socket =
      socket
      |> take_task_params(params)
      |> take_times_params(params)
      |> cancel_autosave()
      |> assign(:pending_params, params)
      |> autosave_now()

    if socket.assigns[:save_state] == :error do
      {:noreply, socket}
    else
      socket =
        socket
        |> remove_pending_files()
        |> assign(dirty?: false)
        |> WebHelpers.notify_dirty(false)

      handle_event("close_form", %{}, socket)
    end
  end

  def handle_event("save", %{"assignment" => attrs} = params, socket) do
    socket = take_task_params(socket, params)
    assign_type = Map.get(params, "assign_type", "")

    # Save-time gate re-resolution (panel R3-4): the submit binds to the
    # CURRENT flags, not the mount-time snapshot a mid-edit toggle staled.
    fx = Features.gates(socket.assigns.project)
    # "Add & next" (Shift+Enter, or the button — the submitter carries
    # `then=next`): after a successful create the form resets for the next
    # task instead of closing. Only a create can chain.
    # `:assign_tasks` is re-read with the gates: `strip_unassignable/2`
    # must judge the save by the right as it is now, not at mount.
    socket =
      assign(socket,
        fx: fx,
        can_assign?: can_assign?(socket),
        add_next?: socket.assigns.live_action == :new and Map.get(params, "then") == "next"
      )

    # With the library off for this project, a submit can neither pick
    # from it nor feed it — whatever the (stale or forged) params say.
    task_mode =
      if fx.library, do: Map.get(params, "task_mode", socket.assigns.task_mode), else: "new"

    socket =
      case {fx.library, Map.get(params, "add_to_library")} do
        {false, _} -> assign(socket, add_to_library: false)
        {true, nil} -> socket
        {true, value} -> assign(socket, add_to_library: value == "true")
      end

    # Labels ride a separate param (checkbox list) — captured only when
    # the flag is on at SAVE time, applied after the record write.
    socket = assign(socket, :pending_labels, pending_labels(fx, params))

    attrs =
      attrs
      |> form_attrs(socket)
      |> clear_other_assignees(assign_type)
      |> strip_gated_attrs(fx)
      |> strip_unassignable(socket)
      |> merge_attrs(socket)

    case {socket.assigns.live_action, task_mode} do
      {:new, "new"} ->
        save_with_new_task(socket, attrs, params)

      {:new, "existing"} when length(socket.assigns.library_picked) > 1 ->
        save_library_many(socket)

      {:new, _} ->
        save_new(socket, attrs)

      {:edit, _} ->
        save_edit(socket, attrs)
    end
  end

  # Time logged from the task's form, as the project page's "Log time"
  # would: the viewer's own, or — for someone who runs the plan — a
  # person picked from the project's people. The controls render only
  # where the ledger is on; the event is asked again here.
  def handle_event("log_time", params, %{assigns: %{live_action: :edit}} = socket) do
    %{project: project, assignment: assignment} = socket.assigns
    scope = socket.assigns[:phoenix_kit_current_scope]

    with true <- Features.on?(project, "ledger"),
         true <- PhoenixKitProjects.Authz.can?(scope, project, :log_time, assignment),
         {:ok, actor} <- log_actor(socket),
         {:ok, minutes} <- DurationInput.to_minutes(params["duration"]),
         {:ok, _entry} <-
           PhoenixKitProjects.Ledger.log_time(
             assignment.project_uuid,
             minutes,
             [
               assignment_uuid: assignment.uuid,
               note: log_note(params["note"]),
               # Only where the project tracks billable time (its `billable` flag).
               billable:
                 Features.on?(project, "billable") and params["billable"] in ["true", "on"]
             ] ++ actor
           ) do
      {:noreply,
       socket
       |> assign_logged_minutes()
       |> assign(log_person: nil, log_seq: (socket.assigns[:log_seq] || 0) + 1)
       |> put_flash(:info, gettext("Time logged."))}
    else
      :error ->
        {:noreply, put_flash(socket, :error, gettext("Enter a positive amount of time."))}

      false ->
        {:noreply,
         put_flash(socket, :error, gettext("You don't have permission to log time here."))}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Could not log the time."))}
    end
  end

  # The "Who" picker of the log line (core's `<.search_picker>`): the
  # project's people, searched as typed, twenty at a time.
  def handle_event("log_person_search", %{"q" => q} = params, socket) do
    needle = q |> to_string() |> String.trim() |> String.downcase()

    matches =
      Enum.filter(socket.assigns[:log_people] || [], fn {name, _key} ->
        needle == "" or String.contains?(String.downcase(name), needle)
      end)

    rows =
      matches
      |> Enum.take(20)
      |> Enum.map(fn {name, key} ->
        %{kind: "person", uuid: key, label: name, icon: "hero-user"}
      end)

    {:noreply,
     push_event(socket, "picker_results", %{
       q: q,
       results: rows,
       has_more: length(matches) > 20,
       id: params["id"]
     })}
  end

  def handle_event("log_person_pick", %{"uuid" => key} = params, socket) do
    person =
      Enum.find_value(socket.assigns[:log_people] || [], fn {name, k} ->
        k == key && %{key: k, name: name}
      end)

    {:noreply,
     socket
     |> assign(:log_person, person)
     |> push_event("picker_staged", %{id: params["id"]})}
  end

  def handle_event("log_person_clear", _params, socket),
    do: {:noreply, assign(socket, :log_person, nil)}

  def handle_event("log_time", _params, socket), do: {:noreply, socket}

  # Portal visibility flip — immediate write, never a form param. Gated
  # explicitly on :edit_tasks (a PUBLIC-exposure change gets the strict
  # shape even though this LV otherwise trusts its mount gate).
  def handle_event("toggle_board_published", _params, socket) do
    assignment = socket.assigns[:assignment]
    project = socket.assigns[:project]
    actor = socket.assigns[:phoenix_kit_current_scope] || Activity.actor_uuid(socket)
    publish? = is_map(assignment) and is_nil(assignment.board_published_at)

    # Same guard chain as the link-holder toggle beside it: publishing to
    # the OPEN WEB cannot be an easier action than publishing to the link.
    with %Assignment{uuid: uuid} when is_binary(uuid) <- assignment,
         true <- public_board?(project),
         true <- actor != nil and PhoenixKitProjects.Authz.can?(actor, project, :edit_tasks),
         {:ok, _} <- PhoenixKitProjects.Portal.set_board_published(uuid, publish?) do
      Activity.log(
        if(publish?,
          do: "projects.issue_board_published",
          else: "projects.issue_board_unpublished"
        ),
        actor_uuid: Activity.actor_uuid(socket),
        resource_type: "assignment",
        resource_uuid: assignment.uuid,
        metadata: %{"project_uuid" => assignment.project_uuid}
      )

      {:noreply,
       socket
       |> assign(assignment: Projects.get_assignment(assignment.uuid))
       |> put_flash(
         :info,
         if(publish?,
           do: gettext("Published to the public board."),
           else: gettext("Removed from the public board.")
         )
       )}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Could not change that."))}
    end
  end

  def handle_event("toggle_portal_public", _params, socket) do
    assignment = socket.assigns[:assignment]
    project = socket.assigns[:project]

    actor =
      socket.assigns[:phoenix_kit_current_scope] || Activity.actor_uuid(socket)

    with %Assignment{uuid: uuid} when is_binary(uuid) <- assignment,
         true <- portal_enabled?(project),
         true <- actor != nil and PhoenixKitProjects.Authz.can?(actor, project, :edit_tasks),
         {:ok, updated} <-
           PhoenixKitProjects.Portal.set_public(assignment, assignment.public != true,
             actor_uuid: Activity.actor_uuid(socket)
           ) do
      {:noreply, assign(socket, assignment: updated)}
    else
      _ -> {:noreply, socket}
    end
  end

  # ── Sub-project mode (V127) ──────────────────────────────────────
  # Same add/edit page as a task, but the form is the child project
  # (name + assignee) and the dependency section uses the same handlers.

  # Toggle between "create new child" and "nest existing project" (V127).
  # Feature-gated: sub-project mode is unreachable when the flag is off
  # (kind resolution already forces "task"), but a stale client could still
  # emit the event — refuse it the same way.
  def handle_event("set_sp_mode", %{"tab" => mode}, socket)
      when mode in ~w(new existing) do
    if socket.assigns.fx.subprojects do
      do_set_sp_mode(mode, socket)
    else
      {:noreply,
       put_flash(socket, :error, gettext("This feature is turned off for this project."))}
    end
  end

  def handle_event("validate_subproject", %{"subproject" => attrs} = params, socket) do
    assign_type = Map.get(params, "assign_type", socket.assigns.assign_type)
    mode = Map.get(params, "status_translation_mode", socket.assigns.status_translation_mode)
    attrs = attrs |> clear_other_assignees(assign_type) |> sp_translations(socket)
    cs = Projects.change_project(sp_source(socket), attrs)

    {:noreply,
     socket
     |> assign(
       sp_form: to_form(cs, as: :subproject),
       assign_type: assign_type,
       status_translation_mode: mode
     )
     |> refresh_assignee_chip()
     |> refresh_status_preview()
     |> WebHelpers.mark_dirty()}
  end

  # "Link existing" mode renders no `subproject[...]` inputs, so the form's
  # `phx-change` arrives without a "subproject" key — nothing to validate.
  def handle_event("validate_subproject", _params, socket), do: {:noreply, socket}

  # A sub-project is a project, so it gets the same "Generate default" action
  # ProjectFormLive has (V125). Operates on `@sp_form`. Feature-gated on
  # `statuses` (panel R3-5): with the flag off this provisions nothing.
  def handle_event("generate_default_statuses", _params, socket) do
    if Features.gates(socket.assigns.project).statuses do
      do_generate_default_statuses(socket)
    else
      {:noreply,
       put_flash(socket, :error, gettext("This feature is turned off for this project."))}
    end
  end

  # "Link existing" mode: no `subproject[...]` inputs, just the picked child.
  # The whole sub-project branch is feature-gated (panel R3-2): kind
  # resolution already forces the task form when the flag is off, but a
  # forged save_subproject would still create/link a child — refuse it, and
  # strip gated attrs the same way the task save does.
  def handle_event("save_subproject", %{"link_child_uuid" => child_uuid}, socket) do
    fx = Features.gates(socket.assigns.project)

    if fx.subprojects do
      link_existing_subproject(socket, child_uuid)
    else
      {:noreply,
       put_flash(socket, :error, gettext("This feature is turned off for this project."))}
    end
  end

  def handle_event("save_subproject", %{"subproject" => attrs} = params, socket) do
    # Re-resolve at save time (panel R3-4): a mid-edit toggle in another
    # session must bind the SUBMIT, not the stale mount-time map.
    fx = Features.gates(socket.assigns.project)

    if fx.subprojects do
      assign_type = Map.get(params, "assign_type", "")

      attrs =
        attrs
        |> clear_other_assignees(assign_type)
        |> sp_translations(socket)
        |> strip_gated_attrs(fx)
        |> then(fn a ->
          if fx.statuses, do: a, else: Map.drop(a, ~w(status_entity_uuid))
        end)
        |> WSF.apply_mode(params, sp_source(socket))

      attrs =
        fold_completion(
          attrs,
          params,
          if(socket.assigns.live_action == :new, do: nil, else: sp_source(socket))
        )

      case socket.assigns.live_action do
        :new -> save_new_subproject(socket, attrs)
        :edit -> save_edit_subproject(socket, attrs)
      end
    else
      {:noreply,
       put_flash(socket, :error, gettext("This feature is turned off for this project."))}
    end
  end

  # What the «Project to nest» picker offers: the projects the viewer may
  # nest here, minus the ones the host's move lock holds in place (nesting
  # moves a project). One hook call for the whole list.
  defp nestable_projects(parent, scope) do
    candidates = Projects.available_projects_to_link(parent, scope)
    locked = MoveLock.reasons(candidates)

    Enum.reject(candidates, &Map.has_key?(locked, &1.uuid))
  end

  defp link_existing_subproject(socket, child_uuid)
       when child_uuid in [nil, ""] do
    {:noreply, put_flash(socket, :error, gettext("Pick a project to nest."))}
  end

  defp link_existing_subproject(socket, child_uuid) do
    parent = socket.assigns.project

    # Re-resolved at save time, not trusted from the client: only a project
    # the picker would offer this viewer right now may be nested — the
    # picker's own rule, asked for this one project.
    eligible? =
      case Projects.linkable_project(
             parent,
             socket.assigns[:phoenix_kit_current_scope],
             child_uuid
           ) do
        nil -> false
        project -> not Map.has_key?(MoveLock.reasons([project]), project.uuid)
      end

    if eligible? do
      do_link_existing_subproject(socket, parent, child_uuid)
    else
      {:noreply, put_flash(socket, :error, link_error_message(:not_available))}
    end
  end

  defp do_link_existing_subproject(socket, parent, child_uuid) do
    case Projects.link_subproject(parent.uuid, child_uuid) do
      {:ok, %{child_project: child, assignment: link}} ->
        Activity.log("projects.subproject_linked",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "assignment",
          resource_uuid: link.uuid,
          metadata: %{"name" => child.name, "child_project_uuid" => child.uuid}
        )

        {:noreply,
         socket
         |> put_flash(:info, gettext("Existing project nested as a sub-project."))
         |> WebHelpers.navigate_after_save(Paths.project(parent.uuid),
           kind: :assignment,
           record: link,
           action: :create
         )}

      {:error, reason} ->
        Activity.log_failed("projects.subproject_linked",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "project",
          resource_uuid: child_uuid,
          metadata: %{"parent_project_uuid" => parent.uuid, "reason" => to_string(reason)}
        )

        {:noreply, put_flash(socket, :error, link_error_message(reason))}
    end
  end

  defp link_error_message(:self_link), do: gettext("A project can't be its own sub-project.")

  defp link_error_message(:would_create_cycle),
    do: gettext("That project is an ancestor — nesting it here would create a cycle.")

  defp link_error_message(:already_subproject),
    do: gettext("That project is already a sub-project of another parent.")

  defp link_error_message(:kind_mismatch),
    do: gettext("Templates and projects can't be nested into each other.")

  defp link_error_message(:not_available),
    do: gettext("That project can't be nested here.")

  defp link_error_message(:archived),
    do: gettext("That project is archived — restore it before nesting it.")

  defp link_error_message(:not_found), do: gettext("That project no longer exists.")
  defp link_error_message(_), do: gettext("Could not nest that project.")

  # ── Tasks under tasks ──────────────────────────────────────────────

  # The "Sits under" choices (every task of the project but this one and
  # what is under it, indented by depth), the current choice, and — when
  # editing — the task's own subtasks.
  defp assign_outline(socket, params) do
    project = socket.assigns[:project]
    on? = match?(%Project{}, project) and Features.on?(project, "subtasks")

    if on? do
      rows = Projects.list_assignments(project.uuid)
      own = socket.assigns[:assignment]
      own_uuid = own && own.uuid

      excluded =
        if own_uuid,
          do:
            Map.new(
              [own_uuid | rows |> Outline.descendants(own_uuid) |> Enum.map(& &1.uuid)],
              &{&1, true}
            ),
          else: %{}

      options =
        for {a, depth} <- Outline.walk(rows),
            not Map.has_key?(excluded, a.uuid),
            not Assignment.subproject?(a),
            do: {String.duplicate("— ", depth) <> (Assignment.label(a) || ""), a.uuid}

      subtasks = if own_uuid, do: Enum.filter(rows, &(&1.parent_uuid == own_uuid)), else: []

      parent =
        cond do
          own_uuid -> own.parent_uuid
          is_binary(params["parent"]) -> params["parent"]
          true -> nil
        end

      assign(socket,
        subtasks_on?: true,
        parent_options: options,
        parent_task: parent,
        subtasks: subtasks,
        subtask_counts: Outline.counts(rows)
      )
      |> assign_delete(rows)
    else
      socket
      |> assign(
        subtasks_on?: false,
        parent_options: [],
        parent_task: nil,
        subtasks: [],
        subtask_counts: %{}
      )
      |> then(fn s ->
        if match?(%Project{}, s.assigns[:project]),
          do: assign_delete(s, Projects.list_assignments(s.assigns.project.uuid)),
          else: assign(s, can_delete_task?: false, subtask_total: 0)
      end)
    end
  rescue
    _ ->
      assign(socket,
        subtasks_on?: false,
        parent_options: [],
        parent_task: nil,
        subtasks: [],
        subtask_counts: %{},
        can_delete_task?: false,
        subtask_total: 0
      )
  end

  # The form's Delete: shown to whoever may delete this task, and the
  # question names how many subtasks go with it.
  defp assign_delete(socket, rows) do
    case socket.assigns[:assignment] do
      %Assignment{uuid: uuid} = a when is_binary(uuid) ->
        assign(socket,
          can_delete_task?: socket.assigns[:live_action] == :edit and can_delete?(socket, a),
          subtask_total: rows |> Outline.descendants(uuid) |> length()
        )

      _ ->
        assign(socket, can_delete_task?: false, subtask_total: 0)
    end
  rescue
    _ -> assign(socket, can_delete_task?: false, subtask_total: 0)
  end

  defp place_under_parent(socket, %Assignment{} = record) do
    with parent when is_binary(parent) and parent != "" <- socket.assigns[:parent_task],
         true <- socket.assigns[:subtasks_on?] == true do
      Outline.move(record, parent, :last)
    end

    :ok
  rescue
    _ -> :ok
  end

  # The "Sits under" select changed on a task being edited: moved at once
  # (with its branch), not on the autosave — where a task sits is not a
  # field of the row, it is its place in the list.
  defp maybe_move(socket, %{"parent_task" => choice}) when is_binary(choice) do
    parent = if choice == "", do: nil, else: choice

    case socket.assigns do
      %{
        live_action: :edit,
        assignment: %Assignment{} = a,
        parent_task: current,
        subtasks_on?: true
      }
      when current != parent ->
        if WriteGate.allowed?(socket),
          do: move_to(socket, a, parent),
          else: WriteGate.refuse(socket)

      %{live_action: :new} ->
        assign(socket, parent_task: parent)

      _ ->
        socket
    end
  end

  defp maybe_move(socket, _params), do: socket

  defp move_to(socket, a, parent) do
    case Outline.move(a, parent, :last) do
      {:ok, moved} ->
        log_subtask_act(socket, "projects.assignment_moved", a.uuid, %{"parent" => parent})

        socket
        |> assign(assignment: %{a | parent_uuid: moved.parent_uuid})
        |> assign_outline(%{})

      {:error, _} ->
        log_subtask_act(socket, "projects.assignment_moved", a.uuid, %{}, :failed)
        put_flash(socket, :error, gettext("The task could not be moved there."))
    end
  end

  defp log_subtask_act(socket, action, uuid, metadata, outcome \\ :ok) do
    opts = [
      actor_uuid: Activity.actor_uuid(socket),
      resource_type: "assignment",
      resource_uuid: uuid,
      metadata: Map.put(metadata, "project_uuid", socket.assigns.project.uuid)
    ]

    if outcome == :ok, do: Activity.log(action, opts), else: Activity.log_failed(action, opts)
  rescue
    _ -> :ok
  end

  defp can_delete?(socket, %Assignment{} = a) do
    PhoenixKitProjects.Authz.can?(
      socket.assigns[:phoenix_kit_current_scope],
      socket.assigns.project,
      :delete_tasks,
      a
    )
  end

  defp delete_question(0),
    do: gettext("Delete this task? This cannot be undone.")

  defp delete_question(n),
    do:
      ngettext(
        "Delete this task and its subtask? This cannot be undone.",
        "Delete this task and its %{count} subtasks? This cannot be undone.",
        n
      )

  @doc false
  # The events that write. `log_time` keeps its own `:log_time` check (it
  # is reachable by a role that may log time on a task it may not edit).
  def write_events do
    ~w(save delete_task subtask_add subtask_toggle add_assignment_dep remove_assignment_dep
       toggle_board_published toggle_portal_public generate_default_statuses save_subproject
       staff_create_confirm remove_task_file)
  end

  @doc false
  # What opening this form needed (`permitted_project/3`): the project's
  # `:create_tasks` for a new task, `:edit_tasks` to edit one, the projects
  # module for a template — asked of the live scope and of the project as
  # stored NOW, so a stale assign cannot widen it (`Web.WriteGate`, and the
  # autosave timer below).
  def write_allowed?(socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]

    with %Project{uuid: uuid} when is_binary(uuid) <- socket.assigns[:project],
         %Project{} = project <- Projects.get_project(uuid) do
      if project.is_template do
        PhoenixKitProjects.Authz.can_use_templates?(scope)
      else
        action = if socket.assigns[:live_action] == :new, do: :create_tasks, else: :edit_tasks

        PhoenixKitProjects.Authz.can?(scope, project, action) and
          PhoenixKitProjects.Extensions.enabled?(project, "tasks")
      end
    else
      _ -> false
    end
  end

  @doc false
  # The AI-translate modal's events need the same (`Web.AITranslateGate`).
  def ai_translate_allowed?(socket), do: write_allowed?(socket)

  defp may?(socket, action) do
    PhoenixKitProjects.Authz.can?(
      socket.assigns[:phoenix_kit_current_scope],
      socket.assigns.project,
      action
    )
  end

  @doc false
  def completion_options do
    [
      {gettext("When the last task is done"), "auto"},
      {gettext("Only when someone ends it — ongoing work"), "manual"}
    ]
  end

  # `completion` from the form into the project's settings, keeping every
  # other key the project already holds.
  defp fold_completion(attrs, %{"completion" => mode}, source) when mode in ["auto", "manual"] do
    base = (source && source.settings) || %{}
    Map.put(attrs, "settings", Map.put(base, "completion", mode))
  end

  defp fold_completion(attrs, _params, _source), do: attrs

  # The base struct the sub-project form edits (a fresh `%Project{}` on :new,
  # the embedded child on :edit). Read off the form's changeset data.
  defp sp_source(socket), do: socket.assigns.sp_form.source.data

  # The sub-project's name and description per language (its words block):
  # what a secondary tab posted folded into the translations typed so far,
  # the primary columns kept when that tab does not render them.
  defp sp_translations(attrs, socket) do
    in_flight = WebHelpers.in_flight_record(socket, :sp_form, :nothing) || sp_source(socket)
    WebHelpers.merge_translations_attrs(attrs, in_flight, Project.translatable_fields())
  end

  defp save_new_subproject(socket, attrs) do
    case Projects.create_subproject(socket.assigns.project.uuid, attrs) do
      {:ok, %{child_project: child, assignment: link}} ->
        Activity.log("projects.subproject_created",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "assignment",
          resource_uuid: link.uuid,
          metadata: %{"name" => child.name, "child_project_uuid" => child.uuid}
        )

        flush_pending_deps(socket, link)
        sync_mentions(socket, child)

        {:noreply,
         socket
         |> put_flash(:info, gettext("Sub-project added."))
         |> WebHelpers.navigate_after_save(Paths.project(socket.assigns.project.uuid),
           kind: :assignment,
           record: link,
           action: :create
         )}

      {:error, %Ecto.Changeset{} = cs} ->
        log_subproject_save_failed(socket, "projects.subproject_created")
        {:noreply, assign(socket, sp_form: to_form(cs, as: :subproject))}

      {:error, _other} ->
        log_subproject_save_failed(socket, "projects.subproject_created")
        {:noreply, put_flash(socket, :error, gettext("Could not add sub-project."))}
    end
  end

  # What a `#` in this form offers: the project's own records and its
  # sub-projects' (`ResourceLinks.search_resources/2` narrows by it).
  defp mention_context(%{uuid: uuid}) when is_binary(uuid), do: Jason.encode!(%{project: uuid})
  defp mention_context(_), do: nil

  # Indexes the @ and # mentions in a saved description and delivers the
  # pings. Deliberately on the DURABLE save rather than on change: `sync`
  # returns only what is new, and notifying from a debounce would ping on
  # every pause in typing.
  #
  # Never allowed to fail the save. A mention that doesn't index is a
  # missing backlink; a save that rolls back because of one is lost work.
  # The same, for a TASK's description: indexed under `project_task` (the
  # type `ResourceLinks` resolves an assignment as), so a task whose text
  # says "from this meeting" is listed on the meeting — and so a `#` in a
  # task is a backlink at all, which it was not before V8 of the CRM asked.
  defp sync_task_mentions(socket, assignment_uuid, description) when is_binary(description) do
    # As it was stored: a `#ACME-42` in the submitted text is a token there.
    description = RefText.expand(description)

    case Mentions.sync("project_task", assignment_uuid, description,
           field: "description",
           actor_uuid: Activity.actor_uuid(socket)
         ) do
      {:ok, new} ->
        Mentions.notify(new,
          source_type: "project_task",
          source_uuid: assignment_uuid,
          preview: description
        )

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp sync_task_mentions(_socket, _uuid, _description), do: :ok

  defp sync_mentions(socket, %{uuid: uuid, description: description}) do
    case Mentions.sync("project", uuid, description,
           field: "description",
           actor_uuid: Activity.actor_uuid(socket)
         ) do
      {:ok, new} ->
        Mentions.notify(new,
          source_type: "project",
          source_uuid: uuid,
          preview: description
        )

      _ ->
        :ok
    end
  end

  # Error-branch audit row for the sub-project save paths — the module
  # convention is that even a validation failure leaves a trace of the
  # attempted action (see project_form_live's save handlers).
  defp log_subproject_save_failed(socket, action) do
    Activity.log_failed(action,
      actor_uuid: Activity.actor_uuid(socket),
      resource_type: "project",
      metadata: %{"parent_project_uuid" => socket.assigns.project.uuid}
    )
  end

  defp save_edit_subproject(socket, attrs) do
    # A sub-project is a project: a started one's status source is frozen, so
    # strip it from the attrs (the picker is also locked in the form).
    attrs = Statuses.lock_status_source(attrs, sp_source(socket))

    case Projects.update_project(sp_source(socket), attrs) do
      {:ok, updated} ->
        changes = PhoenixKitProjects.Changes.project(sp_source(socket), updated)

        Activity.log("projects.project_updated",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "project",
          resource_uuid: updated.uuid,
          metadata: with_changes(%{"name" => updated.name}, changes)
        )

        # Re-sync the linking row's denormalized rollup; climbs to this project.
        Projects.recompute_project_completion(updated.uuid)

        {:noreply,
         socket
         |> put_flash(:info, gettext("Sub-project updated."))
         |> WebHelpers.navigate_after_save(Paths.project(socket.assigns.project.uuid),
           kind: :assignment,
           record: socket.assigns.assignment,
           action: :update
         )}

      {:error, %Ecto.Changeset{} = cs} ->
        log_subproject_save_failed(socket, "projects.project_updated")
        {:noreply, assign(socket, sp_form: to_form(cs, as: :subproject))}
    end
  end

  # A task was created. Plain Add hands over to the host / navigates;
  # "Add & next" tells the host the record exists (`close: false` — the
  # frame stays and the page behind refreshes its list) and resets this
  # form for the next task, clean and focused.
  defp after_create(socket, record) do
    project = socket.assigns.project
    place_under_parent(socket, record)

    if socket.assigns.task_mode == "existing" and is_binary(record.task_uuid) do
      LibrarySearch.remember(Activity.actor_uuid(socket), [record.task_uuid])
    end

    if socket.assigns.add_next? do
      socket
      |> then(fn s ->
        if s.assigns.embed_mode == :emit do
          WebHelpers.navigate_after_save(s, Paths.project(project.uuid),
            kind: :assignment,
            record: record,
            action: :create,
            close: false
          )
        else
          s
        end
      end)
      |> reset_for_next()
    else
      WebHelpers.navigate_after_save(socket, Paths.project(project.uuid),
        kind: :assignment,
        record: record,
        action: :create
      )
    end
  end

  # The same mount as a fresh :new page, keeping what the user chose for
  # the run (library tab or Create new, the "add to library" box), then
  # clean again: the host may close on Esc, and the re-keyed title
  # wrapper mounts and refocuses.
  defp reset_for_next(socket) do
    %{project: project, kind: kind, task_mode: task_mode, add_to_library: to_library} =
      socket.assigns

    socket
    |> apply_action(:new, %{"project_id" => project.uuid, "kind" => kind})
    |> assign_fx()
    |> assign_ai_translate()
    |> assign(
      task_mode: task_mode,
      add_to_library: to_library,
      dirty?: false,
      form_seq: socket.assigns.form_seq + 1,
      form_pane: "task"
    )
    |> WebHelpers.notify_dirty(false)
    |> WebHelpers.keep_host_title()
  end

  defp merge_attrs(attrs, socket) do
    in_flight = WebHelpers.in_flight_record(socket, :form, :assignment)
    WebHelpers.merge_translations_attrs(attrs, in_flight, Assignment.translatable_fields())
  end

  # `@task_form` is always a changeset-backed form (mounted with one), so
  # the in-flight record is the applied changeset — no fallback needed.
  defp merge_task_attrs(attrs, socket) do
    in_flight = Ecto.Changeset.apply_changes(socket.assigns.task_form.source)
    WebHelpers.merge_translations_attrs(attrs, in_flight, Task.translatable_fields())
  end

  defp save_with_new_task(socket, attrs, params) do
    task_form =
      case Map.get(params, "task") do
        %{} = task_params -> new_task_form(merge_task_attrs(task_params, socket))
        _ -> socket.assigns.task_form
      end

    socket = assign(socket, task_form: task_form)
    task = Ecto.Changeset.apply_changes(task_form.source)

    case String.trim(task.title || "") do
      "" ->
        {:noreply,
         socket
         |> assign(:form_pane, "task")
         |> put_flash(:error, gettext("Task title is required."))}

      title ->
        create_task_and_assign(socket, attrs, title, task.translations || %{})
    end
  end

  # Library task + assignment in ONE transaction
  # (`Projects.create_task_with_assignment/3`) — the same write the
  # quick-add composer uses, here with the form's full attrs and a
  # reusable (not one-off) task. Nothing is broadcast or logged before
  # the commit; on failure neither row exists.
  defp create_task_and_assign(socket, attrs, title, title_translations) do
    project = socket.assigns.project

    # "Add to the task library" (off by default — a one-off task, `ad_hoc`,
    # V15, exactly what the quick-add composer creates; ticked = reusable
    # from the library). The task's translations combine the title's own
    # (typed under the language tabs) with the description's, which the
    # assignment form collected under `assignment[translations]`.
    task_attrs =
      %{
        "title" => title,
        "description" => attrs["description"],
        "translations" => task_translations(title_translations, attrs["translations"]),
        "estimated_duration" => attrs["estimated_duration"],
        "estimated_duration_unit" => attrs["estimated_duration_unit"],
        # Feeding the shared library is `projects.manage_library`'s, whatever
        # the (possibly forged) checkbox says.
        "ad_hoc" =>
          not (socket.assigns.add_to_library and
                 Authz.manage_library?(socket.assigns[:phoenix_kit_current_scope]))
      }
      |> maybe_add_default_assignee(attrs)

    case Projects.create_task_with_assignment(project.uuid, task_attrs, attrs) do
      {:ok, %{assignment: assignment}} ->
        {:ok, _} =
          Projects.stamp_assignment(assignment, %{created_by_uuid: Activity.actor_uuid(socket)})

        apply_pending_labels(socket, assignment)

        {flash_kind, flash_msg} =
          flash_for_template_deps(
            assignment,
            gettext("Task created and added to project.")
          )

        Activity.log("projects.assignment_created",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "assignment",
          resource_uuid: assignment.uuid,
          target_uuid: Activity.assignee_target_uuid(assignment),
          metadata: %{"project" => project.name, "new_task" => title}
        )

        flush_pending_deps(socket, assignment)
        sync_task_mentions(socket, assignment.uuid, task_attrs["description"])

        {:noreply, socket |> put_flash(flash_kind, flash_msg) |> after_create(assignment)}

      {:error, :task, _cs} ->
        Activity.log_failed("projects.task_created",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "task",
          metadata: %{"project_uuid" => project.uuid}
        )

        {:noreply, put_flash(socket, :error, gettext("Could not create task."))}

      {:error, :assignment, cs} ->
        {:noreply, on_save_error(socket, cs)}

      {:error, :project, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Project not found."))
         |> WebHelpers.close_or_navigate(Paths.projects())}
    end
  end

  # `%{lang => %{"title" => …}}` from the title form merged with the
  # description translations `%{lang => %{"description" => …}}`; empty
  # languages dropped so the JSONB holds only real overrides.
  defp task_translations(title_tr, description_tr) do
    title_tr = if is_map(title_tr), do: title_tr, else: %{}
    description_tr = if is_map(description_tr), do: description_tr, else: %{}

    Map.merge(
      Map.new(title_tr, fn {lang, fields} -> {lang, Map.take(fields || %{}, ["title"])} end),
      Map.new(description_tr, fn {lang, fields} ->
        {lang, Map.take(fields || %{}, ["description"])}
      end),
      fn _lang, a, b -> Map.merge(a, b) end
    )
    |> Enum.reject(fn {_lang, fields} -> fields == %{} end)
    |> Map.new()
  end

  # A library task keeps one default assignee: the task's when it has
  # exactly one (V29: several stay with this task only).
  defp maybe_add_default_assignee(task_attrs, %{"assignees" => list} = attrs) do
    case PhoenixKitProjects.AssigneeSet.normalize(list) do
      {:ok, [{kind, uuid}]} ->
        Map.put(task_attrs, "default_assigned_#{kind}_uuid", uuid)

      _ ->
        maybe_add_default_assignee(task_attrs, Map.delete(attrs, "assignees"))
    end
  end

  defp maybe_add_default_assignee(task_attrs, attrs) do
    cond do
      attrs["assigned_team_uuid"] && attrs["assigned_team_uuid"] != "" ->
        Map.put(task_attrs, "default_assigned_team_uuid", attrs["assigned_team_uuid"])

      attrs["assigned_department_uuid"] && attrs["assigned_department_uuid"] != "" ->
        Map.put(task_attrs, "default_assigned_department_uuid", attrs["assigned_department_uuid"])

      attrs["assigned_person_uuid"] && attrs["assigned_person_uuid"] != "" ->
        Map.put(task_attrs, "default_assigned_person_uuid", attrs["assigned_person_uuid"])

      true ->
        task_attrs
    end
  end

  defp save_new(socket, attrs) do
    attrs = Map.put(attrs, "project_uuid", socket.assigns.project.uuid)

    # Route through the closure-aware path when the picked task has at
    # least one ticked, not-already-in-project descendant. Otherwise the
    # closure path adds zero-value transactional overhead — fall back to
    # the simple `create_assignment/1` write.
    if closure_pull_needed?(socket) do
      save_new_with_closure(socket, attrs)
    else
      save_new_simple(socket, attrs)
    end
  end

  defp closure_pull_needed?(socket) do
    case socket.assigns.closure_tree do
      nil ->
        false

      tree ->
        # Use the cascade-expanded set so unticking a parent (which
        # also disables descendants) correctly drops the closure-pull
        # path back to the simple-insert one when nothing's left.
        effective_excluded =
          expand_excluded_closure(tree, socket.assigns.excluded_closure_uuids)

        Enum.any?(tree.children, fn child ->
          closure_branch_yields_inserts?(child, effective_excluded)
        end)
    end
  end

  defp closure_branch_yields_inserts?(node, excluded) do
    cond do
      MapSet.member?(excluded, node.task.uuid) ->
        # Self excluded — skip self. Children are also excluded by the
        # cascade so nothing in this subtree yields an insert.
        false

      not node.already_in_project? ->
        true

      true ->
        Enum.any?(node.children, &closure_branch_yields_inserts?(&1, excluded))
    end
  end

  # Expands the user's per-node clicks into the full effective set:
  # every descendant of an excluded ancestor is also excluded. The
  # user-only set lives in socket state so re-ticking an ancestor
  # un-cascades; this helper is the projection used at render + save.
  defp expand_excluded_closure(tree, user_excluded) do
    do_expand_excluded(tree, user_excluded, false, MapSet.new())
  end

  defp do_expand_excluded(%{cycle?: true}, _user_excluded, _ancestor_excluded?, acc), do: acc

  defp do_expand_excluded(
         %{task: task, children: children},
         user_excluded,
         ancestor_excluded?,
         acc
       ) do
    self_excluded? = MapSet.member?(user_excluded, task.uuid)
    effective_excluded? = ancestor_excluded? or self_excluded?
    acc = if effective_excluded?, do: MapSet.put(acc, task.uuid), else: acc

    Enum.reduce(children, acc, fn child, a ->
      do_expand_excluded(child, user_excluded, effective_excluded?, a)
    end)
  end

  defp save_new_with_closure(socket, attrs) do
    task_uuid = socket.assigns.closure_tree.task.uuid

    # Expand the user's explicit clicks into the full effective set:
    # every descendant of an unticked ancestor is also excluded. The
    # `excluded_closure_uuids` socket assign stays minimal (only
    # user-clicked uuids) so re-ticking an ancestor can un-cascade.
    effective_excluded =
      expand_excluded_closure(socket.assigns.closure_tree, socket.assigns.excluded_closure_uuids)

    case Projects.create_assignments_with_closure(
           task_uuid,
           socket.assigns.project.uuid,
           attrs,
           excluded_task_uuids: effective_excluded
         ) do
      {:ok, %{root: root, extras: extras}} ->
        apply_pending_labels(socket, root)

        Activity.log("projects.assignment_created",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "assignment",
          resource_uuid: root.uuid,
          target_uuid: Activity.assignee_target_uuid(root),
          metadata: %{
            "project" => socket.assigns.project.name,
            "closure_extras" => length(extras)
          }
        )

        Enum.each(extras, fn extra ->
          Activity.log("projects.assignment_created",
            actor_uuid: Activity.actor_uuid(socket),
            resource_type: "assignment",
            resource_uuid: extra.uuid,
            metadata: %{
              "project" => socket.assigns.project.name,
              "via_closure_of" => task_uuid
            }
          )
        end)

        flush_pending_deps(socket, root)

        msg =
          case length(extras) do
            0 -> gettext("Task added to project.")
            n -> gettext("Task added with %{count} dependent task(s).", count: n)
          end

        {:noreply, socket |> put_flash(:info, msg) |> after_create(root)}

      {:error, %Ecto.Changeset{} = cs} ->
        Activity.log_failed("projects.assignment_created",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "assignment",
          metadata: %{
            "project" => socket.assigns.project.name,
            "project_uuid" => socket.assigns.project.uuid,
            "via_closure_of" => task_uuid
          }
        )

        {:noreply, on_save_error(socket, cs)}

      {:error, reason} ->
        Logger.warning(
          "[Projects] closure-create rolled back for task #{task_uuid}: #{inspect(reason)}"
        )

        Activity.log_failed("projects.assignment_created",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "assignment",
          metadata: %{
            "project" => socket.assigns.project.name,
            "project_uuid" => socket.assigns.project.uuid,
            "via_closure_of" => task_uuid,
            "reason" => inspect(reason)
          }
        )

        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Could not create the task and its dependencies. Please try again.")
         )}
    end
  end

  defp save_new_simple(socket, attrs) do
    case Projects.create_assignment(attrs) do
      {:ok, assignment} ->
        apply_pending_labels(socket, assignment)

        {flash_kind, flash_msg} =
          flash_for_template_deps(
            assignment,
            gettext("Task added to project.")
          )

        Activity.log("projects.assignment_created",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "assignment",
          resource_uuid: assignment.uuid,
          metadata: %{"project" => socket.assigns.project.name}
        )

        flush_pending_deps(socket, assignment)

        {:noreply, socket |> put_flash(flash_kind, flash_msg) |> after_create(assignment)}

      {:error, cs} ->
        Activity.log_failed("projects.assignment_created",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "assignment",
          metadata: %{
            "project" => socket.assigns.project.name,
            "project_uuid" => socket.assigns.project.uuid
          }
        )

        {:noreply, on_save_error(socket, cs)}
    end
  end

  # Flushes the user's pending-dep selections to real Dependency rows
  # now that the new assignment has a uuid. Called from `save_new` and
  # `create_assignment_for_new_task`. Per-dep failures are logged and
  # audited but do not block the navigate-to-project — the assignment
  # is the load-bearing record; deps are reattachable from the
  # project-show page if any failed (and we'd notice the audit-log
  # `_failed` row).
  defp flush_pending_deps(socket, %Assignment{} = assignment) do
    Enum.each(socket.assigns.pending_dep_uuids, fn dep_uuid ->
      case Projects.add_dependency(assignment.uuid, dep_uuid) do
        {:ok, _} ->
          Activity.log("projects.dependency_added",
            actor_uuid: Activity.actor_uuid(socket),
            resource_type: "assignment",
            resource_uuid: assignment.uuid,
            metadata: %{"source" => "assignment_form_pending", "depends_on_uuid" => dep_uuid}
          )

        {:error, reason} ->
          Logger.warning(
            "[Projects] pending dep flush failed for assignment #{assignment.uuid} → #{dep_uuid}: " <>
              inspect(reason)
          )

          Activity.log_failed("projects.dependency_added",
            actor_uuid: Activity.actor_uuid(socket),
            resource_type: "assignment",
            resource_uuid: assignment.uuid,
            metadata: %{"source" => "assignment_form_pending", "depends_on_uuid" => dep_uuid}
          )
      end
    end)
  end

  # The description a one-off task's row shows when the assignment carries
  # none of its own: the task's (`token_home/1` in `Projects` reads the
  # same way). Returns the record to edit and whether the words live on
  # the task.
  defp own_description(%Assignment{description: d, task: %Task{ad_hoc: true} = task} = a)
       when d in [nil, ""] do
    own = description_translations(a.translations)

    if own == %{} do
      shown = Map.merge(a.translations, description_translations(task.translations))
      {%{a | description: task.description, translations: shown}, true}
    else
      {a, false}
    end
  end

  defp own_description(%Assignment{} = a), do: {a, false}

  defp description_translations(translations) when is_map(translations) do
    for {lang, %{"description" => text}} <- translations, text not in [nil, ""], into: %{} do
      {lang, %{"description" => text}}
    end
  end

  defp description_translations(_translations), do: %{}

  # When the words live on the task, the assignment's save leaves them out
  # and `save_task_words/2` writes them to the task instead.
  defp put_save_flash(socket, :ok), do: put_flash(socket, :info, gettext("Assignment updated."))

  defp put_save_flash(socket, :error),
    do:
      put_flash(
        socket,
        :warning,
        gettext("Task updated, but its description could not be saved.")
      )

  # Only words the person changed are written: an untouched box must not
  # put the text it was opened with over a newer one from the API.
  defp split_task_words(socket, attrs) do
    if socket.assigns[:desc_on_task?] do
      shown = socket.assigns.assignment
      words = Map.take(attrs, ["description", "translations"])

      changed? =
        (Map.has_key?(words, "description") and
           (words["description"] || "") != (shown.description || "")) or
          description_translations(words["translations"]) !=
            description_translations(shown.translations)

      {Map.drop(attrs, ["description", "translations"]), if(changed?, do: words)}
    else
      {attrs, nil}
    end
  end

  defp save_task_words(_updated, nil), do: :ok

  defp save_task_words(%Assignment{task_uuid: task_uuid}, words) do
    case Projects.get_task(task_uuid) do
      %Task{} = task -> write_task_words(task, words)
      _ -> :error
    end
  end

  defp write_task_words(%Task{} = task, words) do
    translations =
      Map.merge(
        task.translations,
        description_translations(words["translations"]),
        fn _lang, old, new -> Map.merge(old, new) end
      )

    content = words |> Map.take(["description"]) |> Map.put("translations", translations)

    case Projects.update_task(task, content) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[Projects] a one-off task's description was not saved: #{inspect(reason)}"
        )

        :error
    end
  end

  # Apply template-level default dependencies and return a flash tuple
  # describing what to show the user. A rollback in
  # `Projects.apply_template_dependencies/1` is *not* fatal — the
  # assignment itself was created successfully — but the user expected
  # default deps to land, so we surface a warning instead of the
  # success message.
  defp flash_for_template_deps(assignment, success_msg) do
    case Projects.apply_template_dependencies(assignment) do
      :ok ->
        {:info, success_msg}

      {:ok, _} ->
        {:info, success_msg}

      {:error, reason} ->
        Logger.warning(
          "[Projects] apply_template_dependencies/1 rolled back for assignment " <>
            "#{assignment.uuid}: #{inspect(reason)}"
        )

        {:warning,
         gettext(
           "Task added to project, but applying default dependencies from the template failed."
         )}
    end
  end

  # ── Saving a task being edited ──
  #
  # The form's latest params wait in `pending_params` and go through
  # `autosave_now/1` when Save is pressed (it was a timer after every
  # change until the boss, 2026-11-02: one save style for every popup).
  # Logging time, dependencies, subtasks, files and the portal switches
  # still write at once — they are records of their own.

  # The description editors (Leaf): their text into the form being shown —
  # the task's (held until Save) or the sub-project's.
  @impl true
  def handle_info({:leaf_changed, _} = msg, socket) do
    case DescriptionEditor.changed(msg) do
      {"assignment-description", lang, markdown} ->
        {:noreply, put_description(socket, lang, markdown)}

      {"subproject-description", lang, markdown} ->
        {:noreply, put_sp_description(socket, lang, markdown)}

      _ ->
        {:noreply, socket}
    end
  end

  # The editor's own image button: opens the description picture upload's
  # file chooser (`DescriptionImages.pick/1`).
  def handle_info(
        {:leaf_insert_request, %{editor_id: "assignment-description--" <> _, type: :image}},
        socket
      ),
      do: {:noreply, DescriptionImages.pick(socket)}

  # The same for a sub-project's description (its own folder).
  def handle_info(
        {:leaf_insert_request, %{editor_id: "subproject-description--" <> _, type: :image}},
        socket
      ),
      do: {:noreply, DescriptionImages.pick(socket)}

  # An image pasted into the task's description: stored as the task's file
  # (`inline`) and placed at the cursor by its address — never kept in the
  # text as a `data:` URL.
  def handle_info(
        {:leaf_paste_image, %{editor_id: "assignment-description--" <> _ = id} = paste},
        socket
      ) do
    {:noreply, store_pasted_image(socket, id, paste)}
  end

  # An image pasted into a sub-project's description: kept in the
  # sub-project's own folder (it is a project) and placed at the cursor.
  def handle_info(
        {:leaf_paste_image, %{editor_id: "subproject-description--" <> _ = id} = paste},
        socket
      ) do
    target =
      case sp_source(socket) do
        %Project{uuid: uuid} = sub when is_binary(uuid) -> {sub, id}
        _ -> nil
      end

    {:noreply, DescriptionImages.paste_for(socket, target, id, paste)}
  end

  # `@` and `#` typed in a description: the mentions the textarea offered.
  def handle_info({:leaf_suggest, _} = msg, socket) do
    context = DescriptionEditor.decode_context(mention_context(socket.assigns[:project]))
    {:noreply, DescriptionEditor.suggest(socket, msg, context)}
  end

  def handle_info(message, socket) do
    Logger.debug("[AssignmentFormLive] unexpected handle_info: #{inspect(message)}")
    {:noreply, socket}
  end

  # Held until Save (the boss, 2026-11-02): no timer any more, the form's
  # latest params wait for the Save button.
  defp schedule_autosave(%{assigns: %{live_action: :edit, kind: "task"}} = socket, params) do
    assign(socket, pending_params: params, save_state: :idle)
  end

  defp schedule_autosave(socket, _params), do: socket

  defp cancel_autosave(socket) do
    if timer = socket.assigns[:autosave_timer], do: Process.cancel_timer(timer)
    assign(socket, :autosave_timer, nil)
  end

  # Saves what the form last sent, through the same steps a submit took
  # (gates re-read, the other assignee kinds cleared, translations merged,
  # the checklist folded), and stays where it is.
  defp autosave_now(%{assigns: %{pending_params: %{"assignment" => attrs} = params}} = socket) do
    assign_type = Map.get(params, "assign_type", socket.assigns.assign_type)
    fx = Features.gates(socket.assigns.project)

    # The right to hand the task out is asked again too, like the gates: a
    # manager made a member since the form opened no longer reassigns.
    socket =
      assign(socket,
        fx: fx,
        pending_labels: pending_labels(fx, params),
        can_assign?: can_assign?(socket)
      )

    attrs =
      attrs
      |> form_attrs(socket)
      |> clear_other_assignees(assign_type)
      |> strip_gated_attrs(fx)
      |> strip_unassignable(socket)
      |> merge_attrs(socket)

    {attrs, task_words} = split_task_words(socket, attrs)
    title_pair = title_pair(socket)

    case Projects.update_assignment_form(socket.assigns.assignment, attrs) do
      {:ok, updated} ->
        words_saved = save_task_words(updated, task_words)
        title_saved = save_edit_title(socket, updated)
        changes = edit_changes(socket.assigns.assignment, updated, title_pair, task_words)

        # The words become the person's only when the person changed them:
        # a form that saves on every change must not take a task's text
        # from the agent that wrote it because its priority was touched.
        if words_changed?(socket, attrs, task_words) do
          _ = Projects.stamp_assignment(updated, %{words_by_key_uuid: nil})

          sync_task_mentions(
            socket,
            updated.uuid,
            attrs["description"] || (task_words && task_words["description"])
          )
        end

        apply_pending_labels(socket, updated)
        told? = log_typed_changes(socket, socket.assigns.assignment, updated)
        times = save_times(socket, updated)

        socket
        |> log_edit_once(updated, told?, changes)
        |> hold_saved(updated)
        |> hold_saved_title(title_saved)
        |> hold_saved_times(times)
        |> assign(
          pending_params: nil,
          save_state: if(words_saved == :ok, do: :saved, else: :error),
          save_error:
            if(words_saved == :ok, do: nil, else: gettext("The description could not be saved.")),
          dirty?: title_saved != :ok
        )
        |> part_error(title_saved)
        |> part_error(times)
        |> WebHelpers.notify_dirty(title_saved != :ok)

      {:error, %Ecto.Changeset{} = cs} ->
        socket
        |> assign_form(Map.put(cs, :action, :validate))
        |> assign(save_state: :error, save_error: first_error_message(cs))
        |> show_error_pane()
    end
  rescue
    e ->
      Logger.error("[Projects] a task's form could not be saved: #{Exception.message(e)}")
      assign(socket, save_state: :error, save_error: gettext("Could not save. Try again."))
  end

  defp autosave_now(socket), do: socket

  defp words_changed?(socket, attrs, task_words) do
    shown = socket.assigns.assignment

    not is_nil(task_words) or
      (Map.has_key?(attrs, "description") and
         (attrs["description"] || "") != (shown.description || "")) or
      title_change(socket) != :same
  end

  # The record the next change is compared with: the task as it is now
  # saved, in the form's own shape (its own description shown, short refs).
  defp hold_saved(socket, %Assignment{uuid: uuid} = updated) do
    {record, desc_on_task?} = own_description(Projects.get_assignment(uuid) || updated)

    assign(socket,
      assignment: RefText.collapse_fields(record, [:description]),
      desc_on_task?: desc_on_task?
    )
  end

  # The title as now saved: what the next change is compared with. A
  # refused rename keeps the box as typed, with the task's error on it.
  defp hold_saved_title(socket, {:error, %Ecto.Changeset{} = cs}),
    do: assign(socket, :task_form, to_form(Map.put(cs, :action, :validate), as: :task))

  defp hold_saved_title(socket, _result), do: hold_saved_title(socket)

  defp hold_saved_title(%{assigns: %{title_editable?: true}} = socket) do
    case socket.assigns.assignment do
      %Assignment{task: %Task{} = task} ->
        assign(socket,
          title_task: task,
          task_form: to_form(Projects.change_task(task, %{}), as: :task),
          edit_title: task.title
        )

      _ ->
        socket
    end
  end

  defp hold_saved_title(socket), do: socket

  # Corrected times that did not save keep their box and its error; else
  # the boxes show the row as it now is.
  defp hold_saved_times(socket, {:error, %Ecto.Changeset{} = cs}),
    do: assign(socket, :times_form, to_form(Map.put(cs, :action, :validate), as: :times))

  defp hold_saved_times(socket, _result), do: assign_times_form(socket)

  # A part saved after the row's own save (the title, the corrected times)
  # that failed: the bar says so and the tab holding it opens.
  defp part_error(socket, {:error, %Ecto.Changeset{} = cs}) do
    socket
    |> assign(save_state: :error, save_error: first_error_message(cs))
    |> show_error_pane()
  end

  defp part_error(socket, _result), do: socket

  # A status or a waiting-on changed through the form is its own line in the
  # project's history (the page's buttons log theirs the same way); the
  # generic "updated" row above says only that the form was used.
  defp log_typed_changes(socket, %Assignment{} = was, %Assignment{} = now) do
    base = [
      actor_uuid: Activity.actor_uuid(socket),
      resource_type: "assignment",
      resource_uuid: now.uuid
    ]

    meta = %{"project" => socket.assigns.project.name, "project_uuid" => now.project_uuid}

    status_action =
      cond do
        was.status == now.status -> nil
        now.status == "done" -> "projects.assignment_completed"
        was.status == "done" -> "projects.assignment_reopened"
        now.status == "in_progress" -> "projects.assignment_started"
        true -> "projects.assignment_reopened"
      end

    reassigned? = PhoenixKitProjects.Notices.reassigned(was, now, Activity.actor_uuid(socket))

    # Handed on in the same save: the new people hear "gave you a task", not
    # also that it started.
    cond do
      # Waiting <-> can be started is readiness, not a reopen: logged as the
      # page's and the API's buttons log it, naming nobody (`Handoffs` tells
      # the people a released task is theirs).
      readiness_action(was.status, now.status) ->
        Activity.log(
          readiness_action(was.status, now.status),
          base ++
            [
              tell: false,
              metadata: Map.merge(meta, %{"from" => was.status, "to" => now.status})
            ]
        )

      status_action ->
        Activity.log(
          status_action,
          base ++
            [
              target_uuid: if(not reassigned?, do: Activity.assignee_target_uuid(now)),
              tell: not reassigned?,
              metadata: meta
            ]
        )

      true ->
        :ok
    end

    if blank_waiting(was.waiting_on) != blank_waiting(now.waiting_on) do
      Activity.log(
        "projects.assignment_waiting",
        base ++ [metadata: Map.put(meta, "waiting_on", blank_waiting(now.waiting_on))]
      )
    end

    # Whether the people were told of this save already: the generic
    # "changed your task" row then tells nobody.
    status_action != nil or reassigned?
  end

  defp log_typed_changes(_socket, _was, _now), do: false

  defp readiness_action("waiting", "todo"), do: "projects.assignment_made_ready"
  defp readiness_action("todo", "waiting"), do: "projects.assignment_made_idle"
  defp readiness_action(_was, _now), do: nil

  defp blank_waiting(v) when is_binary(v) do
    case String.trim(v) do
      "" -> nil
      t -> t
    end
  end

  defp blank_waiting(_), do: nil

  # Every save that changed something records what it changed (the boss,
  # 2026-10-31: a history saying only "edited" is useless); the history
  # shows one visit's saves as one line (`HistoryFeed`). A save that changed
  # nothing it records is not a line, past the visit's first.
  # The task's people hear "changed your task" once per visit — from the
  # first save that was not already news to them (a status change or a hand
  # over tells them in its own words).
  defp log_edit_once(socket, updated, told?, changes) do
    first? = socket.assigns[:edit_logged?] != true
    tell? = not told? and socket.assigns[:edit_told?] != true

    if first? or changes != [] do
      Activity.log("projects.assignment_updated",
        actor_uuid: Activity.actor_uuid(socket),
        resource_type: "assignment",
        resource_uuid: updated.uuid,
        target_uuid: if(tell?, do: Activity.assignee_target_uuid(updated)),
        tell: tell?,
        metadata: with_changes(%{"project" => socket.assigns.project.name}, changes)
      )

      assign(socket, edit_logged?: true, edit_told?: socket.assigns[:edit_told?] == true or tell?)
    else
      socket
    end
  end

  defp with_changes(meta, []), do: meta
  defp with_changes(meta, changes), do: Map.put(meta, "changes", changes)

  # The task's name before and after this save, when the form renames it
  # (read before the save: afterwards the form and the task agree).
  defp title_pair(socket) do
    case title_change(socket) do
      {:changed, title, _titles} -> {Assignment.label(socket.assigns.assignment), title}
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp edit_changes(%Assignment{} = was, %Assignment{} = now, title_pair, task_words) do
    description =
      case {task_words, was.task} do
        {%{"description" => d}, %Task{} = task} -> {task.description, d}
        _ -> nil
      end

    PhoenixKitProjects.Changes.assignment(was, now, title: title_pair, description: description)
  rescue
    _ -> []
  end

  defp save_edit(socket, attrs) do
    {attrs, task_words} = split_task_words(socket, attrs)
    title_pair = title_pair(socket)

    case Projects.update_assignment_form(socket.assigns.assignment, attrs) do
      {:ok, updated} ->
        words_saved = save_task_words(updated, task_words)
        title_saved = save_edit_title(socket, updated)
        changes = edit_changes(socket.assigns.assignment, updated, title_pair, task_words)
        # A person saved the form: the title and description are theirs
        # now, whatever key wrote them before.
        _ = Projects.stamp_assignment(updated, %{words_by_key_uuid: nil})
        apply_pending_labels(socket, updated)

        sync_task_mentions(
          socket,
          updated.uuid,
          attrs["description"] || (task_words && task_words["description"])
        )

        told? = log_typed_changes(socket, socket.assigns.assignment, updated)

        Activity.log("projects.assignment_updated",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "assignment",
          resource_uuid: updated.uuid,
          target_uuid: if(not told?, do: Activity.assignee_target_uuid(updated)),
          tell: not told?,
          metadata: with_changes(%{"project" => socket.assigns.project.name}, changes)
        )

        case title_saved do
          # The rest is saved; the form stays open on the refused title.
          {:error, %Ecto.Changeset{} = cs} ->
            {:noreply,
             socket
             |> hold_saved(updated)
             |> hold_saved_title(title_saved)
             |> part_error(title_saved)
             |> put_flash(:error, first_error_message(cs))}

          :ok ->
            {:noreply,
             socket
             |> put_save_flash(words_saved)
             |> WebHelpers.navigate_after_save(Paths.project(socket.assigns.project.uuid),
               kind: :assignment,
               record: updated,
               action: :update
             )}
        end

      {:error, cs} ->
        Activity.log_failed("projects.assignment_updated",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "assignment",
          resource_uuid: socket.assigns.assignment.uuid,
          metadata: %{"project" => socket.assigns.project.name}
        )

        {:noreply, on_save_error(socket, cs)}
    end
  end

  # Same shape as ProjectFormLive — flips back to the primary tab when
  # the save error sits on a translatable primary field. Assignment
  # only translates `:description`, but listing the field for symmetry
  # with the other forms keeps the helper's API uniform.
  defp on_save_error(socket, %Ecto.Changeset{} = cs) do
    socket
    |> assign_form(cs)
    |> WebHelpers.maybe_switch_to_primary_on_error(cs, [:description])
    |> show_error_pane()
    |> put_flash(:error, first_error_message(cs))
  end

  defp first_error_message(%Ecto.Changeset{errors: [{field, {msg, _opts}} | _]}) do
    gettext("%{field}: %{message}", field: humanize(field), message: msg)
  end

  defp first_error_message(_), do: gettext("Could not save the assignment.")

  # The fields this form added with V26 are named as their boxes are, in
  # the viewer's language; older fields keep the generic spelling.
  defp humanize(:deadline), do: gettext("Deadline")
  defp humanize(:started_at), do: gettext("Started at")
  defp humanize(:completed_at), do: gettext("Finished at")
  defp humanize(:start_time), do: gettext("Start time")
  defp humanize(:end_time), do: gettext("End time")
  defp humanize(:repeat_rule), do: gettext("Repeats")

  defp humanize(field) do
    field |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  defp do_generate_default_statuses(socket) do
    case Statuses.create_default_status_entity(actor_uuid: Activity.actor_uuid(socket)) do
      {:ok, entity} ->
        Activity.log("projects.status_entity_provisioned",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "entity",
          resource_uuid: entity.uuid,
          metadata: %{"scope" => "subproject"}
        )

        cs =
          socket.assigns.sp_form.source
          |> Ecto.Changeset.put_change(:status_entity_uuid, entity.uuid)

        {:noreply,
         socket
         |> assign(status_entities: WSF.entity_options(), sp_form: to_form(cs, as: :subproject))
         |> refresh_status_preview()
         |> put_flash(:info, gettext("Default statuses entity created."))}

      {:error, _reason} ->
        Activity.log_failed("projects.status_entity_provisioned",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "entity",
          metadata: %{"scope" => "subproject"}
        )

        {:noreply,
         put_flash(socket, :error, gettext("Could not create the default statuses entity."))}
    end
  end

  defp do_add_assignment_dep(dep_uuid, socket) do
    case Projects.add_dependency(socket.assigns.assignment.uuid, dep_uuid) do
      {:ok, _} ->
        Activity.log("projects.dependency_added",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "assignment",
          resource_uuid: socket.assigns.assignment.uuid,
          metadata: %{"depends_on_uuid" => dep_uuid}
        )

        reload_deps(socket)

      {:error, _} ->
        Activity.log_failed("projects.dependency_added",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "assignment",
          resource_uuid: socket.assigns.assignment.uuid,
          metadata: %{"depends_on_uuid" => dep_uuid}
        )

        {:noreply, put_flash(socket, :error, gettext("Could not add dependency."))}
    end
  end

  defp do_remove_assignment_dep(dep_uuid, socket) do
    case Projects.remove_dependency(socket.assigns.assignment.uuid, dep_uuid) do
      {:ok, _} ->
        Activity.log("projects.dependency_removed",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "assignment",
          resource_uuid: socket.assigns.assignment.uuid,
          metadata: %{"depends_on_uuid" => dep_uuid}
        )

        reload_deps(socket)

      {:error, _} ->
        Activity.log_failed("projects.dependency_removed",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "assignment",
          resource_uuid: socket.assigns.assignment.uuid,
          metadata: %{"depends_on_uuid" => dep_uuid}
        )

        {:noreply, put_flash(socket, :error, gettext("Could not remove dependency."))}
    end
  end

  defp do_set_sp_mode(mode, socket) do
    {:noreply, assign(socket, sp_mode: mode)}
  end

  # Server-side mate of the render gates (Step 4): a submit crafted past a
  # hidden section can't smuggle gated fields in. Assignee attrs drop when
  # `assignees` is off; duration attrs when `estimates` is off;
  # counts_weekends when `scheduling` is off.
  defp strip_gated_attrs(attrs, fx) do
    attrs
    |> then(fn a ->
      if fx.assignees,
        do: a,
        else:
          Map.drop(
            a,
            ~w(assigned_team_uuid assigned_department_uuid assigned_person_uuid assignees)
          )
    end)
    |> then(fn a ->
      if fx.estimates, do: a, else: Map.drop(a, ~w(estimated_duration estimated_duration_unit))
    end)
    |> then(fn a -> if fx.scheduling, do: a, else: Map.drop(a, ~w(counts_weekends)) end)
    |> then(fn a -> if fx.priorities, do: a, else: Map.drop(a, ~w(priority)) end)
    |> then(fn a -> if fx[:waiting] != false, do: a, else: Map.drop(a, ~w(waiting_on origin)) end)
    |> then(fn a ->
      if fx[:dates] != false,
        do: a,
        else: Map.drop(a, ~w(start_date end_date start_time end_time deadline))
    end)
  end

  # Who may not hand tasks out (`:assign_tasks`) leaves the assignee as it
  # is, whatever a forged submit says — the picker is not drawn for them.
  defp strip_unassignable(attrs, socket) do
    if socket.assigns[:can_assign?] == false,
      do:
        Map.drop(
          attrs,
          ~w(assigned_team_uuid assigned_department_uuid assigned_person_uuid assignees)
        ),
      else: attrs
  end

  # The tabs the form shows, in order; a tab with nothing in it for this
  # task is left out.
  defp form_panes(assigns) do
    [
      {"task", gettext("Task"), true},
      {"planning", gettext("Planning"), planning_pane?(assigns)},
      {"connections", gettext("Connections"), assigns.fx.dependencies},
      {"more", gettext("More"), more_pane?(assigns)}
    ]
    |> Enum.filter(&elem(&1, 2))
    |> Enum.map(fn {pane, label, _shown} -> {pane, label} end)
  end

  defp planning_pane?(%{fx: fx} = assigns) do
    template? = Map.get(assigns.project, :is_template, false) == true

    fx.estimates or fx[:dates] != false or fx.scheduling or
      (fx.labels and assigns.project_labels != []) or (assigns.subtasks_on? and not template?)
  end

  defp more_pane?(%{live_action: :edit, fx: fx} = assigns) do
    template? = Map.get(assigns.project, :is_template, false) == true

    (fx.ledger and not template?) or assigns.portal? or show_times?(assigns) or
      assigns[:can_attach?] == true
  end

  defp more_pane?(_assigns), do: false

  # The real start and finish: once there is one, or once the task is under
  # way — before that there is nothing to correct.
  defp show_times?(%{times_form: %Phoenix.HTML.Form{}, assignment: a}),
    do: a.status in ~w(in_progress done) or not is_nil(a.started_at) or not is_nil(a.completed_at)

  defp show_times?(_assigns), do: false

  # Which tab each field's error shows under; anything unlisted is the
  # first tab's.
  @pane_of %{
    estimated_duration: "planning",
    estimated_duration_unit: "planning",
    start_date: "planning",
    end_date: "planning",
    start_time: "planning",
    end_time: "planning",
    counts_weekends: "planning",
    parent_uuid: "planning"
  }

  # The tabs holding an error the form shows — a dot on each, so an error
  # on a tab that is not open is not missed.
  defp error_panes(assigns) do
    form_panes =
      case assigns.form.source do
        %Ecto.Changeset{action: action, errors: errors} when not is_nil(action) ->
          Enum.map(errors, fn {field, _} -> Map.get(@pane_of, field, "task") end)

        _ ->
          []
      end

    # A refused rename: its box is on the Task tab.
    title_panes =
      case assigns[:task_form] do
        %Phoenix.HTML.Form{source: %Ecto.Changeset{action: action, errors: [_ | _]}}
        when not is_nil(action) ->
          ["task"]

        _ ->
          []
      end

    times_panes =
      case assigns[:times_form] do
        %Phoenix.HTML.Form{source: %Ecto.Changeset{action: action, errors: [_ | _]}}
        when not is_nil(action) ->
          ["more"]

        _ ->
          []
      end

    MapSet.new(form_panes ++ title_panes ++ times_panes)
  end

  # After a failed save: the open tab when the error is there, else the
  # first tab that holds one.
  defp show_error_pane(socket) do
    errors = error_panes(socket.assigns)

    cond do
      MapSet.member?(errors, socket.assigns[:form_pane]) -> socket
      pane = Enum.find(@panes, &MapSet.member?(errors, &1)) -> assign(socket, :form_pane, pane)
      true -> socket
    end
  end

  defp priority_options do
    [
      {gettext("Urgent"), "urgent"},
      {gettext("High"), "high"},
      {gettext("Normal"), "normal"},
      {gettext("Low"), "low"}
    ]
  end

  # The labels a submit sets: nil (leave them) unless the flag is on and the
  # label boxes were posted — they always post an empty sentinel, so a
  # value set by a button (an assignee, a deadline preset) never clears
  # them for want of the boxes.
  defp pending_labels(%{labels: true}, %{"labels" => labels}),
    do: labels |> List.wrap() |> Enum.reject(&(&1 in [nil, ""])) |> Enum.uniq()

  defp pending_labels(_fx, _params), do: nil

  # Replace the saved assignment's labels with the submit's checkbox set
  # (nil = the flag was off at save time — leave the joins untouched).
  defp apply_pending_labels(socket, assignment) do
    case socket.assigns[:pending_labels] do
      nil -> :ok
      uuids -> Labels.set_assignment_labels(assignment, uuids)
    end
  end

  defp clear_other_assignees(attrs, "team") do
    Map.merge(attrs, %{"assigned_department_uuid" => nil, "assigned_person_uuid" => nil})
  end

  defp clear_other_assignees(attrs, "department") do
    Map.merge(attrs, %{"assigned_team_uuid" => nil, "assigned_person_uuid" => nil})
  end

  defp clear_other_assignees(attrs, "person") do
    Map.merge(attrs, %{"assigned_team_uuid" => nil, "assigned_department_uuid" => nil})
  end

  defp clear_other_assignees(attrs, _) do
    Map.merge(attrs, %{
      "assigned_team_uuid" => nil,
      "assigned_department_uuid" => nil,
      "assigned_person_uuid" => nil
    })
  end

  # Recent (this viewer's) and Often used (the site's), as library tasks.
  defp assign_library_blocks(socket) do
    tasks = socket.assigns[:library_tasks] || []
    by_uuid = Map.new(tasks, &{&1.uuid, &1})
    pick = fn uuids -> for u <- uuids, %Task{} = t <- [Map.get(by_uuid, u)], do: t end

    recent = socket |> Activity.actor_uuid() |> LibrarySearch.recent() |> pick.()
    often = tasks |> Enum.map(& &1.uuid) |> LibrarySearch.often_used(8) |> pick.()

    assign(socket, library_recent: recent, library_often: often)
  end

  # One tick is the form's library pick, as the old select made it (its
  # details prefilled, the tasks it pulls in offered); any other count
  # leaves the form without one.
  defp sync_library_pick(%{assigns: %{library_picked: [uuid]}} = socket),
    do: prefill_from_template(socket, uuid, socket.assigns.form.params || %{})

  defp sync_library_pick(socket),
    do:
      assign(socket,
        selected_task_uuid: nil,
        closure_tree: nil,
        excluded_closure_uuids: MapSet.new()
      )

  # Several library tasks at once, in the order ticked: each with its own
  # library defaults (description, estimate, default assignee), under the
  # same gates as a single add.
  defp save_library_many(socket) do
    project = socket.assigns.project
    fx = socket.assigns.fx

    created =
      Enum.reduce_while(socket.assigns.library_picked, [], fn uuid, acc ->
        with %Task{} = task <- Projects.get_task(uuid),
             attrs =
               task
               |> library_attrs(project)
               |> strip_gated_attrs(fx)
               |> strip_unassignable(socket),
             {:ok, a} <- Projects.create_assignment(attrs) do
          Activity.log("projects.assignment_created",
            actor_uuid: Activity.actor_uuid(socket),
            resource_type: "assignment",
            resource_uuid: a.uuid,
            target_uuid: Activity.assignee_target_uuid(a),
            metadata: %{"project" => project.name}
          )

          {:cont, [a | acc]}
        else
          _ -> {:halt, {:error, acc}}
        end
      end)

    case created do
      {:error, done} ->
        Enum.each(done, &place_under_parent(socket, &1))

        Activity.log_failed("projects.assignment_created",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "assignment",
          metadata: %{"project" => project.name, "project_uuid" => project.uuid}
        )

        {:noreply,
         put_flash(
           socket,
           :error,
           ngettext(
             "Could not add every task: 1 was added.",
             "Could not add every task: %{count} were added.",
             length(done)
           )
         )}

      [last | earlier] ->
        earlier |> Enum.reverse() |> Enum.each(&place_under_parent(socket, &1))

        LibrarySearch.remember(
          Activity.actor_uuid(socket),
          Enum.reverse(Enum.map(earlier, & &1.task_uuid))
        )

        n = length(earlier) + 1

        {:noreply,
         socket
         |> put_flash(
           :info,
           ngettext("1 task added to project.", "%{count} tasks added to project.", n)
         )
         |> after_create(last)}
    end
  end

  defp library_attrs(%Task{} = task, project) do
    %{
      "task_uuid" => task.uuid,
      "project_uuid" => project.uuid,
      "description" => RefText.collapse(task.description),
      "estimated_duration" => task.estimated_duration && to_string(task.estimated_duration),
      "estimated_duration_unit" => task.estimated_duration_unit,
      "assigned_team_uuid" => task.default_assigned_team_uuid,
      "assigned_department_uuid" => task.default_assigned_department_uuid,
      "assigned_person_uuid" => task.default_assigned_person_uuid,
      "status" => "waiting"
    }
  end

  defp prefill_from_template(socket, task_uuid, attrs) do
    case Projects.get_task(task_uuid) do
      nil ->
        cs =
          socket.assigns.assignment
          |> Projects.change_assignment(attrs)
          |> Map.put(:action, :validate)

        assign_form(socket, cs)

      task ->
        prefilled = %{
          "task_uuid" => task.uuid,
          "project_uuid" => socket.assigns.project.uuid,
          "description" => RefText.collapse(task.description),
          "estimated_duration" => task.estimated_duration && to_string(task.estimated_duration),
          "estimated_duration_unit" => task.estimated_duration_unit,
          "assigned_team_uuid" => task.default_assigned_team_uuid,
          "assigned_department_uuid" => task.default_assigned_department_uuid,
          "assigned_person_uuid" => task.default_assigned_person_uuid,
          "status" => attrs["status"] || "waiting"
        }

        assign_type =
          cond do
            task.default_assigned_person_uuid -> "person"
            task.default_assigned_team_uuid -> "team"
            task.default_assigned_department_uuid -> "department"
            true -> socket.assigns.assign_type
          end

        cs = %Assignment{} |> Projects.change_assignment(prefilled) |> Map.put(:action, :validate)

        # Build the template-dep closure tree so the form can render
        # the prune UI. Only the root + first level are kept by
        # default (everything ticked); the user can untick branches.
        closure_tree = Projects.task_closure(task_uuid, socket.assigns.project.uuid)

        socket
        |> assign(
          assign_type: assign_type,
          selected_task_uuid: task_uuid,
          closure_tree: closure_tree,
          excluded_closure_uuids: MapSet.new()
        )
        |> assign_form(cs)
    end
  end

  # The tasks that wait on this one: what finishing it lets start.
  defp unlocks(%Project{uuid: project_uuid}, %Assignment{uuid: uuid}) when is_binary(uuid) do
    waiting =
      for d <- Projects.list_all_dependencies(project_uuid),
          d.depends_on_uuid == uuid,
          into: MapSet.new(),
          do: d.assignment_uuid

    project_uuid
    |> Projects.list_assignments()
    |> Enum.filter(&MapSet.member?(waiting, &1.uuid))
  rescue
    _ -> []
  end

  defp unlocks(_project, _assignment), do: []

  defp reload_deps(socket) do
    {:noreply,
     assign(socket,
       unlocks: unlocks(socket.assigns.project, socket.assigns.assignment),
       assignment_deps: Projects.list_dependencies(socket.assigns.assignment.uuid),
       available_assignment_deps:
         Projects.available_dependencies(
           socket.assigns.project.uuid,
           socket.assigns.assignment.uuid
         )
     )}
  end

  @impl true
  # A sub-project being edited, by someone who may change its settings: the
  # project's own form, with everything a project has (the boss,
  # 2026-11-02), plus what its row waits on here (`subproject_link_uuid`).
  def render(%{kind: "subproject", live_action: :edit, sp_nest: %{} = nest} = assigns) do
    assigns = assign(assigns, :nest, nest)

    ~H"""
    <div class={@wrapper_class}>
      {Phoenix.Component.live_render(@socket, PhoenixKitProjects.Web.ProjectFormLive,
        id: "subproject-project-form-#{@nest.child_uuid}",
        session: @nest.session
      )}
    </div>
    """
  end

  def render(%{kind: "subproject"} = assigns) do
    assigns = prepare_subproject_render(assigns)

    ~H"""
    <div class={@wrapper_class}>
      <%!-- The same header as the task's: where it sits, and the name as
           it is typed (the boss: the project and sub-project popups should
           look like the task's, with tabs). --%>
      <.form_header
        id="subproject-form-header"
        title={subproject_title(assigns)}
        untitled={@live_action != :edit && gettext("New sub-project")}
        mode={if @live_action == :edit, do: gettext("Editing"), else: gettext("Add sub-project")}
        close_event={@embed_mode not in [:navigate, :emit] && "cancel"}
        close_confirm={@dirty? && gettext("Discard your changes?")}
      >
        <:context>
          <.link
            :if={@embed_mode == :navigate}
            navigate={Paths.project(@project.uuid)}
            class="btn btn-ghost btn-sm btn-square shrink-0"
            title={@project.name}
            aria-label={@project.name}
          >
            <.icon name="hero-arrow-left" class="w-4 h-4" />
          </.link>
          <button
            :if={@embed_mode != :navigate and @from_view?}
            type="button"
            {ConfirmAction.close("cancel", @dirty?)}
            class="btn btn-ghost btn-sm btn-square shrink-0"
            title={gettext("Back to task")}
            aria-label={gettext("Back to task")}
          >
            <.icon name="hero-arrow-left" class="w-4 h-4" />
          </button>
          <.ref_chip :if={assigns[:task_ref]} ref={assigns[:task_ref]} />
        </:context>
      </.form_header>

      <% sp_lang = L10n.current_content_lang() %>
      <.form
        for={@sp_form}
        id="subproject-form"
        phx-change="validate_subproject"
        phx-submit="save_subproject"
        phx-debounce="300"
        class="flex flex-col gap-3"
      >
        <%!-- On :new a sub-project can either be created fresh or an existing
             standalone project can be nested in place (V127). On :edit only
             the create-new fields exist (you're editing the child itself). --%>
        <.nav_tabs
          :if={@live_action == :new}
          on_change="set_sp_mode"
          active_tab={@sp_mode}
          tabs={[
            %{id: "new", label: gettext("Create new"), icon: "hero-plus"},
            %{id: "existing", label: gettext("Nest existing"), icon: "hero-rectangle-stack"}
          ]}
        />

        <%= if @sp_mode == "existing" do %>
          <div class="flex flex-col gap-3">
            <p class="text-sm text-base-content/60">
              {gettext("Nest a standalone project under this one. It keeps its own tasks and sub-projects; its progress rolls up here.")}
            </p>
            <%= if @link_options == [] do %>
              <p class="text-sm text-base-content/50">
                {gettext("No eligible standalone projects to nest.")}
              </p>
            <% else %>
              <.select
                name="link_child_uuid"
                label={gettext("Project to nest")}
                value=""
                options={Enum.map(@link_options, &{&1.name, &1.uuid})}
                prompt={gettext("Select a project")}
                required
              />
            <% end %>
          </div>
        <% else %>
          <.form_tabs
            id={"subproject-form-tabs-#{@dom}"}
            prefix={"subproject-#{@dom}"}
            panes={@sp_panes}
            active={@sp_pane}
            errors={@sp_pane_errors}
          />

          <%!-- ── Sub-project: what it is and whose it is ── --%>
          <.form_pane prefix={"subproject-#{@dom}"} pane="subproject" active={@sp_pane}>
            <.words_block
              id="subproject-words"
              multilang_enabled={@multilang_enabled}
              language_tabs={@language_tabs}
              current_lang={@current_lang}
            >
              <.translatable_field
                field_name="name"
                form_prefix="subproject"
                changeset={@sp_form.source}
                schema_field={:name}
                multilang_enabled={@multilang_enabled}
                current_lang={@current_lang}
                primary_language={@primary_language}
                lang_data={WebHelpers.lang_data(@sp_form, @current_lang)}
                secondary_name={"subproject[translations][#{@current_lang}][name]"}
                lang_data_key="name"
                label=""
                placeholder={gettext("Sub-project name")}
                aria-label={gettext("Sub-project name")}
              />
              <%!-- Pictures are intercepted (`uploads`): a pasted one is kept
                   in the sub-project's own folder and placed by file, as a
                   project's (`DescriptionImages`). --%>
              <.description_editor
                id={DescriptionEditor.editor_id("subproject-description", @current_lang)}
                name={DescriptionEditor.field_name("subproject", @current_lang, @primary_language, @multilang_enabled)}
                value={description_value(@sp_form, @current_lang, @primary_language, @multilang_enabled)}
                content={
                  editor_content(
                    description_value(@sp_form, @current_lang, @primary_language, @multilang_enabled),
                    assigns[:phoenix_kit_current_scope]
                  )
                }
                placeholder={gettext("Description…")}
                mention_context={mention_context(@project)}
                uploads
                image_button={@live_action == :edit}
              />
              <DescriptionImages.file_input
                :if={@live_action == :edit and is_map(assigns[:uploads]) and Map.has_key?(assigns[:uploads], :description_images)}
                uploads={assigns[:uploads]}
              />
            </.words_block>

            <%!-- The same picker as a task's (V128: the assignee lives on
                 the child project). --%>
            <.assignee_picker
              :if={@fx.assignees}
              id="subproject-assignee"
              label={gettext("Assignee")}
              search_form={"subproject-assignee-form-#{@dom}"}
              fields={[
                {@sp_form[:assigned_person_uuid].name, @sp_form[:assigned_person_uuid].value},
                {@sp_form[:assigned_team_uuid].name, @sp_form[:assigned_team_uuid].value},
                {@sp_form[:assigned_department_uuid].name, @sp_form[:assigned_department_uuid].value}
              ]}
              chip={@assignee_chip}
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
          </.form_pane>

          <%!-- ── Schedule: how it ends, what it waits on ── --%>
          <.form_pane prefix={"subproject-#{@dom}"} pane="schedule" active={@sp_pane}>
            <%!-- How it ends. A new sub-project copies the parent's
                 answer; the value is folded into the child's settings on
                 save, never posted as the settings map itself (a posted
                 map replaces every other key). --%>
            <.select
              name="completion"
              label={gettext("Ends")}
              value={if @live_action == :new, do: Project.completion(@project), else: Project.completion(@sp_form.source.data)}
              options={completion_options()}
            />

            <%!-- Dependencies — identical to a task's (this sub-project is a
                 row in the parent's timeline). Edit mode adds/removes live;
                 new mode collects pending selections applied on save. --%>
            <fieldset
              :if={@fx.dependencies}
              id="subproject-waits-on"
              class="rounded-box border border-base-300 p-3 flex flex-col gap-2"
            >
              <legend class="px-1 text-sm font-semibold">{gettext("Waits on")}</legend>
              <p class="text-xs text-base-content/60">
                {gettext("Items in this project that must finish before this sub-project can start.")}
              </p>
              <%= if @live_action == :edit do %>
                <ul :if={@assignment_deps != []} class="flex flex-col gap-1">
                  <li :for={dep <- @assignment_deps} class="flex items-center gap-2 text-sm">
                    <.assignment_status_badge status={dep.depends_on.status} size="xs" class="shrink-0" />
                    <span class="truncate flex-1">{Assignment.label(dep.depends_on, sp_lang)}</span>
                    <button
                      type="button"
                      phx-click="remove_assignment_dep"
                      phx-value-uuid={dep.depends_on_uuid}
                      phx-disable-with={gettext("Removing…")}
                      class="btn btn-ghost btn-xs btn-circle hover:text-error"
                      aria-label={gettext("Remove")}
                    >
                      <.icon name="hero-x-mark" class="w-3.5 h-3.5" />
                    </button>
                  </li>
                </ul>
                <.select
                  :if={@available_assignment_deps != []}
                  name="depends_on_uuid"
                  label={gettext("Add dependency")}
                  value=""
                  options={Enum.map(@available_assignment_deps, &{Assignment.label(&1, sp_lang), &1.uuid})}
                  prompt={gettext("Select")}
                  phx-change="add_assignment_dep"
                />
                <p :if={@assignment_deps == [] and @available_assignment_deps == []} class="text-sm text-base-content/50">
                  {gettext("No other items in this project to depend on.")}
                </p>
              <% else %>
                <% by_uuid = Map.new(@pending_dep_options, &{&1.uuid, &1}) %>
                <% pending = for u <- @pending_dep_uuids, a = Map.get(by_uuid, u), a, do: {u, a} %>
                <ul :if={pending != []} class="flex flex-col gap-1">
                  <li :for={{dep_uuid, a} <- pending} class="flex items-center gap-2 text-sm">
                    <.assignment_status_badge status={a.status} size="xs" class="shrink-0" />
                    <span class="truncate flex-1">{Assignment.label(a, sp_lang)}</span>
                    <button
                      type="button"
                      phx-click="remove_pending_dep"
                      phx-value-uuid={dep_uuid}
                      class="btn btn-ghost btn-xs btn-circle hover:text-error"
                      aria-label={gettext("Remove")}
                    >
                      <.icon name="hero-x-mark" class="w-3.5 h-3.5" />
                    </button>
                  </li>
                </ul>
                <% remaining = Enum.reject(@pending_dep_options, fn a -> a.uuid in @pending_dep_uuids end) %>
                <.select
                  :if={remaining != []}
                  name="depends_on_uuid"
                  label={gettext("Add dependency")}
                  value=""
                  options={Enum.map(remaining, &{Assignment.label(&1, sp_lang), &1.uuid})}
                  prompt={gettext("Select")}
                  phx-change="add_pending_dep"
                />
                <p :if={@pending_dep_options == []} class="text-sm text-base-content/50">
                  {gettext("No other items in this project to depend on.")}
                </p>
              <% end %>
            </fieldset>
          </.form_pane>

          <%!-- ── Settings: its workflow statuses (V125) ── --%>
          <.form_pane :if={@statuses_available} prefix={"subproject-#{@dom}"} pane="settings" active={@sp_pane}>
            <.workflow_status_fields
              statuses_available={@statuses_available}
              field={@sp_form[:status_entity_uuid]}
              status_entities={@status_entities}
              status_preview={@status_preview}
              status_translation_mode={@status_translation_mode}
              locked={Statuses.started?(@sp_form.source.data)}
            />
          </.form_pane>
        <% end %>

        <%!-- The same `cancel` as the task form: in a drawer it closes
             the frame, on the page it navigates back. --%>
        <div class="sticky bottom-0 z-10 flex flex-wrap items-center justify-end gap-2 mt-2 py-2 px-3 rounded-box border border-base-300 bg-base-100 shadow">
          <button
            type="button"
            {ConfirmAction.close("cancel", @dirty?)}
            class="btn btn-ghost btn-sm mr-auto"
          >
            {gettext("Close")}
          </button>
          <button
            type="submit"
            phx-disable-with={gettext("Saving…")}
            disabled={@sp_mode == "existing" and @link_options == []}
            class="btn btn-primary btn-sm"
          >
            {cond do
              @live_action == :edit -> gettext("Save")
              @sp_mode == "existing" -> gettext("Nest sub-project")
              true -> gettext("Add sub-project")
            end}
          </button>
        </div>
      </.form>
      <.assignee_picker_outside search_form={"subproject-assignee-form-#{@dom}"} staff_confirm={@staff_confirm} />
    </div>
    """
  end

  def render(assigns) do
    assigns = prepare_task_render(assigns)

    ~H"""
    <div class={@wrapper_class}>
      <%!-- The header names the task as it is being typed (the boss: the
           name at the top did not follow the field below), with where it
           stands; it stays above the tabs. --%>
      <.form_header
        id="assignment-form-header"
        title_id="assignment-form-title"
        title={header_title(assigns)}
        untitled={@live_action != :edit && gettext("New task")}
        mode={if @live_action == :edit, do: gettext("Editing"), else: gettext("Add task")}
        close_event={
          @embed_mode not in [:navigate, :emit] and not @from_view? &&
            if(@live_action == :edit, do: "close_form", else: "cancel")
        }
        close_confirm={@live_action != :edit && @dirty? && gettext("Discard your changes?")}
      >
        <:context>
          <.link
            :if={@embed_mode == :navigate and @project.uuid not in [nil, ""]}
            navigate={Paths.project(@project.uuid)}
            class="btn btn-ghost btn-sm btn-square shrink-0"
            title={@project.name}
            aria-label={@project.name}
          >
            <.icon name="hero-arrow-left" class="w-4 h-4" />
          </.link>
          <button
            :if={@from_view?}
            type="button"
            {ConfirmAction.close(if(@live_action == :edit, do: "close_form", else: "cancel"), @dirty?)}
            class="btn btn-ghost btn-sm btn-square shrink-0"
            title={gettext("Back to task")}
            aria-label={gettext("Back to task")}
          >
            <.icon name="hero-arrow-left" class="w-4 h-4" />
          </button>
          <.ref_chip :if={assigns[:task_ref]} ref={assigns[:task_ref]} />
        </:context>
      </.form_header>

      <.form for={@form} id="assignment-form" phx-change="validate" phx-submit="save" phx-debounce="300" class="flex flex-col gap-3">
        <%!-- The tabs. Every tab's fields stay in this one form and are only
             hidden, so switching loses nothing typed and a save posts them
             all; a tab holding an error the form shows carries a dot. --%>
        <.form_tabs
          id={"assignment-form-tabs-#{@dom}"}
          prefix={"assignment-#{@dom}"}
          panes={@panes}
          active={@pane}
          errors={@pane_errors}
        />

        <%!-- ── Task: what it is, where it stands, whose it is, by when ── --%>
        <section id={"assignment-#{@dom}-pane-task"} role="tabpanel" class={["flex flex-col gap-4", @pane != "task" && "hidden"]}>
            <%= if @live_action == :new do %>
              <%!-- Task-source tabs. Replaces the old "Pick from library /
                   Create new" dropdown — a tab strip makes the two
                   alternatives visually parallel instead of buried
                   inside a select. The active tab is held in
                   `@task_mode`; a hidden input keeps the value in form
                   data so existing `validate`/`save` handlers don't
                   need to special-case socket reads. --%>
              <input type="hidden" name="task_mode" value={@task_mode} />
              <%!-- Create new first and default; the library is the deliberate
                   second choice — and no choice at all while it is empty
                   (a new install sees one clean form, not a dead tab). --%>
              <.nav_tabs
                :if={@fx.library and @task_options != []}
                on_change="set_task_mode"
                active_tab={@task_mode}
                tabs={[
                  %{id: "new", label: gettext("Create new"), icon: "hero-plus"},
                  %{id: "existing", label: gettext("From library"), icon: "hero-rectangle-stack"}
                ]}
              />

              <%= if @task_mode == "existing" do %>
                <%!-- One tick is the form's library pick; several are
                     added each with its library defaults. --%>
                <input
                  type="hidden"
                  name={@form[:task_uuid].name}
                  value={single_pick(@library_picked)}
                />
                <.library_picker
                  dom={@dom}
                  q={@library_q}
                  picked={@library_picked}
                  tasks={@library_tasks}
                  recent={@library_recent}
                  often={@library_often}
                  lang={L10n.current_content_lang()}
                />

                <%!-- Closure pull-in tree. Renders only when the
                     selected task has at least one descendant in the
                     `TaskDependency` graph. The user can untick any
                     branch to drop it from the auto-create batch.
                     Already-in-project tasks render as static "✓"
                     markers (no-op on save). --%>
                <%= if @closure_tree && @closure_tree.children != [] do %>
                  <div class="bg-base-200/50 rounded-lg p-3 mt-1">
                    <div class="flex items-center gap-2">
                      <.icon name="hero-arrow-down-tray" class="w-4 h-4 text-base-content/70" />
                      <h3 class="text-sm font-semibold">
                        {gettext("This task pulls in other tasks")}
                      </h3>
                    </div>
                    <p class="text-xs text-base-content/60 mt-1">
                      {gettext("Untick any you don't want for this project. Tasks already in this project (✓) won't be re-added.")}
                    </p>

                    <ul class="mt-3 space-y-1">
                      <.closure_node
                        node={@closure_tree}
                        excluded_uuids={@excluded_closure_uuids}
                        is_root={true}
                        lang={L10n.current_content_lang()}
                      />
                    </ul>
                  </div>
                <% end %>
                <%!-- Separates the library pick from the details below; the
                     Create-new title lives with the details (it is
                     translatable like the description), so no divider there. --%>
                <div class="divider text-xs text-base-content/50 my-1">{gettext("Details")}</div>
              <% end %>
            <% end %>

          <%!-- The words of the task, at the top and marked as what they
               are (the boss): written per language, under the language
               tabs. Only these two sit inside the wrapper — it re-mounts
               on a language switch, so anything else in it would lose its
               value. --%>
          <.words_block
            id="assignment-words"
            multilang_enabled={@multilang_enabled}
            language_tabs={@language_tabs}
            current_lang={@current_lang}
            ai_translate={FormGlue.ai_translate_config(assigns)}
          >
            <:skeleton>
              <%!-- Mirrors the fields the wrapper holds: the title (input
                   height) above the description (textarea). --%>
              <div :if={@title_field?} class="space-y-2 mb-3">
                <div class="bg-base-content/15 rounded h-4 w-20 animate-pulse"></div>
                <div class="bg-base-content/15 rounded h-10 w-full animate-pulse"></div>
              </div>
              <div class="space-y-2">
                <div class="bg-base-content/15 rounded h-4 w-24 animate-pulse"></div>
                <div class="bg-base-content/15 rounded h-16 w-full animate-pulse"></div>
              </div>
            </:skeleton>

              <%!-- Re-keyed by `form_seq` so "Add & next" mounts a fresh
                   wrapper and the cursor lands back in the title; the same
                   mount focuses it when the sheet opens. Enter submits
                   through the first submit button, "Add" (then=next): the
                   form stays for the next task. Editing, the cursor is left
                   alone. --%>
              <div
                :if={@title_field?}
                id={"new-task-title-#{@form_seq}"}
                phx-mounted={@live_action == :new && JS.focus(to: "#task_title")}
              >
                <.translatable_field
                  field_name="title"
                  form_prefix="task"
                  changeset={@task_form.source}
                  schema_field={:title}
                  multilang_enabled={@multilang_enabled}
                  current_lang={@current_lang}
                  primary_language={@primary_language}
                  lang_data={WebHelpers.lang_data(@task_form, @current_lang)}
                  secondary_name={"task[translations][#{@current_lang}][title]"}
                  lang_data_key="title"
                  label=""
                  placeholder={gettext("Task name")}
                  aria-label={gettext("Task name")}
                  hint={if(@title_shared?, do: gettext("This task is in the task library: renaming it here renames it in every project that uses it."))}
                />
                <%!-- Library tasks matching the title as typed: a press adds
                     that one, as from the library tab. --%>
                <div
                  :if={@live_action == :new and assigns[:title_suggestions] not in [nil, []]}
                  id="assignment-title-suggestions"
                  class="mt-1.5 flex flex-wrap items-center gap-1.5"
                >
                  <span class="text-xs text-base-content/60">{gettext("From the library:")}</span>
                  <button
                    :for={t <- @title_suggestions}
                    type="button"
                    phx-click="pick_title_suggestion"
                    phx-value-uuid={t.uuid}
                    class="btn btn-xs btn-ghost border-base-300 gap-1 font-normal"
                  >
                    <.icon name="hero-rectangle-stack" class="w-3.5 h-3.5 opacity-60" />
                    {Task.localized_title(t, @current_lang)}
                  </button>
                </div>
              </div>

              <%!-- Pictures are always intercepted (`uploads`): a picture
                   pasted where it cannot be stored is refused with a
                   word, never put in the text as a `data:` address. --%>
              <.description_editor
                id={DescriptionEditor.editor_id("assignment-description", @current_lang)}
                name={DescriptionEditor.field_name("assignment", @current_lang, @primary_language, @multilang_enabled)}
                value={description_value(@form, @current_lang, @primary_language, @multilang_enabled)}
                content={
                  editor_content(
                    description_value(@form, @current_lang, @primary_language, @multilang_enabled),
                    assigns[:phoenix_kit_current_scope]
                  )
                }
                placeholder={gettext("Description…")}
                mention_context={mention_context(@project)}
                readonly={@current_lang in @ai_in_flight}
                uploads
                image_button={@can_attach?}
              />
          </.words_block>

          <%!-- Where it stands: the list's own status colours, one press each
               — a radio group, so the choice posts with the form. --%>
          <.status_choices
            id="assignment-status"
            name={@form[:status].name}
            value={to_string(@form[:status].value)}
            options={AssignmentStatusBadge.options(@assignment, @fx)}
          />

          <%!-- Whose it is (V29: any number of people, teams and
               departments, all equal): ticked in lists — Recent, then five
               of each kind with "Browse more", or a search — and shown as
               chips. Posted as the form's `assignees` list. --%>
          <.assignee_multi_picker
            :if={@fx.assignees}
            id="assignment-assignee"
            me_id="assignment-assign-me"
            label={gettext("Assignees")}
            name="assignment[assignees][]"
            selected={@assignee_selected}
            rows={@assignee_rows}
            view={@assignee_view}
            home={@assignee_home}
            more?={not is_nil(@assignee_cursor)}
            none?={@assignee_seen == %{}}
            open?={@assignee_open?}
            streams={@streams}
            search_form={"assignment-assignee-form-#{@dom}"}
            can_assign?={@can_assign?}
            my_person_uuid={@my_person_uuid}
            recent={@recent_assignees}
            notice={@assignee_notice}
          />

          <%!-- The deadline: by when it has to be done — the one date that
               makes a task overdue. The planned days are on Planning. --%>
          <div :if={@fx[:dates] != false} id="assignment-deadline" class="flex flex-col gap-1.5">
            <.datetime_input
              id="assignment-deadline-at"
              field={@form[:deadline]}
              value={local_input_value(@form[:deadline].value)}
              label={gettext("Deadline")}
              default_hour={17}
            />
            <div class="flex flex-wrap items-center gap-1.5 text-xs">
              <span class="text-base-content/60">{gettext("By when it has to be done.")}</span>
              <button type="button" phx-click="deadline_preset" phx-value-preset="hour" class="btn btn-xs btn-ghost border-base-300 font-normal">
                {gettext("In 1 hour")}
              </button>
              <button type="button" phx-click="deadline_preset" phx-value-preset="today" class="btn btn-xs btn-ghost border-base-300 font-normal">
                {gettext("Today %{time}", time: L10n.format_clock(17, 0))}
              </button>
              <button type="button" phx-click="deadline_preset" phx-value-preset="tomorrow" class="btn btn-xs btn-ghost border-base-300 font-normal">
                {gettext("Tomorrow %{time}", time: L10n.format_clock(9, 0))}
              </button>
              <button
                :if={@form[:deadline].value not in [nil, ""]}
                type="button"
                phx-click="deadline_clear"
                class="btn btn-xs btn-ghost font-normal text-base-content/60"
              >
                {gettext("No deadline")}
              </button>
            </div>
          </div>

          <div :if={@fx.priorities} class="w-full sm:w-48">
            <.select field={@form[:priority]} label={gettext("Priority")} options={priority_options()} />
          </div>

          <.checkbox
            :if={
              @live_action == :new and @task_mode == "new" and @fx.library and
                Authz.manage_library?(@phoenix_kit_current_scope)
            }
            name="add_to_library"
            checked={@add_to_library}
            label={gettext("Add to the task library")}
            class="checkbox-primary checkbox-sm"
          />
        </section>

        <%!-- ── Planning: the effort and the days it is meant for ── --%>
        <section id={"assignment-#{@dom}-pane-planning"} role="tabpanel" class={["flex flex-col gap-4", @pane != "planning" && "hidden"]}>
            <%!-- The ESTIMATE: planned effort, not time already spent (that is
                 logged under More). --%>
            <.duration_input
              :if={@fx.estimates}
              id="assignment-estimate"
              amount_field={@form[:estimated_duration]}
              unit_field={@form[:estimated_duration_unit]}
              label={gettext("Estimate")}
            />

          <%!-- The plan (Max, 2026-10-06): optional days, either alone, each
               with an optional time that belongs to its day. A dated task
               sits on these days in the calendar and the timeline. Not the
               deadline: a plan that slips makes nothing overdue. --%>
          <div :if={@fx[:dates] != false} class="grid gap-3 sm:grid-cols-2">
            <fieldset id="assignment-planned-start" class="rounded-box border border-base-300 p-3 flex flex-col gap-2">
              <legend class="px-1 text-sm font-semibold">{gettext("Planned start")}</legend>
              <.input field={@form[:start_date]} type="date" label={gettext("Day")} />
              <.clock_input id="assignment-start-time" field={@form[:start_time]} label={gettext("Time")} />
            </fieldset>
            <fieldset id="assignment-planned-end" class="rounded-box border border-base-300 p-3 flex flex-col gap-2">
              <legend class="px-1 text-sm font-semibold">{gettext("Planned end")}</legend>
              <.input field={@form[:end_date]} type="date" label={gettext("Day")} />
              <.clock_input id="assignment-end-time" field={@form[:end_time]} label={gettext("Time")} />
            </fieldset>
            <p class="sm:col-span-2 -mt-1 text-xs text-base-content/60">
              {gettext("The plan: when the work is meant to happen. A time belongs to its day. Only the deadline makes a task overdue.")}
            </p>
          </div>

            <%!-- NOT migrated to `<.checkbox>`: unlike Project/Template,
                 `Assignment.counts_weekends` has no schema default — `nil`
                 is a load-bearing third state meaning "inherit the parent
                 project's counts_weekends" (see `Projects.node_hours/2` and
                 `batched_planned_hours/2`, both `if is_nil(a.counts_weekends),
                 do: project.counts_weekends, else: a.counts_weekends`). The
                 hidden fallback below deliberately submits `""`, which Ecto's
                 `cast/4` (empty_values) turns back into the schema default
                 (`nil`) — preserving "inherit" on every unchecked save.
                 `<.checkbox>` hardcodes its hidden fallback to `value="false"`
                 (not configurable), so swapping it in would silently turn
                 every unchecked submit into an explicit "never count
                 weekends" override and permanently lose the inherit-from-
                 project state through this form. --%>
            <label :if={@fx.scheduling} class="flex items-center gap-2 cursor-pointer">
              <input type="hidden" name={@form[:counts_weekends].name} value="" />
              <input
                type="checkbox"
                name={@form[:counts_weekends].name}
                value="true"
                checked={@form[:counts_weekends].value == true or @form[:counts_weekends].value == "true"}
                class="checkbox checkbox-primary checkbox-sm"
              />
              <span class="text-sm">{gettext("Counts weekends (e.g. deliveries, external processes)")}</span>
            </label>

            <%!-- Labels: plain checkboxes over the PROJECT's registry (managed
                 in the Modules panel); selection replaces the join rows on
                 save. Renders only when the flag is on AND labels exist. --%>
            <div :if={@fx.labels and @project_labels != []} class="fieldset">
              <span class="fieldset-legend text-sm font-medium mb-1">{gettext("Labels")}</span>
              <%!-- Always posted, so a save that comes from a button (an
                   assignee, a deadline preset) tells "no labels" apart from
                   "the boxes were not sent" (`pending_labels/2`). --%>
              <input type="hidden" name="labels[]" value="" />
              <div class="flex flex-wrap gap-2">
                <label
                  :for={label <- @project_labels}
                  class="flex items-center gap-1.5 cursor-pointer rounded-lg border border-base-200 px-2 py-1"
                >
                  <input
                    type="checkbox"
                    name="labels[]"
                    value={label.uuid}
                    checked={label.uuid in @selected_labels}
                    class="checkbox checkbox-primary checkbox-xs"
                  />
                  <span class={["badge badge-sm", label.color]}>{label.name}</span>
                </label>
              </div>
            </div>

            <%!-- Where the task sits: under another task of this project, or
                 at the top. Moving it takes its own subtasks along. --%>
            <.select
              :if={@subtasks_on? and @kind == "task" and not @project.is_template}
              id="assignment-parent-task"
              name="parent_task"
              value={@parent_task || ""}
              label={gettext("Sits under")}
              options={[{gettext("Nothing — a top-level task"), ""} | @parent_options]}
            />

            <%!-- The task's subtasks: ticked here, opened here, and added by
                 typing a line and pressing Enter (the inputs belong to a
                 form of their own, drawn after this one). --%>
            <fieldset
              :if={@live_action == :edit and @subtasks_on? and @kind == "task" and not @project.is_template}
              id="assignment-subtasks"
              class="rounded-box border border-base-300 p-3"
            >
              <legend class="px-1 text-sm font-medium">
                {gettext("Subtasks")}
                <span :if={@subtasks != []} class="text-base-content/50 font-normal">
                  {Enum.count(@subtasks, &(&1.status == "done"))}/{length(@subtasks)}
                </span>
              </legend>
              <ul class="flex flex-col gap-1 mb-2">
                <li :for={sub <- @subtasks} class="flex items-center gap-2 text-sm">
                  <input
                    type="checkbox"
                    class="checkbox checkbox-sm checkbox-success"
                    checked={sub.status == "done"}
                    phx-click="subtask_toggle"
                    phx-value-uuid={sub.uuid}
                    aria-label={AssignmentStatusBadge.label("done")}
                  />
                  <.link
                    navigate={Paths.edit_assignment(@project.uuid, sub.uuid)}
                    class={["link link-hover truncate flex-1", sub.status == "done" && "line-through text-base-content/50"]}
                  >
                    {Assignment.label(sub, @current_lang)}
                  </.link>
                  <span :if={Map.get(@subtask_counts, sub.uuid)} class="text-xs text-base-content/50">
                    {Map.get(@subtask_counts, sub.uuid).done}/{Map.get(@subtask_counts, sub.uuid).total}
                  </span>
                </li>
              </ul>
              <%!-- Re-keyed after each add: a fresh, empty input that takes
                   the cursor back for the next line. --%>
              <input
                type="text"
                name="title"
                form={"assignment-subtask-form-#{@dom}"}
                id={"assignment-subtask-new-#{assigns[:subtask_seq] || 0}"}
                phx-mounted={(assigns[:subtask_seq] || 0) > 0 && JS.focus()}
                placeholder={gettext("Add a subtask and press Enter")}
                maxlength="500"
                autocomplete="off"
                class="input input-sm input-bordered w-full"
              />
            </fieldset>

            <%!-- Repeating (the boss, via Max, 2026-10-31: low priority, and
                 not on the first tab — "the UI is too cluttered"): one row,
                 last here. Done, the task stays done and its next
                 occurrence is made (`Repeats`). --%>
            <.repeat_row
              :if={not Map.get(@project, :is_template, false)}
              choice={assigns[:repeat_choice] || Repeats.choice(@form[:repeat_rule].value)}
              rule={@form[:repeat_rule].value}
            />

        </section>

        <%!-- ── Connections: what it waits on, what it lets start ── --%>
        <% lang = L10n.current_content_lang() %>
        <section
          :if={@fx.dependencies}
          id={"assignment-#{@dom}-pane-connections"}
          role="tabpanel"
          class={["flex flex-col gap-4", @pane != "connections" && "hidden"]}
        >
          <%!-- These write as they are made (records of their own), unlike
               the fields above, which wait for Save. --%>
          <p :if={@live_action == :edit} class="text-xs text-base-content/60 flex items-center gap-1.5">
            <.icon name="hero-bolt" class="w-3.5 h-3.5 shrink-0" />
            {gettext("Saved as soon as you add them — Close does not undo these.")}
          </p>
          <%!-- The picker uses `phx-change` on its own `<.select>` (a form
               inside a form is not HTML); it overrides the form's
               `validate` for its own changes. Editing, a row is written at
               once; adding, the choices wait for the task to exist and are
               written right after it (`flush_pending_deps/2`). --%>
          <fieldset id="assignment-waits-on" class="rounded-box border border-base-300 p-3 flex flex-col gap-2">
            <legend class="px-1 text-sm font-semibold">{gettext("Waits on")}</legend>
            <p class="text-xs text-base-content/60">
              {gettext("Tasks in this project that must finish before this one can start.")}
              <span :if={@live_action == :new}>{gettext("Selections will be applied when you save this task.")}</span>
            </p>

            <%= if @live_action == :edit do %>
              <ul :if={@assignment_deps != []} class="flex flex-col gap-1">
                <li :for={dep <- @assignment_deps} class="flex items-center gap-2 text-sm">
                  <.assignment_status_badge status={dep.depends_on.status} size="xs" class="shrink-0" />
                  <span class="truncate flex-1">{Assignment.label(dep.depends_on, lang)}</span>
                  <button
                    type="button"
                    phx-click="remove_assignment_dep"
                    phx-value-uuid={dep.depends_on_uuid}
                    phx-disable-with={gettext("Removing…")}
                    class="btn btn-ghost btn-xs btn-circle hover:text-error"
                    aria-label={gettext("Remove")}
                  >
                    <.icon name="hero-x-mark" class="w-3.5 h-3.5" />
                  </button>
                </li>
              </ul>
              <.select
                :if={@available_assignment_deps != []}
                name="depends_on_uuid"
                label={gettext("Add dependency")}
                value=""
                options={Enum.map(@available_assignment_deps, &{Assignment.label(&1, lang), &1.uuid})}
                prompt={gettext("Select task")}
                phx-change="add_assignment_dep"
              />
              <p :if={@assignment_deps == [] and @available_assignment_deps == []} class="text-sm text-base-content/50">
                {gettext("No other tasks in this project to depend on.")}
              </p>
            <% else %>
              <% by_uuid = Map.new(@pending_dep_options, &{&1.uuid, &1}) %>
              <% pending = for u <- @pending_dep_uuids, a = Map.get(by_uuid, u), a, do: {u, a} %>
              <ul :if={pending != []} class="flex flex-col gap-1">
                <li :for={{dep_uuid, a} <- pending} class="flex items-center gap-2 text-sm">
                  <.assignment_status_badge status={a.status} size="xs" class="shrink-0" />
                  <span class="truncate flex-1">{Assignment.label(a, lang)}</span>
                  <button
                    type="button"
                    phx-click="remove_pending_dep"
                    phx-value-uuid={dep_uuid}
                    class="btn btn-ghost btn-xs btn-circle hover:text-error"
                    aria-label={gettext("Remove")}
                  >
                    <.icon name="hero-x-mark" class="w-3.5 h-3.5" />
                  </button>
                </li>
              </ul>
              <% remaining = Enum.reject(@pending_dep_options, fn a -> a.uuid in @pending_dep_uuids end) %>
              <.select
                :if={remaining != []}
                name="depends_on_uuid"
                label={gettext("Add dependency")}
                value=""
                options={Enum.map(remaining, &{Assignment.label(&1, lang), &1.uuid})}
                prompt={gettext("Select task")}
                phx-change="add_pending_dep"
              />
              <p :if={@pending_dep_options == []} class="text-sm text-base-content/50">
                {gettext("No other tasks in this project to depend on.")}
              </p>
            <% end %>
          </fieldset>

          <fieldset :if={@live_action == :edit} id="assignment-unlocks" class="rounded-box border border-base-300 p-3 flex flex-col gap-2">
            <legend class="px-1 text-sm font-semibold">{gettext("Unlocks")}</legend>
            <p class="text-xs text-base-content/60">{gettext("Tasks that wait for this one to finish.")}</p>
            <ul :if={@unlocks != []} class="flex flex-col gap-1">
              <li :for={u <- @unlocks} class="flex items-center gap-2 text-sm">
                <.assignment_status_badge status={u.status} size="xs" class="shrink-0" />
                <span class="truncate">{Assignment.label(u, lang)}</span>
              </li>
            </ul>
            <p :if={@unlocks == []} class="text-sm text-base-content/50">{gettext("Nothing waits for this task.")}</p>
          </fieldset>
        </section>

        <%!-- ── More: time logged, the real start and finish, the portal ── --%>
        <section
          :if={Enum.any?(@panes, &(elem(&1, 0) == "more"))}
          id={"assignment-#{@dom}-pane-more"}
          role="tabpanel"
          class={["flex flex-col gap-4", @pane != "more" && "hidden"]}
        >
          <%!-- These write as they are made (records of their own), unlike
               the fields above, which wait for Save. --%>
          <p :if={@live_action == :edit} class="text-xs text-base-content/60 flex items-center gap-1.5">
            <.icon name="hero-bolt" class="w-3.5 h-3.5 shrink-0" />
            {gettext("Saved as soon as you add them — Close does not undo these.")}
          </p>
            <%!-- The task's time, in one box: what people logged, what an
                 agent reported for itself (it sends its own time and tokens
                 over the API; nobody types those in), and a line to log
                 more — for yourself or, for someone who runs the plan, for
                 anybody on it. The inputs belong to a form of their own
                 (`form=`), drawn after this one: a form inside a form is
                 not HTML. --%>
            <fieldset
              :if={@live_action == :edit and @kind == "task" and @fx.ledger and not @project.is_template}
              id="assignment-log-time"
              class="flex flex-col gap-3 rounded-box border border-base-300 p-3"
            >
              <legend class="px-1 text-sm font-semibold">{gettext("Time and AI usage")}</legend>
              <dl :if={@logged} class="grid grid-cols-2 sm:grid-cols-4 gap-3 text-sm" id="assignment-logged">
                <div>
                  <dt class="text-xs text-base-content/60">{gettext("Human time")}</dt>
                  <dd class={["font-semibold", @logged.minutes == 0 && "opacity-40"]}>
                    {PhoenixKitProjects.Hours.Format.duration(@logged.minutes)}
                  </dd>
                </div>
                <div>
                  <dt class="text-xs text-base-content/60">{gettext("AI time")}</dt>
                  <dd class={["font-semibold", @logged.ai_minutes == 0 && "opacity-40"]}>
                    {PhoenixKitProjects.Hours.Format.duration(@logged.ai_minutes)}
                  </dd>
                </div>
                <div>
                  <dt class="text-xs text-base-content/60">{gettext("AI tokens")}</dt>
                  <dd class={["font-semibold", @logged.tokens == 0 && "opacity-40"]}>
                    {if @logged.tokens > 0, do: PhoenixKitProjects.Hours.Format.tokens(@logged.tokens), else: "0"}
                  </dd>
                </div>
                <div>
                  <dt class="text-xs text-base-content/60">{gettext("AI cost")}</dt>
                  <dd class={["font-semibold", @logged.cost_cents == 0 && "opacity-40"]}>
                    {if @logged.cost_cents > 0, do: PhoenixKitProjects.Hours.Format.cost(@logged.cost_cents), else: "—"}
                  </dd>
                </div>
              </dl>
              <%!-- The AI's own last words on the task, where its figures
                   are: the summary of its latest note. --%>
              <p :if={@ai_summary} class="text-sm" id="assignment-ai-summary">
                <span class="text-xs text-base-content/60">{gettext("Latest from the AI")}:</span>
                {@ai_summary}
              </p>
              <p class="text-xs text-base-content/60">
                {gettext("AI figures are self-reported. Its full notes open from the chip icon on the task's row.")}
              </p>
              <div class="grid grid-cols-2 gap-x-2 gap-y-3 border-t border-base-300 pt-3 [&_label.label]:mb-1 [&_label.label>span]:text-xs [&_label.label>span]:font-medium">
                <div>
                  <FormFieldLabel.label for="assignment-log-person">{gettext("Log for")}</FormFieldLabel.label>
                  <%!-- Whose time: always said. A search for someone who runs
                       the plan; the viewer, as text, for everyone else. --%>
                  <.search_picker
                    :if={@log_people != []}
                    id="assignment-log-person"
                    dropdown_id="assignment-log-person-list"
                    form={"assignment-log-form-#{@dom}"}
                    search_event="log_person_search"
                    pick_event="log_person_pick"
                    chosen={@log_person && @log_person.name}
                    clear_event="log_person_clear"
                    clear_label={gettext("Back to me")}
                    search_on_focus
                    close_on_pick
                    row_layout="stacked"
                    placeholder={gettext("Me — or search a person")}
                    class="input input-sm w-full"
                    searching_label={gettext("Searching…")}
                    more_label={gettext("Load more")}
                    loading_more_label={gettext("Loading…")}
                    no_matches_label={gettext("No matches")}
                  />
                  <span :if={@log_people == []} id="assignment-log-person" class="input input-sm w-full flex items-center text-base-content/70">
                    {gettext("Me")}
                  </span>
                </div>
                <%!-- Re-keyed after each entry (`log_seq`): the two boxes come
                     back empty, so a second press cannot log the same again. --%>
                <.duration_input
                  id={"assignment-log-duration-#{@log_seq}"}
                  name="duration"
                  form={"assignment-log-form-#{@dom}"}
                  label={gettext("How long")}
                />
                <.input
                  id={"assignment-log-note-#{@log_seq}"}
                  name="note"
                  form={"assignment-log-form-#{@dom}"}
                  label={gettext("What was done")}
                  value=""
                  autocomplete="off"
                  class="input-sm"
                  wrapper_class="col-span-2"
                />
                <div class="col-span-2 flex flex-wrap items-center justify-between gap-2">
                  <label :if={@billable_on?} class="flex items-center gap-2 cursor-pointer text-sm">
                    <input type="checkbox" name="billable" value="true" form={"assignment-log-form-#{@dom}"} class="checkbox checkbox-sm" />
                    {gettext("Billable")}
                  </label>
                  <button type="submit" form={"assignment-log-form-#{@dom}"} class="btn btn-primary btn-sm" phx-disable-with={gettext("Saving…")}>
                    <.icon name="hero-plus" class="w-4 h-4" /> {gettext("Log time")}
                  </button>
                </div>
              </div>
            </fieldset>

          <%!-- The task's own files and images (V27): a button and a drop
               zone; each is stored as it arrives, in the task's folder
               inside the project's. Images pasted into the description
               are listed too. The file input belongs to a form of its own,
               drawn after this one. --%>
          <fieldset
            :if={@can_attach?}
            id="assignment-files"
            class="rounded-box border border-base-300 p-3 flex flex-col gap-2"
            phx-drop-target={@uploads.task_files.ref}
          >
            <legend class="px-1 text-sm font-semibold">{gettext("Files")}</legend>
            <.task_files
              id="assignment-file-list"
              files={@task_files}
              urls={@task_file_urls}
              remove_event="remove_task_file"
            />
            <label class="flex flex-col items-center justify-center gap-1 rounded-box border border-dashed border-base-300 px-3 py-4 text-sm text-base-content/60 cursor-pointer hover:bg-base-200/50">
              <.icon name="hero-arrow-up-tray" class="w-5 h-5" />
              <span>{gettext("Drop files here or choose them")}</span>
              <.live_file_input upload={@uploads.task_files} form={"assignment-files-form-#{@dom}"} class="sr-only" />
            </label>
            <div :for={entry <- @uploads.task_files.entries} class="flex items-center gap-2 text-xs">
              <span class="truncate flex-1">{entry.client_name}</span>
              <progress class="progress progress-primary w-24" value={entry.progress} max="100"></progress>
              <button
                type="button"
                phx-click="cancel_task_upload"
                phx-value-ref={entry.ref}
                phx-value-upload="task_files"
                class="btn btn-ghost btn-xs btn-circle"
                aria-label={gettext("Cancel")}
              >
                <.icon name="hero-x-mark" class="w-3.5 h-3.5" />
              </button>
              <span :for={err <- upload_errors(@uploads.task_files, entry)} class="text-error">
                {upload_error_text(err)}
              </span>
            </div>
          </fieldset>

          <%!-- When it really began and ended: stamped by Start and Done, and
               corrected here — a "Done" pressed late moves back to when the
               work was finished. Saved with the form, through their own
               changeset; never in the future. --%>
          <fieldset :if={@show_times?} id="assignment-real-times" class="rounded-box border border-base-300 p-3 flex flex-col gap-2">
            <legend class="px-1 text-sm font-semibold">{gettext("When it really happened")}</legend>
            <div class="grid gap-3 sm:grid-cols-2">
              <.datetime_input
                id="assignment-started-at"
                field={@times_form[:started_at]}
                value={local_input_value(@times_form[:started_at].value)}
                label={gettext("Started at")}
              />
              <.datetime_input
                id="assignment-completed-at"
                field={@times_form[:completed_at]}
                value={local_input_value(@times_form[:completed_at].value)}
                label={gettext("Finished at")}
              />
            </div>
            <p class="text-xs text-base-content/60">
              {gettext("Set when the task is started and done; correct them here if they were pressed late.")}
            </p>
          </fieldset>

        <%!-- Portal visibility. Inside the form so the page reads in
             order — fields, then who can see this, then Save. It used to
             sit after the closing tag, which put two switches BELOW the
             Save button and made the page look like it had ended and
             then carried on.

             Still immediate writes, not form params: each input carries
             `phx-click` and deliberately NO `name`, so nothing here is
             ever cast from the submitted params. `public` and
             `board_published_at` are server-set only — do not name them. --%>
        <div
          :if={@portal?}
          class="card bg-base-100 shadow"
        >
          <div class="card-body flex-row items-start gap-3 py-4">
            <input
              type="checkbox"
              class="toggle toggle-primary shrink-0 mt-0.5"
              checked={@assignment.public == true}
              phx-click="toggle_portal_public"
              aria-label={gettext("Show on the public portal")}
            />
            <div class="min-w-0">
              <h3 class="text-sm font-semibold">{gettext("Public portal")}</h3>
              <p class="text-xs opacity-60">
              {gettext("Show this issue (title and status only) on the project's public page.")}
              </p>
            </div>
          </div>

          <%!-- What the stranger actually attached. This sits ABOVE the two
               publish switches on purpose: the whole justification for
               letting anonymous people upload files is that a person looks
               at them first, and that was not true until this panel existed
               — the text was reviewed here while the images went from an
               unknown submitter straight onto an indexable page, seen by
               nobody. Server-side re-encoding strips the payloads it can;
               it cannot tell you what the picture is OF. --%>
          <div
            :if={@portal_review_images != []}
            class="card-body border-t border-base-200 py-4"
          >
            <h3 class="text-sm font-semibold">{gettext("Attached by the submitter")}</h3>
            <p class="text-xs opacity-60">
              {gettext(
                "Sent by an anonymous visitor and re-encoded on arrival. Look at them before publishing — publishing puts them on the open internet."
              )}
            </p>
            <div class="mt-2 flex flex-wrap gap-3">
              <a
                :for={image <- @portal_review_images}
                href={image.url}
                target="_blank"
                rel="noopener noreferrer nofollow"
                class="block"
              >
                <img
                  src={image.url}
                  alt={gettext("Submitted attachment")}
                  loading="lazy"
                  class="h-28 w-28 rounded-lg border border-base-300 object-cover"
                />
              </a>
            </div>
          </div>

        <%!-- The second, deliberate act. Only offered on a board that is
             actually public and for an issue already visible to
             link-holders: "on the open web" is a bigger decision than "on
             the private link", and the design's whole blast-radius guard
             depends on it being taken one issue at a time. Without this
             control the guard has no product path and a public board stays
             empty forever. --%>
          <div
            :if={@assignment.public == true and public_board?(@project)}
            class="card-body flex-row items-start gap-3 border-t border-base-200 py-4"
          >
            <input
              type="checkbox"
              class="toggle toggle-primary shrink-0 mt-0.5"
              checked={@assignment.board_published_at != nil}
              phx-click="toggle_board_published"
              aria-label={gettext("Publish to the public board")}
            />
            <div class="min-w-0">
              <h3 class="text-sm font-semibold">{gettext("Publish to the public board")}</h3>
              <p class="text-xs opacity-60">
              {gettext("This board is on the open internet and can be indexed by search engines. The issue's description is shown too.")}
              </p>
            </div>
          </div>
        </div>

        </section>

        <%!-- DOM order matters: the browser's implicit submission (Enter in
             an input) presses the FIRST submit button, so "Add" comes before
             "Add & next" in the markup and CSS `order` puts it last on
             screen. "Add & next" carries `then=next`, which LiveView sends
             as the submitter — Shift+Enter presses it through PkShiftEnter. --%>
        <%!-- A task being edited saves with Save, like every popup (the
             boss, 2026-11-02: "if someone makes a mistake, they can just
             cancel"); Close leaves without saving and asks first when
             something is unsaved. Files, subtasks, connections and logged
             time are their own records and are kept as they are added (each
             section says so). Always in reach: the form is two screens long. --%>
        <div
          :if={@live_action == :edit}
          id="assignment-save-bar"
          class="sticky bottom-0 z-10 flex flex-wrap items-center justify-between gap-2 mt-2 py-2 px-3 rounded-box border border-base-300 bg-base-100 shadow"
        >
          <span id="assignment-save-state" role="status" class="inline-flex items-center gap-1.5 text-xs text-base-content/60">
            <%= cond do %>
              <% @save_state == :error -> %>
                <span class="badge badge-error badge-sm h-auto gap-1">
                  <.icon name="hero-exclamation-triangle" class="w-3 h-3" />
                  {gettext("Not saved")}: {@save_error}
                </span>
              <% @dirty? -> %>
                {gettext("Unsaved changes")}
              <% true -> %>
            <% end %>
          </span>
          <div class="flex items-center gap-1">
            <%!-- Deleting a task from its own form (Max, 2026-10-14: "I'm not
                 seeing a delete button"). Its subtasks go with it, and the
                 question says how many. --%>
            <button
              :if={@kind == "task" and @can_delete_task?}
              type="button"
              id="assignment-delete"
              {ConfirmAction.ask("delete_task",
                title: delete_question(@subtask_total),
                confirm: gettext("Delete")
              )}
              class="btn btn-ghost btn-sm text-error"
            >
              <.icon name="hero-trash" class="w-4 h-4" /> {gettext("Delete")}
            </button>
            <button type="button" id="assignment-close-edit" {ConfirmAction.close("close_form", @dirty?)} class="btn btn-ghost btn-sm">
              {if @from_view?, do: gettext("Back to task"), else: gettext("Close")}
            </button>
            <button
              type="submit"
              id="assignment-save"
              phx-disable-with={gettext("Saving…")}
              disabled={@ai_in_flight != []}
              class="btn btn-primary btn-sm"
            >
              {gettext("Save")}
            </button>
          </div>
        </div>
        <div :if={@live_action != :edit} class="sticky bottom-0 z-10 flex flex-wrap items-center justify-end gap-2 mt-2 py-2 px-3 rounded-box border border-base-300 bg-base-100 shadow">
          <button
            type="button"
            id="assignment-close"
            {ConfirmAction.close("cancel", @dirty?)}
            class="btn btn-ghost btn-sm order-1 mr-auto"
          >
            {gettext("Close")}
          </button>
          <%!-- The browser's implicit submission (Enter in a field) presses
               the FIRST submit button: Enter adds and starts the next task,
               like Enter in the typed list. "Add and close" is the click most
               people make, so it is the highlighted one, last in the row. --%>
          <button
            :if={@live_action == :new}
            type="submit"
            id="assignment-add-next"
            name="then"
            value="next"
            phx-disable-with={gettext("Saving…")}
            title={gettext("Enter")}
            class="btn btn-outline btn-sm order-2"
          >
            {gettext("Add")}
          </button>
          <button
            type="submit"
            phx-disable-with={gettext("Saving…")}
            class="btn btn-primary btn-sm order-3"
          >
            <%= cond do %>
              <% @live_action == :new and @task_mode == "existing" and @library_picked != [] -> %>
                {ngettext("Add %{count} task", "Add %{count} tasks", length(@library_picked))}
              <% @live_action == :new -> %>
                {gettext("Add and close")}
              <% true -> %>
                {gettext("Save")}
            <% end %>
          </button>
        </div>
        <p :if={@live_action == :new} class="text-xs text-base-content/50 text-right">
          <%= if @embed_mode == :navigate do %>
            {gettext("Enter adds it and starts the next")}
          <% else %>
            {gettext("Enter adds it and starts the next · Esc closes")}
          <% end %>
        </p>

        <.ai_translate_modal ai_translate={FormGlue.ai_translate_config(assigns)} />
      </.form>
      <%!-- Owns the "Log time" inputs drawn inside the form above (`form=`). --%>
      <form id={"assignment-log-form-#{@dom}"} phx-submit="log_time" class="hidden"></form>
      <%!-- Owns the library picker's search and ticks drawn inside the form above. --%>
      <form
        id={"assignment-library-form-#{@dom}"}
        phx-change="library_search"
        phx-submit="library_search"
        class="hidden"
      ></form>
      <%!-- Owns the "Add a subtask" line drawn inside the form above. --%>
      <form id={"assignment-subtask-form-#{@dom}"} phx-submit="subtask_add" class="hidden"></form>
      <%!-- Owns the task's file inputs drawn inside the form above. --%>
      <form
        :if={@can_attach?}
        id={"assignment-files-form-#{@dom}"}
        phx-change="task_files_validate"
        phx-submit="task_files_validate"
        class="hidden"
      >
        <.live_file_input upload={@uploads.description_images} />
      </form>
      <%!-- Owns the assignee search box, and asks before an assignment
           makes a staff record. --%>
      <.assignee_picker_outside search_form={"assignment-assignee-form-#{@dom}"} staff_confirm={@staff_confirm} />
      <%!-- The shared confirm (`Components.ConfirmAction`): removing a file. --%>
      <.confirm_action_modal confirm={assigns[:confirm_action]} />
    </div>
    """
  end

  attr(:choice, :string, required: true)
  attr(:rule, :any, default: nil)

  defp repeat_row(assigns) do
    rule = Repeats.normalize(assigns.rule)

    assigns =
      assign(assigns,
        every: (rule && rule["every"]) || 1,
        unit: (rule && rule["unit"]) || "week"
      )

    ~H"""
    <div id="assignment-repeat" class="flex flex-wrap items-center gap-2">
      <.icon name="hero-arrow-path" class="w-4 h-4 opacity-60" />
      <select
        name="assignment[repeat]"
        id="assignment-repeat-choice"
        aria-label={gettext("Repeats")}
        class="select select-sm select-bordered w-auto"
      >
        <option
          :for={
            {value, label} <- [
              {"none", gettext("Does not repeat")},
              {"week", pgettext("repeat", "Every week")},
              {"2weeks", pngettext("repeat", "Every %{count} week", "Every %{count} weeks", 2)},
              {"month", pgettext("repeat", "Every month")},
              {"custom", gettext("Every…")}
            ]
          }
          value={value}
          selected={@choice == value}
        >
          {label}
        </option>
      </select>
      <%= if @choice == "custom" do %>
        <input
          type="number"
          name="assignment[repeat_every]"
          id="assignment-repeat-every"
          value={@every}
          min="1"
          max="365"
          aria-label={gettext("How often")}
          class="input input-sm input-bordered w-20"
        />
        <select
          name="assignment[repeat_unit]"
          id="assignment-repeat-unit"
          aria-label={gettext("Unit")}
          class="select select-sm select-bordered w-auto"
        >
          <%!-- The word agrees with the number beside it (ru "2 недели",
               "5 недель"; pl "2 tygodnie", "5 tygodni"). --%>
          <option
            :for={
              {value, label} <- [
                {"day", pngettext("repeat unit", "day", "days", @every)},
                {"week", pngettext("repeat unit", "week", "weeks", @every)},
                {"month", pngettext("repeat unit", "month", "months", @every)}
              ]
            }
            value={value}
            selected={@unit == value}
          >
            {label}
          </option>
        </select>
      <% end %>
    </div>
    """
  end

  # The suffix of every id another element points at (a `form=` attribute,
  # a tab's pane, a hook): the task's uuid, or this mount's key while it is
  # new — so two stacked forms never bind to each other's elements.
  defp dom_key(%{assignment: %Assignment{uuid: uuid}}) when is_binary(uuid), do: uuid
  defp dom_key(assigns), do: assigns[:dom_seed] || "new"

  # The sub-project form's tabs, the open one, and the ones holding an error.
  # A sub-project's description takes pictures as a project's does: pasted,
  # or through the editor's image button (`DescriptionImages`), kept in the
  # sub-project's own folder. Only on edit (a new one has nowhere to keep
  # them yet) and only where the project's form is not nested instead.
  defp allow_subproject_images(%{assigns: %{kind: "subproject", live_action: :edit}} = socket) do
    if socket.assigns[:sp_nest],
      do: socket,
      else: DescriptionImages.allow(socket, &subproject_image_target/1)
  end

  defp allow_subproject_images(socket), do: socket

  defp subproject_image_target(socket) do
    case sp_source(socket) do
      %Project{uuid: uuid} = sub when is_binary(uuid) ->
        {sub,
         DescriptionEditor.editor_id("subproject-description", socket.assigns[:current_lang])}

      _ ->
        nil
    end
  end

  # ── A sub-project edited as the project it is ──────────────────────
  #
  # The boss, 2026-11-02: "Everything that the project has should be in the
  # subproject as well." Whoever may change the sub-project's settings
  # (`:edit_settings` on it, as the project popup asks) gets the project's
  # own form — nested here in a popup, the project's edit page otherwise —
  # told which row it is (`subproject_link_uuid`) so its Schedule tab also
  # shows what that row waits on. Anyone else keeps this form's short
  # version (name, description, assignee, how it ends, what it waits on).
  defp nest_project_form(socket, %Project{uuid: child_uuid} = child, %Assignment{} = link)
       when is_binary(child_uuid) do
    scope = socket.assigns[:phoenix_kit_current_scope]

    cond do
      child.is_template or not PhoenixKitProjects.Authz.can?(scope, child, :edit_settings) ->
        assign(socket, sp_nest: nil)

      socket.assigns[:embed_mode] == :navigate ->
        socket
        |> assign(sp_nest: nil)
        |> push_navigate(to: Paths.edit_project(child_uuid) <> "?subproject_link=" <> link.uuid)

      true ->
        session =
          (socket.assigns[:embed_session] || %{})
          |> Map.drop(~w(project_id kind from_view))
          |> Map.merge(%{
            "live_action" => "edit",
            "id" => child_uuid,
            "subproject_link_uuid" => link.uuid
          })

        assign(socket, sp_nest: %{child_uuid: child_uuid, session: session})
    end
  end

  defp nest_project_form(socket, _child, _link), do: assign(socket, sp_nest: nil)

  defp prepare_subproject_render(assigns) do
    assigns = assign(assigns, :dom, dom_key(assigns))

    panes =
      [
        {"subproject", gettext("Sub-project")},
        {"schedule", gettext("Schedule")},
        assigns[:statuses_available] && {"settings", gettext("Settings")}
      ]
      |> Enum.filter(& &1)

    assign(assigns,
      sp_panes: panes,
      sp_pane: open_pane(panes, assigns[:form_pane]),
      sp_pane_errors:
        error_panes([assigns.sp_form.source], %{
          name: "subproject",
          description: "subproject",
          assigned_person_uuid: "subproject",
          assigned_team_uuid: "subproject",
          assigned_department_uuid: "subproject",
          status_entity_uuid: "settings"
        })
    )
  end

  # The sub-project's name as typed, in the language whose tab is open.
  defp subproject_title(assigns) do
    typed =
      assigns.sp_form.source
      |> Ecto.Changeset.apply_changes()
      |> Project.localized_name(assigns[:current_lang])

    case typed && String.trim(typed) do
      name when is_binary(name) and name != "" -> name
      _ -> ""
    end
  end

  defp single_pick([uuid]), do: uuid
  defp single_pick(_), do: ""

  attr(:dom, :string, required: true)
  attr(:q, :string, required: true)
  attr(:picked, :list, required: true)
  attr(:tasks, :list, required: true)
  attr(:recent, :list, required: true)
  attr(:often, :list, required: true)
  attr(:lang, :string, default: nil)

  # The "From library" picker: search, then Recent / Often used / A–Z;
  # typing replaces the blocks with one list of matches.
  defp library_picker(assigns) do
    form_id = "assignment-library-form-#{assigns.dom}"

    matches =
      if String.trim(assigns.q) == "",
        do: nil,
        else: LibrarySearch.filter(assigns.tasks, assigns.q, assigns.lang)

    assigns =
      assign(assigns,
        form_id: form_id,
        matches: matches,
        groups: if(matches, do: [], else: LibrarySearch.alphabetical(assigns.tasks, assigns.lang))
      )

    ~H"""
    <div id={"library-picker-#{@dom}"} class="flex flex-col gap-2">
      <label class="input input-bordered input-sm flex items-center gap-2 w-full">
        <.icon name="hero-magnifying-glass" class="w-4 h-4 opacity-60" />
        <input
          type="search"
          id={"library-search-#{@dom}"}
          name="library_q"
          form={@form_id}
          value={@q}
          placeholder={gettext("Search the library")}
          autocomplete="off"
          phx-debounce="150"
          phx-mounted={JS.focus()}
          class="grow"
        />
      </label>
      <p :if={@picked != []} class="text-xs text-base-content/70">
        {ngettext("1 task ticked", "%{count} tasks ticked", length(@picked))}
      </p>
      <div class="max-h-80 overflow-y-auto rounded-box border border-base-200 p-1 [scrollbar-gutter:stable]">
        <%= if @matches do %>
          <p :if={@matches == []} class="text-sm text-base-content/60 p-2">
            {gettext("No library task matches “%{q}”.", q: @q)}
          </p>
          <.library_rows id={"library-matches-#{@dom}"} tasks={@matches} picked={@picked} lang={@lang} />
        <% else %>
          <.library_block :if={@recent != []} title={gettext("Recent")} id={"library-recent-#{@dom}"}>
            <.library_rows id={"library-recent-rows-#{@dom}"} tasks={@recent} picked={@picked} lang={@lang} />
          </.library_block>
          <.library_block :if={@often != []} title={gettext("Often used")} id={"library-often-#{@dom}"}>
            <.library_rows id={"library-often-rows-#{@dom}"} tasks={@often} picked={@picked} lang={@lang} />
          </.library_block>
          <.library_block
            :for={{letter, tasks} <- @groups}
            title={letter}
            id={"library-letter-#{@dom}-#{letter_id(letter)}"}
          >
            <.library_rows id={"library-letter-rows-#{@dom}-#{letter_id(letter)}"} tasks={tasks} picked={@picked} lang={@lang} />
          </.library_block>
        <% end %>
      </div>
    </div>
    """
  end

  defp letter_id(letter), do: letter |> :erlang.phash2() |> Integer.to_string()

  attr(:title, :string, required: true)
  attr(:id, :string, required: true)
  slot(:inner_block, required: true)

  defp library_block(assigns) do
    ~H"""
    <section id={@id} class="mb-1">
      <h4 class="sticky top-0 z-[1] bg-base-100 px-2 py-1 text-xs font-semibold uppercase tracking-wide text-base-content/60">
        {@title}
      </h4>
      {render_slot(@inner_block)}
    </section>
    """
  end

  attr(:id, :string, required: true)
  attr(:tasks, :list, required: true)
  attr(:picked, :list, required: true)
  attr(:lang, :string, default: nil)

  defp library_rows(assigns) do
    ~H"""
    <ul id={@id} class="flex flex-col">
      <li :for={t <- @tasks}>
        <%!-- A button, not a native checkbox: LiveView locks a clicked input
             while its event is in flight and drops the server's `checked` on
             it, so the box the person clicked stayed empty. The server alone
             draws the tick (daisyUI styles `aria-checked`). --%>
        <button
          type="button"
          role="checkbox"
          aria-checked={to_string(t.uuid in @picked)}
          class="flex w-full items-center gap-2 rounded px-2 py-1 text-left cursor-pointer hover:bg-base-200"
          phx-click="library_toggle"
          phx-value-uuid={t.uuid}
          data-library-task={t.uuid}
        >
          <span class="checkbox checkbox-sm" aria-hidden="true" aria-checked={to_string(t.uuid in @picked)}></span>
          <span class="flex-1 min-w-0 truncate text-sm">{Task.localized_title(t, @lang)}</span>
          <span
            :if={t.uuid in @picked}
            class="badge badge-sm badge-primary"
            title={gettext("Added in this order")}
          >
            {Enum.find_index(@picked, &(&1 == t.uuid)) + 1}
          </span>
        </button>
      </li>
    </ul>
    """
  end

  # What the task form's template reads besides the assigns: which tabs it
  # has and which is open, which hold an error, and which parts show.
  defp prepare_task_render(assigns) do
    assigns = assign(assigns, :dom, dom_key(assigns))
    project = assigns.project

    assigns =
      assign(assigns,
        portal?:
          assigns.live_action == :edit and project.uuid not in [nil, ""] and
            portal_enabled?(project),
        show_times?: show_times?(assigns),
        title_field?:
          (assigns.live_action == :new and assigns.task_mode == "new") or
            (assigns.live_action == :edit and assigns[:title_editable?] == true),
        translated?: assigns.multilang_enabled and match?([_, _ | _], assigns.language_tabs)
      )

    panes = form_panes(assigns)
    open? = Enum.any?(panes, &(elem(&1, 0) == assigns.form_pane))

    assign(assigns,
      panes: panes,
      pane: if(open?, do: assigns.form_pane, else: "task"),
      pane_errors: error_panes(assigns)
    )
  end

  defp public_board?(project) do
    case PhoenixKitProjects.Portal.get_portal(project.uuid) do
      %{access_mode: "public"} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp portal_enabled?(project) do
    PhoenixKitProjects.Extensions.enabled?(project, "portal")
  rescue
    _ -> false
  end
end
