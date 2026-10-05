defmodule PhoenixKitProjects.TaskNotes do
  @moduledoc """
  The notes thread of a task: what an agent (or a person) wrote while
  working on it — reasoning, what changed, what came out — kept APART from
  the task's discussion, so the human conversation stays readable and the
  long record is there when it is wanted.

  A note is a comment (`phoenix_kit_comments`) on the resource type
  `project_task_notes` with the assignment's uuid: the comments module
  already stores, renders, caps (length, depth) and permissions a thread,
  so nothing is reinvented. What this module adds is the convention —
  one note profile, validated here and nowhere else (panel 2026-10-05:
  "it holds only if the task context enforces one note profile"):

    * `kind` — `agent_note` (through the API), `note` (a person, in the
      drawer), `redirect` (a person changing the direction: "no, that's
      wrong, do X"). Server-set; the drawer declares it a decoration key.
    * `summary` — one line, required on an agent note and a redirect: the
      TLDR the next worker reads first (`display_summary/2`).
    * `outcome` — the agent's claim about THIS attempt (`done`, `partial`,
      `blocked`, `failed`, `needs_review`); a later redirect supersedes it,
      and it never becomes the task's status.
    * `refs` — the artifacts of this attempt: `{type, id, url?, label?}`,
      a commit, a branch, a PR, a run, a file… Shape-validated, never
      fetched, type is a free slug (a fixed catalogue rots; a published
      recommended list is in the docs). Per note, not per task: attempt
      one's commit is not attempt two's.
    * `next_steps` — where the agent stopped and what it would do next.
    * `usage` — the tokens / cost / minutes reported WITH the note. The
      figures are ledger rows (each carrying `note_uuid`); totals are sums
      over those, never over this map, which is the per-note display.
    * the author — a comment needs a real user, so an agent's note is
      written by the person who minted the key (the accountable person),
      with the key's name pinned as the display name and the key itself
      in `metadata.api_key`.

  The note and its ledger rows are one transaction. Notes are meant to be
  append-only; the comments module lets the author edit or delete one,
  and when that happens the ledger rows stay — the ledger is the money
  truth, the note the narrative.
  """

  use Gettext, backend: PhoenixKitProjects.Gettext
  import Ecto.Query

  alias PhoenixKit.RepoHelper
  alias PhoenixKitProjects.Ledger
  alias PhoenixKitProjects.Schemas.Assignment

  @resource_type "project_task_notes"
  @kinds ~w(agent_note note redirect)
  @outcomes ~w(done partial blocked failed needs_review)
  @summary_max 240
  @next_steps_max 2000
  @refs_max 20
  @recommended_ref_types ~w(commit branch pr issue run deploy file url ticket)

  @doc "The comments resource type a task's notes live under."
  @spec resource_type() :: String.t()
  def resource_type, do: @resource_type

  @doc "The note kinds."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc "The outcomes an agent may claim for an attempt."
  @spec outcomes() :: [String.t()]
  def outcomes, do: @outcomes

  @doc "The reference types the docs recommend (any slug is accepted)."
  @spec recommended_ref_types() :: [String.t()]
  def recommended_ref_types, do: @recommended_ref_types

  @doc "The summary's length cap."
  @spec summary_max() :: pos_integer()
  def summary_max, do: @summary_max

  @doc "Whether notes can be stored: the comments module loaded and switched on."
  @spec available?() :: boolean()
  def available? do
    Code.ensure_loaded?(PhoenixKitComments) and
      function_exported?(PhoenixKitComments, :enabled?, 0) and
      PhoenixKitComments.enabled?()
  rescue
    _ -> false
  end

  @doc "A task's notes, oldest first, authors preloaded. Empty when comments are absent."
  @spec list(binary()) :: [map()]
  def list(assignment_uuid) when is_binary(assignment_uuid),
    do: list_on(@resource_type, assignment_uuid)

  @project_resource_type "project_notes"

  @doc "The comments anchor type of a PROJECT's notes: decisions, research, the in-flight block."
  @spec project_resource_type() :: String.t()
  def project_resource_type, do: @project_resource_type

  @doc "A project's own notes (not its tasks'), oldest first; `since` keeps only the newer ones."
  @spec list_for_project(binary(), DateTime.t() | nil) :: [map()]
  def list_for_project(project_uuid, since \\ nil) when is_binary(project_uuid) do
    @project_resource_type
    |> list_on(project_uuid)
    |> Enum.filter(fn note ->
      is_nil(since) or DateTime.compare(note.inserted_at, since) == :gt
    end)
  end

  defp list_on(type, uuid) do
    PhoenixKitComments.list_comments(type, uuid, status: "published", preload: [:user])
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  @doc "Published note counts per assignment, for the task row's badge. One query."
  @spec count_for_assignments([binary()]) :: %{binary() => non_neg_integer()}
  def count_for_assignments([]), do: %{}

  def count_for_assignments(uuids) when is_list(uuids) do
    from(c in PhoenixKitComments.Comment,
      where:
        c.resource_type == @resource_type and c.resource_uuid in ^uuids and
          c.status == "published",
      group_by: c.resource_uuid,
      select: {c.resource_uuid, count(c.uuid)}
    )
    |> RepoHelper.repo().all()
    |> Map.new()
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  @doc """
  What the next worker reads first: the latest redirect (the direction
  now), the latest agent note (its outcome and summary) and the latest
  note a person wrote — each the whole note, or nil.
  """
  @spec latest(binary() | [map()]) :: %{
          redirect: map() | nil,
          agent: map() | nil,
          human: map() | nil
        }
  def latest(assignment_uuid) when is_binary(assignment_uuid), do: latest(list(assignment_uuid))

  def latest(notes) when is_list(notes) do
    by_kind = fn kinds -> notes |> Enum.filter(&(kind(&1) in kinds)) |> List.last() end

    %{
      redirect: by_kind.(["redirect"]),
      agent: by_kind.(["agent_note"]),
      human: by_kind.(["note", "redirect"])
    }
  end

  @doc "A note's kind (`note` when unset)."
  @spec kind(map()) :: String.t()
  def kind(note), do: (note.metadata || %{})["kind"] || "note"

  @doc """
  The one line to show for a task, and where it came from: the person's
  description when there is one, else the latest redirect's summary, else
  the latest agent note's summary (a preview, unconfirmed), else nothing.
  """
  @spec display_summary(String.t() | nil, map()) ::
          %{text: String.t() | nil, source: :description | :redirect | :agent | nil}
  def display_summary(description, latest) do
    cond do
      is_binary(description) and String.trim(description) != "" ->
        %{text: description, source: :description}

      summary = latest[:redirect] && latest.redirect.metadata["summary"] ->
        %{text: summary, source: :redirect}

      summary = latest[:agent] && latest.agent.metadata["summary"] ->
        %{text: summary, source: :agent}

      true ->
        %{text: nil, source: nil}
    end
  end

  @doc """
  Validates a note's fields and returns them normalised:
  `{:ok, %{content, summary, outcome, refs, next_steps, usage}}` or
  `{:error, %{field => [message]}}`. `usage` arrives already validated
  (integers) from the caller. An agent note or a redirect needs a
  `summary`; a person's note needs content; `outcome` is for agent notes.
  """
  @spec validate(map(), String.t()) :: {:ok, map()} | {:error, %{String.t() => [String.t()]}}
  def validate(attrs, kind) when kind in @kinds do
    get = fn key -> Map.get(attrs, key) || Map.get(attrs, String.to_atom(key)) end

    fields = %{
      content: blank_to_nil(get.("content")),
      summary: blank_to_nil(get.("summary")),
      outcome: blank_to_nil(get.("outcome")),
      next_steps: blank_to_nil(get.("next_steps")),
      refs: get.("refs"),
      usage: normalize_usage(get.("usage"))
    }

    errors =
      Enum.reduce([:summary, :content, :outcome, :next_steps, :refs], %{}, fn field, acc ->
        check(acc, field, fields, kind)
      end)

    if errors == %{} do
      {:ok, %{fields | refs: normalize_refs(fields.refs)}}
    else
      {:error, errors}
    end
  end

  def validate(_attrs, _kind),
    do: {:error, %{"kind" => ["must be one of #{Enum.join(@kinds, ", ")}"]}}

  defp check(errors, :summary, %{summary: nil}, kind) when kind in ["agent_note", "redirect"],
    do: Map.put(errors, "summary", ["is required: one line the next worker reads first"])

  defp check(errors, :summary, %{summary: nil}, _kind), do: errors

  defp check(errors, :summary, %{summary: s}, _kind) when is_binary(s) do
    if String.length(s) > @summary_max,
      do: Map.put(errors, "summary", ["must be at most #{@summary_max} characters"]),
      else: errors
  end

  defp check(errors, :summary, %{summary: _}, _kind),
    do: Map.put(errors, "summary", ["must be a string"])

  defp check(errors, :content, %{content: nil, usage: nil}, "note"),
    do: Map.put(errors, "content", ["is required"])

  defp check(errors, :content, %{content: c}, _kind) when not is_nil(c) and not is_binary(c),
    do: Map.put(errors, "content", ["must be a string"])

  defp check(errors, :content, _fields, _kind), do: errors

  defp check(errors, :outcome, %{outcome: nil}, _kind), do: errors

  defp check(errors, :outcome, %{outcome: o}, "agent_note") when o in @outcomes, do: errors

  defp check(errors, :outcome, %{outcome: _}, "agent_note"),
    do: Map.put(errors, "outcome", ["must be one of #{Enum.join(@outcomes, ", ")}"])

  defp check(errors, :outcome, _fields, _kind),
    do: Map.put(errors, "outcome", ["is for agent notes only"])

  defp check(errors, :next_steps, %{next_steps: nil}, _kind), do: errors

  defp check(errors, :next_steps, %{next_steps: s}, _kind) when is_binary(s) do
    if String.length(s) > @next_steps_max,
      do: Map.put(errors, "next_steps", ["must be at most #{@next_steps_max} characters"]),
      else: errors
  end

  defp check(errors, :next_steps, _fields, _kind),
    do: Map.put(errors, "next_steps", ["must be a string"])

  defp check(errors, :refs, %{refs: nil}, _kind), do: errors

  defp check(errors, :refs, %{refs: refs}, _kind) when is_list(refs) do
    if length(refs) > @refs_max do
      Map.put(errors, "refs", ["at most #{@refs_max} per note"])
    else
      case Enum.find_value(Enum.with_index(refs), &ref_error/1) do
        nil -> errors
        message -> Map.put(errors, "refs", [message])
      end
    end
  end

  defp check(errors, :refs, _fields, _kind),
    do: Map.put(errors, "refs", ["must be a list of {type, id, url?, label?}"])

  # One reference: a slug type, a non-empty id, an http(s) url without
  # credentials if any, a short label if any. The first failing part names
  # itself.
  defp ref_error({ref, idx}) when is_map(ref) do
    [
      type_error(ref["type"] || ref[:type]),
      id_error(ref["id"] || ref[:id]),
      url_error(ref["url"] || ref[:url]),
      label_error(ref["label"] || ref[:label])
    ]
    |> Enum.find(&is_binary/1)
    |> case do
      nil -> nil
      message -> "refs[#{idx}].#{message}"
    end
  end

  defp ref_error({_ref, idx}), do: "refs[#{idx}] must be an object"

  defp type_error(type) do
    if Regex.match?(~r/\A[a-z][a-z0-9_-]{0,31}\z/, to_string(type || "")),
      do: nil,
      else: "type must be a slug (a-z, 0-9, _ -), 1–32 characters"
  end

  defp id_error(id) do
    id = to_string(id || "")

    if id == "" or String.length(id) > 256,
      do: "id is required, at most 256 characters",
      else: nil
  end

  defp url_error(nil), do: nil

  defp url_error(url) do
    if valid_url?(url),
      do: nil,
      else: "url must be an http(s) URL without credentials, at most 2048 characters"
  end

  defp label_error(nil), do: nil

  defp label_error(label) when is_binary(label) and byte_size(label) <= 480 do
    if String.length(label) > 120, do: "label must be a string of at most 120 characters"
  end

  defp label_error(_), do: "label must be a string of at most 120 characters"

  defp valid_url?(url) when is_binary(url) and byte_size(url) <= 2048 do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, userinfo: nil} when scheme in ["http", "https"] ->
        is_binary(host) and host != ""

      _ ->
        false
    end
  end

  defp valid_url?(_), do: false

  # Normalised, deduped on (type, id) within the note — a revert may
  # legitimately re-reference a commit on a LATER note.
  defp normalize_refs(nil), do: nil

  defp normalize_refs(refs) do
    refs
    |> Enum.map(fn ref ->
      %{
        "type" => to_string(ref["type"] || ref[:type]),
        "id" => to_string(ref["id"] || ref[:id])
      }
      |> maybe_put_str("url", ref["url"] || ref[:url])
      |> maybe_put_str("label", ref["label"] || ref[:label])
    end)
    |> Enum.uniq_by(&{&1["type"], &1["id"]})
  end

  @doc """
  Writes a note on `assignment`, and its usage into the project's ledger,
  in one transaction. `fields` is what `validate/2` returned.

  Options: `:user_uuid` (required — the comment's author), `:label` (the
  pinned display name, e.g. the key's name), `:kind` (default
  `"agent_note"`), `:actor` (`%{kind, uuid}` for the ledger rows; default
  the user), `:metadata` (extra keys kept on the note, e.g. the key).

  Returns `{:ok, %{note, entries}}`.
  """
  @spec create(Assignment.t(), map(), keyword()) ::
          {:ok, %{note: map(), entries: [map()]}} | {:error, term()}
  def create(%Assignment{} = assignment, fields, opts) do
    create_on(
      %{
        anchor_type: @resource_type,
        anchor_uuid: assignment.uuid,
        project_uuid: assignment.project_uuid,
        assignment_uuid: assignment.uuid
      },
      fields,
      opts
    )
  end

  @doc """
  Writes a note on the PROJECT itself — the same shape, the same ledger
  rows for its usage, no task. Options as `create/3`.
  """
  @spec create_for_project(map(), map(), keyword()) ::
          {:ok, %{note: map(), entries: [map()]}} | {:error, term()}
  def create_for_project(%{uuid: project_uuid}, fields, opts) do
    create_on(
      %{
        anchor_type: @project_resource_type,
        anchor_uuid: project_uuid,
        project_uuid: project_uuid,
        assignment_uuid: nil
      },
      fields,
      opts
    )
  end

  defp create_on(target, fields, opts) do
    user_uuid = Keyword.fetch!(opts, :user_uuid)
    kind = Keyword.get(opts, :kind, "agent_note")

    cond do
      not available?() -> {:error, :unavailable}
      kind not in @kinds -> {:error, :invalid_kind}
      true -> insert(target, fields, kind, user_uuid, opts)
    end
  end

  defp insert(target, fields, kind, user_uuid, opts) do
    repo = RepoHelper.repo()
    label = Keyword.get(opts, :label)
    actor = Keyword.get(opts, :actor) || %{kind: "user", uuid: user_uuid}
    extra = Keyword.get(opts, :metadata, %{})

    repo.transaction(fn ->
      with {:ok, note} <- insert_note(target, fields, kind, user_uuid, label, extra),
           {:ok, entries} <- record_usage(target, fields[:usage], note, actor, user_uuid),
           {:ok, note} <- link_entries(note, entries) do
        %{note: repo.preload(note, [:user]), entries: entries}
      else
        {:error, reason} -> repo.rollback(reason)
      end
    end)
  end

  defp insert_note(target, fields, kind, user_uuid, label, extra) do
    metadata =
      extra
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put("kind", kind)
      |> maybe_put_str("summary", fields[:summary])
      |> maybe_put_str("outcome", fields[:outcome])
      |> maybe_put_str("next_steps", fields[:next_steps])
      |> maybe_put_list("refs", fields[:refs])
      |> put_usage(fields[:usage])

    attrs =
      %{
        # A usage-only note has nothing to say but its figures; the
        # comments module wants text or media, so the summary stands in.
        content: fields[:content] || fields[:summary] || "",
        metadata: metadata,
        # Server-side: a note is never queued for moderation.
        status: "published"
      }
      |> maybe_attribution(label)

    PhoenixKitComments.create_comment(target.anchor_type, target.anchor_uuid, user_uuid, attrs)
  end

  defp maybe_attribution(attrs, label) when is_binary(label) and label != "",
    do: Map.put(attrs, :attribution, %{mode: "personal", label: label})

  defp maybe_attribution(attrs, _), do: attrs

  defp put_usage(metadata, nil), do: metadata

  defp put_usage(metadata, usage) do
    metadata
    |> Map.put("usage", Map.new(usage, fn {k, v} -> {to_string(k), usage_value(v)} end))
    |> Map.put("usage_label", usage_label(usage))
  end

  defp usage_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp usage_value(v), do: v

  # The ledger rows for the usage: tokens and cost through `record_ai/3`
  # (one row per non-zero figure), minutes through `log_time/3` — never
  # billable, the actor is the agent (the key) or the person. Every row
  # names the note.
  defp record_usage(_target, nil, _note, _actor, _user_uuid), do: {:ok, []}

  defp record_usage(target, usage, note, actor, user_uuid) do
    project_uuid = target.project_uuid
    base_meta = %{"note_uuid" => note.uuid, "entered_by_uuid" => user_uuid, "via" => "api"}

    with {:ok, ai_entries} <- record_ai(project_uuid, target, usage, actor, base_meta),
         {:ok, time_entries} <- record_minutes(project_uuid, target, usage, actor, base_meta) do
      {:ok, ai_entries ++ time_entries}
    end
  end

  defp record_ai(project_uuid, target, usage, actor, base_meta) do
    tokens = usage[:tokens] || 0
    cost = usage[:cost_cents] || 0

    if tokens > 0 or cost > 0 do
      payload =
        base_meta
        |> Map.merge(%{tokens: tokens, cost_cents: cost, agent_uuid: actor.uuid})
        |> maybe_put(:model, usage[:model])
        |> maybe_put(:estimated, if(usage[:estimated] == true, do: true))

      Ledger.record_ai(project_uuid, payload,
        assignment_uuid: target.assignment_uuid,
        occurred_at: usage[:occurred_at]
      )
    else
      {:ok, []}
    end
  end

  defp record_minutes(project_uuid, target, %{minutes: minutes} = usage, actor, meta)
       when is_integer(minutes) and minutes > 0 do
    case Ledger.log_time(project_uuid, minutes,
           assignment_uuid: target.assignment_uuid,
           billable: false,
           actor_kind: ledger_actor_kind(actor.kind),
           actor_uuid: actor.uuid,
           source: if(actor.kind == "ai_agent", do: "ai", else: "manual"),
           ended_at: usage[:occurred_at],
           metadata: meta
         ) do
      {:ok, entry} -> {:ok, [entry]}
      {:error, _} = error -> error
    end
  end

  defp record_minutes(_, _, _, _, _), do: {:ok, []}

  defp ledger_actor_kind("ai_agent"), do: "ai_agent"
  defp ledger_actor_kind("staff_person"), do: "staff_person"
  defp ledger_actor_kind(_), do: "user"

  # The note learns its rows' uuids, so the drawer and the API can point
  # from the note to the figures without a search. The rows stay the
  # truth: a total is never read from here.
  defp link_entries(note, []), do: {:ok, note}

  defp link_entries(note, entries) do
    usage = Map.put(note.metadata["usage"] || %{}, "entries", Enum.map(entries, & &1.uuid))
    metadata = Map.put(note.metadata, "usage", usage)

    note
    |> Ecto.Changeset.change(metadata: metadata)
    |> RepoHelper.repo().update()
  end

  defp normalize_usage(nil), do: nil

  defp normalize_usage(usage) when is_map(usage) do
    usage = Map.new(usage, fn {k, v} -> {to_atom_key(k), v} end)

    if Enum.any?([:tokens, :cost_cents, :minutes], &positive?(usage[&1])),
      do: Map.take(usage, [:tokens, :cost_cents, :minutes, :model, :occurred_at, :estimated]),
      else: nil
  end

  defp normalize_usage(_), do: nil

  defp positive?(n), do: is_integer(n) and n > 0

  defp to_atom_key(k) when is_atom(k), do: k

  defp to_atom_key(k) when is_binary(k) do
    case k do
      "tokens" -> :tokens
      "cost_cents" -> :cost_cents
      "minutes" -> :minutes
      "model" -> :model
      "occurred_at" -> :occurred_at
      "estimated" -> :estimated
      _other -> :ignored
    end
  end

  @doc "The one-line form of a usage map: `1.8k tokens · $0.03 · 4m`."
  @spec usage_label(map() | nil) :: String.t() | nil
  def usage_label(nil), do: nil

  def usage_label(usage) when is_map(usage) do
    get = fn key -> Map.get(usage, key) || Map.get(usage, to_string(key)) end

    [
      get.(:tokens) |> positive_or_nil() |> then(&(&1 && "#{format_tokens(&1)} tokens")),
      get.(:cost_cents) |> positive_or_nil() |> then(&(&1 && "$#{format_cents(&1)}")),
      get.(:minutes) |> positive_or_nil() |> then(&(&1 && "#{&1}m"))
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, " · ")
    end
  end

  defp positive_or_nil(n) when is_integer(n) and n > 0, do: n
  defp positive_or_nil(_), do: nil

  defp format_tokens(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_tokens(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}k"
  defp format_tokens(n), do: Integer.to_string(n)

  defp format_cents(c), do: :erlang.float_to_binary(c / 100, decimals: 2)

  @doc """
  The decoration registry the comments drawer renders a note's lines
  with: a label above a comment when one of its metadata values is listed
  here — the usage line (every distinct `usage_label` maps to itself), the
  kind for a redirect, and the outcome.
  """
  @spec decorations([map()]) :: map()
  def decorations(notes) do
    labels =
      notes
      |> Enum.map(&get_in(&1.metadata, ["usage_label"]))
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    outcomes =
      Map.new(@outcomes, fn outcome ->
        label = gettext("Outcome: %{outcome}", outcome: String.replace(outcome, "_", " "))
        {outcome, %{label: label, on_save: nil}}
      end)

    %{}
    |> put_decoration("usage_label", Map.new(labels, &{&1, %{label: &1, on_save: nil}}))
    |> put_decoration("kind", %{
      "redirect" => %{label: gettext("Direction changed"), on_save: nil}
    })
    |> put_decoration("outcome", outcomes)
  end

  defp put_decoration(map, _key, values) when map_size(values) == 0, do: map
  defp put_decoration(map, key, values), do: Map.put(map, key, values)

  @doc "The metadata keys a form may never set on a note (the drawer declares them)."
  @spec decoration_keys() :: [String.t()]
  def decoration_keys,
    do: ~w(kind summary outcome next_steps refs usage usage_label api_key api_key_name via)

  @doc "The JSON shape of a note for the API."
  @spec to_json(map()) :: map()
  def to_json(note) do
    m = note.metadata || %{}

    %{
      uuid: note.uuid,
      kind: m["kind"] || "note",
      author: author_label(note),
      summary: m["summary"],
      outcome: m["outcome"],
      content: note.content,
      next_steps: m["next_steps"],
      refs: m["refs"] || [],
      usage: m["usage"],
      inserted_at: note.inserted_at
    }
  end

  defp author_label(%{author_display_name: name}) when is_binary(name) and name != "", do: name

  defp author_label(%{user: %{email: email}}) when is_binary(email), do: email
  defp author_label(_), do: nil

  defp blank_to_nil(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: v)
  defp blank_to_nil(v), do: v

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)

  defp maybe_put_str(map, _k, nil), do: map
  defp maybe_put_str(map, k, v) when is_binary(v), do: Map.put(map, k, v)
  defp maybe_put_str(map, _k, _v), do: map

  defp maybe_put_list(map, _k, nil), do: map
  defp maybe_put_list(map, k, v) when is_list(v), do: Map.put(map, k, v)
  defp maybe_put_list(map, _k, _v), do: map
end
