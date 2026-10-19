defmodule PhoenixKitProjects.ApiUsage do
  @moduledoc """
  How much each API key is used (Max, 2026-10-19: "some kind of usage stats
  and graph"), for the API keys page.

  Two sources, one shape:

    * **requests** — every authenticated API call bumps a per key, project
      and UTC day counter (`record/3`, from `Web.Api.Auth`; chain V25), with
      how many failed (`errors`, 4xx/5xx) and how many of those were
      refused (`denied`, 403 — usually access set too narrowly). An agent
      cannot skip these.
    * **work** — the AI time, tokens and cost an agent reports go to the
      work ledger with the key as the actor (`actor_kind: "ai_agent"`); they
      are summed here per key, project and day of the work (`ended_at`,
      else when it was recorded — the Hours tab's rule). An agent that does
      not report shows little here; its requests still show.

  `rows/2` returns both as one flat list; `days/2`, `totals/1` and
  `by_project/1` shape it for a chart and its figures.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKit.RepoHelper
  alias PhoenixKitProjects.Schemas.{ApiKeyUsage, WorkEntry}

  @zero %{requests: 0, errors: 0, denied: 0, minutes: 0.0, tokens: 0.0, cost_cents: 0.0}

  @typedoc "One key's figures in one project on one day."
  @type row :: %{
          key: binary(),
          project: binary(),
          day: Date.t(),
          requests: non_neg_integer(),
          errors: non_neg_integer(),
          denied: non_neg_integer(),
          minutes: float(),
          tokens: float(),
          cost_cents: float()
        }

  @doc "The figures with nothing in them."
  @spec zero() :: map()
  def zero, do: @zero

  @doc """
  Counts one request by `key_uuid` in `project_uuid` that answered
  `status`. Never raises: a counter that fails must not fail the call it
  counts.
  """
  @spec record(binary(), binary(), integer()) :: :ok
  def record(key_uuid, project_uuid, status)
      when is_binary(key_uuid) and is_binary(project_uuid) and is_integer(status) do
    errors = if status >= 400, do: 1, else: 0
    denied = if status == 403, do: 1, else: 0

    RepoHelper.repo().insert_all(
      ApiKeyUsage,
      [
        %{
          api_key_uuid: key_uuid,
          project_uuid: project_uuid,
          day: Date.utc_today(),
          requests: 1,
          errors: errors,
          denied: denied
        }
      ],
      on_conflict: [inc: [requests: 1, errors: errors, denied: denied]],
      conflict_target: [:api_key_uuid, :project_uuid, :day]
    )

    :ok
  rescue
    e ->
      Logger.warning("ApiUsage.record failed: #{Exception.message(e)}")
      :ok
  end

  def record(_key, _project, _status), do: :ok

  @doc """
  Every key's figures per project and day for the last `days` UTC days
  (today included), requests and reported work merged. Days and projects
  with nothing are absent.
  """
  @spec rows([binary()], pos_integer()) :: [row()]
  def rows(key_uuids, days \\ 30)
  def rows([], _days), do: []

  def rows(key_uuids, days) when is_list(key_uuids) and days > 0 do
    from_day = Date.add(Date.utc_today(), 1 - days)

    (request_rows(key_uuids, from_day) ++ work_rows(key_uuids, from_day))
    |> Enum.group_by(&{&1.key, &1.project, &1.day})
    |> Enum.map(fn {{key, project, day}, parts} ->
      parts
      |> Enum.reduce(@zero, fn part, acc ->
        Map.merge(acc, Map.drop(part, [:key, :project, :day]), fn _k, a, b -> a + b end)
      end)
      |> Map.merge(%{key: key, project: project, day: day})
    end)
  rescue
    e ->
      Logger.warning("ApiUsage.rows failed: #{Exception.message(e)}")
      []
  end

  defp request_rows(key_uuids, from_day) do
    from(u in ApiKeyUsage,
      where: u.api_key_uuid in ^key_uuids and u.day >= ^from_day,
      select: %{
        key: u.api_key_uuid,
        project: u.project_uuid,
        day: u.day,
        requests: u.requests,
        errors: u.errors,
        denied: u.denied
      }
    )
    |> RepoHelper.repo().all()
  end

  defp work_rows(key_uuids, from_day) do
    since = DateTime.new!(from_day, ~T[00:00:00], "Etc/UTC")

    from(e in WorkEntry,
      where:
        e.actor_kind == "ai_agent" and e.actor_uuid in ^key_uuids and
          coalesce(e.ended_at, e.inserted_at) >= ^since,
      group_by: [
        e.actor_uuid,
        e.project_uuid,
        fragment("(coalesce(?, ?) AT TIME ZONE 'UTC')::date", e.ended_at, e.inserted_at),
        e.kind
      ],
      select: {
        e.actor_uuid,
        e.project_uuid,
        fragment("(coalesce(?, ?) AT TIME ZONE 'UTC')::date", e.ended_at, e.inserted_at),
        e.kind,
        sum(e.amount)
      }
    )
    |> RepoHelper.repo().all()
    |> Enum.flat_map(fn {key, project, day, kind, sum} ->
      case field_of(kind) do
        nil -> []
        field -> [%{:key => key, :project => project, :day => day, field => to_float(sum)}]
      end
    end)
  end

  defp field_of("time"), do: :minutes
  defp field_of("tokens"), do: :tokens
  defp field_of("cost"), do: :cost_cents
  defp field_of(_), do: nil

  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float(n) when is_number(n), do: n / 1
  defp to_float(_), do: 0.0

  @doc "The figures of `rows` summed."
  @spec totals([row()]) :: map()
  def totals(rows) do
    Enum.reduce(rows, @zero, fn row, acc ->
      Map.new(acc, fn {k, v} -> {k, v + Map.fetch!(row, k)} end)
    end)
  end

  @doc "The figures of `rows` summed per project: `%{project_uuid => figures}`."
  @spec by_project([row()]) :: %{binary() => map()}
  def by_project(rows) do
    rows |> Enum.group_by(& &1.project) |> Map.new(fn {p, rs} -> {p, totals(rs)} end)
  end

  @doc """
  The last `days` UTC days, oldest first, each with `metric` per project —
  `[%{date, parts: [{project_uuid, value}]}]` — every day present, empty
  ones too, so a chart's bars line up with the calendar.
  """
  @spec days([row()], atom(), pos_integer()) :: [%{date: Date.t(), parts: [{binary(), number()}]}]
  def days(rows, metric, days \\ 30) do
    today = Date.utc_today()
    by_day = Enum.group_by(rows, & &1.day)

    for offset <- (days - 1)..0//-1 do
      date = Date.add(today, -offset)

      parts =
        by_day
        |> Map.get(date, [])
        |> Enum.map(&{&1.project, Map.fetch!(&1, metric)})
        |> Enum.filter(fn {_p, v} -> v > 0 end)

      %{date: date, parts: parts}
    end
  end
end
