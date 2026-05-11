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

  @doc "Formats a `Date`/`DateTime` as `Mon DD, YYYY`. Returns `nil` for nil."
  def format_date(nil), do: nil

  def format_date(%DateTime{} = dt),
    do: dt |> DateTime.to_date() |> format_date()

  def format_date(%NaiveDateTime{} = dt),
    do: dt |> NaiveDateTime.to_date() |> format_date()

  def format_date(%Date{} = d),
    do: gettext("%{month} %{day}, %{year}", month: short_month(d.month), day: d.day, year: d.year)

  @doc """
  Formats as `Mon DD, YYYY at HH:MM`. For DateTimes.
  """
  def format_datetime(nil), do: nil

  def format_datetime(%DateTime{} = dt) do
    gettext("%{month} %{day}, %{year} at %{time}",
      month: short_month(dt.month),
      day: dt.day,
      year: dt.year,
      time: format_time(dt)
    )
  end

  @doc "Formats as `Mon DD HH:MM` — month, day, and time only."
  def format_month_day_time(nil), do: nil

  def format_month_day_time(%DateTime{} = dt) do
    gettext("%{month} %{day} %{time}",
      month: short_month(dt.month),
      day: dt.day,
      time: format_time(dt)
    )
  end

  @doc "24-hour time string as `HH:MM` (locale-neutral)."
  def format_time(%DateTime{hour: h, minute: m}),
    do: :io_lib.format("~2..0B:~2..0B", [h, m]) |> IO.iodata_to_binary()

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
    Gettext.get_locale(PhoenixKitWeb.Gettext)
  rescue
    _ -> nil
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
