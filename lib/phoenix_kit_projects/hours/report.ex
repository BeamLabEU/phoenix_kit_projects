defmodule PhoenixKitProjects.Hours.Report do
  @moduledoc """
  A report of logged hours, built from what `PhoenixKitProjects.Hours`
  already read: the same figures as a plain-text summary a person can paste
  into an e-mail (`text/1`, Markdown) and as rows for a spreadsheet
  (`csv/1`). The print view is the page's own template over the same map.

  Pure: no database, no clock of its own — `build/1` takes everything it
  writes, so a report can be tested as text.

  ## The report map (`build/1`)

    * `:title`, `:period` (a label), `:generated_at` (a `DateTime`)
    * `:filters` — `[{label, value}]`, the narrowing in words
    * `:totals`, `:by_worker`, `:by_task`, `:by_project` — as
      `Hours.summary/2` returns them
    * `:entries` — rows as `Hours.list/2` returns them, oldest first
    * `:total_entries` — how many matched; more than `length(entries)`
      means the entry list is cut and the report says so
    * `:offset` — the viewer's timezone value, for the times
  """

  use Gettext, backend: PhoenixKitProjects.Gettext

  alias PhoenixKit.Utils.Date, as: KitDate
  alias PhoenixKitProjects.Hours.Format

  @type t :: map()

  @doc "A report map with every key present."
  @spec build(map() | keyword()) :: t()
  def build(attrs) do
    attrs = Map.new(attrs)
    entries = Map.get(attrs, :entries, [])

    %{
      title: Map.get(attrs, :title) || gettext("Hours"),
      period: Map.get(attrs, :period) || gettext("All time"),
      generated_at: Map.get(attrs, :generated_at) || DateTime.utc_now(),
      filters: Map.get(attrs, :filters, []),
      totals: Map.get(attrs, :totals) || PhoenixKitProjects.Hours.empty_summary().totals,
      by_worker: Map.get(attrs, :by_worker, []),
      by_task: Map.get(attrs, :by_task, []),
      by_project: Map.get(attrs, :by_project, []),
      entries: entries,
      total_entries: Map.get(attrs, :total_entries, length(entries)),
      offset: Map.get(attrs, :offset, "0")
    }
  end

  @doc "Whether the entry list is shorter than what matched."
  @spec truncated?(t()) :: boolean()
  def truncated?(%{entries: entries, total_entries: total}), do: total > length(entries)

  # ── Text ────────────────────────────────────────────────────────────

  @doc """
  The report as Markdown: totals, the hours of each person and each task,
  and — under `entries: true` (the default) — every entry.
  """
  @spec text(t(), keyword()) :: String.t()
  def text(report, opts \\ []) do
    [
      "# #{report.title}",
      "",
      "#{gettext("Period")}: #{report.period}",
      Enum.map(report.filters, fn {label, value} -> "#{label}: #{value}" end),
      "",
      totals_lines(report.totals),
      section(gettext("By person"), report.by_worker, &worker_line/1),
      if(length(report.by_project) > 1,
        do: section(gettext("By project"), report.by_project, &project_line/1),
        else: []
      ),
      section(gettext("By task"), report.by_task, &task_line/1),
      if(Keyword.get(opts, :entries, true), do: entries_section(report), else: [])
    ]
    |> List.flatten()
    |> Enum.join("\n")
    |> String.trim_trailing()
    |> Kernel.<>("\n")
  end

  defp totals_lines(t) do
    [
      "#{gettext("Total")}: #{Format.duration(t.minutes)} (#{Format.hours_shown(t.minutes)} h)",
      if(t.billable_minutes > 0,
        do:
          "#{gettext("Billable")}: #{Format.duration(t.billable_minutes)} (#{Format.hours_shown(t.billable_minutes)} h)",
        else: []
      ),
      if(t.ai_minutes > 0,
        do: "#{gettext("AI time")}: #{Format.duration(t.ai_minutes)}",
        else: []
      ),
      if(t.tokens > 0, do: "#{gettext("AI tokens")}: #{Format.tokens(t.tokens)}", else: []),
      if(t.cost_cents > 0, do: "#{gettext("AI cost")}: #{Format.cost(t.cost_cents)}", else: [])
    ]
  end

  defp section(_title, [], _line), do: []
  defp section(title, rows, line), do: ["", "## #{title}", "" | Enum.map(rows, line)]

  defp worker_line(row), do: "- #{row.worker.name}: #{amount(row)}"
  defp project_line(row), do: "- #{row.project.name || "—"}: #{amount(row)}"
  defp task_line(row), do: "- #{task_title(row.task)}: #{amount(row)}"

  defp amount(%{minutes: minutes, billable_minutes: billable}) when billable > 0 do
    "#{Format.duration(minutes)} (#{gettext("%{amount} billable", amount: Format.duration(billable))})"
  end

  defp amount(%{minutes: minutes}), do: Format.duration(minutes)

  defp task_title(nil), do: gettext("The project itself")
  defp task_title(%{title: nil}), do: gettext("A removed task")
  defp task_title(%{title: title, ref: ref}) when is_binary(ref), do: "#{ref} · #{title}"
  defp task_title(%{title: title}), do: title

  defp entries_section(%{entries: []}), do: []

  defp entries_section(report) do
    lines =
      Enum.map(report.entries, fn row ->
        note = if row.entry.note in [nil, ""], do: "", else: " — #{one_line(row.entry.note)}"
        billable = if row.entry.billable, do: " [#{gettext("billable")}]", else: ""

        "- #{stamp(row.at, report.offset)} · #{row.worker.name} · #{task_title(row.task)} · " <>
          "#{Format.duration(row.entry.amount |> Decimal.to_float())}#{billable}#{note}"
      end)

    cut =
      if truncated?(report),
        do: [
          "",
          gettext("The first %{shown} of %{total} entries.",
            shown: length(report.entries),
            total: report.total_entries
          )
        ],
        else: []

    ["", "## #{gettext("Entries")}", ""] ++ lines ++ cut
  end

  defp one_line(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()

  # ── CSV ─────────────────────────────────────────────────────────────

  @doc """
  The entries as CSV (RFC 4180, CRLF rows), one row per entry: date, time,
  person, project, task, minutes, decimal hours, billable, note, source.
  """
  @spec csv(t()) :: String.t()
  def csv(report) do
    header = [
      gettext("Date"),
      gettext("Time"),
      gettext("Person"),
      gettext("Project"),
      gettext("Task"),
      gettext("Minutes"),
      gettext("Hours"),
      gettext("Billable"),
      gettext("Note"),
      gettext("Source")
    ]

    rows =
      Enum.map(report.entries, fn row ->
        local = KitDate.shift_to_offset(row.at, report.offset)
        minutes = Decimal.to_float(row.entry.amount)

        [
          Date.to_iso8601(DateTime.to_date(local)),
          Calendar.strftime(local, "%H:%M"),
          row.worker.name,
          row.project.name || "",
          if(row.task, do: task_title(row.task), else: ""),
          to_string(round(minutes)),
          Format.decimal_hours(minutes),
          if(row.entry.billable, do: gettext("yes"), else: gettext("no")),
          row.entry.note || "",
          row.entry.source || ""
        ]
      end)

    Enum.map_join([header | rows], "", fn row -> Enum.map_join(row, ",", &cell/1) <> "\r\n" end)
  end

  # A cell is quoted when it must be; a value a spreadsheet would run as a
  # formula (`=`, `+`, `-`, `@` first) is written as text.
  defp cell(value) do
    value = value |> to_string() |> defuse()

    if String.contains?(value, [",", "\"", "\n", "\r"]),
      do: "\"" <> String.replace(value, "\"", "\"\"") <> "\"",
      else: value
  end

  defp defuse(<<c, _::binary>> = value) when c in [?=, ?+, ?-, ?@, ?\t], do: "'" <> value
  defp defuse(value), do: value

  @doc "The CSV as a `data:` URL a plain link can download, with a byte-order mark so a spreadsheet reads it as UTF-8."
  @spec csv_data_url(t()) :: String.t()
  def csv_data_url(report) do
    "data:text/csv;charset=utf-8;base64," <> Base.encode64("﻿" <> csv(report))
  end

  @doc ~S|A file name for the download: `hours-kitchen-2026-10-01.csv`.|
  @spec filename(t(), String.t()) :: String.t()
  def filename(report, ext \\ "csv") do
    slug =
      report.title
      |> String.downcase()
      |> String.replace(~r/[^\p{L}\p{N}]+/u, "-")
      |> String.trim("-")
      |> String.slice(0, 60)

    date = report.generated_at |> DateTime.to_date() |> Date.to_iso8601()
    Enum.join(Enum.reject(["hours", slug, date], &(&1 == "")), "-") <> "." <> ext
  end

  @doc ~S|An instant as `2026-10-05 14:30` in the viewer's timezone.|
  @spec stamp(DateTime.t(), String.t()) :: String.t()
  def stamp(%DateTime{} = at, offset),
    do: at |> KitDate.shift_to_offset(offset) |> Calendar.strftime("%Y-%m-%d %H:%M")
end
