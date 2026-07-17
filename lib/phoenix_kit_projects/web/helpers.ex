defmodule PhoenixKitProjects.Web.Helpers do
  @moduledoc """
  Cross-cutting helpers for the projects module's LiveView layer.

  Two surfaces live here:

  ## Multilang form merge helpers

  `lang_data/2`, `merge_translations_attrs/3`, `in_flight_record/3`,
  `normalize_datetime_local_attrs/2`, `maybe_switch_to_primary_on_error/3`
  — shared between `ProjectFormLive`, `TaskFormLive`, and
  `AssignmentFormLive`. See each function's docstring for the contract.

  ## Embed-mode helpers (PR follow-up to PR #6 audit)

  `assign_embed_state/2`, `assign_embed_user/2`, `navigate_or_open/2`,
  `close_or_navigate/2`, `navigate_after_save/3`, `notify_deleted/3`,
  `attach_open_embed_hook/1`, `embeddable_lv?/1`, plus the
  `decode_embeddable_lv/1` and `decode_session/1` decoders used by the
  shared `open_embed` event handler.

  `assign_embed_user/2` bridges the current user across the `live_render`
  process boundary (the `on_mount` auth hook doesn't run for embedded
  LVs); the host passes `session["current_user_uuid"]`. See its docstring.

  When a host mounts an embedded LV with `session["mode"] = "emit"` +
  `session["pubsub_topic"] = topic`, no `push_navigate` ever fires from
  this module. Instead, UI-intent events are broadcast on the host's
  topic so the host can render the requested LV inside a popup/drawer/
  inline panel on the existing page — no URL change, no DOM replacement.
  See `dev_docs/embedding_emit.md` for the full contract.
  """

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitProjects.PubSub, as: ProjectsPubSub

  require Logger

  # ─────────────────────────────────────────────────────────────────
  # Schedule & assignee helpers
  #
  # Shared by ProjectShowLive (vertical list) and ProjectGanttLive
  # (Timeline) — the gantt was split out of the show page, so these
  # live here rather than duplicated in both LVs.
  # ─────────────────────────────────────────────────────────────────

  @doc """
  The display label for an assignment's assignee (person email / team /
  department name), or `nil` when unassigned. Requires the assignee assocs
  to be preloaded.
  """
  @spec assignee_label(
          PhoenixKitProjects.Schemas.Assignment.t()
          | PhoenixKitProjects.Schemas.Project.t()
        ) :: String.t() | nil
  def assignee_label(a) do
    cond do
      a.assigned_person && a.assigned_person.user -> a.assigned_person.user.email
      a.assigned_team -> a.assigned_team.name
      a.assigned_department -> a.assigned_department.name
      true -> nil
    end
  end

  @doc """
  Whether an assignment counts weekends — its own override, falling back to
  the project's setting. Delegates to `PhoenixKitProjects.ScheduleLayout`,
  where the schedule math lives; kept here so LV imports stay one-stop.
  """
  defdelegate task_counts_weekends?(a, project), to: PhoenixKitProjects.ScheduleLayout

  @doc """
  The estimated hours for an assignment: its own duration override if set,
  otherwise the underlying task's duration (nil-safe). Weekends are honored
  per `task_counts_weekends?/2`. Delegates to
  `PhoenixKitProjects.ScheduleLayout`.
  """
  defdelegate assignment_hours(a, project), to: PhoenixKitProjects.ScheduleLayout

  # ─────────────────────────────────────────────────────────────────
  # Embeddable LV whitelist
  # ─────────────────────────────────────────────────────────────────

  @embeddable_lvs [
    PhoenixKitProjects.Web.OverviewLive,
    PhoenixKitProjects.Web.ProjectsLive,
    PhoenixKitProjects.Web.TemplatesLive,
    PhoenixKitProjects.Web.TasksLive,
    PhoenixKitProjects.Web.ProjectShowLive,
    # The Timeline view. Embed-ready (off-router mount, requires session["id"]
    # like ProjectShowLive). The admin tab renders it via a direct live_render,
    # which never needed this list — but host-driven insertion (PopupHost
    # root_view, <.smart_link emit>, emit :opened, `next` frames) all gate on
    # the whitelist, so it must be listed to be insertable by other apps.
    PhoenixKitProjects.Web.ProjectGanttLive,
    # The Calendar view — same embed contract as the gantt (off-router mount,
    # requires session["id"]).
    PhoenixKitProjects.Web.ProjectCalendarLive,
    PhoenixKitProjects.Web.ProjectFormLive,
    PhoenixKitProjects.Web.TaskFormLive,
    PhoenixKitProjects.Web.TemplateFormLive,
    PhoenixKitProjects.Web.AssignmentFormLive
  ]

  @doc "The canonical list of LVs eligible for embed-mode mounting."
  @spec embeddable_lvs() :: [module()]
  def embeddable_lvs, do: @embeddable_lvs

  @doc """
  Returns `true` iff `mod` is in the embeddable whitelist.

  Used by `PopupHostLive` and the shared `open_embed` event handler
  before passing a module atom to `live_render` or
  `String.to_existing_atom/1`. Protects against hot-reload renames and
  arbitrary-atom injection if the contract is ever wired to an
  untrusted HTTP boundary.
  """
  @spec embeddable_lv?(module()) :: boolean()
  def embeddable_lv?(mod) when is_atom(mod), do: mod in @embeddable_lvs
  def embeddable_lv?(_), do: false

  @doc """
  Render-time JSON encoding of an emit-target session for the
  `phx-value-session` attribute on an `open_embed` button.

  Wrapped (non-bang `Jason.encode/1`) so a caller passing a struct or
  atom value never crashes the whole view at render time — `<.smart_link>`
  / `<.smart_menu_link>` are the canonical navigation primitives and a
  single bad payload would take down every button rendered on the page.
  On failure we fall back to `"{}"`: the click still fires, and the
  target LV's fail-closed `mount(:not_mounted_at_router, session,
  socket)` clause (every embeddable LV has one) flashes "not found" and
  closes the modal — the same shape as a deliberately empty session.
  The warning surfaces the misuse in logs without the page crashing.

  `source` is the calling component module, included in the log line so
  the misuse is traceable to the offending button.
  """
  @spec encode_emit_session(term(), module(), module()) :: String.t()
  def encode_emit_session(session_overrides, source, target_lv) do
    case Jason.encode(session_overrides) do
      {:ok, json} ->
        json

      {:error, reason} ->
        Logger.warning(
          "[phoenix_kit_projects] #{inspect(source)} session encode failed for " <>
            "#{inspect(target_lv)}: #{inspect(reason)} " <>
            "(session=#{inspect(session_overrides)}). " <>
            "Falling back to empty session — target LV will fail-closed."
        )

        "{}"
    end
  end

  @doc """
  Reads the `translations` field off the current changeset and returns
  the sub-map for `current_lang` (or `%{}`).

  Used as the `lang_data` attr on `<.translatable_field>` so secondary
  tabs see in-flight overrides — without this, switching between two
  secondary tabs would lose unsaved edits.
  """
  @spec lang_data(Phoenix.HTML.Form.t(), String.t() | nil) :: map()
  def lang_data(form, current_lang) do
    case form.source do
      %Ecto.Changeset{} = cs ->
        cs
        |> Ecto.Changeset.get_field(:translations)
        |> case do
          %{} = m -> Map.get(m, current_lang) || %{}
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  @doc """
  Folds secondary-language form params into the in-flight record's
  `translations` JSONB and preserves primary-language column values
  that the current secondary-tab DOM didn't render.

  `primary_fields` is the list of DB column names (as strings) that are
  translatable — e.g. `["name", "description"]` for Project,
  `["title", "description"]` for Task. Same as
  `Project.translatable_fields/0` etc.
  """
  @spec merge_translations_attrs(map(), struct(), [String.t()]) :: map()
  def merge_translations_attrs(attrs, record, primary_fields) do
    attrs
    |> merge_translations_map(record)
    |> preserve_primary_fields(record, primary_fields)
  end

  defp merge_translations_map(attrs, record) do
    case Map.get(attrs, "translations") do
      submitted when is_map(submitted) and submitted != %{} ->
        cleaned = clean_submitted_translations(submitted)
        existing = Map.get(record, :translations) || %{}
        merged = deep_merge_translations(existing, cleaned)
        Map.put(attrs, "translations", merged)

      _ ->
        Map.delete(attrs, "translations")
    end
  end

  # Strips Phoenix LV's `_unused_*` sentinel keys (added by the form
  # helper to drive `used_input?/1`) and drops empty-string overrides
  # so that clearing a secondary-tab field falls back cleanly to the
  # primary value at render time, rather than persisting a `""` that
  # the localized-read helpers would have to special-case.
  defp clean_submitted_translations(submitted) when is_map(submitted) do
    submitted
    |> Enum.map(fn {lang, fields} -> {lang, clean_lang_fields(fields)} end)
    |> Enum.reject(fn {_lang, fields} -> fields == %{} end)
    |> Map.new()
  end

  defp clean_lang_fields(fields) when is_map(fields) do
    fields
    |> Enum.reject(fn
      {"_unused_" <> _, _} -> true
      {_k, ""} -> true
      {_k, nil} -> true
      _ -> false
    end)
    |> Map.new()
  end

  defp clean_lang_fields(_), do: %{}

  defp deep_merge_translations(existing, submitted) do
    Map.merge(existing, submitted, fn _lang, old_lang_map, new_lang_map ->
      Map.merge(old_lang_map || %{}, new_lang_map || %{})
    end)
  end

  defp preserve_primary_fields(attrs, record, primary_fields) do
    Enum.reduce(primary_fields, attrs, fn field, acc ->
      if Map.has_key?(acc, field) do
        acc
      else
        existing = Map.get(record, String.to_existing_atom(field))
        if is_nil(existing), do: acc, else: Map.put(acc, field, existing)
      end
    end)
  end

  @doc """
  Normalises `<input type="datetime-local">` form values to ISO 8601
  strings Ecto's `:utc_datetime` cast accepts.

  Browsers post `YYYY-MM-DDTHH:mm` (or `:ss`) with no timezone info.
  Ecto's `:utc_datetime` cast rejects naive strings without an offset,
  so we attach `Z` (UTC) before handing to the changeset. The user's
  picked clock-time is treated as already-UTC — PhoenixKit doesn't
  thread per-user timezone preferences yet, and the date/time pickers
  in browsers are timezone-agnostic anyway, so what the user types is
  what gets stored.

  `fields` is a list of string keys to normalise (typically
  `["scheduled_start_date"]` for the project form). Missing/empty
  values pass through untouched so the changeset's required-validation
  fires on its own.
  """
  @spec normalize_datetime_local_attrs(map(), [String.t()]) :: map()
  def normalize_datetime_local_attrs(attrs, fields) when is_map(attrs) do
    Enum.reduce(fields, attrs, fn field, acc ->
      case Map.get(acc, field) do
        val when is_binary(val) and val != "" ->
          Map.put(acc, field, normalize_local_to_utc(val))

        _ ->
          acc
      end
    end)
  end

  defp normalize_local_to_utc(val) do
    # `datetime-local` posts `YYYY-MM-DDTHH:mm` (16 chars, no seconds)
    # or `YYYY-MM-DDTHH:mm:ss`. Pad seconds when missing, then append
    # `Z` so the result parses as UTC. Pass-through on parse failure —
    # let Ecto's cast surface the actual validation error rather than
    # eating it here.
    with_seconds = if String.length(val) == 16, do: val <> ":00", else: val

    case NaiveDateTime.from_iso8601(with_seconds) do
      {:ok, _ndt} -> with_seconds <> "Z"
      {:error, _} -> val
    end
  end

  @doc """
  When a save fails with errors on translatable primary fields, the
  inline error renders on the primary tab — `<.translatable_field>`
  suppresses errors on secondary tabs by design (it's the wrong field
  to attach them to). If the user submitted from a secondary tab,
  they'll see no visible change. This helper detects that case and
  flips `:current_lang` back to `:primary_language` so the error is
  immediately visible after the form re-renders.

  `translatable_fields` is the list of DB column names (atoms) tracked
  by the schema's `translatable_fields/0` — e.g. `[:name, :description]`.
  """
  @spec maybe_switch_to_primary_on_error(Phoenix.LiveView.Socket.t(), Ecto.Changeset.t(), [
          atom()
        ]) ::
          Phoenix.LiveView.Socket.t()
  def maybe_switch_to_primary_on_error(
        socket,
        %Ecto.Changeset{errors: errors},
        translatable_fields
      ) do
    on_secondary? =
      socket.assigns[:multilang_enabled] == true and
        socket.assigns[:current_lang] != socket.assigns[:primary_language]

    has_primary_error? = Enum.any?(errors, fn {field, _} -> field in translatable_fields end)

    if on_secondary? and has_primary_error? do
      Phoenix.Component.assign(socket, :current_lang, socket.assigns[:primary_language])
    else
      socket
    end
  end

  def maybe_switch_to_primary_on_error(socket, _other, _fields), do: socket

  @doc """
  Returns the user's in-flight record by applying the current changeset.

  When the user has been typing in a primary-tab field and switches to a
  secondary tab, the server-side changeset already captures those primary
  values from prior `validate` events. Re-using `socket.assigns[:project]`
  (or `:task`, etc.) would lose them because that struct is the
  pristine pre-form-edit version. Apply the changeset to get the
  baseline that has both the primary fields AND the existing
  translations the user has already typed.
  """
  @spec in_flight_record(Phoenix.LiveView.Socket.t(), atom(), atom()) :: struct()
  def in_flight_record(socket, form_assign, fallback_assign) do
    case socket.assigns[form_assign] do
      %Phoenix.HTML.Form{source: %Ecto.Changeset{} = cs} ->
        Ecto.Changeset.apply_changes(cs)

      _ ->
        socket.assigns[fallback_assign]
    end
  end

  @doc """
  Restores the Gettext locale in an embedded LiveView process.

  When an LV is mounted via `live_render/3`, Phoenix spawns a new process
  that does not inherit the parent's process dictionary. The active Gettext
  locale is lost, so all translations fall back to the backend default
  (English). Embedders can pass the current locale via
  `session["locale"]`; calling this helper at the top of `mount/3`
  reapplies it before any `gettext/1` or `L10n.current_content_lang/0`
  call runs.

  Backward-compatible: when `"locale"` is absent, this is a no-op.
  """
  @spec maybe_put_locale(map()) :: :ok | nil
  def maybe_put_locale(session) do
    if locale = Map.get(session, "locale") do
      Gettext.put_locale(PhoenixKitWeb.Gettext, locale)
      Gettext.put_locale(locale)
    end
  end

  @doc """
  Resolves the `live_action` for the embedded mount path.

  Router-mounted LVs get `live_action` set by Phoenix LV before
  `mount/3` runs (from the `live "/...", Mod, :action` macro). Embedded
  LVs mounted via `live_render` get nothing — the host has to pass it
  via session. Falls back to `default` (typically `:new`) when neither
  source is present.

  Accepts strings (`"new"`, `"edit"`) from session, converts via
  `String.to_existing_atom/1`, **then validates against an allowlist
  (`[:new, :edit]`)** — anything else falls back to `default`. Without
  the allowlist a tampered `"live_action": "show"` would mint `:show`
  (an existing atom from Phoenix.LiveView land) and then crash inside
  `apply_action/3` which has no `:show` clause.
  """
  @valid_live_actions [:new, :edit]

  @spec resolve_live_action(Phoenix.LiveView.Socket.t(), map(), atom()) :: atom()
  def resolve_live_action(socket, session, default \\ :new) do
    cond do
      action = socket.assigns[:live_action] -> action
      raw = Map.get(session, "live_action") -> normalize_action(raw, default)
      true -> default
    end
  end

  defp normalize_action(value, default) when is_atom(value) do
    if value in @valid_live_actions, do: value, else: default
  end

  defp normalize_action(value, default) when is_binary(value) do
    candidate = String.to_existing_atom(value)
    if candidate in @valid_live_actions, do: candidate, else: default
  rescue
    ArgumentError -> default
  end

  defp normalize_action(_, default), do: default

  @doc """
  Builds the params map an `apply_action/3` clause expects.

  Router mount passes URL params as a map; embed mount passes the atom
  `:not_mounted_at_router`. This helper unifies both: if `params` is a
  map, returns it as-is; otherwise extracts the same string keys from
  `session` (`"id"`, `"project_id"`, `"template"`). Embedders pass those
  keys explicitly when they want `:edit` or template-prefill behavior.
  """
  @spec resolve_action_params(map() | atom(), map()) :: map()
  def resolve_action_params(params, _session) when is_map(params), do: params

  def resolve_action_params(_atom, session) do
    session
    |> Map.take(["id", "project_id", "template", "kind"])
  end

  @doc """
  Routes a form-save transition per the socket's `:embed_mode`.

  In navigate mode (default) — push_navigates to `default_path` unless
  the embedder supplied `session["redirect_to"]` (already on socket as
  `:embed_redirect_to`), with the same-host open-redirect guard.

  In emit mode — broadcasts `{:projects, :saved, %{kind, action, record,
  frame_ref}}` on the host topic and returns the socket unchanged. No
  navigation fires. `opts` must include `:kind` and `:record`; `:action`
  defaults to `:update`.

  The broadcast `record` in the payload is **only `%{uuid: record.uuid}`**,
  never the full struct (it may ride the client-readable wire and a
  preloaded record would leak PII). `kind` conveys the type; a host that
  needs the record re-fetches it by uuid.

  ## Opts

    * `:kind` (atom) — `:project | :task | :template | :assignment`.
      Required in emit mode; ignored in navigate mode.
    * `:record` (struct) — the saved record. Required in emit mode. Only
      its `uuid` is broadcast (see above).
    * `:action` (atom) — `:create | :update`. Defaults to `:update`.
    * `:next` (`{module(), map()} | nil`) — optional follow-up LV the
      host should open after the save. When set, `PopupHostLive` pops
      the current frame and pushes a new frame for `next` — this is
      how form LVs offer a "create then edit" flow in emit mode that
      mirrors their navigate-mode `push_navigate(to: edit_path)`.

  ## Open-redirect guard (navigate mode)

  The `:embed_redirect_to` override is validated as a *relative* path
  before use: must start with `/`, must not start with `//`, must not
  contain `://`. Protects naive embedders who forward an unvalidated
  `params["return_to"]` from a request query string. Invalid overrides
  silently fall back to `default_path`.
  """
  @spec navigate_after_save(Phoenix.LiveView.Socket.t(), String.t(), keyword()) ::
          Phoenix.LiveView.Socket.t()
  def navigate_after_save(socket, default_path, opts \\ []) do
    case socket.assigns[:embed_mode] do
      :emit ->
        emit_saved(socket, opts)
        socket

      _ ->
        target =
          case socket.assigns[:embed_redirect_to] do
            path when is_binary(path) and path != "" ->
              if safe_internal_path?(path), do: path, else: default_path

            _ ->
              default_path
          end

        Phoenix.LiveView.push_navigate(socket, to: target)
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Embed-mode primitives
  # ─────────────────────────────────────────────────────────────────

  @doc """
  Reads the four embed-mode session keys, validates them, and assigns
  them onto the socket. Call from every embeddable LV's `mount/3` after
  `wrapper_class` resolution.

  Session keys read:
    * `"mode"` — `"navigate"` (default) or `"emit"`
    * `"pubsub_topic"` — string; required when mode is `"emit"`
    * `"frame_ref"` — opaque integer stamped by `PopupHostLive` (may be nil)

  Socket assigns produced:
    * `:embed_mode` — `:navigate | :emit`
    * `:embed_pubsub_topic` — string or nil
    * `:embed_frame_ref` — integer or nil

  Raises `ArgumentError` if `mode == "emit"` but `pubsub_topic` is missing
  — fail-fast at mount rather than silently no-op every later emit call.
  """
  @spec assign_embed_state(Phoenix.LiveView.Socket.t(), map()) ::
          Phoenix.LiveView.Socket.t()
  def assign_embed_state(socket, session) when is_map(session) do
    mode = decode_mode(Map.get(session, "mode"))
    topic = Map.get(session, "pubsub_topic")
    frame_ref = decode_frame_ref(Map.get(session, "frame_ref"))

    if mode == :emit and (not is_binary(topic) or topic == "") do
      raise ArgumentError,
            "embed mode is \"emit\" but session[\"pubsub_topic\"] is missing or empty"
    end

    if mode == :emit and is_binary(Map.get(session, "redirect_to", nil)) and
         Map.get(session, "redirect_to") != "" do
      Logger.warning(
        "[phoenix_kit_projects] both `mode: \"emit\"` and `redirect_to` " <>
          "supplied — preferring emit; `redirect_to` ignored."
      )
    end

    Phoenix.Component.assign(socket,
      embed_mode: mode,
      embed_pubsub_topic: topic,
      embed_frame_ref: frame_ref
    )
  end

  defp decode_mode("emit"), do: :emit
  defp decode_mode(:emit), do: :emit
  defp decode_mode("navigate"), do: :navigate
  defp decode_mode(:navigate), do: :navigate
  defp decode_mode(nil), do: :navigate

  defp decode_mode(other) do
    Logger.warning(
      "[phoenix_kit_projects] unknown embed mode #{inspect(other)} — defaulting to :navigate"
    )

    :navigate
  end

  defp decode_frame_ref(n) when is_integer(n), do: n

  defp decode_frame_ref(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} ->
        n

      _ ->
        Logger.warning(
          "[phoenix_kit_projects] ignoring malformed frame_ref #{inspect(s)} — defaulting to nil"
        )

        nil
    end
  end

  defp decode_frame_ref(_), do: nil

  @doc """
  Reconstructs the current user + scope for an **embedded** LiveView mount.

  Router-mounted LVs receive `:phoenix_kit_current_scope` /
  `:phoenix_kit_current_user` from core's `:phoenix_kit_ensure_admin`
  `on_mount` hook, which runs *before* `mount/3`. An LV mounted via
  `live_render` (`:not_mounted_at_router`) never enters that
  `live_session`, so the hook never runs and both assigns are absent —
  leaving user-aware embedded UI blind to who's acting: the comments
  drawer's composer flips to "Sign in to post a comment." and
  `PhoenixKitProjects.Activity.actor_uuid/1` records `nil`.

  The host bridges identity across the `live_render` process boundary by
  passing its **own authenticated user's** uuid as
  `session["current_user_uuid"]` — a string, never the `%User{}` struct
  (a `live_render` session is serialized into the client-readable,
  signed-but-not-encrypted `data-phx-session` token, so a struct would
  leak the password hash to the browser). This helper reloads that user
  and assigns both `:phoenix_kit_current_user` and
  `:phoenix_kit_current_scope`.

  Contract:

    * If `:phoenix_kit_current_scope` is **already present** (router
      mount — the hook ran before `mount/3`) this is a **no-op**: the
      canonical scope is never clobbered.
    * Else if `session["current_user_uuid"]` resolves to an **active**
      user → assigns that user + `Scope.for_user(user)`.
    * Else → assigns a `nil` user + `Scope.for_user(nil)` (anonymous), so
      the assigns always exist and downstream `scope.user` reads stay
      nil-safe.

  A provided-but-unresolvable uuid (unknown, inactive, or a transient DB
  error) degrades to the anonymous branch and logs a warning — comments
  fall back to "Sign in to post a comment." rather than crashing the
  embed.

  > ## Host responsibilities
  >
  > The uuid MUST come from the host's trusted server-side assign — its
  > `phoenix_kit_current_scope` assign, i.e. `scope.user.uuid` — and
  > **never** from request params: the host owns the page and must not
  > forward attacker-controlled input. The signed `live_render` session
  > only stops a *client* from swapping the value after render; it is **not**
  > server-side authorization — nothing here re-verifies the uuid belongs to
  > a projects-authorized user.
  >
  > **This helper reconstructs identity, NOT authorization.** Core's
  > `:phoenix_kit_ensure_admin` `on_mount` (the `permission: "projects"`
  > gate) runs only for router-mounted admin pages — never for an
  > off-router `live_render` mount. Embedded mutation handlers are therefore
  > NOT role-gated, so the **host MUST gate the embedding page** to
  > projects-authorized users. The reconstructed user only drives audit
  > attribution (`Activity.actor_uuid/1`) and the comments composer.
  >
  > The reconstructed scope is a **snapshot** taken at mount. Unlike the
  > standalone admin page it carries no live scope-refresh hook, so a
  > permission change / account switch mid-session is not reflected until
  > the embed remounts. Acceptable for an embedded panel/drawer.
  """
  @spec assign_embed_user(Phoenix.LiveView.Socket.t(), map()) ::
          Phoenix.LiveView.Socket.t()
  def assign_embed_user(socket, session) when is_map(session) do
    # Prefer core's canonical implementation when the running phoenix_kit
    # exposes it (the release that promoted this helper into
    # `PhoenixKitWeb.Users.Auth`); fall back to the local copy against older
    # cores so the Hex-pinned build stays green. `apply/3` (not a direct
    # call) keeps compilation warning-free against a core that lacks the
    # function. The two are behaviourally identical — drop the fallback
    # (and `resolve_embed_identity/1`) once the `phoenix_kit` floor includes
    # the core helper.
    if function_exported?(PhoenixKitWeb.Users.Auth, :assign_embedded_current_user, 2) do
      # `apply/3` is intentional here (see above): a direct call would emit an
      # `unknown_function` warning — fatal under `--warnings-as-errors` — when
      # compiled against an older core that lacks this helper.
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(PhoenixKitWeb.Users.Auth, :assign_embedded_current_user, [socket, session])
    else
      local_assign_embed_user(socket, session)
    end
  end

  def assign_embed_user(socket, _session), do: socket

  defp local_assign_embed_user(socket, session) do
    # A non-nil scope means the on_mount hook already ran (router mount).
    # on_mount runs before mount/3, so an embedded mount — which skips the
    # live_session entirely — always sees nil here. Don't clobber a real
    # scope with a reconstructed one.
    if is_nil(socket.assigns[:phoenix_kit_current_scope]) do
      {user, scope} = resolve_embed_identity(Map.get(session, "current_user_uuid"))

      Phoenix.Component.assign(socket,
        phoenix_kit_current_user: user,
        phoenix_kit_current_scope: scope
      )
    else
      socket
    end
  end

  # Loads the user behind the host-supplied uuid and pairs it with a scope.
  # `get_user/1` is nil-safe (validates the uuid shape, returns nil on a
  # miss); `ensure_active_user/1` drops a deactivated user so a revoked
  # account can't act through an embed. The DB-error rescue mirrors the
  # module-wide convention (see the cross-module staff-lookup rule in
  # AGENTS.md) so a transient DB blip degrades to anonymous instead of
  # 500-ing the host page.
  defp resolve_embed_identity(uuid) when is_binary(uuid) and uuid != "" do
    user =
      uuid
      |> Auth.get_user()
      |> Auth.ensure_active_user()

    if is_nil(user) do
      Logger.warning(
        "[phoenix_kit_projects] embed session current_user_uuid=#{inspect(uuid)} " <>
          "did not resolve to an active user — embedded UI degrades to anonymous"
      )
    end

    {user, Scope.for_user(user)}
  rescue
    e in [Postgrex.Error, DBConnection.ConnectionError, Ecto.QueryError] ->
      Logger.warning(
        "[phoenix_kit_projects] failed to load embed user #{inspect(uuid)}: " <>
          Exception.message(e) <> " — degrading to anonymous"
      )

      {nil, Scope.for_user(nil)}
  end

  defp resolve_embed_identity(_), do: {nil, Scope.for_user(nil)}

  @doc """
  Routes per `:embed_mode`. In navigate mode: `push_navigate(to: opts[:to])`.
  In emit mode: broadcasts `{:projects, :opened, %{lv, session, frame_ref}}`
  and returns the socket unchanged.

  ## Opts

    * `:to` (string) — fallback path used in navigate mode
    * `:open` (`{module(), map()}`) — `{TargetLV, session_overrides}` used
      in emit mode

  Both opts are required. In emit mode the open-target's module is
  validated against `embeddable_lvs/0`; an unlisted module logs a
  warning and is dropped (no broadcast, no navigation — caller's bug).
  """
  @spec navigate_or_open(Phoenix.LiveView.Socket.t(), keyword()) ::
          Phoenix.LiveView.Socket.t()
  def navigate_or_open(socket, opts) when is_list(opts) do
    case socket.assigns[:embed_mode] do
      :emit ->
        {lv, session_overrides} = Keyword.fetch!(opts, :open)
        emit_opened(socket, lv, session_overrides)
        socket

      _ ->
        path = Keyword.fetch!(opts, :to)
        Phoenix.LiveView.push_navigate(socket, to: path)
    end
  end

  @doc """
  Cancel / Back behaviour.

  In emit mode: broadcasts `{:projects, :closed, %{frame_ref}}` and
  returns the socket unchanged.

  In navigate mode: `push_navigate(to: fallback_path)`, but if the
  embedder supplied `session["redirect_to"]` (already on socket as
  `:embed_redirect_to`) it takes precedence — same open-redirect guard
  as `navigate_after_save/3`. This honors the host-supplied exit point
  for both cancel/back AND save success in PR #6's contract.
  """
  @spec close_or_navigate(Phoenix.LiveView.Socket.t(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def close_or_navigate(socket, fallback_path) when is_binary(fallback_path) do
    case socket.assigns[:embed_mode] do
      :emit ->
        emit_closed(socket)
        socket

      _ ->
        target =
          case socket.assigns[:embed_redirect_to] do
            path when is_binary(path) and path != "" ->
              if safe_internal_path?(path), do: path, else: fallback_path

            _ ->
              fallback_path
          end

        Phoenix.LiveView.push_navigate(socket, to: target)
    end
  end

  @doc """
  Emits `{:projects, :deleted, %{kind, uuid, close: false, frame_ref}}`
  on the host topic when in emit mode, no-ops in navigate mode.

  Use at list-LV delete-success branches where the LV stays on the
  same page after delete (just reloads its own list). The broadcast is
  **informational** — `close: false` tells `PopupHostLive` not to pop
  the modal that hosts this list. The host learns about the delete
  through the canonical UI-intent vocabulary; the list itself stays
  open showing the post-delete state.

  An LV whose *own* resource was deleted reacts through
  `close_or_navigate/2` instead (pops the frame in emit mode) — the
  `:deleted` vocabulary reserves `close: true` for that shape should an
  emitter ever need it.
  """
  @spec notify_deleted(Phoenix.LiveView.Socket.t(), atom(), binary()) ::
          Phoenix.LiveView.Socket.t()
  def notify_deleted(socket, kind, uuid)
      when is_atom(kind) and is_binary(uuid) do
    if socket.assigns[:embed_mode] == :emit do
      emit_deleted(socket, kind, uuid, false)
    end

    socket
  end

  @doc """
  Attaches the shared `open_embed` event handler to the socket via
  `Phoenix.LiveView.attach_hook/4`. Call from every LV that uses
  `<.smart_link>` (the conventional entry point is to chain it after
  `assign_embed_state/2` in `mount/3`).

  The hook intercepts `phx-click="open_embed"` events fired by
  `<.smart_link>` in emit mode, validates the `lv` value against
  `embeddable_lvs/0`, JSON-decodes the `session` value, and emits
  `:opened`. Halts the event so the host LV's own `handle_event/3`
  never sees it.

  In navigate mode `<.smart_link>` renders a plain `<.link navigate>`
  and no `open_embed` event ever fires — the hook is harmless then.
  """
  @spec attach_open_embed_hook(Phoenix.LiveView.Socket.t()) ::
          Phoenix.LiveView.Socket.t()
  def attach_open_embed_hook(socket) do
    Phoenix.LiveView.attach_hook(
      socket,
      :phoenix_kit_projects_open_embed,
      :handle_event,
      &handle_open_embed/3
    )
  end

  defp handle_open_embed("open_embed", %{"lv" => lv_str} = params, socket) do
    # The `open_embed` event name is owned by this helper end-to-end.
    # `<.smart_link>` renders the button only in emit mode, so reaching
    # this handler in navigate mode means the payload is stale or
    # adversarial — most LVs do not implement `handle_event("open_embed",
    # ...)`, so a fall-through would crash them. Halt + log in both modes;
    # only emit mode actually fires the broadcast.
    case socket.assigns[:embed_mode] do
      :emit ->
        with {:ok, lv} <- decode_embeddable_lv(lv_str),
             {:ok, session} <- decode_session(Map.get(params, "session")) do
          emit_opened(socket, lv, session)
        else
          _ ->
            Logger.warning(
              "[phoenix_kit_projects] dropping malformed open_embed event " <>
                "(lv=#{inspect(lv_str)})"
            )
        end

      _ ->
        Logger.warning(
          "[phoenix_kit_projects] dropping unexpected open_embed event in navigate mode " <>
            "(lv=#{inspect(lv_str)})"
        )
    end

    {:halt, socket}
  end

  defp handle_open_embed(_event, _params, socket), do: {:cont, socket}

  @doc """
  Decodes a stringified module name into an atom, validating that the
  result is in `embeddable_lvs/0`. Used by the `open_embed` event
  handler and by `PopupHostLive`'s `root_view` decoder.

  Accepts both forms hosts can plausibly write:

    * `"Elixir.PhoenixKitProjects.Web.OverviewLive"` — the fully-
      qualified atom string (what `Atom.to_string/1` produces on a
      module, and what `<.smart_link>` puts on the wire)
    * `"PhoenixKitProjects.Web.OverviewLive"` — the human-friendly
      form used in docs and `PopupHostLive`'s `root_view` session
      example. Prepended with `Elixir.` before lookup.

  Returns `:error` if the resulting atom isn't in the whitelist (or
  doesn't exist as an atom yet — `String.to_existing_atom/1` raises,
  which we trap).
  """
  @spec decode_embeddable_lv(String.t()) :: {:ok, module()} | :error
  def decode_embeddable_lv(str) when is_binary(str) do
    normalized =
      if String.starts_with?(str, "Elixir."), do: str, else: "Elixir." <> str

    case String.to_existing_atom(normalized) do
      mod when is_atom(mod) ->
        if embeddable_lv?(mod), do: {:ok, mod}, else: :error
    end
  rescue
    ArgumentError -> :error
  end

  def decode_embeddable_lv(_), do: :error

  @doc """
  Decodes the `phx-value-session` JSON blob produced by `<.smart_link>`.
  Returns `{:ok, map}` on success, `:error` on malformed JSON.
  """
  @spec decode_session(any()) :: {:ok, map()} | :error
  def decode_session(nil), do: {:ok, %{}}
  def decode_session(""), do: {:ok, %{}}

  def decode_session(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> :error
    end
  end

  def decode_session(map) when is_map(map), do: {:ok, map}
  def decode_session(_), do: :error

  # ─────────────────────────────────────────────────────────────────
  # Emit primitives (internal — drive the helpers above)
  # ─────────────────────────────────────────────────────────────────

  defp emit_opened(socket, lv, session_overrides)
       when is_atom(lv) and is_map(session_overrides) do
    if embeddable_lv?(lv) do
      payload = %{
        lv: lv,
        session: session_overrides,
        frame_ref: socket.assigns[:embed_frame_ref]
      }

      do_broadcast(socket, :opened, payload)
      emit_telemetry(:open, lv: lv, mode: :emit)
    else
      Logger.warning(
        "[phoenix_kit_projects] refusing to emit :opened for #{inspect(lv)} — " <>
          "not in embeddable_lvs/0 whitelist"
      )
    end

    :ok
  end

  defp emit_closed(socket) do
    do_broadcast(socket, :closed, %{frame_ref: socket.assigns[:embed_frame_ref]})
    :ok
  end

  defp emit_saved(socket, opts) do
    kind = Keyword.fetch!(opts, :kind)
    record = Keyword.fetch!(opts, :record)
    # Emit only the uuid, never the full Ecto struct: the `:saved` payload
    # rides a host-supplied PubSub topic that a host may relay over the
    # (client-readable, signed-not-encrypted) wire, and a preloaded record
    # (e.g. `assigned_person: [:user]`) would leak user PII. `kind` conveys
    # the type; the host re-fetches by uuid if it needs the record.
    record_ref = %{uuid: record.uuid}
    action = Keyword.get(opts, :action, :update)
    close = Keyword.get(opts, :close, true)
    next = Keyword.get(opts, :next)

    # R5-IM1: `next` only has well-defined semantics when the current
    # frame is also being closed (pop-then-push). `close: false, next:
    # {...}` would silently drop the next at the PopupHost layer —
    # surfacing it loudly here avoids the silent no-op.
    if next != nil and close != true do
      raise ArgumentError,
            "navigate_after_save/3 requires `close: true` when `next:` is set " <>
              "(got close=#{inspect(close)}, next=#{inspect(next)}). " <>
              "The next-frame chain replaces the current frame; stacking a " <>
              "follow-up while keeping the current form open is a separate " <>
              "flow that should emit :opened explicitly."
    end

    payload =
      %{
        kind: kind,
        action: action,
        record: record_ref,
        close: close,
        next: next,
        frame_ref: socket.assigns[:embed_frame_ref]
      }

    do_broadcast(socket, :saved, payload)
    emit_telemetry(:save, kind: kind, action: action, mode: :emit)
    :ok
  end

  # `close: true` signals to PopupHost "this resource is gone — pop the
  # modal frame that was showing it." `close: false` is informational
  # ("a row in my view was deleted; I'm staying open") — the shape
  # `notify_deleted/3` emits. `close: true` is currently reserved
  # vocabulary (own-resource-gone LVs pop via `close_or_navigate/2`).
  defp emit_deleted(socket, kind, uuid, close) do
    payload = %{
      kind: kind,
      uuid: uuid,
      close: close,
      frame_ref: socket.assigns[:embed_frame_ref]
    }

    do_broadcast(socket, :deleted, payload)
    emit_telemetry(:delete, kind: kind, mode: :emit)
    :ok
  end

  defp do_broadcast(socket, event, payload) do
    case socket.assigns[:embed_pubsub_topic] do
      topic when is_binary(topic) and topic != "" ->
        ProjectsPubSub.broadcast_embed(topic, event, payload)

      _ ->
        Logger.warning(
          "[phoenix_kit_projects] cannot broadcast #{inspect(event)} — " <>
            "embed_pubsub_topic missing on socket"
        )
    end
  end

  defp emit_telemetry(event, metadata) do
    # Built outside the rescue on purpose: a failure here is a bug in
    # this module's own metadata construction and must crash loudly.
    measurements = %{system_time: System.system_time()}
    metadata = Map.new(metadata)

    try do
      :telemetry.execute([:phoenix_kit_projects, :embed, event], measurements, metadata)
    rescue
      # Host-attached handlers run synchronously inside `execute/3` and
      # may raise anything (including host-defined exception structs).
      # Telemetry is observability, not load-bearing, so a misbehaved
      # host handler must never crash the embed flow — rescue broadly
      # here, but here only, and log the full exception for postmortem.
      e ->
        Logger.warning(
          "[phoenix_kit_projects] telemetry handler raised: " <>
            Exception.format(:error, e, __STACKTRACE__)
        )

        :ok
    end
  end

  # Accepts absolute paths under the current host (`/admin/...`,
  # `/host/orders/123`). Rejects schemes (`https://...`,
  # `javascript:...`) and protocol-relative URLs (`//evil.example.com/...`).
  # Only called from `navigate_after_save/2` where the outer `case` has
  # already narrowed the value to a non-empty binary — no catch-all
  # clause needed (Dialyzer flagged it as unreachable).
  defp safe_internal_path?(path) when is_binary(path) do
    String.starts_with?(path, "/") and
      not String.starts_with?(path, "//") and
      not String.contains?(path, "://")
  end
end
