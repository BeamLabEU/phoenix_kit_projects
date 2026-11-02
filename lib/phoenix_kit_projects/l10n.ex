defmodule PhoenixKitProjects.L10n do
  @moduledoc """
  Tiny locale-aware date/time formatting helpers used by the projects UI.

  Unlike `Calendar.strftime(d, "%b %d, %Y")`, the output of these helpers
  is safe to translate: the three-letter month labels and the surrounding
  string template all go through Gettext.

  The 12 month labels are intentionally listed as separate `gettext/1`
  calls so the string-extraction task picks them up into the .pot file.
  Don't collapse them into a map-based lookup.
  """

  use Gettext, backend: PhoenixKitWeb.Gettext
  require Gettext.Macros

  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.TimeZone

  @zone_key :phoenix_kit_projects_viewer_zone
  @clock_key :phoenix_kit_projects_twelve_hour

  @doc """
  Settles the time zone this process prints instants in — the viewer's
  (`TimeZone.for_viewer/1`: their profile, else the site's). Called once per
  LiveView by `Web.Helpers.assign_embed_user/2`, like the Gettext locale: a
  LiveView renders in its own process, so every helper below reads it without
  threading a zone through each template. A process that never set one (a job,
  the API) prints UTC, as before.
  """
  @spec put_viewer_zone(term()) :: :ok
  def put_viewer_zone(viewer) do
    Process.put(@zone_key, TimeZone.for_viewer(viewer))
    # The clock is settled with the zone, once per LiveView: every time on
    # the page is printed and typed the same way (`twelve_hour?/0`).
    Process.put(@clock_key, read_twelve_hour())
    :ok
  end

  @doc """
  Forgets the viewer zone: a process that serves the API after a page (a
  reused connection) prints UTC again, not the last viewer's zone.
  """
  @spec reset_viewer_zone() :: :ok
  def reset_viewer_zone do
    Process.delete(@zone_key)
    Process.delete(@clock_key)
    :ok
  end

  @doc """
  Whether times are shown on a 12-hour clock with AM/PM — core's
  `time_format` setting (`"h:i A"`; `"H:i"`, the default, is 24-hour; see
  `PhoenixKit.Utils.Date`). Every time this module prints goes through
  `format_time/1` and every time it asks for goes through the
  `TimeInput` picker, and both read this — so the site's choice holds on
  every device, whatever clock the device itself uses (an iPad's native
  time field showed AM/PM on a 24-hour site; the boss, 2026-10-30).

  Read once per LiveView with the viewer's zone (`put_viewer_zone/1`);
  elsewhere (a job, the API) from the cached setting on each call.
  """
  @spec twelve_hour?() :: boolean()
  def twelve_hour? do
    case Process.get(@clock_key) do
      nil -> read_twelve_hour()
      value -> value
    end
  end

  defp read_twelve_hour do
    Settings.get_setting_cached("time_format", "H:i") == "h:i A"
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  @doc "A UTC `DateTime` as the viewer's wall clock (unchanged when no zone is set)."
  @spec local(DateTime.t()) :: DateTime.t()
  def local(%DateTime{} = dt), do: TimeZone.shift(dt, Process.get(@zone_key))

  @doc """
  A typed wall clock read in the viewer's zone, as the UTC instant to store
  (`TimeZone.from_wall/2`); `nil` when it cannot be resolved.
  """
  @spec from_wall(NaiveDateTime.t()) :: DateTime.t() | nil
  def from_wall(%NaiveDateTime{} = naive) do
    case TimeZone.from_wall(naive, Process.get(@zone_key)) do
      {:ok, dt} -> dt
      :error -> nil
    end
  end

  @doc "The viewer's local date of an instant."
  @spec local_date(DateTime.t()) :: Date.t()
  def local_date(%DateTime{} = dt), do: dt |> local() |> DateTime.to_date()

  @doc "The viewer's clock time of an instant (`format_time/1`)."
  @spec local_time(DateTime.t()) :: String.t()
  def local_time(%DateTime{} = dt), do: dt |> local() |> format_time()

  @doc "Formats a `Date`/`DateTime` as `Mon DD, YYYY`. Returns `nil` for nil."
  @spec format_date(Date.t() | DateTime.t() | NaiveDateTime.t() | nil) :: String.t() | nil
  def format_date(nil), do: nil

  def format_date(%DateTime{} = dt),
    do: dt |> local() |> DateTime.to_date() |> format_date()

  def format_date(%NaiveDateTime{} = dt),
    do: dt |> NaiveDateTime.to_date() |> format_date()

  def format_date(%Date{} = d),
    do: gettext("%{month} %{day}, %{year}", month: short_month(d.month), day: d.day, year: d.year)

  @doc """
  A short date: `Oct 27` this year (in the order the language writes a
  month and a day), the full `format_date/1` another year — for a line like
  "since %{date}". An instant is read on the viewer's clock. nil for nil.
  """
  @spec format_short_date(Date.t() | DateTime.t() | NaiveDateTime.t() | nil) :: String.t() | nil
  def format_short_date(nil), do: nil
  def format_short_date(%DateTime{} = dt), do: dt |> local_date() |> format_short_date()

  def format_short_date(%NaiveDateTime{} = n),
    do: n |> NaiveDateTime.to_date() |> format_short_date()

  def format_short_date(%Date{} = d) do
    if d.year == local_date(DateTime.utc_now()).year,
      do:
        Gettext.Macros.gettext_with_backend(PhoenixKitProjects.Gettext, "%{month} %{day}",
          month: short_month(d.month),
          day: d.day
        ),
      else: format_date(d)
  end

  @doc """
  Formats as `Mon DD, YYYY at HH:MM`. For DateTimes.
  """
  @spec format_datetime(DateTime.t() | nil) :: String.t() | nil
  def format_datetime(nil), do: nil

  def format_datetime(%DateTime{} = dt) do
    dt = local(dt)

    gettext("%{month} %{day}, %{year} at %{time}",
      month: short_month(dt.month),
      day: dt.day,
      year: dt.year,
      time: format_time(dt)
    )
  end

  @doc "Formats as `Mon DD HH:MM` — month, day, and time only."
  @spec format_month_day_time(DateTime.t() | nil) :: String.t() | nil
  def format_month_day_time(nil), do: nil

  def format_month_day_time(%DateTime{} = dt) do
    dt = local(dt)

    gettext("%{month} %{day} %{time}",
      month: short_month(dt.month),
      day: dt.day,
      time: format_time(dt)
    )
  end

  @doc """
  A clock time as the site shows times (`twelve_hour?/0`): `15:30`, or
  `3:30 PM` on a 12-hour site. Takes anything with an hour and a minute
  (`Time`, `DateTime`, `NaiveDateTime`) and prints it as it is — shift an
  instant into the viewer's zone first (`local_time/1`).
  """
  @spec format_time(Time.t() | DateTime.t() | NaiveDateTime.t()) :: String.t()
  def format_time(%{hour: h, minute: m}), do: format_clock(h, m)

  @doc "`format_time/1` from an hour (0–23) and a minute."
  @spec format_clock(0..23, 0..59) :: String.t()
  def format_clock(h, m) when is_integer(h) and is_integer(m) do
    if twelve_hour?() do
      {h12, suffix} = to_twelve_hour(h)
      # The module's own catalogue (the month names above are core's).
      Gettext.Macros.gettext_with_backend(
        PhoenixKitProjects.Gettext,
        "%{hour}:%{minute} %{suffix}",
        hour: h12,
        minute: pad2(m),
        suffix: suffix
      )
    else
      pad2(h) <> ":" <> pad2(m)
    end
  end

  @doc """
  An hour of the day (0–23) on the 12-hour clock: `{1..12, "AM" | "PM"}`,
  the suffix translated (`day_half_label/1`).
  """
  @spec to_twelve_hour(0..23) :: {1..12, String.t()}
  def to_twelve_hour(h) when h in 0..23 do
    half = if h < 12, do: "am", else: "pm"

    h12 =
      case rem(h, 12) do
        0 -> 12
        n -> n
      end

    {h12, day_half_label(half)}
  end

  @doc ~S(The translated `AM` / `PM` of `"am"` / `"pm"`.)
  @spec day_half_label(String.t()) :: String.t()
  def day_half_label("am"),
    do: Gettext.Macros.pgettext_with_backend(PhoenixKitProjects.Gettext, "time of day", "AM")

  def day_half_label("pm"),
    do: Gettext.Macros.pgettext_with_backend(PhoenixKitProjects.Gettext, "time of day", "PM")

  defp pad2(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  # Languages that write a decimal comma (`4,6`). The rest — English
  # first — write a point.
  @comma_decimal ~w(et ru de es fr it pl pt nl sv fi da nb nn no lt lv uk be cs sk sl hr sr bs bg ro hu tr el)

  @doc """
  A fractional number as the page's language writes it: `4.6` in English,
  `4,6` in Estonian, Russian, German, Spanish, French, Italian, Polish (and
  the other decimal-comma languages). Every fractional number the module
  prints goes through this (the walk-through, 2026-10-31: "4.6 kuud üle
  tähtaja", "Aega jäänud: 1.1 nädalat").

  Options:

    * `:decimals` — places to round to (default `1`);
    * `:trim` — drop zeros at the end, and the separator with them
      (`2.0` → `2`, `1.50` → `1.5`; default `true`). `trim: false` keeps
      every place (`1,50`), for a column of figures.

  Machine output (CSV, JSON, CSS) never goes through it.
  """
  @spec format_decimal(number(), keyword()) :: String.t()
  def format_decimal(number, opts \\ []) when is_number(number) do
    decimals = Keyword.get(opts, :decimals, 1)
    trim? = Keyword.get(opts, :trim, true)
    rounded = Float.round(number * 1.0, decimals)

    text =
      cond do
        trim? and rounded == trunc(rounded) -> Integer.to_string(trunc(rounded))
        trim? -> :erlang.float_to_binary(rounded, [:compact, decimals: decimals])
        true -> :erlang.float_to_binary(rounded, decimals: decimals)
      end

    String.replace(text, ".", decimal_separator())
  end

  @doc ~S|The page's decimal separator: `","` or `"."` (`format_decimal/2`).|
  @spec decimal_separator() :: String.t()
  def decimal_separator do
    base =
      current_content_lang()
      |> to_string()
      |> String.downcase()
      |> String.split(["-", "_"], parts: 2)
      |> hd()

    if base in @comma_decimal, do: ",", else: "."
  end

  @doc """
  The current content-display language code.

  Reads `Gettext.get_locale/1` against the parent app's gettext backend
  — that's the locale Phoenix's pipeline set on the URL prefix
  (`/bs/...` → `"bs"`). Used by the localized-read helpers on schemas
  to pick the right entry from the `translations` JSONB; the helpers
  themselves fall back to the primary-language column when the locale
  has no override or is `nil`, so this never needs to validate the
  result against `enabled_languages/0`.
  """
  @spec current_content_lang() :: String.t() | nil
  def current_content_lang do
    # Reads the process dictionary (never the DB) — with a compiled backend
    # it cannot fail, so no rescue: a blanket one here would only mask
    # genuine bugs introduced by future refactors.
    Gettext.get_locale(PhoenixKitWeb.Gettext)
  end

  @doc """
  True when `translations` matches the documented JSONB shape:

      %{optional(String.t()) => %{optional(String.t()) => String.t()}}

  i.e. an outer map keyed by language code (`"es-ES"`) whose values
  are maps keyed by translatable field name (`"name"`) with string
  values. `%{}` and `nil` are valid (empty / unset). Used by every
  schema with a `translations` column to add a changeset-level guard
  so a programmatic caller can't persist garbage that the read
  helpers would silently fall back through.
  """
  @spec valid_translations_shape?(any()) :: boolean()
  def valid_translations_shape?(nil), do: true

  def valid_translations_shape?(map) when is_map(map) do
    Enum.all?(map, fn
      {lang, fields} when is_binary(lang) and is_map(fields) ->
        Enum.all?(fields, fn
          {k, v} when is_binary(k) and (is_binary(v) or is_nil(v)) -> true
          _ -> false
        end)

      _ ->
        false
    end)
  end

  def valid_translations_shape?(_), do: false

  @doc "Short 3-letter month name, translated (`Jan`, `Feb`, ...)."
  @spec short_month(1..12) :: String.t()
  def short_month(1), do: gettext("Jan")
  def short_month(2), do: gettext("Feb")
  def short_month(3), do: gettext("Mar")
  def short_month(4), do: gettext("Apr")
  def short_month(5), do: gettext("May")
  def short_month(6), do: gettext("Jun")
  def short_month(7), do: gettext("Jul")
  def short_month(8), do: gettext("Aug")
  def short_month(9), do: gettext("Sep")
  def short_month(10), do: gettext("Oct")
  def short_month(11), do: gettext("Nov")
  def short_month(12), do: gettext("Dec")
end
