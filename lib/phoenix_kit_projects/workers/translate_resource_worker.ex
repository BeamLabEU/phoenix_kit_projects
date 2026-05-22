defmodule PhoenixKitProjects.Workers.TranslateResourceWorker do
  @moduledoc """
  Oban worker that translates a `Project` / `Task` / `Assignment`'s
  translatable fields from a source language to a single target
  language, then writes the result into the resource's `translations`
  JSONB map.

  Templates use the same `Project` schema as regular projects (with
  `is_template: true`), so `resource_type` of `"project"` or
  `"template"` both route through `Project`. The distinction shows up
  only in the activity-log entry and the user-facing flash text.

  ## Job arg shape

      %{
        "resource_type" => "project" | "template" | "task" | "assignment",
        "resource_uuid" => uuid,
        "endpoint_uuid" => uuid,        # PhoenixKitAI endpoint
        "prompt_uuid" => uuid,          # PhoenixKitAI prompt template
        "source_lang" => "en",
        "target_lang" => "es",
        "actor_uuid" => uuid_or_nil
      }

  ## Storage

  Writes to `resource.translations[target_lang]` via the resource's
  existing changeset, preserving any pre-existing translations on
  other languages. The shape matches what the multilang form writes
  (e.g. `%{"et" => %{"name" => "...", "description" => "..."}}`) so
  the form's edit round-trip works unchanged after a translation
  finishes.

  ## Broadcasts

  - `{:projects, :translation_started, %{...}}` before the AI call
  - `{:projects, :translation_completed, %{...}}` after a successful write
  - `{:projects, :translation_failed, %{...}}` on any failure path

  Payload always includes `resource_type`, `resource_uuid`,
  `target_lang`. `:translation_failed` adds `reason` (a normalised
  atom or `{atom, term}` tuple from `PhoenixKit.Modules.AI.Translation`).

  ## Uniqueness

  One job in flight per `(resource_uuid, target_lang)` pair so a
  double-click in the UI doesn't burn AI tokens twice. Other target
  languages on the same resource can run concurrently.

  `period: :infinity` is deliberate: Oban's `unique` default is a
  60-second window, which would let a second enqueue slip through
  for a translation that runs longer than a minute (entirely possible
  for a multi-field AI call). With `:infinity` the dedup is bounded by
  the in-flight `states` instead of time — a duplicate is rejected as
  long as the original is still `available`/`scheduled`/`executing`/
  `retryable`, and a fresh job is allowed only once the previous one
  reaches a terminal state (so re-translating later still works).

  ## Auto-completion

  Mirrors publishing's `TranslatePostWorker` shape (queue, retry
  policy, activity-log action) but writes a much smaller surface
  (no version model, no per-language status, no cache invalidation).
  Each module owns its own broadcast topic + activity-log action;
  the actual AI orchestration lives in
  `PhoenixKit.Modules.AI.Translation`.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [
      period: :infinity,
      keys: [:resource_uuid, :target_lang],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  import Ecto.Query

  require Logger

  alias PhoenixKit.Modules.AI.Translation
  alias PhoenixKit.PubSub.Manager, as: PubSubManager
  alias PhoenixKit.RepoHelper
  alias PhoenixKitProjects.{Activity, Projects}
  alias PhoenixKitProjects.PubSub, as: ProjectsPubSub
  alias PhoenixKitProjects.Schemas.{Assignment, Project, Task}

  @resource_types ~w(project template task assignment)

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    with {:ok, type} <- fetch_resource_type(args),
         {:ok, uuid} <- fetch_string(args, "resource_uuid"),
         {:ok, endpoint_uuid} <- fetch_string(args, "endpoint_uuid"),
         {:ok, prompt_uuid} <- fetch_string(args, "prompt_uuid"),
         {:ok, source_lang} <- fetch_string(args, "source_lang"),
         {:ok, target_lang} <- fetch_string(args, "target_lang"),
         {:ok, resource} <- load_resource(type, uuid) do
      actor_uuid = Map.get(args, "actor_uuid")

      do_translate(resource, type, %{
        endpoint_uuid: endpoint_uuid,
        prompt_uuid: prompt_uuid,
        source_lang: source_lang,
        target_lang: target_lang,
        actor_uuid: actor_uuid
      })
    else
      {:error, reason} ->
        # Deterministic failures (missing args, resource_not_found,
        # resource_type_mismatch) are not worth retrying — Oban would
        # just burn the max_attempts running the same broken job.
        # Surface a normalised `:translation_failed` broadcast using
        # whatever args we have, then discard.
        broadcast_early_failure(args, reason)
        {:discard, reason}
    end
  end

  # `broadcast/5` needs the resource for type-aware fan-out; on a deterministic
  # arg-validation error we don't have one. Broadcast on `projects:all` only
  # so subscribed admin LVs see the failure without crashing on a nil resource.
  defp broadcast_early_failure(args, reason) do
    payload = %{
      resource_type: Map.get(args, "resource_type"),
      resource_uuid: Map.get(args, "resource_uuid"),
      source_lang: Map.get(args, "source_lang"),
      target_lang: Map.get(args, "target_lang"),
      reason: reason
    }

    PubSubManager.broadcast(
      ProjectsPubSub.topic_all(),
      {:projects, :translation_failed, payload}
    )
  end

  # Public entry point for the host LV — bypasses Oban for callers that
  # need a synchronous translation (preview-then-save flows). The vast
  # majority of callers should use `enqueue/1` from
  # `PhoenixKitProjects.Translations`; this is here for symmetry with
  # publishing's `translate_now/1`.
  @doc false
  def translate_now(%{} = args) do
    perform(%Oban.Job{args: stringify_keys(args), attempt: 1, inserted_at: DateTime.utc_now()})
  end

  defp do_translate(resource, type, params) do
    broadcast(:translation_started, resource, type, params)

    fields = translatable_field_map(resource, type, params.source_lang)

    if map_size(fields) == 0 do
      # Nothing to translate (every translatable field is empty / nil).
      # Treat as success — the resource just has no content yet.
      broadcast(:translation_completed, resource, type, params,
        fields: %{},
        empty: true
      )

      :ok
    else
      case Translation.translate_fields(
             params.endpoint_uuid,
             params.prompt_uuid,
             params.source_lang,
             params.target_lang,
             fields,
             actor_uuid: params.actor_uuid,
             resource_type: type,
             resource_uuid: get_uuid(resource),
             source: "PhoenixKitProjects.Workers.TranslateResourceWorker"
           ) do
        {:ok, translated_fields} ->
          handle_translation_success(resource, type, params, translated_fields)

        {:error, reason} ->
          handle_translation_failure(resource, type, params, reason)
      end
    end
  end

  defp handle_translation_success(resource, type, params, translated_fields) do
    case persist_translation_atomic(resource, type, params.target_lang, translated_fields) do
      {:ok, _updated} ->
        Activity.log("projects.translation_added",
          actor_uuid: params.actor_uuid,
          resource_type: type,
          resource_uuid: get_uuid(resource),
          metadata: %{
            "source_lang" => params.source_lang,
            "target_lang" => params.target_lang,
            "fields" => Map.keys(translated_fields)
          }
        )

        broadcast(:translation_completed, resource, type, params, fields: translated_fields)

        :ok

      {:error, reason} ->
        Logger.warning(
          "[TranslateResourceWorker] persist failed for #{type} #{get_uuid(resource)}: " <>
            inspect(reason)
        )

        broadcast(:translation_failed, resource, type, params, reason: {:persist_error, reason})

        {:error, {:persist_error, reason}}
    end
  end

  # Wraps the load → merge → write cycle in a transaction with
  # SELECT FOR UPDATE so concurrent bulk translations on the same
  # resource don't race-clobber each other.
  #
  # The old path (load resource pre-AI, merge with in-memory snapshot,
  # update_all the whole `translations` field) lost writes when N
  # workers ran in parallel: each one loaded an empty `translations`
  # before any peer had persisted, merged in only its own lang, and
  # overwrote everyone else's contribution. Surfaced when the user
  # dispatched bulk "all" — DB ended up with ~11 of 40 langs.
  #
  # Fix: re-read the row inside a transaction with `lock: "FOR UPDATE"`
  # so the merge is computed against the latest committed state.
  # Postgres serializes the row locks; the second worker waits for
  # the first's commit and then reads its peer's write before
  # computing its own merge. Wall-clock cost is negligible — the
  # serialization happens AFTER the multi-second AI call, and a
  # JSONB write is sub-millisecond.
  defp persist_translation_atomic(resource, type, target_lang, translated_fields) do
    schema = schema_for(type)
    uuid = get_uuid(resource)
    repo = RepoHelper.repo()

    query =
      schema
      |> where([r], r.uuid == ^uuid)
      |> lock("FOR UPDATE")

    # `repo.transaction/1` already returns `{:ok, updated}` on commit
    # and `{:error, reason}` on `repo.rollback/1` — exactly the shape
    # this function contracts, so return it directly.
    #
    # CONSTRAINT: `persist_translation/3` calls `Projects.update_*`,
    # which emits a `:project_updated` / `:task_updated` PubSub
    # broadcast as part of its success path. That broadcast fires
    # while the row lock is still held — subscribers reacting by
    # reading the row back would see the pre-commit state. Today
    # this is harmless because `update_*` is the terminal step in
    # the transaction body (success → return `updated`; no further
    # writes can roll back the broadcast). If a future change adds
    # work after the persist (e.g. a second mutation, a side-effect
    # we expect to roll back together), move the broadcast outside
    # the transaction (caller-side, after `{:ok, _}`) so subscribers
    # see committed state. Until then, `persist_translation/3` MUST
    # remain the last write inside this block.
    repo.transaction(fn ->
      case repo.one(query) do
        nil ->
          repo.rollback(:resource_not_found)

        fresh ->
          merged = merge_translation(fresh, target_lang, translated_fields)

          case persist_translation(fresh, type, merged) do
            {:ok, updated} ->
              updated

            {:error, %Ecto.Changeset{errors: errors}} ->
              repo.rollback(errors)
          end
      end
    end)
  end

  defp handle_translation_failure(resource, type, params, reason) do
    safe_reason = sanitize_reason(reason)

    Logger.warning(
      "[TranslateResourceWorker] translation failed for #{type} #{get_uuid(resource)} → " <>
        "#{params.target_lang}: #{safe_reason}"
    )

    # Broadcast carries the full reason — subscribed LVs are in-process,
    # not log destinations, so they can render rich error info if they
    # want. Activity log gets the sanitized form to avoid persisting
    # plugin-specific structured data (e.g. raw API responses, prompt
    # excerpts) that the failing path might fold into the reason tuple.
    broadcast(:translation_failed, resource, type, params, reason: reason)

    Activity.log_failed("projects.translation_added",
      actor_uuid: params.actor_uuid,
      resource_type: type,
      resource_uuid: get_uuid(resource),
      metadata: %{
        "source_lang" => params.source_lang,
        "target_lang" => params.target_lang,
        "reason" => safe_reason
      }
    )

    # Choose between retry and discard based on whether retrying the
    # job could plausibly produce a different result. Oban defaults
    # `{:error, _}` to retry up to `max_attempts: 3` — which burns AI
    # tokens 3× when the failure is deterministic (parse error from a
    # model that ignores the structured-marker contract, plugin not
    # installed, etc.). Retry only the cases that are genuinely
    # transient.
    if retryable?(reason) do
      {:error, reason}
    else
      {:discard, reason}
    end
  end

  # Transient failures worth retrying: HTTP timeouts, rate-limited
  # responses, connection errors. Everything else (parse errors,
  # unexpected response shape, missing plugin, missing endpoint,
  # missing prompt, persist errors) is deterministic and a retry would
  # just produce the same outcome at the cost of another AI billing
  # event.
  # Public (`@doc false`) so the classification contract can be unit
  # tested directly: in CI the AI plugin isn't loaded, so the public
  # `perform/1` path can only ever surface `:ai_not_installed` and
  # never reaches these clauses. Same testing-seam rationale as
  # `translate_now/1` above.
  @doc false
  @spec retryable?(term()) :: boolean()
  def retryable?({:ai_error, :request_timeout}), do: true
  def retryable?({:ai_error, :rate_limited}), do: true
  def retryable?({:ai_error, {:connection_error, _}}), do: true
  def retryable?({:ai_error, {:exit, _}}), do: true
  # Provider 5xx — explicit allow-list of transient codes. Excludes
  # `501 Not Implemented` and `505 HTTP Version Not Supported` which
  # are deterministic config/integration mismatches (retrying them
  # burns AI tokens without ever succeeding). Core's
  # `Completion.handle_error_status/2` returns `{:api_error, status}`
  # for any non-200 that isn't 401/402/429.
  def retryable?({:ai_error, {:api_error, status}})
      when status in [500, 502, 503, 504, 522, 524, 529],
      do: true

  def retryable?(_), do: false

  # Reduces a translation-failure reason to a stable, log-safe string.
  # Keeps the top-level shape (`:ai_not_installed`, `{:ai_error, ...}`,
  # `{:parse_error, ...}`, `{:persist_error, ...}`) but redacts deeper
  # payloads that may carry prompt text, API keys, or raw responses.
  defp sanitize_reason(:ai_not_installed), do: "ai_not_installed"
  defp sanitize_reason({:ai_error, inner}) when is_atom(inner), do: "ai_error:#{inner}"

  defp sanitize_reason({:ai_error, {inner_atom, _}}) when is_atom(inner_atom),
    do: "ai_error:#{inner_atom}"

  defp sanitize_reason({:ai_error, _}), do: "ai_error:opaque"

  defp sanitize_reason({:parse_error, {kind, _}}) when is_atom(kind),
    do: "parse_error:#{kind}"

  defp sanitize_reason({:parse_error, kind}) when is_atom(kind),
    do: "parse_error:#{kind}"

  defp sanitize_reason({:persist_error, _}), do: "persist_error"
  defp sanitize_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp sanitize_reason(_), do: "unknown"

  # Builds `%{field_name => primary_text}` for fields whose primary
  # value is a non-empty string. Skipping empty fields keeps the AI
  # prompt focused — translating empty strings is a token waste and
  # confuses the model.
  defp translatable_field_map(resource, type, source_lang) do
    schema = schema_for(type)

    resource_lang_map = Map.get(resource.translations || %{}, source_lang, %{})

    schema.translatable_fields()
    |> Enum.reduce(%{}, fn field, acc ->
      value = field_value(resource, field, resource_lang_map)

      if is_binary(value) and String.trim(value) != "" do
        Map.put(acc, field, value)
      else
        acc
      end
    end)
  end

  # The source value to translate from: the secondary-language column
  # in `translations[source_lang]` if present, otherwise the primary
  # column on the resource. This lets a host translate "from Estonian
  # to French" by passing `source_lang: "et"` after writing the
  # Estonian translation, even though the schema's primary column
  # holds English.
  defp field_value(resource, field, lang_map) do
    case Map.get(lang_map, field) do
      v when is_binary(v) and v != "" ->
        v

      _ ->
        # Guard: `translatable_fields/0` returns strings that should map
        # one-to-one onto Ecto schema fields (atoms), so the atom always
        # exists at runtime. The rescue is belt-and-suspenders for the
        # case where a future schema lists a field name that's never
        # been used as an atom anywhere — falling through to nil makes
        # `translatable_field_map/3` skip it as if blank.
        try do
          Map.get(resource, String.to_existing_atom(field))
        rescue
          ArgumentError -> nil
        end
    end
  end

  defp merge_translation(resource, target_lang, translated_fields) do
    existing = resource.translations || %{}
    target_map = Map.get(existing, target_lang, %{})
    new_target_map = Map.merge(target_map, translated_fields)
    Map.put(existing, target_lang, new_target_map)
  end

  defp persist_translation(resource, "task", merged) do
    Projects.update_task(resource, %{"translations" => merged})
  end

  defp persist_translation(resource, "assignment", merged) do
    Projects.update_assignment_form(resource, %{"translations" => merged})
  end

  defp persist_translation(resource, type, merged) when type in ["project", "template"] do
    Projects.update_project(resource, %{"translations" => merged})
  end

  defp schema_for("project"), do: Project
  defp schema_for("template"), do: Project
  defp schema_for("task"), do: Task
  defp schema_for("assignment"), do: Assignment

  defp load_resource("task", uuid) do
    case Projects.get_task(uuid) do
      nil -> {:error, :resource_not_found}
      task -> {:ok, task}
    end
  end

  defp load_resource("assignment", uuid) do
    case Projects.get_assignment(uuid) do
      nil -> {:error, :resource_not_found}
      assignment -> {:ok, assignment}
    end
  end

  defp load_resource(type, uuid) when type in ["project", "template"] do
    case Projects.get_project(uuid) do
      nil ->
        {:error, :resource_not_found}

      %Project{is_template: true} = template when type == "template" ->
        {:ok, template}

      %Project{is_template: false} = project when type == "project" ->
        {:ok, project}

      # Mismatch: caller passed `"project"` for a template row (or
      # vice versa). The persistence update would still work, but the
      # activity log + broadcast event would carry the wrong
      # `resource_type` for the row's actual lifecycle. Reject so the
      # caller fixes the type.
      %Project{} = row ->
        {:error,
         {:resource_type_mismatch,
          expected: type, actual: if(row.is_template, do: "template", else: "project")}}
    end
  end

  defp fetch_resource_type(args) do
    case Map.get(args, "resource_type") do
      type when type in @resource_types -> {:ok, type}
      other -> {:error, {:invalid_resource_type, other}}
    end
  end

  defp fetch_string(args, key) do
    case Map.get(args, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, {:missing_arg, key}}
    end
  end

  defp get_uuid(%{uuid: uuid}), do: uuid
  # Defensive: every loaded resource carries a `:uuid`, but a future
  # schema (or a malformed struct) without one should degrade to a nil
  # uuid in logs/broadcasts rather than crash the whole job with a
  # FunctionClauseError.
  defp get_uuid(_), do: nil

  defp broadcast(event, resource, type, params, extra \\ []) do
    payload =
      %{
        resource_type: type,
        resource_uuid: get_uuid(resource),
        source_lang: params.source_lang,
        target_lang: params.target_lang
      }
      |> Map.merge(Map.new(extra))

    msg = {:projects, event, payload}

    # `projects:all` always — global subscribers (admin dashboard,
    # activity feed) see every translation event.
    PubSubManager.broadcast(ProjectsPubSub.topic_all(), msg)

    # Per-type fan-out so the LV that already subscribes to a topic
    # for content changes (`projects:tasks` from TasksLive,
    # `projects:templates` from TemplatesLive, `projects:project:<uuid>`
    # from ProjectShowLive) also receives translation lifecycle
    # events for the same resource. Matches the existing
    # `broadcast_task/2` / `broadcast_project/2` fan-out shape.
    Enum.each(broadcast_topics(resource, type), fn topic ->
      PubSubManager.broadcast(topic, msg)
    end)
  end

  defp broadcast_topics(_resource, "task"), do: [ProjectsPubSub.topic_tasks()]

  defp broadcast_topics(resource, "template") do
    [ProjectsPubSub.topic_templates(), ProjectsPubSub.topic_project(resource.uuid)]
  end

  defp broadcast_topics(resource, "project") do
    [ProjectsPubSub.topic_project(resource.uuid)]
  end

  defp broadcast_topics(%Assignment{project_uuid: uuid}, "assignment") when is_binary(uuid) do
    [ProjectsPubSub.topic_project(uuid)]
  end

  defp broadcast_topics(_, _), do: []

  defp stringify_keys(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      kv -> kv
    end)
  end
end
