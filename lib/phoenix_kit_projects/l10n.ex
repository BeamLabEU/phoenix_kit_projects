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

  alias PhoenixKit.Utils.TimeZone

  @zone_key :phoenix_kit_projects_viewer_zone

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
    :ok
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

  @doc "The viewer's `HH:MM` of an instant."
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

  @doc "24-hour time string as `HH:MM` (locale-neutral)."
  @spec format_time(DateTime.t()) :: String.t()
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
