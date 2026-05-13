defmodule PhoenixKitProjects.Web.Helpers do
  @moduledoc """
  Cross-cutting helpers for the projects module's LiveView layer.

  Right now this is the canonical home for the multilang-form merge
  helpers used by `ProjectFormLive`, `TaskFormLive`, and
  `AssignmentFormLive`. Each form has its own non-translatable fields
  and primary-language columns, but the JSONB-shaping plumbing is
  identical — extracted here to avoid three near-identical copies.

  See the corresponding form LV's `mount/3` and `handle_event/3` for the
  call sites; the shape they expect:

    * `lang_data(form, current_lang)` — pulled-in for `<.translatable_field
      lang_data={...}>` so the secondary-tab inputs render the existing
      override (and edits survive a `phx-change` round-trip without a DB
      hit).
    * `merge_translations_attrs(attrs, in_flight_record, primary_fields)` —
      called from the `validate`/`save` handlers to:
        1. clean the submitted `attrs["translations"]` map (strip
           `_unused_*` sentinels, drop empty/`nil` overrides),
        2. merge it on top of the record's existing JSONB so other
           languages aren't clobbered, and
        3. preserve primary-language column values that aren't in the
           current submission (the secondary-tab DOM doesn't render
           them, so they'd otherwise come back nil and trigger
           `validate_required` failures on save).
    * `in_flight_record(socket, form_assign, fallback_assign)` — the form's
      changeset captures the user's typed-but-not-yet-saved primary
      values from prior `validate` events. Apply it for the merge-baseline.
  """

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
  Resolves the `live_action` for the embedded mount path.

  Router-mounted LVs get `live_action` set by Phoenix LV before
  `mount/3` runs (from the `live "/...", Mod, :action` macro). Embedded
  LVs mounted via `live_render` get nothing — the host has to pass it
  via session. Falls back to `default` (typically `:new`) when neither
  source is present.

  Accepts strings (`"new"`, `"edit"`) from session and converts via
  `String.to_existing_atom/1` (safer than `to_atom/1`; an unknown action
  raises rather than minting atoms from arbitrary user input).
  """
  @spec resolve_live_action(Phoenix.LiveView.Socket.t(), map(), atom()) :: atom()
  def resolve_live_action(socket, session, default \\ :new) do
    cond do
      action = socket.assigns[:live_action] -> action
      raw = Map.get(session, "live_action") -> normalize_action(raw, default)
      true -> default
    end
  end

  defp normalize_action(value, _default) when is_atom(value), do: value

  defp normalize_action(value, default) when is_binary(value) do
    String.to_existing_atom(value)
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
    |> Map.take(["id", "project_id", "template"])
  end

  @doc """
  Push-navigates to `default_path` unless the embedder supplied a
  `session["redirect_to"]` override (already on socket as
  `:embed_redirect_to`).

  Used by form save handlers so that an embedded form can return to a
  host-app path on save (and the host can close a modal, refresh its
  own state, etc.) instead of yanking the user to `/admin/projects/...`.
  """
  @spec navigate_after_save(Phoenix.LiveView.Socket.t(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def navigate_after_save(socket, default_path) do
    target =
      case socket.assigns[:embed_redirect_to] do
        path when is_binary(path) and path != "" -> path
        _ -> default_path
      end

    Phoenix.LiveView.push_navigate(socket, to: target)
  end
end
