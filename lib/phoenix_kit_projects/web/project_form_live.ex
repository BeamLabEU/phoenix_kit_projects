defmodule PhoenixKitProjects.Web.ProjectFormLive do
  @moduledoc "Create or edit a project."

  use PhoenixKitWeb, :live_view
  use PhoenixKitAI.Components.AITranslate.Embed
  use Gettext, backend: PhoenixKitProjects.Gettext
  use PhoenixKitProjects.Web.Components

  import PhoenixKitWeb.Components.MultilangForm

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Values
  alias PhoenixKitAI.Components.AITranslate.FormGlue
  alias PhoenixKitProjects.{Activity, Archetypes, Errors, Features, L10n, Paths, Projects}
  alias PhoenixKitProjects.{Extensions, Members, Statuses}
  alias PhoenixKitProjects.Extensions.ConfigOptions
  alias PhoenixKitProjects.Schemas.Project
  alias PhoenixKitProjects.Web.Helpers, as: WebHelpers

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
      |> WebHelpers.assign_embed_user(session)
      |> WebHelpers.attach_open_embed_hook()
      |> apply_action(live_action, resolved_params)
      |> assign_fx_and_presets()
      |> assign_creation_state()
      |> assign_assignee_state()
      |> assign_status_preview()
      |> assign_status_mode()
      |> assign_ai_translate()

    {:ok, socket}
  end

  # ── Creation state (the 2026-08-06 five-AI redesign) ─────────────
  #
  # :new carries the starting-point recipe state: the archetype cards,
  # per-extension checked/config state, the tasks-extension flag
  # checklist, pending member invites, and the template preview. The
  # union rule throughout: archetype + template SEED, the user's explicit
  # toggles OVERRIDE (extension overrides survive an archetype switch;
  # flag tweaks soft-reset with it — Grok's semantics).
  defp assign_creation_state(%{assigns: %{live_action: :new}} = socket) do
    archetype_key = Archetypes.default_key()

    socket
    |> assign(
      archetypes: Archetypes.list(),
      archetype_key: archetype_key,
      ext_types: creation_ext_types(),
      flag_defs: creation_flag_defs(),
      ext_overrides: %{},
      ext_configs: %{},
      invites: [],
      invite_email: "",
      invite_role: "member",
      template_preview: nil,
      template_ref: nil,
      customized?: false,
      top_blocks: Features.creation_top_blocks()
    )
    |> seed_capability_states()
    |> then(fn s ->
      # The ?template= deep link (the show page's "Use template" button)
      # seeds at mount like a selection would — previously it mounted
      # unseeded and healed only on the first validate.
      case s.assigns.selected_template do
        uuid when is_binary(uuid) and uuid != "" -> apply_template_selection(s, uuid)
        _ -> s
      end
    end)
  end

  defp assign_creation_state(socket) do
    assign(socket,
      archetypes: [],
      archetype_key: nil,
      ext_types: [],
      flag_defs: [],
      ext_overrides: %{},
      ext_configs: %{},
      invites: [],
      invite_email: "",
      invite_role: "member",
      template_preview: nil,
      template_ref: nil,
      customized?: false,
      top_blocks: []
    )
  end

  # Every AVAILABLE extension except tasks (whose on/off rides the
  # preset; a task-less project is a Modules-panel edge case, not a
  # creation-page decision).
  defp creation_ext_types do
    Extensions.list_types()
    |> Enum.filter(&Extensions.Registry.available?/1)
    |> Enum.reject(&(&1.key == "tasks"))
  rescue
    _ -> []
  end

  # The tasks extension's flag catalog — the Customize checklist.
  defp creation_flag_defs do
    Features.catalog_by_extension()
    |> Enum.find_value([], fn {ext, flags} -> if ext.key == "tasks", do: flags end)
  rescue
    _ -> []
  end

  # (Re)computes checked states from the current archetype + template +
  # explicit extension overrides. Flag layering (the union rule, panel-
  # hardened): archetype preset → TEMPLATE feature pins on top (what the
  # template author froze is the user's visible truth) — an archetype/
  # template switch soft-resets them. Template extension CONFIGS seed the
  # inline fields too (they'd otherwise render blank and clobber the
  # carried values on save — the panel's #2).
  defp seed_capability_states(socket) do
    {flag_states, ext_states} = compute_seed_states(socket.assigns, socket.assigns.archetype_key)

    template_configs =
      case socket.assigns.template_preview do
        %{} = preview -> Map.get(preview, :extension_configs, %{})
        _ -> %{}
      end

    # Template configs are the base; anything the user already typed wins.
    ext_configs = Map.merge(template_configs, socket.assigns.ext_configs)

    assign(socket, flag_states: flag_states, ext_states: ext_states, ext_configs: ext_configs)
  end

  # The union rule as a PURE function of (assigns, archetype key) — the
  # single source for the live seed AND the per-archetype receipt
  # variants (which show what SWITCHING to that card would produce).
  defp compute_seed_states(assigns, archetype_key) do
    archetype = Archetypes.get(archetype_key)
    preset = archetype && Features.get_preset(archetype.preset)
    preset_flags = (preset && preset.flags) || %{}

    {template_exts, template_flags} =
      case assigns.template_preview do
        %{extensions: exts} = preview -> {exts, Map.get(preview, :features, %{})}
        _ -> {[], %{}}
      end

    flag_states =
      Map.new(assigns.flag_defs, fn flag ->
        seeded = Map.get(preset_flags, flag.key, flag.default)
        {flag.key, Map.get(template_flags, flag.key, seeded)}
      end)

    seed_exts = ((archetype && archetype.extensions) || []) ++ template_exts

    ext_states =
      Map.new(assigns.ext_types, fn ext ->
        seeded = ext.default_enabled or ext.key in seed_exts

        {ext.key, Map.get(assigns.ext_overrides, ext.key, seeded)}
      end)

    {flag_states, ext_states}
  end

  # Hub gate map + creation presets. :edit resolves the real project's
  # gates; :new uses catalog defaults (what a fresh project would get) and
  # offers the preset picker, defaulted from the site-wide setting.
  defp assign_fx_and_presets(socket) do
    case socket.assigns[:project] do
      %Project{uuid: uuid} = project when is_binary(uuid) ->
        assign(socket, fx: Features.gates(project), presets: [], preset_key: nil)

      _ ->
        assign(socket,
          fx: Features.default_gates(),
          presets: Features.presets(),
          preset_key: Features.default_preset_key()
        )
    end
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

  # ── Invites (pending seats, applied after create) ────────────────

  def handle_event("add_invite", _params, %{assigns: %{live_action: :new}} = socket) do
    email = String.trim(socket.assigns.invite_email || "")

    cond do
      email == "" ->
        {:noreply, socket}

      Enum.any?(socket.assigns.invites, &(&1.email == email)) ->
        {:noreply, assign(socket, invite_email: "")}

      true ->
        case find_user(email) do
          nil ->
            {:noreply, put_flash(socket, :error, gettext("No account with that email address."))}

          user ->
            if user.uuid == Activity.actor_uuid(socket) do
              # The creator is seated as owner automatically.
              {:noreply, assign(socket, invite_email: "")}
            else
              invite = %{uuid: user.uuid, email: email, role: socket.assigns.invite_role}

              {:noreply,
               assign(socket,
                 invites: socket.assigns.invites ++ [invite],
                 invite_email: ""
               )}
            end
        end
    end
  end

  def handle_event("add_invite", _params, socket), do: {:noreply, socket}

  def handle_event("remove_invite", %{"uuid" => uuid}, socket) do
    {:noreply, assign(socket, invites: Enum.reject(socket.assigns.invites, &(&1.uuid == uuid)))}
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
  # The changeset is still rebuilt so reactive bits stay in sync
  # with form state.
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
     |> track_creation_state(params)
     |> assign_form(cs)
     |> assign_status_preview()}
  end

  def handle_event("save", %{"project" => attrs} = params, socket) do
    if socket.assigns.ai_in_flight == [] do
      template_uuid = Map.get(params, "template_uuid", nil) |> Values.blank_to_nil()
      assign_type = Map.get(params, "assign_type", socket.assigns.assign_type)

      # Save-time gate re-resolution (panel R3-4): a mid-edit toggle in
      # another session binds THIS submit, not the mount-time snapshot.
      # (:new has no project row yet — catalog defaults, unchanged.)
      fx = save_time_fx(socket)
      socket = assign(socket, fx: fx)

      attrs =
        merge_attrs(attrs, socket)
        |> clear_other_assignees(assign_type)
        |> maybe_apply_status_mode(params, socket.assigns.project, fx)
        |> strip_gated_project_attrs(fx)

      socket =
        assign(socket, preset_key: Map.get(params, "project_preset", socket.assigns[:preset_key]))

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
    if save_time_fx(socket).statuses do
      do_generate_default_statuses(socket)
    else
      {:noreply,
       put_flash(socket, :error, gettext("This feature is turned off for this project."))}
    end
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, WebHelpers.close_or_navigate(socket, Paths.projects())}
  end

  # ── Creation-state tracking (:new only; no-op on :edit) ──────────

  defp track_creation_state(%{assigns: %{live_action: :new}} = socket, params) do
    # A template/archetype switch RESEEDS the checked states — the
    # checkbox params in that same cycle reflect the PRE-switch render,
    # so applying them would immediately undo the reseed (and mint
    # spurious overrides). Skip diff-tracking on switch cycles.
    switched? = template_switching?(socket, params) or archetype_switching?(socket, params)

    socket
    |> track_template(params)
    |> track_archetype(params)
    |> then(fn s ->
      if switched?, do: s, else: s |> track_extensions(params) |> track_flags(params)
    end)
    |> assign(
      invite_email: Map.get(params, "invite_email", socket.assigns.invite_email),
      invite_role: valid_invite_role(Map.get(params, "invite_role", socket.assigns.invite_role))
    )
  end

  defp track_creation_state(socket, _params), do: socket

  # Compared against template_ref, NOT the preview: a bogus/deleted uuid
  # leaves the preview nil, and comparing against it made EVERY validate a
  # "switch" — permanently dead checkbox tracking + a preview query per
  # keystroke (the panel's stuck-guard find).
  defp template_switching?(socket, params) do
    case Map.get(params, "template_uuid") do
      nil -> false
      value -> value != (socket.assigns.template_ref || "")
    end
  end

  defp archetype_switching?(socket, params) do
    case Map.get(params, "archetype") do
      nil -> false
      key -> key != socket.assigns.archetype_key and Archetypes.get(key) != nil
    end
  end

  defp track_template(socket, params) do
    case Map.get(params, "template_uuid") do
      nil -> socket
      value -> apply_template_selection(socket, value)
    end
  end

  # Shared by validate-tracking AND the mount-time ?template= deep link
  # (which previously mounted unseeded). template_ref records what we
  # PROCESSED, valid or not — the switching? comparison keys on it.
  defp apply_template_selection(socket, value) do
    cond do
      value == (socket.assigns.template_ref || "") ->
        socket

      value == "" ->
        socket
        |> assign(template_ref: nil, template_preview: nil)
        |> seed_capability_states()

      true ->
        preview = Projects.template_preview(value)

        socket
        |> assign(
          template_ref: value,
          template_preview: preview && Map.put(preview, :uuid, value)
        )
        |> seed_capability_states()
    end
  end

  # Archetype switch: soft-reset the flags to the new preset, keep the
  # user's explicit EXTENSION overrides (Grok's semantics).
  defp track_archetype(socket, %{"archetype" => key}) do
    if is_binary(key) and key != socket.assigns.archetype_key and Archetypes.get(key) do
      socket |> assign(archetype_key: key) |> seed_capability_states()
    else
      socket
    end
  end

  defp track_archetype(socket, _params), do: socket

  # Extension checkbox diffs become explicit overrides (they survive an
  # archetype switch); config fields merge per extension.
  defp track_extensions(socket, params) do
    ext_params = Map.get(params, "ext", %{})

    {states, overrides} =
      Enum.reduce(
        socket.assigns.ext_types,
        {socket.assigns.ext_states, socket.assigns.ext_overrides},
        fn ext, {states, overrides} ->
          case Map.get(ext_params, ext.key) do
            nil ->
              {states, overrides}

            value ->
              checked = value == "true"

              if checked == Map.get(states, ext.key) do
                {states, overrides}
              else
                {Map.put(states, ext.key, checked), Map.put(overrides, ext.key, checked)}
              end
          end
        end
      )

    configs =
      params
      |> Map.get("ext_config", %{})
      |> Enum.reduce(socket.assigns.ext_configs, fn {key, fields}, acc ->
        if is_map(fields), do: Map.put(acc, key, fields), else: acc
      end)

    assign(socket,
      ext_states: states,
      ext_overrides: overrides,
      ext_configs: configs,
      customized?: socket.assigns.customized? or overrides != socket.assigns.ext_overrides
    )
  end

  defp track_flags(socket, params) do
    flag_params = Map.get(params, "flag", %{})

    if flag_params == %{} do
      socket
    else
      states =
        Map.new(socket.assigns.flag_states, fn {key, current} ->
          case Map.get(flag_params, key) do
            nil -> {key, current}
            value -> {key, value == "true"}
          end
        end)

      assign(socket,
        flag_states: states,
        customized?: socket.assigns.customized? or states != socket.assigns.flag_states
      )
    end
  end

  defp valid_invite_role(role) when role in ~w(manager member viewer), do: role
  defp valid_invite_role(_), do: "member"

  defp find_user(email) do
    Auth.get_user_by_email(email)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  # {:ai_translation, ...} events folded into the form by `use ...AITranslate.Embed`.

  defp merge_attrs(attrs, socket) do
    in_flight = WebHelpers.in_flight_record(socket, :form, :project)

    attrs
    |> WebHelpers.normalize_datetime_local_attrs(["scheduled_start_date"])
    |> WebHelpers.merge_translations_attrs(in_flight, Project.translatable_fields())
  end

  defp do_generate_default_statuses(socket) do
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

  defp save_time_fx(socket) do
    case socket.assigns[:project] do
      %Project{uuid: uuid} when is_binary(uuid) -> Features.gates(socket.assigns.project.uuid)
      _ -> Features.default_gates()
    end
  end

  # The status translation-mode fold also writes into settings — it rides
  # the same statuses gate as the source field (panel R3-5).
  defp maybe_apply_status_mode(attrs, params, project, fx) do
    if fx.statuses, do: apply_status_mode_to_attrs(attrs, params, project), else: attrs
  end

  # Server-side mate of the render gates: with `statuses` off a crafted
  # submit can't pick a status source; with `assignees` off it can't smuggle
  # project-assignee fields past the hidden picker.
  defp strip_gated_project_attrs(attrs, fx) do
    attrs
    |> then(fn a -> if fx.statuses, do: a, else: Map.drop(a, ~w(status_entity_uuid)) end)
    |> then(fn a ->
      if fx.assignees,
        do: a,
        else: Map.drop(a, ~w(assigned_team_uuid assigned_department_uuid assigned_person_uuid))
    end)
    |> then(fn a -> if fx.scheduling, do: a, else: Map.drop(a, ~w(counts_weekends)) end)
  end

  # Applies the creation-page capability choices after a successful
  # create (both the scratch AND template paths — the old preset apply
  # silently skipped templates). Layering: the template's carried
  # settings/extensions are already on the project; these are the FORM's
  # effective states (archetype seed + explicit user overrides), so the
  # user's visible truth wins. Each unit is isolated best-effort (one
  # failing extension must not skip the rest or the invites — a panel
  # find); nothing here can undo the successful create.
  defp apply_creation_capabilities(socket, project) do
    actor_uuid = Activity.actor_uuid(socket)

    # MINIMAL-DIFF flag write: only flags differing from their catalog
    # default get pinned. Writing the whole rendered map froze catalog/
    # site-default drift for untouched flags (a panel find) — the old
    # "standard preset writes nothing" inheritance behavior is preserved.
    flags_to_pin =
      socket.assigns.flag_defs
      |> Enum.filter(fn flag ->
        Map.get(socket.assigns.flag_states, flag.key, flag.default) != flag.default
      end)
      |> Map.new(fn flag -> {flag.key, Map.get(socket.assigns.flag_states, flag.key)} end)

    best_effort("set_flags", fn ->
      if flags_to_pin != %{} do
        Features.set_flags(project, flags_to_pin, actor_uuid: actor_uuid)
      end
    end)

    # Reconcile extensions to the rendered checklist: enable checked
    # (with any inline config — BLANK values dropped so an untouched
    # empty field never clobbers a template-carried config), disable
    # unchecked-but-on (default_enabled or template-carried).
    Enum.each(socket.assigns.ext_types, fn ext ->
      best_effort("ext #{ext.key}", fn ->
        desired = Map.get(socket.assigns.ext_states, ext.key, false)

        config =
          socket.assigns.ext_configs
          |> Map.get(ext.key, %{})
          |> Map.reject(fn {_k, v} -> v in [nil, ""] end)

        cond do
          desired ->
            Extensions.enable(project.uuid, ext.key, config: config, actor_uuid: actor_uuid)

          Extensions.enabled?(project.uuid, ext.key) ->
            Extensions.disable(project.uuid, ext.key, actor_uuid: actor_uuid)

          true ->
            :ok
        end
      end)
    end)

    # Seat the pending invites (the creator's owner seat already exists).
    Enum.each(socket.assigns.invites, fn invite ->
      best_effort("invite #{invite.email}", fn ->
        Members.add_member(project, invite.uuid, role: invite.role, actor_uuid: actor_uuid)
      end)
    end)

    :ok
  end

  defp best_effort(label, fun) do
    case fun.() do
      {:error, reason} ->
        Logger.warning("[Projects] creation apply (#{label}) failed: #{inspect(reason)}")
        :ok

      _ ->
        :ok
    end
  rescue
    e ->
      Logger.warning("[Projects] creation apply (#{label}) raised: #{Exception.message(e)}")
      :ok
  catch
    kind, reason ->
      Logger.warning("[Projects] creation apply (#{label}) #{kind}: #{inspect(reason)}")
      :ok
  end

  defp save(socket, :new, attrs, nil) do
    case Projects.create_project(attrs, actor_uuid: Activity.actor_uuid(socket)) do
      {:ok, project} ->
        apply_creation_capabilities(socket, project)

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
    case Projects.create_project_from_template(template_uuid, attrs,
           actor_uuid: Activity.actor_uuid(socket)
         ) do
      {:ok, project} ->
        apply_creation_capabilities(socket, project)

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

  # ── Creation-page render helpers ─────────────────────────────────

  # Archetype names/descriptions are catalog DATA (plain strings) —
  # runtime-translated like the dashboards widget catalog.
  defp translate_catalog_string(s) when is_binary(s),
    do: Gettext.gettext(PhoenixKitProjects.Gettext, s)

  defp translate_catalog_string(s), do: s

  defp ext_name(ext_types, key) do
    Enum.find_value(ext_types, key, fn ext -> if ext.key == key, do: ext.name end)
  end

  defp ext_config_value(configs, ext_key, field_key) do
    configs |> Map.get(ext_key, %{}) |> Map.get(field_key, "")
  end

  # The receipt line for ONE archetype: what Create would produce if that
  # card were the selection (simulated via the shared seed math). One
  # variant renders per card, CSS-revealed by the checked radio — so the
  # receipt answers a card click INSTANTLY; server re-renders refine all
  # variants when the template/customize state changes.
  defp creation_summary(assigns, archetype_key) do
    archetype = Archetypes.get(archetype_key)
    {flag_states, ext_states} = compute_seed_states(assigns, archetype_key)
    current? = archetype_key == assigns.archetype_key

    kind =
      case {archetype, current? and assigns.customized?} do
        {nil, _} -> gettext("Custom")
        {a, true} -> translate_catalog_string(a.name) <> " · " <> gettext("customized")
        {a, false} -> translate_catalog_string(a.name)
      end

    ons =
      assigns.ext_types
      |> Enum.filter(&ext_states[&1.key])
      |> Enum.map_join(", ", & &1.name)

    statuses =
      cond do
        flag_states["statuses"] == false -> nil
        assigns.form[:status_entity_uuid].value in [nil, ""] -> gettext("Statuses: site default")
        true -> gettext("Statuses: custom set")
      end

    template =
      case assigns.template_preview do
        %{task_count: n} -> gettext("Template: %{count} tasks", count: n)
        _ -> nil
      end

    [
      kind,
      if(ons != "", do: gettext("With: %{list}", list: ons)),
      statuses,
      template
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  # LITERAL class strings per archetype key — Tailwind's scanner needs
  # them verbatim in source (an interpolated variant never compiles).
  defp receipt_reveal_class("quick_todo"),
    do: "hidden group-has-[[data-arch=quick-todo]:checked]/kind:block"

  defp receipt_reveal_class("standard"),
    do: "hidden group-has-[[data-arch=standard]:checked]/kind:block"

  defp receipt_reveal_class("client_hub"),
    do: "hidden group-has-[[data-arch=client-hub]:checked]/kind:block"

  defp receipt_reveal_class("public_intake"),
    do: "hidden group-has-[[data-arch=public-intake]:checked]/kind:block"

  defp receipt_reveal_class(_), do: "hidden"

  # ── Creation-page blocks (promotable via Settings → Projects) ──────

  attr(:templates, :list, required: true)
  attr(:selected_template, :any, required: true)
  attr(:template_preview, :any, required: true)
  attr(:ext_types, :list, required: true)

  defp template_block(assigns) do
    ~H"""
    <.select
      name="template_uuid"
      label={gettext("From template (optional)")}
      value={@selected_template}
      options={Enum.map(@templates, &{&1.name, &1.uuid})}
      prompt={gettext("Start from scratch")}
    />

    <%!-- What the template brings (server-rendered preview). --%>
    <div :if={@template_preview} class="rounded-lg border border-base-200 bg-base-200/40 p-3 text-xs">
      <p class="font-semibold">
        {gettext("%{count} tasks from this template", count: @template_preview.task_count)}
      </p>
      <p :if={@template_preview.sample_titles != []} class="mt-1 opacity-70">
        {Enum.join(@template_preview.sample_titles, " · ")}<span :if={@template_preview.task_count > 5}> …</span>
      </p>
      <p :if={@template_preview.extensions != []} class="mt-1 opacity-70">
        {gettext("Brings extensions:")} {Enum.map_join(@template_preview.extensions, ", ", &ext_name(@ext_types, &1))}
      </p>
      <p class="mt-1 opacity-50">
        {gettext("Template capabilities carry over; your choices below win.")}
      </p>
    </div>
    """
  end

  attr(:form, :any, required: true)

  defp start_block(assigns) do
    ~H"""
    <%!-- The date field reveals via CSS the instant "Scheduled" is
         picked (group-has on the option) — no round trip. --%>
    <div class="group/start flex flex-col gap-3">
      <.select
        field={@form[:start_mode]}
        label={gettext("Start")}
        options={[
          {gettext("Immediately (set up tasks first)"), "immediate"},
          {gettext("Scheduled date"), "scheduled"}
        ]}
      />
      <div class="hidden group-has-[option[value=scheduled]:checked]/start:block">
        <.input
          field={@form[:scheduled_start_date]}
          label={gettext("Start date and time")}
          type="datetime-local"
        />
      </div>
    </div>
    """
  end

  attr(:statuses_available, :boolean, required: true)
  attr(:form, :any, required: true)
  attr(:status_entities, :list, required: true)
  attr(:status_preview, :list, required: true)
  attr(:status_translation_mode, :string, required: true)

  defp statuses_block(assigns) do
    ~H"""
    <.workflow_status_fields
      statuses_available={@statuses_available}
      field={@form[:status_entity_uuid]}
      status_entities={@status_entities}
      status_preview={@status_preview}
      status_translation_mode={@status_translation_mode}
      locked={false}
    />
    <p class="text-xs opacity-50">
      {gettext("Statuses lock in when the project starts.")}
    </p>
    """
  end

  attr(:invites, :list, required: true)
  attr(:invite_email, :string, required: true)
  attr(:invite_role, :string, required: true)
  attr(:flag_states, :map, required: true)
  attr(:assign_type, :string, required: true)
  attr(:form, :any, required: true)
  attr(:department_options, :list, required: true)
  attr(:team_options, :list, required: true)
  attr(:person_options, :list, required: true)

  defp people_block(assigns) do
    ~H"""
    <div class="flex flex-col gap-3">
      <p class="text-xs opacity-60">
        <span class="badge badge-ghost badge-sm">{gettext("You — Owner")}</span>
      </p>

      <div class="flex flex-wrap items-end gap-2">
        <div class="grow max-w-xs">
          <.input
            type="email"
            name="invite_email"
            value={@invite_email}
            label={gettext("Email")}
            placeholder={gettext("person@example.com")}
            class="input-sm"
            phx-debounce="300"
          />
        </div>
        <div class="w-32">
          <.select
            name="invite_role"
            value={@invite_role}
            label={gettext("Role")}
            class="select-sm"
            options={[
              {gettext("Member"), "member"},
              {gettext("Manager"), "manager"},
              {gettext("Viewer"), "viewer"}
            ]}
          />
        </div>
        <button type="button" phx-click="add_invite" class="btn btn-ghost btn-sm gap-1">
          <.icon name="hero-user-plus" class="w-4 h-4" /> {gettext("Add")}
        </button>
      </div>

      <div :if={@invites != []} class="flex flex-wrap gap-1">
        <span :for={invite <- @invites} class="badge badge-outline gap-1">
          {invite.email} · {invite.role}
          <button
            type="button"
            phx-click="remove_invite"
            phx-value-uuid={invite.uuid}
            class="ml-1 opacity-60 hover:opacity-100"
            aria-label={gettext("Remove")}
          >
            ✕
          </button>
        </span>
      </div>

      <%= if @flag_states["assignees"] != false do %>
        <%!-- The matching picker reveals via CSS the instant the
             type is chosen (group-has on the option); the server
             still nulls non-matching uuids at save. --%>
        <div class="group/assign flex flex-col gap-2 border-t border-base-200 pt-2">
          <.select
            name="assign_type"
            label={gettext("Responsible (optional)")}
            value={@assign_type}
            options={[
              {gettext("Nobody"), ""},
              {gettext("Department"), "department"},
              {gettext("Team"), "team"},
              {gettext("Person"), "person"}
            ]}
          />
          <div class="hidden group-has-[option[value=department]:checked]/assign:block">
            <.select field={@form[:assigned_department_uuid]} label={gettext("Department")} options={@department_options} prompt={gettext("Select department")} />
          </div>
          <div class="hidden group-has-[option[value=team]:checked]/assign:block">
            <.select field={@form[:assigned_team_uuid]} label={gettext("Team")} options={@team_options} prompt={gettext("Select team")} />
          </div>
          <div class="hidden group-has-[option[value=person]:checked]/assign:block">
            <.select field={@form[:assigned_person_uuid]} label={gettext("Person")} options={@person_options} prompt={gettext("Select person")} />
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # The multilang name+description card — the house pattern shared by
  # BOTH actions (Max: every create form offers all languages from the
  # start). One definition so the two branches can never drift.
  attr(:form, :any, required: true)
  attr(:multilang_enabled, :boolean, required: true)
  attr(:language_tabs, :list, required: true)
  attr(:current_lang, :string, required: true)
  attr(:primary_language, :string, required: true)
  attr(:ai_in_flight, :list, required: true)
  attr(:ai_translate, :any, required: true)

  defp translatable_card(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow">
          <%!-- Bundled tabs + AI row (phoenix_kit_ai's canonical placement;
            the border-b separator converges away — see the PR note). --%>
          <.ai_multilang_tabs
            multilang_enabled={@multilang_enabled}
            language_tabs={@language_tabs}
            current_lang={@current_lang}
            ai_translate={@ai_translate}
          />

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
    """
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
        <%!-- ══ :new — the 2026-08-06 redesign: basics, starting-point
             cards, capability customize, statuses, invites. ══ --%>
        <%= if @live_action == :new do %>
          <%!-- The house pattern: the SAME multilang tabs card every other
               create form uses — all languages fillable from the start. --%>
          <.translatable_card
            form={@form}
            multilang_enabled={@multilang_enabled}
            language_tabs={@language_tabs}
            current_lang={@current_lang}
            primary_language={@primary_language}
            ai_in_flight={@ai_in_flight}
            ai_translate={FormGlue.ai_translate_config(assigns)}
          />

          <%!-- Starting point: outcome cards bundling preset + extension
               seeds (the panel's strongest consensus). The radio is real
               and visible — works without JS. --%>
          <div class="card bg-base-100 shadow">
            <div class="group/kind card-body flex flex-col gap-3">
              <div>
                <h2 class="text-sm font-semibold">{gettext("Choose a starting point")}</h2>
                <p class="text-xs opacity-50">
                  {gettext("Pick the closest fit — you can change everything below.")}
                </p>
              </div>
              <div class="grid grid-cols-1 gap-2 sm:grid-cols-2">
                <%!-- The quorum card face: icon + intent name, radio far
                     right, description, two plain-language outcome lines
                     (the internal-vocabulary chips are gone). Selection
                     highlight is PURE CSS (has-[:checked]) — instant; the
                     server round-trip only reseeds Customize. --%>
                <label
                  :for={a <- @archetypes}
                  class={[
                    "flex cursor-pointer flex-col gap-1 rounded-lg border p-3 transition-colors",
                    "border-base-300 hover:border-base-content/30",
                    "has-[:checked]:border-primary has-[:checked]:bg-primary/5",
                    "has-[:checked]:ring-1 has-[:checked]:ring-primary"
                  ]}
                >
                  <span class="flex items-center justify-between gap-2">
                    <span class="flex min-w-0 items-center gap-2">
                      <.icon name={a.icon} class="w-5 h-5 opacity-70" />
                      <span class="truncate text-sm font-semibold">
                        {translate_catalog_string(a.name)}
                      </span>
                    </span>
                    <input
                      type="radio"
                      name="archetype"
                      value={a.key}
                      checked={@archetype_key == a.key}
                      data-arch={String.replace(a.key, "_", "-")}
                      class="radio radio-primary radio-xs shrink-0"
                    />
                  </span>
                  <span class="text-xs opacity-60">{translate_catalog_string(a.description)}</span>
                  <span class="mt-1 flex flex-col gap-0.5">
                    <span :for={outcome <- a.outcomes} class="flex items-center gap-1 text-xs opacity-50">
                      <.icon name="hero-check" class="w-3 h-3 shrink-0" />
                      {translate_catalog_string(outcome)}
                    </span>
                  </span>
                </label>
              </div>

              <%!-- The receipt: one PRE-RENDERED line per card, revealed by
                   the checked radio (pure CSS — instant on click; the
                   server refines all variants on template/customize
                   changes). --%>
              <div aria-live="polite" class="flex flex-wrap items-baseline justify-between gap-2 border-t border-base-200 pt-2 text-xs">
                <div class="opacity-70">
                  <p :for={a <- @archetypes} class={receipt_reveal_class(a.key)}>
                    <span class="opacity-60">{gettext("Current setup:")}</span> {creation_summary(assigns, a.key)}
                  </p>
                </div>
                <button
                  type="button"
                  phx-click={Phoenix.LiveView.JS.set_attribute({"open", ""}, to: "#create-customize")}
                  class="link link-hover shrink-0 opacity-60"
                >
                  {gettext("Customize capabilities ↓")}
                </button>
              </div>
            </div>
          </div>

          <%!-- Site-PROMOTED blocks (Settings → Projects → New project
               page): each renders as its own top-level card; everything
               not promoted lives in the Setup options accordion below. --%>
          <div :if={"template" in @top_blocks and @templates != []} id="create-top-template" class="card bg-base-100 shadow">
            <div class="card-body flex flex-col gap-3">
              <.template_block
                templates={@templates}
                selected_template={@selected_template}
                template_preview={@template_preview}
                ext_types={@ext_types}
              />
            </div>
          </div>

          <div :if={"start" in @top_blocks} id="create-top-start" class="card bg-base-100 shadow">
            <div class="card-body flex flex-col gap-3">
              <.start_block form={@form} />
            </div>
          </div>

          <div
            :if={"statuses" in @top_blocks and @flag_states["statuses"] != false}
            id="create-top-statuses"
            class="card bg-base-100 shadow"
          >
            <div class="card-body flex flex-col gap-2">
              <.statuses_block
                statuses_available={@statuses_available}
                form={@form}
                status_entities={@status_entities}
                status_preview={@status_preview}
                status_translation_mode={@status_translation_mode}
              />
            </div>
          </div>

          <div :if={"people" in @top_blocks} id="create-top-people" class="card bg-base-100 shadow">
            <div class="card-body flex flex-col gap-3">
              <h2 class="text-sm font-semibold">
                {gettext("People")}
                <span :if={@invites != []} class="badge badge-ghost badge-xs ml-2">{length(@invites)}</span>
              </h2>
              <.people_block
                invites={@invites}
                invite_email={@invite_email}
                invite_role={@invite_role}
                flag_states={@flag_states}
                assign_type={@assign_type}
                form={@form}
                department_options={@department_options}
                team_options={@team_options}
                person_options={@person_options}
              />
            </div>
          </div>

          <%!-- Customize: flags + extensions with inert-unless-on inline
               config (ZAI's pattern — the whole form submits in one pass
               without JS; unchecked extensions' fields are ignored). --%>
          <.accordion
            id="create-customize"
          >
            <:title>
              {gettext("Customize capabilities")}
              <span :if={@customized?} class="badge badge-ghost badge-xs ml-2">{gettext("custom")}</span>
            </:title>
            <:content>
            <div class="flex flex-col gap-4">
              <div>
                <h3 class="mb-1 text-xs font-semibold uppercase opacity-50">{gettext("Task features")}</h3>
                <div class="grid grid-cols-1 gap-x-6 gap-y-1 sm:grid-cols-2">
                  <label :for={flag <- @flag_defs} class="flex items-center justify-between gap-3 py-0.5">
                    <span class="text-sm">
                      {flag.label}
                      <span :if={flag.requires != []} class="block text-xs opacity-40">
                        {gettext("Needs: %{list}", list: Enum.join(flag.requires, ", "))}
                      </span>
                    </span>
                    <input type="hidden" name={"flag[#{flag.key}]"} value="false" />
                    <input
                      type="checkbox"
                      name={"flag[#{flag.key}]"}
                      value="true"
                      checked={@flag_states[flag.key]}
                      class="toggle toggle-sm"
                    />
                  </label>
                </div>
              </div>

              <div :if={@ext_types != []}>
                <h3 class="mb-1 text-xs font-semibold uppercase opacity-50">{gettext("Extensions")}</h3>
                <div class="flex flex-col gap-2">
                  <%!-- Config reveals via CSS the instant the toggle flips
                       (group-has); the server enforces inert-unless-on at
                       save regardless of what the hidden fields submit. --%>
                  <div :for={ext <- @ext_types} class="group/extbox rounded-lg border border-base-200 p-2">
                    <label class="flex items-center justify-between gap-3">
                      <span class="min-w-0">
                        <span class="flex items-center gap-2 text-sm font-medium">
                          <.icon name={ext.icon} class="w-4 h-4 opacity-60" /> {ext.name}
                        </span>
                        <span :if={ext.description} class="block text-xs opacity-50">{ext.description}</span>
                      </span>
                      <input type="hidden" name={"ext[#{ext.key}]"} value="false" />
                      <input
                        type="checkbox"
                        name={"ext[#{ext.key}]"}
                        value="true"
                        checked={@ext_states[ext.key]}
                        class="toggle toggle-sm"
                      />
                    </label>
                    <div
                      :if={ext.config_schema != []}
                      class="mt-2 hidden flex-wrap gap-2 border-t border-base-200 pt-2 group-has-[:checked]/extbox:flex"
                    >
                      <div :for={field <- ext.config_schema} class="w-full max-w-xs">
                        <.select
                          :if={field.type == :select}
                          name={"ext_config[#{ext.key}][#{field.key}]"}
                          value={ext_config_value(@ext_configs, ext.key, field.key)}
                          label={field[:label] || field.key}
                          class="select-sm"
                          prompt={gettext("—")}
                          options={
                            for opt <-
                                  ConfigOptions.resolve(
                                    field,
                                    ext_config_value(@ext_configs, ext.key, field.key)
                                  ),
                                do: {opt.label, opt.value}
                          }
                        />
                        <.input
                          :if={field.type != :select}
                          type="text"
                          name={"ext_config[#{ext.key}][#{field.key}]"}
                          value={ext_config_value(@ext_configs, ext.key, field.key)}
                          label={field[:label] || field.key}
                          class="input-sm"
                          phx-debounce="300"
                        />
                      </div>
                    </div>
                  </div>
                </div>
                <p class="mt-1 text-xs opacity-40">
                  {gettext("Everything here can be changed later in Modules & features.")}
                </p>
              </div>
            </div>
            </:content>
          </.accordion>

          <%!-- Invite people (collapsed — empty pickers are fast-path noise). --%>
          <.accordion
            :if={"people" not in @top_blocks}
            id="create-people"
          >
            <:title>
              {gettext("People (optional)")}
              <span :if={@invites != []} class="badge badge-ghost badge-xs ml-2">{length(@invites)}</span>
            </:title>
            <:content>
              <.people_block
                invites={@invites}
                invite_email={@invite_email}
                invite_role={@invite_role}
                flag_states={@flag_states}
                assign_type={@assign_type}
                form={@form}
                department_options={@department_options}
                team_options={@team_options}
                person_options={@person_options}
              />
            </:content>
          </.accordion>

          <%!-- Setup options: everything the site didn't promote —
               template, start timing, workflow statuses, schedule math. --%>
          <.accordion
            id="create-setup"
          >
            <:title>{gettext("Setup options")}</:title>
            <:content>
              <div class="flex flex-col gap-4">
                <div :if={"template" not in @top_blocks and @templates != []} class="flex flex-col gap-3">
                  <.template_block
                    templates={@templates}
                    selected_template={@selected_template}
                    template_preview={@template_preview}
                    ext_types={@ext_types}
                  />
                </div>

                <div :if={"start" not in @top_blocks}>
                  <.start_block form={@form} />
                </div>

                <div
                  :if={"statuses" not in @top_blocks and @flag_states["statuses"] != false}
                  class="flex flex-col gap-2 border-t border-base-200 pt-3"
                >
                  <.statuses_block
                    statuses_available={@statuses_available}
                    form={@form}
                    status_entities={@status_entities}
                    status_preview={@status_preview}
                    status_translation_mode={@status_translation_mode}
                  />
                </div>

                <.checkbox
                  :if={@flag_states["scheduling"] != false}
                  field={@form[:counts_weekends]}
                  label={gettext("Count weekends in schedule")}
                  class="checkbox-sm"
                />
              </div>
            </:content>
          </.accordion>

          <div class="flex justify-end gap-2">
            <button type="button" phx-click="cancel" class="btn btn-ghost btn-sm">
              {gettext("Cancel")}
            </button>
            <button type="submit" phx-disable-with={gettext("Creating…")} class="btn btn-primary btn-sm">
              {gettext("Create")}
            </button>
          </div>
        <% end %>

        <%!-- Translatable card: name + description with language tabs.
             Wrapper id keys on @current_lang so morphdom re-mounts the
             inputs when the user switches languages — that's what swaps
             primary-column inputs for `lang_*` JSONB inputs. --%>
        <%= if @live_action == :edit do %>
          <.translatable_card
            form={@form}
            multilang_enabled={@multilang_enabled}
            language_tabs={@language_tabs}
            current_lang={@current_lang}
            primary_language={@primary_language}
            ai_in_flight={@ai_in_flight}
            ai_translate={FormGlue.ai_translate_config(assigns)}
          />
        <% end %>

        <%!-- Non-translatable settings stay outside the wrapper so they
             don't lose state when the user switches languages. --%>
        <div :if={@live_action == :edit} class="card bg-base-100 shadow">
          <div class="card-body flex flex-col gap-3">
            <%!-- Schedule math config — gated on `scheduling` (start mode /
                 date below stay: they're lifecycle, not schedule math). --%>
            <.checkbox
              :if={@fx.scheduling}
              field={@form[:counts_weekends]}
              label={gettext("Count weekends in schedule")}
              class="checkbox-sm"
            />
            <.start_block form={@form} />

            <%!-- Assignee (V128) — same polymorphic team/department/person
                 picker tasks use. Non-translatable, so it lives outside the
                 multilang wrapper. `assign_type` chooses which staff select
                 shows; `clear_other_assignees/2` nulls the rest on change.
                 Feature-gated (Step 4): hidden when `assignees` is off. --%>
            <%= if @fx.assignees do %>
              <%!-- Instant reveal via CSS (group-has) — same pattern as the
                   :new People block; the server still nulls non-matching
                   uuids at save. --%>
              <div class="group/assign flex flex-col gap-2">
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
                <div class="hidden group-has-[option[value=department]:checked]/assign:block">
                  <.select field={@form[:assigned_department_uuid]} label={gettext("Department")} options={@department_options} prompt={gettext("Select department")} />
                </div>
                <div class="hidden group-has-[option[value=team]:checked]/assign:block">
                  <.select field={@form[:assigned_team_uuid]} label={gettext("Team")} options={@team_options} prompt={gettext("Select team")} />
                </div>
                <div class="hidden group-has-[option[value=person]:checked]/assign:block">
                  <.select field={@form[:assigned_person_uuid]} label={gettext("Person")} options={@person_options} prompt={gettext("Select person")} />
                </div>
              </div>
            <% end %>

            <%!-- Workflow-status list selection (entities-backed), via the
                 shared `<.workflow_status_fields>` so projects, templates and
                 sub-projects render an identical section. The source is a
                 pre-start choice — `locked` once the project has started,
                 since its statuses were cemented at `started_at`. --%>
            <%!-- Feature-gated (Step 4): with `statuses` off for this project
                 the whole workflow-status section disappears; the save path
                 strips the field so a crafted submit can't set a source. --%>
            <.workflow_status_fields
              :if={@fx.statuses}
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
