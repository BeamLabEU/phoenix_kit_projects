defmodule PhoenixKitProjects.Web.Api.HoursController do
  @moduledoc """
  `GET /hours` — the project's logged time summed for a period: the totals
  and one grouping (by person, by task or by day). The figures the Hours tab
  shows a person, read from the same place (`PhoenixKitProjects.Hours`).

  It reads the key's project — or, with `project`, a sub-project within
  reach — and by default everything nested under it (`include_subprojects`)
  that the key may read time in. Days are UTC days.
  """

  use Phoenix.Controller, formats: [:json]

  alias PhoenixKitProjects.{ApiKeys, Hours}
  alias PhoenixKitProjects.Web.Api.Json

  @groups ~w(person task day)

  def show(conn, params) do
    with {:ok, conn} <- Json.scope_project(conn, params),
         {:ok, conn} <- Json.require_scope(conn, "time:read"),
         {:ok, conn} <- Json.require_feature(conn, :ledger),
         {:ok, conn} <- Json.require_action(conn, :view),
         {:ok, opts} <- options(params) do
      %{pk_project: project, pk_api_key: key} = conn.assigns

      # Each nested project only where this key may read time there: a
      # grant can stop at a sub-project, or narrow it (V24). One batched
      # read of the key's access for the whole tree, not a walk per project.
      tree = Hours.project_uuids(project.uuid, opts.include_subprojects)
      access = ApiKeys.access_map(key, tree)

      may? = fn uuid, scope ->
        case access[uuid] do
          {:ok, %{scopes: scopes}} -> scope in scopes
          _ -> false
        end
      end

      uuids = Enum.filter(tree, &(&1 == project.uuid or may?.(&1, "time:read")))

      # Tokens and cost are the usage area's: summed over the projects this
      # key may read usage in, which `usage_projects` names. A sub-project
      # without it used to hide them for the whole answer.
      usage_uuids = Enum.filter(uuids, &may?.(&1, "usage:read"))

      filters = fn project_uuids ->
        Hours.filters(
          project_uuids: project_uuids,
          from: opts.from,
          until: opts.until,
          workers: opts.workers,
          billable: opts.billable
        )
      end

      summary = Hours.summary(filters.(uuids))

      json(conn, %{
        project_uuid: project.uuid,
        include_subprojects: opts.include_subprojects,
        period: %{from: opts.from, to: opts.until},
        totals:
          summary.totals
          |> Map.drop([:tokens, :cost_cents])
          |> Map.merge(usage_totals(summary, uuids, usage_uuids, filters))
          |> Map.new(fn {k, v} -> {k, Json.number(v)} end),
        usage_projects: usage_uuids,
        group_by: opts.group_by,
        groups: groups(summary, opts.group_by)
      })
    else
      {:halt, conn} -> conn
      {:error, {status, body}} -> conn |> put_status(status) |> json(body)
    end
  end

  # Usage of every project summed: the same summary. Of some: a second one
  # over those alone. Of none: no usage figures.
  defp usage_totals(_summary, _uuids, [], _filters), do: %{}

  defp usage_totals(summary, uuids, usage_uuids, _filters)
       when length(uuids) == length(usage_uuids),
       do: Map.take(summary.totals, [:tokens, :cost_cents])

  defp usage_totals(_summary, _uuids, usage_uuids, filters),
    do:
      usage_uuids
      |> filters.()
      |> Hours.summary()
      |> Map.fetch!(:totals)
      |> Map.take([:tokens, :cost_cents])

  defp groups(summary, "person") do
    Enum.map(summary.by_worker, fn row ->
      %{
        worker: row.worker |> Map.take([:key, :kind, :uuid, :name]) |> without_email(),
        minutes: Json.number(row.minutes),
        billable_minutes: Json.number(row.billable_minutes),
        entries: row.entries
      }
    end)
  end

  defp groups(summary, "task") do
    Enum.map(summary.by_task, fn row ->
      %{
        task_uuid: row.task && row.task.uuid,
        ref: row.task && row.task[:ref],
        title: row.task && row.task.title,
        project_uuid: row.project.uuid,
        minutes: Json.number(row.minutes),
        billable_minutes: Json.number(row.billable_minutes),
        entries: row.entries
      }
    end)
  end

  defp groups(summary, "day") do
    Enum.map(summary.by_day, fn day ->
      %{
        date: day.date,
        minutes: Json.number(day.minutes),
        by_worker: Map.new(day.by_worker, fn {key, minutes} -> {key, Json.number(minutes)} end)
      }
    end)
  end

  # ── Params ──────────────────────────────────────────────────────

  defp options(params) do
    with {:ok, from} <- instant(params["from"], "from", 0),
         {:ok, until} <- instant(params["to"], "to", 1),
         {:ok, group_by} <- group_by(params["group_by"]),
         {:ok, billable} <- boolean(params["billable"], "billable", nil),
         {:ok, sub?} <- boolean(params["include_subprojects"], "include_subprojects", true),
         {:ok, workers} <- workers(params["worker"]) do
      {:ok,
       %{
         from: from,
         until: until,
         group_by: group_by,
         billable: billable,
         include_subprojects: sub?,
         workers: workers
       }}
    end
  end

  # A day (`2026-10-01`, UTC) or an ISO 8601 instant. A day given as `to` is
  # INCLUDED: the period ends where the next day begins.
  defp instant(nil, _field, _add_days), do: {:ok, nil}
  defp instant("", _field, _add_days), do: {:ok, nil}

  defp instant(value, field, add_days) when is_binary(value) do
    with {:error, _} <- Date.from_iso8601(value),
         {:ok, dt, _offset} <- DateTime.from_iso8601(value) do
      {:ok, DateTime.truncate(dt, :second)}
    else
      {:ok, %Date{} = date} ->
        {:ok, DateTime.new!(Date.add(date, add_days), ~T[00:00:00], "Etc/UTC")}

      _ ->
        invalid(field, "must be a day (2026-10-01) or an ISO 8601 datetime")
    end
  end

  defp instant(_value, field, _add_days),
    do: invalid(field, "must be a day (2026-10-01) or an ISO 8601 datetime")

  defp group_by(nil), do: {:ok, "person"}
  defp group_by(value) when value in @groups, do: {:ok, value}
  defp group_by(_), do: invalid("group_by", "must be one of #{Enum.join(@groups, ", ")}")

  defp boolean(nil, _field, default), do: {:ok, default}
  defp boolean(value, _field, _default) when value in [true, "true", "1"], do: {:ok, true}
  defp boolean(value, _field, _default) when value in [false, "false", "0"], do: {:ok, false}
  defp boolean(_value, field, _default), do: invalid(field, "must be true or false")

  # One worker key, or several separated by commas: `user:<uuid>`,
  # `staff_person:<uuid>`, `ai_agent:<uuid>` — the `worker.key` of a
  # `group_by=person` answer.
  defp workers(nil), do: {:ok, []}
  defp workers(""), do: {:ok, []}

  defp workers(value) when is_binary(value) do
    keys = value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

    if Hours.filters(workers: keys).workers == keys,
      do: {:ok, keys},
      else:
        invalid("worker", "must be a worker key like user:<uuid> (comma-separated for several)")
  end

  defp workers(_), do: invalid("worker", "must be a worker key like user:<uuid>")

  defp invalid(field, why) do
    {:error, Json.error_body(422, "validation_failed", "#{field} #{why}.", %{field => [why]})}
  end

  # The page names a person with no full name by their email; the API never
  # gives an email out (`Api.Assignee`'s rule), so such a worker has no name
  # here — the uuid says who.
  defp without_email(%{name: name} = worker) when is_binary(name) do
    if String.contains?(name, "@"), do: %{worker | name: nil}, else: worker
  end

  defp without_email(worker), do: worker
end
