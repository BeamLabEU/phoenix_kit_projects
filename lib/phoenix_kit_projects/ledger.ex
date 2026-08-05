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
      ended_at: Keyword.get(opts, :ended_at)
    })
  end

  @doc """
  Records AI usage attributed to a project/task: a `tokens` entry plus a
  `cost` entry when `cost_cents` is POSITIVE, both `actor_kind: "ai_agent"`
  with shared metadata (`model`, `endpoint`, anything else passed).
  Returns `{:ok, [entries]}`.

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

  @doc "Entries for a project, newest first (capped)."
  @spec list_entries(binary(), keyword()) :: [WorkEntry.t()]
  def list_entries(project_uuid, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    RepoHelper.repo().all(
      from(e in WorkEntry,
        where: e.project_uuid == ^project_uuid,
        order_by: [desc: e.inserted_at],
        limit: ^limit
      )
    )
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
          group_by: [e.kind, e.billable],
          select: {e.kind, e.billable, sum(e.amount)}
        )
      )

    Enum.reduce(rows, empty_totals(), fn {kind, billable, sum}, acc ->
      sum = Decimal.to_float(sum)

      acc =
        case kind do
          "time" -> Map.update!(acc, :time_minutes, &(&1 + sum))
          "tokens" -> Map.update!(acc, :tokens, &(&1 + sum))
          "cost" -> Map.update!(acc, :cost_cents, &(&1 + sum))
        end

      if kind == "time" and billable,
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

  defp empty_totals,
    do: %{time_minutes: 0.0, tokens: 0.0, cost_cents: 0.0, billable_minutes: 0.0}

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
