defmodule PhoenixKitProjects.Ledger do
  @moduledoc """
  The work ledger (Step 10): unified effort tracking where the actor can
  be a human or an AI agent and the quantity minutes, tokens, or cents —
  one table, so "what did this task actually cost" is a single query
  across people-hours and AI spend.

  Append-only: corrections are new entries; nothing here updates or
  deletes rows. Ledger writes ride the `ledger` feature flag at the
  CALLER (LV) layer — the context trusts its callers, mirroring the rest
  of the module.

  ## Human time

      Ledger.log_time(project, 45, assignment_uuid: a.uuid,
        note: "Design pass", actor_uuid: user.uuid)

  ## AI usage

      Ledger.record_ai(project, %{tokens: 1234, cost_cents: 12,
        model: "gpt-x", agent_uuid: agent.uuid}, assignment_uuid: a.uuid)

  writes a `tokens` entry and (when cost is present) a `cost` entry
  sharing metadata — sums stay trivial per kind. This is the API the
  `phoenix_kit_ai` attribution seam calls when it lands; nothing here
  depends on that package.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKit.RepoHelper
  alias PhoenixKitProjects.Activity
  alias PhoenixKitProjects.PubSub
  alias PhoenixKitProjects.Schemas.WorkEntry

  @doc """
  Logs human time in MINUTES. Options: `:assignment_uuid`, `:note`,
  `:billable`, `:actor_uuid` (a core user), `:actor_kind` (default
  `"user"`), `:source` (`"manual"`/`"timer"`), `:started_at`/`:ended_at`.
  """
  @spec log_time(map() | binary(), pos_integer() | Decimal.t(), keyword()) ::
          {:ok, WorkEntry.t()} | {:error, term()}
  def log_time(project_or_uuid, minutes, opts \\ []) do
    insert_entry(project_or_uuid, %{
      kind: "time",
      amount: minutes,
      assignment_uuid: Keyword.get(opts, :assignment_uuid),
      actor_kind: Keyword.get(opts, :actor_kind, "user"),
      actor_uuid: Keyword.get(opts, :actor_uuid),
      note: Keyword.get(opts, :note),
      billable: Keyword.get(opts, :billable, false),
      source: Keyword.get(opts, :source, "manual"),
      started_at: Keyword.get(opts, :started_at),
      ended_at: Keyword.get(opts, :ended_at),
      metadata: Keyword.get(opts, :metadata, %{})
    })
  end

  @doc """
  Records AI usage attributed to a project/task: a `tokens` entry plus a
  `cost` entry when `cost_cents` is POSITIVE, both `actor_kind: "ai_agent"`
  with shared metadata (`model`, `endpoint`, anything else passed).
  Options: `:assignment_uuid`; `:occurred_at` — when the work happened,
  stored as the entries' `ended_at` (the API's batch reporting), default
  nil. Returns `{:ok, [entries]}`.

  Zero/absent quantities are SKIPPED, not errors — `cost_cents: 0` is the
  normal shape for free/cached/local calls (panel round: `0` is truthy in
  Elixir, so a naive `&&` built a zero-amount entry that failed the
  amount>0 validation AFTER the tokens row committed). Both inserts run in
  one transaction; activity/broadcast fire only after it commits.
  """
  @spec record_ai(map() | binary(), map(), keyword()) ::
          {:ok, [WorkEntry.t()]} | {:error, term()}
  def record_ai(project_or_uuid, usage, opts \\ []) when is_map(usage) do
    tokens = Map.get(usage, :tokens) || Map.get(usage, "tokens")
    cost_cents = Map.get(usage, :cost_cents) || Map.get(usage, "cost_cents")

    metadata =
      usage
      |> Map.drop([:tokens, "tokens", :cost_cents, "cost_cents", :agent_uuid, "agent_uuid"])
      |> Map.new(fn {k, v} -> {to_string(k), v} end)

    base = %{
      assignment_uuid: Keyword.get(opts, :assignment_uuid),
      actor_kind: "ai_agent",
      actor_uuid: Map.get(usage, :agent_uuid) || Map.get(usage, "agent_uuid"),
      source: "ai",
      ended_at: Keyword.get(opts, :occurred_at),
      metadata: metadata
    }

    entries =
      []
      |> maybe_entry(base, "tokens", tokens)
      |> maybe_entry(base, "cost", cost_cents)

    if entries == [] do
      {:error, :nothing_to_record}
    else
      insert_all_or_nothing(project_or_uuid, entries)
    end
  end

  defp maybe_entry(entries, base, kind, amount) do
    if positive_amount?(amount) do
      entries ++ [Map.merge(base, %{kind: kind, amount: amount})]
    else
      entries
    end
  end

  defp positive_amount?(%Decimal{} = amount), do: Decimal.compare(amount, 0) == :gt
  defp positive_amount?(amount) when is_number(amount), do: amount > 0
  defp positive_amount?(_), do: false

  # All-or-nothing multi-entry write: either every entry lands or none
  # does (an unwrapped loop left the tokens row committed when the cost
  # row failed). Side effects (activity + broadcast) run after commit so
  # a rollback can't leak phantom events.
  defp insert_all_or_nothing(project_or_uuid, entries) do
    repo = RepoHelper.repo()
    project_uuid = project_uuid(project_or_uuid)

    repo.transaction(fn ->
      Enum.map(entries, fn attrs ->
        case repo.insert(entry_changeset(project_uuid, attrs)) do
          {:ok, entry} -> entry
          {:error, changeset} -> repo.rollback(changeset)
        end
      end)
    end)
    |> case do
      {:ok, inserted} ->
        Enum.each(inserted, &publish_entry/1)
        {:ok, inserted}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  The AI attribution sink's resolver (Phase G): maps a persisted
  phoenix_kit_ai request (duck-typed map/struct — this package never
  references that package's modules) onto `record_ai/3`.

  The request's `metadata["attribution"]` carries `resource_type` +
  `resource_uuid` from the translate pipeline (or any caller passing
  `:attribution`). Resolution:

    * `"assignment"` → that assignment's project + the assignment;
    * `"project"` → the project itself;
    * `"task"`/`"template"`/anything else → not ours (library tasks and
      templates have no project) — `:skipped`.

  UNIT TRAP (scout-verified): phoenix_kit_ai's `cost_cents` column is
  NANODOLLARS despite the name (1e-6 dollars); the ledger stores CENTS.
  Divide by 10_000 as a Decimal so sub-cent calls stay positive
  fractions instead of silently rounding to zero.

  The AI actor identity is the ENDPOINT uuid (`agent_uuid`) — the
  stable "which AI did the work" until first-class agent records exist.
  """
  @spec record_ai_request(map() | struct()) ::
          {:ok, [WorkEntry.t()]} | :skipped | {:error, term()}
  def record_ai_request(request) do
    attribution = request |> field(:metadata) |> attribution_map()

    with %{} <- attribution || :skipped,
         {:ok, project_uuid, assignment_uuid} <- resolve_attribution(attribution) do
      tokens = field(request, :total_tokens)
      nanodollars = field(request, :cost_cents)

      cost_cents =
        case nanodollars do
          n when is_integer(n) and n > 0 -> Decimal.div(Decimal.new(n), 10_000)
          _ -> nil
        end

      usage =
        %{
          tokens: tokens,
          cost_cents: cost_cents,
          model: field(request, :model),
          request_uuid: field(request, :uuid),
          agent_uuid: field(request, :endpoint_uuid)
        }
        |> Map.reject(fn {_k, v} -> is_nil(v) end)

      record_ai(project_uuid, usage, assignment_uuid: assignment_uuid)
    else
      _ -> :skipped
    end
  end

  defp field(request, key) when is_map(request),
    do: Map.get(request, key) || Map.get(request, to_string(key))

  defp attribution_map(metadata) when is_map(metadata),
    do: Map.get(metadata, "attribution") || Map.get(metadata, :attribution)

  defp attribution_map(_), do: nil

  defp resolve_attribution(%{} = attribution) do
    type = Map.get(attribution, "resource_type")
    uuid = Map.get(attribution, "resource_uuid")

    case {type, uuid} do
      {"assignment", uuid} when is_binary(uuid) ->
        case RepoHelper.repo().one(
               from(a in PhoenixKitProjects.Schemas.Assignment,
                 where: a.uuid == ^uuid,
                 select: a.project_uuid
               )
             ) do
          nil -> :skipped
          project_uuid -> {:ok, project_uuid, uuid}
        end

      {"project", uuid} when is_binary(uuid) ->
        {:ok, uuid, nil}

      _ ->
        :skipped
    end
  rescue
    _ -> :skipped
  end

  @doc "One entry by uuid, or nil."
  @spec get_entry(binary()) :: WorkEntry.t() | nil
  def get_entry(uuid) when is_binary(uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, _} -> RepoHelper.repo().get(WorkEntry, uuid)
      :error -> nil
    end
  rescue
    _ -> nil
  end

  @doc """
  Amends a time entry's minutes (and `ended_at`, kept at `started_at` plus
  the new length when both are known). `billable:` changes the flag too.
  Logs `projects.work_amended` with the figure before and after — the
  ledger is append-only in spirit, so an amendment leaves its trace.
  """
  @spec update_time(WorkEntry.t() | binary(), pos_integer(), keyword()) ::
          {:ok, WorkEntry.t()} | {:error, term()}
  def update_time(entry_or_uuid, minutes, opts \\ [])

  def update_time(uuid, minutes, opts) when is_binary(uuid) do
    case get_entry(uuid) do
      nil -> {:error, :not_found}
      entry -> update_time(entry, minutes, opts)
    end
  end

  def update_time(%WorkEntry{kind: "time"} = entry, minutes, opts)
      when is_integer(minutes) and minutes > 0 do
    attrs =
      %{
        amount: minutes,
        ended_at: entry.started_at && DateTime.add(entry.started_at, minutes * 60)
      }
      |> maybe_put_billable(Keyword.get(opts, :billable))

    entry
    |> WorkEntry.changeset(attrs)
    |> RepoHelper.repo().update()
    |> case do
      {:ok, updated} ->
        Activity.log("projects.work_amended",
          actor_uuid: Keyword.get(opts, :actor_uuid),
          resource_type: "project",
          resource_uuid: updated.project_uuid,
          metadata: %{
            "entry_uuid" => updated.uuid,
            "kind" => updated.kind,
            "amount_was" => plain(entry.amount),
            "amount" => plain(updated.amount),
            "actor_kind" => updated.actor_kind,
            "assignment_uuid" => updated.assignment_uuid
          }
        )

        PubSub.broadcast_project(:work_logged, %{uuid: updated.project_uuid})
        {:ok, updated}

      {:error, _} = error ->
        error
    end
  end

  def update_time(%WorkEntry{}, _minutes, _opts), do: {:error, :invalid}

  @doc """
  Removes an entry. Logs `projects.work_removed` with what it held, so the
  figure is still in the project's history.
  """
  @spec delete_entry(WorkEntry.t() | binary(), keyword()) ::
          {:ok, WorkEntry.t()} | {:error, term()}
  def delete_entry(entry_or_uuid, opts \\ [])

  def delete_entry(uuid, opts) when is_binary(uuid) do
    case get_entry(uuid) do
      nil -> {:error, :not_found}
      entry -> delete_entry(entry, opts)
    end
  end

  def delete_entry(%WorkEntry{} = entry, opts) do
    case RepoHelper.repo().delete(entry) do
      {:ok, deleted} ->
        Activity.log("projects.work_removed",
          actor_uuid: Keyword.get(opts, :actor_uuid),
          resource_type: "project",
          resource_uuid: deleted.project_uuid,
          metadata: %{
            "entry_uuid" => deleted.uuid,
            "kind" => deleted.kind,
            "amount" => plain(deleted.amount),
            "actor_kind" => deleted.actor_kind,
            "assignment_uuid" => deleted.assignment_uuid
          }
        )

        PubSub.broadcast_project(:work_logged, %{uuid: deleted.project_uuid})
        {:ok, deleted}

      {:error, _} = error ->
        error
    end
  end

  # "30", not "30.0000": the column's scale is not part of the figure.
  defp plain(%Decimal{} = d), do: d |> Decimal.normalize() |> Decimal.to_string(:normal)
  defp plain(other), do: to_string(other)

  defp maybe_put_billable(attrs, billable) when is_boolean(billable),
    do: Map.put(attrs, :billable, billable)

  defp maybe_put_billable(attrs, _), do: attrs

  @doc """
  Entries for a project, newest first (capped by `:limit`, default 100).
  `metadata: %{"interaction_uuid" => uuid}` keeps only the entries whose
  metadata contains those pairs — how an extension finds the time it
  logged against one of its own records.
  """
  @spec list_entries(binary(), keyword()) :: [WorkEntry.t()]
  def list_entries(project_uuid, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    query =
      from(e in WorkEntry,
        where: e.project_uuid == ^project_uuid,
        order_by: [desc: e.inserted_at],
        limit: ^limit
      )

    query =
      case Keyword.get(opts, :metadata) do
        match when is_map(match) and map_size(match) > 0 ->
          where(query, [e], fragment("? @> ?", e.metadata, ^match))

        _ ->
          query
      end

    RepoHelper.repo().all(query)
  rescue
    _ -> []
  end

  @doc """
  Effort totals for a project:
  `%{time_minutes, tokens, cost_cents, billable_minutes}` — zeros when
  empty; fail-safe zeros on a DB hiccup (a summary line must never take
  the show page down).
  """
  @spec totals_for_project(binary()) :: map()
  def totals_for_project(project_uuid) do
    rows =
      RepoHelper.repo().all(
        from(e in WorkEntry,
          where: e.project_uuid == ^project_uuid,
          group_by: [e.kind, e.billable, e.actor_kind],
          select: {e.kind, e.billable, e.actor_kind, sum(e.amount)}
        )
      )

    # `time_minutes` is PEOPLE's time, as it always was; an agent's minutes
    # (`actor_kind: "ai_agent"`, reported over the API) are `ai_minutes`, so
    # the one kind keeps one meaning and the split is by who did it.
    Enum.reduce(rows, empty_totals(), fn {kind, billable, actor_kind, sum}, acc ->
      sum = Decimal.to_float(sum)

      acc =
        case {kind, actor_kind} do
          {"time", "ai_agent"} -> Map.update!(acc, :ai_minutes, &(&1 + sum))
          {"time", _} -> Map.update!(acc, :time_minutes, &(&1 + sum))
          {"tokens", _} -> Map.update!(acc, :tokens, &(&1 + sum))
          {"cost", _} -> Map.update!(acc, :cost_cents, &(&1 + sum))
        end

      if kind == "time" and billable and actor_kind != "ai_agent",
        do: Map.update!(acc, :billable_minutes, &(&1 + sum)),
        else: acc
    end)
  rescue
    e ->
      Logger.warning("[Projects.Ledger] totals failed: #{Exception.message(e)}")
      empty_totals()
  end

  @doc """
  Logged-time minutes per assignment for a DISPLAYED set (one query).
  Keyed by assignment uuid regardless of owning project, so a show page
  rendering a parent's tasks plus expanded sub-project child tasks gets
  every chip from one call (panel round: entries attribute to the project
  that owns the assignment, which for child rows is not the viewed one).
  """
  @spec time_for_assignments([binary()]) :: %{binary() => float()}
  def time_for_assignments([]), do: %{}

  def time_for_assignments(uuids) when is_list(uuids) do
    RepoHelper.repo().all(
      from(e in WorkEntry,
        where: e.assignment_uuid in ^uuids and e.kind == "time",
        group_by: e.assignment_uuid,
        select: {e.assignment_uuid, sum(e.amount)}
      )
    )
    |> Map.new(fn {uuid, sum} -> {uuid, Decimal.to_float(sum)} end)
  rescue
    _ -> %{}
  end

  @doc """
  Minutes, tokens and cents per assignment for a DISPLAYED set — one query,
  a `%{minutes, tokens, cost_cents}` per uuid asked about (zeros when
  nothing is logged). The task row's chips and the API's `totals` read
  this; `time_for_assignments/1` stays for callers that want minutes only.
  """
  @spec totals_for_assignments([binary()]) :: %{binary() => map()}
  def totals_for_assignments([]), do: %{}

  def totals_for_assignments(uuids) when is_list(uuids) do
    rows =
      RepoHelper.repo().all(
        from(e in WorkEntry,
          where: e.assignment_uuid in ^uuids,
          group_by: [e.assignment_uuid, e.kind],
          select: {e.assignment_uuid, e.kind, sum(e.amount)}
        )
      )

    base = Map.new(uuids, &{&1, %{minutes: 0.0, tokens: 0.0, cost_cents: 0.0}})

    Enum.reduce(rows, base, fn {uuid, kind, sum}, acc ->
      key =
        case kind do
          "time" -> :minutes
          "tokens" -> :tokens
          "cost" -> :cost_cents
        end

      update_in(acc, [uuid, key], &(&1 + Decimal.to_float(sum)))
    end)
  rescue
    _ -> Map.new(uuids, &{&1, %{minutes: 0.0, tokens: 0.0, cost_cents: 0.0}})
  end

  defp empty_totals,
    do: %{
      time_minutes: 0.0,
      ai_minutes: 0.0,
      tokens: 0.0,
      cost_cents: 0.0,
      billable_minutes: 0.0
    }

  defp insert_entry(project_or_uuid, attrs) do
    project_or_uuid
    |> project_uuid()
    |> entry_changeset(attrs)
    |> RepoHelper.repo().insert()
    |> case do
      {:ok, entry} ->
        publish_entry(entry)
        {:ok, entry}

      {:error, _} = error ->
        error
    end
  end

  defp entry_changeset(project_uuid, attrs) do
    WorkEntry.changeset(%WorkEntry{}, Map.put(attrs, :project_uuid, project_uuid))
  end

  defp publish_entry(entry) do
    Activity.log("projects.work_logged",
      actor_uuid: if(entry.actor_kind == "user", do: entry.actor_uuid),
      resource_type: "project",
      resource_uuid: entry.project_uuid,
      metadata: %{
        "kind" => entry.kind,
        "amount" => Decimal.to_string(entry.amount),
        "actor_kind" => entry.actor_kind,
        "assignment_uuid" => entry.assignment_uuid
      }
    )

    PubSub.broadcast_project(:work_logged, %{uuid: entry.project_uuid})
  end

  defp project_uuid(%{uuid: uuid}), do: uuid
  defp project_uuid(uuid) when is_binary(uuid), do: uuid
end
