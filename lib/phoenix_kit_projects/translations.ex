defmodule PhoenixKitProjects.Translations do
  @moduledoc """
  Public API for AI-driven translation of `Project`, `Task`, and
  `Assignment` resources. Wraps Oban enqueuing on
  `PhoenixKitProjects.Workers.TranslateResourceWorker` and exposes
  helpers hosts use to drive the language switcher's `ai_translate`
  attr.

  ## Design notes

  - **Worker does the AI call**, this module just enqueues. Host LVs
    call `enqueue/1` from a `handle_event` clause and subscribe to
    the projects PubSub topic for status updates.
  - **One job per `(resource, target_lang)` pair**. Uniqueness is
    enforced at the Oban worker level; this module just emits the
    enqueue call. A second enqueue for an in-flight pair returns
    `{:ok, %{conflict?: true}}`.
  - **`enqueue_all_missing/1`** loops over the resource's missing
    languages and enqueues one job per language. Each runs
    independently; status events arrive in the order Oban completes
    them, not the order the languages were enqueued.
  - **No "translate all resources in a project" bulk action**. That's
    a level above this module — a host can iterate projects and
    call `enqueue_all_missing/1` per resource if desired.

  ## Status flow

  1. Host calls `enqueue/1` → `{:ok, %{conflict?: false}}` and a
     `:translation_started` PubSub event fires from the worker.
  2. Host's `handle_info({:projects, :translation_started, ...})`
     adds `target_lang` to its `in_flight` set, re-renders the
     switcher with the updated `ai_translate.in_flight` list →
     spinner replaces sparkle.
  3. Worker completes → `:translation_completed` event. Host removes
     `target_lang` from `in_flight` AND from `missing` (the language
     now has a translation), re-renders.
  4. On failure: `:translation_failed` event with `:reason`. Host
     removes from `in_flight` (leaves in `missing`) and surfaces a
     flash.
  """

  alias PhoenixKit.Modules.AI, as: AIModule
  alias PhoenixKit.Settings
  alias PhoenixKitProjects.Workers.TranslateResourceWorker

  @resource_types ~w(project template task assignment)
  @translation_prompt_slug "translate-projects-content"
  @endpoint_setting_key "projects_translation_endpoint_uuid"
  @prompt_setting_key "projects_translation_prompt_uuid"

  # `PhoenixKitAI` is the optional plugin — hosts may not pull it in.
  # `PhoenixKit.Modules.AI` is core (1.7.117+) and required.
  @compile {:no_warn_undefined,
            [
              {PhoenixKitAI, :enabled?, 0},
              {PhoenixKitAI, :list_endpoints, 1},
              {PhoenixKitAI, :list_prompts, 1},
              {PhoenixKitAI, :get_prompt_by_slug, 1},
              {PhoenixKitAI, :create_prompt, 1}
            ]}

  @doc """
  Is AI-driven translation usable right now?

  Returns `true` when the optional `PhoenixKitAI` plugin is loaded, the
  module is enabled at runtime, and at least one AI endpoint is
  configured. Hosts use this to gate the AI translate UI surface.
  """
  @spec ai_translation_available?() :: boolean()
  def ai_translation_available? do
    AIModule.available?() and
      safe_ai_call(fn -> PhoenixKitAI.enabled?() end, false) and
      list_ai_endpoints() != []
  end

  @doc """
  List configured AI endpoints as `{uuid, name}` tuples. Empty when AI
  is unavailable.
  """
  @spec list_ai_endpoints() :: [{String.t(), String.t()}]
  def list_ai_endpoints do
    safe_ai_call(
      fn ->
        if PhoenixKitAI.enabled?() do
          {endpoints, _} = PhoenixKitAI.list_endpoints(enabled: true)
          Enum.map(endpoints, &{&1.uuid, &1.name})
        else
          []
        end
      end,
      []
    )
  end

  @doc """
  List configured AI prompts as `{uuid, name}` tuples. Empty when AI
  is unavailable.
  """
  @spec list_ai_prompts() :: [{String.t(), String.t()}]
  def list_ai_prompts do
    safe_ai_call(
      fn ->
        if PhoenixKitAI.enabled?() do
          case PhoenixKitAI.list_prompts(enabled: true) do
            {prompts, _} -> Enum.map(prompts, &{&1.uuid, &1.name})
            prompts when is_list(prompts) -> Enum.map(prompts, &{&1.uuid, &1.name})
          end
        else
          []
        end
      end,
      []
    )
  end

  @doc "Resolves the default AI endpoint UUID from Settings, or `nil`."
  @spec get_default_ai_endpoint_uuid() :: String.t() | nil
  def get_default_ai_endpoint_uuid do
    case Settings.get_setting(@endpoint_setting_key) do
      "" -> nil
      value -> value
    end
  end

  @doc """
  Resolves the default AI prompt UUID. Prefers the explicit setting;
  falls back to the prompt matching `@translation_prompt_slug` if one
  exists. Returns `nil` when nothing is wired up.
  """
  @spec get_default_ai_prompt_uuid() :: String.t() | nil
  def get_default_ai_prompt_uuid do
    case Settings.get_setting(@prompt_setting_key) do
      nil -> fallback_prompt_uuid()
      "" -> fallback_prompt_uuid()
      value -> value
    end
  end

  defp fallback_prompt_uuid do
    safe_ai_call(
      fn ->
        if PhoenixKitAI.enabled?() do
          case PhoenixKitAI.get_prompt_by_slug(@translation_prompt_slug) do
            nil -> nil
            prompt -> prompt.uuid
          end
        end
      end,
      nil
    )
  end

  @doc "Is the default projects translation prompt already provisioned?"
  @spec default_translation_prompt_exists?() :: boolean()
  def default_translation_prompt_exists? do
    safe_ai_call(
      fn ->
        PhoenixKitAI.enabled?() and
          PhoenixKitAI.get_prompt_by_slug(@translation_prompt_slug) != nil
      end,
      false
    )
  end

  @doc """
  Generates the default projects translation prompt in the AI prompts
  catalog. Returns `{:ok, prompt}` or `{:error, changeset}`. No-op
  surface when `PhoenixKitAI` is unavailable — returns
  `{:error, :ai_not_installed}`.
  """
  @spec generate_default_translation_prompt() :: {:ok, struct()} | {:error, term()}
  def generate_default_translation_prompt do
    # Wrap the plugin call in `safe_ai_call/2` so an enabled-but-
    # broken `PhoenixKitAI` (incompatible version, raising on
    # unexpected attr keys, etc.) returns `{:error, :ai_not_installed}`
    # rather than crashing the caller's IEx / admin button.
    if AIModule.available?() do
      safe_ai_call(fn -> do_generate_default_prompt() end, {:error, :ai_not_installed})
    else
      {:error, :ai_not_installed}
    end
  end

  defp do_generate_default_prompt do
    PhoenixKitAI.create_prompt(%{
      slug: @translation_prompt_slug,
      name: "Translate Projects Content",
      description:
        "Default prompt for translating projects, templates, tasks, and assignments between languages.",
      content: """
      You are translating fields of a project-management resource from {{SourceLanguage}} to {{TargetLanguage}}.

      RULES:
      - Preserve formatting exactly (line breaks, spacing, Markdown if present).
      - Do NOT translate text inside code blocks, inline code, or URLs.
      - Translate naturally and idiomatically — match the tone of the source.
      - Keep any HTML tags and special syntax unchanged.
      - Output ONLY the structured markers below — no commentary, no preface, no closing remarks.

      OUTPUT FORMAT — for each non-empty field below, emit ONE
      marker named after the field, followed by the translation:

          ---<FIELD_NAME_UPPERCASE>---
          [translated value]

      Examples:

          ---NAME---
          <translated name>

          ---TITLE---
          <translated title>

          ---DESCRIPTION---
          <translated description>

      If a field is missing or blank from the SOURCE section, do
      NOT emit a marker for it. Do not emit markers for fields the
      caller did not provide. A value that still looks like a
      literal placeholder (`{{name}}`, `{{title}}`, `{{description}}`,
      etc.) means the caller did not bind that variable and the
      field MUST be skipped — do not emit a marker, do not translate
      the placeholder string itself.

      === SOURCE ===

      Name: {{name}}

      Title: {{title}}

      Description: {{description}}
      """
    })
  end

  # Narrowed `rescue` to the exceptions a missing/broken plugin
  # actually raises: `UndefinedFunctionError` (module not loaded),
  # `FunctionClauseError` (incompatible signature in an older plugin
  # version), and `ArgumentError` (bad input — e.g. nil-fed to the
  # plugin). Anything else is a programming bug and should crash so
  # it surfaces in the test suite.
  #
  # `catch :exit, _` and `catch :throw, _` are intentionally broad
  # — the optional plugin lives behind an arbitrary GenServer (its
  # HTTP client + supervisor tree), and any process down there can
  # exit / throw in shapes we don't control. This module acts as a
  # plugin-boundary fuse, so the broad catch is the correct
  # blast-radius limiter rather than a debugging crutch.
  defp safe_ai_call(fun, default) do
    fun.()
  rescue
    UndefinedFunctionError -> default
    FunctionClauseError -> default
    ArgumentError -> default
  catch
    :exit, _ -> default
    :throw, _ -> default
  end

  @type resource_type :: String.t()
  @type enqueue_params :: %{
          required(:resource_type) => resource_type(),
          required(:resource_uuid) => String.t(),
          required(:endpoint_uuid) => String.t(),
          required(:prompt_uuid) => String.t(),
          required(:source_lang) => String.t(),
          required(:target_lang) => String.t(),
          optional(:actor_uuid) => String.t() | nil
        }

  @doc """
  Enqueue a translation job for a single resource + target language.

  Returns `{:ok, %{conflict?: false}}` when the job is freshly
  enqueued, or `{:ok, %{conflict?: true}}` when an identical job is
  already in flight (Oban's unique constraint catches the dup).

  Validates required keys and returns `{:error, {:invalid, [keys]}}`
  on a malformed input map — saves the host LV from cryptic Oban
  exceptions at job perform time.
  """
  @spec enqueue(enqueue_params()) ::
          {:ok, %{conflict?: boolean()}} | {:error, term()}
  def enqueue(%{} = params) do
    with :ok <- validate_params(params),
         args <- to_job_args(params),
         {:ok, %Oban.Job{conflict?: conflict?}} <-
           args |> TranslateResourceWorker.new() |> Oban.insert() do
      {:ok, %{conflict?: conflict?}}
    end
  end

  # Fail closed with a structured error rather than crashing the
  # caller with FunctionClauseError when a host accidentally passes
  # the wrong shape (e.g. a list of params from a stale flash).
  def enqueue(_other), do: {:error, {:invalid, :not_a_map}}

  @doc """
  Enqueue one translation job per missing target language.

  `missing_langs` is host-supplied — typically computed as
  `enabled_languages -- ([primary_language] ++ Map.keys(resource.translations))`.

  Returns `{:ok, %{enqueued: N, conflicts: M, errors: [...], in_flight: [...]}}`:

  * `enqueued` — number of jobs newly inserted into Oban.
  * `conflicts` — number of duplicates (job for that lang already running).
  * `errors` — list of `{lang, reason}` for langs whose enqueue raised
    or returned `{:error, _}`. Callers should surface this as a partial
    failure.
  * `in_flight` — exactly the langs whose enqueue succeeded (newly or
    by conflict). This is what a host should add to its UI spinner set:
    failed langs MUST NOT spin because no worker broadcast will arrive
    to clear them.
  """
  @spec enqueue_all_missing(enqueue_params(), [String.t()]) ::
          {:ok,
           %{
             enqueued: non_neg_integer(),
             conflicts: non_neg_integer(),
             errors: [{String.t(), term()}],
             in_flight: [String.t()]
           }}
          | {:error, term()}
  def enqueue_all_missing(%{} = base_params, missing_langs) when is_list(missing_langs) do
    base_params
    |> Map.drop([:target_lang])
    |> validate_partial_params()
    |> case do
      :ok ->
        results =
          Enum.map(missing_langs, fn lang ->
            {lang, base_params |> Map.put(:target_lang, lang) |> enqueue()}
          end)

        enqueued_langs =
          for {lang, {:ok, %{conflict?: false}}} <- results, do: lang

        conflict_langs =
          for {lang, {:ok, %{conflict?: true}}} <- results, do: lang

        errors =
          for {lang, {:error, reason}} <- results, do: {lang, reason}

        # `in_flight` is the set the host should add to its spinner state
        # — every lang whose Oban job is now running (or already was).
        # Languages whose enqueue returned an error must NOT be in this
        # set, since no worker broadcast will arrive to clear them.
        {:ok,
         %{
           enqueued: length(enqueued_langs),
           conflicts: length(conflict_langs),
           errors: errors,
           in_flight: enqueued_langs ++ conflict_langs
         }}

      {:error, _} = err ->
        err
    end
  end

  # Fallback for host-passed bad shapes — same defensive posture as
  # `enqueue/1`. Returns a structured error rather than
  # FunctionClauseError so a stale popup session can't crash a LV.
  def enqueue_all_missing(_base_params, _missing_langs),
    do: {:error, {:invalid, :bad_arguments}}

  defp validate_params(params) do
    required = [
      :resource_type,
      :resource_uuid,
      :endpoint_uuid,
      :prompt_uuid,
      :source_lang,
      :target_lang
    ]

    missing = for key <- required, blank?(value_for(params, key)), do: key

    # UUID-shaped fields must actually look like UUIDs — catches stale
    # settings (e.g. `"not-a-uuid"`) at enqueue time rather than letting
    # the Oban worker explode on an obviously bad arg three retries
    # later.
    bad_uuids = invalid_uuids(params, [:resource_uuid, :endpoint_uuid, :prompt_uuid])

    cond do
      missing != [] ->
        {:error, {:invalid, missing}}

      bad_uuids != [] ->
        {:error, {:invalid_uuids, bad_uuids}}

      value_for(params, :resource_type) not in @resource_types ->
        {:error, {:invalid_resource_type, value_for(params, :resource_type)}}

      true ->
        :ok
    end
  end

  defp invalid_uuids(params, keys) do
    for key <- keys,
        value = value_for(params, key),
        is_binary(value),
        not blank?(value),
        Ecto.UUID.cast(value) == :error,
        do: key
  end

  defp validate_partial_params(params) do
    required = [:resource_type, :resource_uuid, :endpoint_uuid, :prompt_uuid, :source_lang]
    missing = for key <- required, blank?(value_for(params, key)), do: key
    if missing == [], do: :ok, else: {:error, {:invalid, missing}}
  end

  # Read either atom- or string-keyed entry without OR-ing two
  # lookups (each missing key on the other side counts as blank,
  # which made every required field look missing).
  defp value_for(params, key) when is_atom(key) do
    case Map.fetch(params, key) do
      {:ok, value} -> value
      :error -> Map.get(params, Atom.to_string(key))
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false

  defp to_job_args(params) do
    %{
      "resource_type" => params[:resource_type] || params["resource_type"],
      "resource_uuid" => params[:resource_uuid] || params["resource_uuid"],
      "endpoint_uuid" => params[:endpoint_uuid] || params["endpoint_uuid"],
      "prompt_uuid" => params[:prompt_uuid] || params["prompt_uuid"],
      "source_lang" => params[:source_lang] || params["source_lang"],
      "target_lang" => params[:target_lang] || params["target_lang"],
      "actor_uuid" => params[:actor_uuid] || params["actor_uuid"]
    }
  end
end
