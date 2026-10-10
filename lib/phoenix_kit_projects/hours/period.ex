defmodule PhoenixKitProjects.Hours.Period do
  @moduledoc """
  The period an Hours page reads: a preset (`today`, `week`, `last_week`,
  `month`, `last_month`, `year`, `all`) or a custom pair of days, resolved
  against the viewer's own "today" into the UTC instants the ledger is
  filtered on.

  Days are the VIEWER's days: `today` at UTC+3 starts at 21:00 UTC the day
  before. A week runs Monday to Sunday.
  """

  use Gettext, backend: PhoenixKitProjects.Gettext

  alias PhoenixKit.Utils.Date, as: KitDate
  alias PhoenixKitProjects.L10n

  @presets ~w(today week last_week month last_month year all custom)

  @type t :: %{
          preset: String.t(),
          from_date: Date.t() | nil,
          to_date: Date.t() | nil,
          from: DateTime.t() | nil,
          until: DateTime.t() | nil,
          label: String.t()
        }

  @doc "The preset keys, in the order the page offers them."
  @spec presets() :: [String.t()]
  def presets, do: @presets

  @doc "A preset's name."
  @spec preset_label(String.t()) :: String.t()
  def preset_label("today"), do: gettext("Today")
  def preset_label("week"), do: gettext("This week")
  def preset_label("last_week"), do: gettext("Last week")
  def preset_label("month"), do: gettext("This month")
  def preset_label("last_month"), do: gettext("Last month")
  def preset_label("year"), do: gettext("This year")
  def preset_label("all"), do: gettext("All time")
  def preset_label(_custom), do: gettext("Custom")

  @doc "The viewer's calendar day right now, `offset` being core's timezone value."
  @spec today(String.t(), DateTime.t()) :: Date.t()
  def today(offset, now \\ DateTime.utc_now()),
    do: now |> KitDate.shift_to_offset(offset) |> DateTime.to_date()

  @doc """
  Resolves a preset (or, for `custom`, the two ISO days — either may be
  blank) into the period. `to_date` is the last day INCLUDED; `until` is
  the first instant after it.
  """
  @spec resolve(String.t(), String.t() | nil, String.t() | nil, Date.t(), String.t()) :: t()
  def resolve(preset, from_str, to_str, %Date{} = today, offset) do
    {from_date, to_date} = days(preset, from_str, to_str, today)

    %{
      preset: if(preset in @presets, do: preset, else: "all"),
      from_date: from_date,
      to_date: to_date,
      from: from_date && day_start(from_date, offset),
      until: to_date && day_start(Date.add(to_date, 1), offset),
      label: label(from_date, to_date)
    }
  end

  defp days("today", _f, _t, today), do: {today, today}

  defp days("week", _f, _t, today) do
    monday = week_start(today)
    {monday, Date.add(monday, 6)}
  end

  defp days("last_week", _f, _t, today) do
    monday = today |> week_start() |> Date.add(-7)
    {monday, Date.add(monday, 6)}
  end

  defp days("month", _f, _t, today),
    do: {Date.beginning_of_month(today), Date.end_of_month(today)}

  defp days("last_month", _f, _t, today) do
    last = today |> Date.beginning_of_month() |> Date.add(-1)
    {Date.beginning_of_month(last), last}
  end

  defp days("year", _f, _t, today),
    do: {%{today | month: 1, day: 1}, %{today | month: 12, day: 31}}

  defp days("custom", from_str, to_str, _today) do
    case {parse(from_str), parse(to_str)} do
      # A pair typed the wrong way round is read the right way round.
      {%Date{} = a, %Date{} = b} -> if Date.compare(a, b) == :gt, do: {b, a}, else: {a, b}
      pair -> pair
    end
  end

  defp days(_all, _f, _t, _today), do: {nil, nil}

  defp parse(str) when is_binary(str) do
    case Date.from_iso8601(str) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse(_), do: nil

  @doc """
  How far the viewer's clock is from UTC at `at`, in seconds — what the
  ledger's days are cut with. One figure for a whole read, so a period that
  crosses a daylight-saving switch has its days an hour off on one side of
  it; the totals are not affected.
  """
  @spec offset_seconds(String.t(), DateTime.t()) :: integer()
  def offset_seconds(offset, at \\ DateTime.utc_now()) do
    at = DateTime.truncate(at, :second)
    shifted = KitDate.shift_to_offset(at, offset)
    NaiveDateTime.diff(DateTime.to_naive(shifted), DateTime.to_naive(at))
  end

  @doc "The Monday of `date`'s week."
  @spec week_start(Date.t()) :: Date.t()
  def week_start(%Date{} = date), do: Date.add(date, 1 - Date.day_of_week(date))

  @doc "The UTC instant a viewer's calendar day begins."
  @spec day_start(Date.t(), String.t()) :: DateTime.t()
  def day_start(%Date{} = date, offset) do
    case KitDate.parse_datetime_local(Date.to_iso8601(date) <> "T00:00", offset) do
      {:ok, utc} -> utc
      _ -> DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
    end
  end

  defp label(nil, nil), do: gettext("All time")
  defp label(%Date{} = from, nil), do: gettext("From %{date}", date: L10n.format_date(from))
  defp label(nil, %Date{} = to), do: gettext("Until %{date}", date: L10n.format_date(to))
  defp label(%Date{} = same, same), do: L10n.format_date(same)

  defp label(%Date{} = from, %Date{} = to),
    do: gettext("%{from} – %{to}", from: L10n.format_date(from), to: L10n.format_date(to))
end
