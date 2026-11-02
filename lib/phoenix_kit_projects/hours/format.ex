defmodule PhoenixKitProjects.Hours.Format do
  @moduledoc """
  How the Hours pages write and read an amount of time: `1h 30m` on the
  page, `1.50` in a spreadsheet column, and the same shapes typed back into
  the "Log time" field.
  """

  use Gettext, backend: PhoenixKitProjects.Gettext

  alias PhoenixKitProjects.L10n
  alias PhoenixKitProjects.Schemas.WorkEntry

  @doc ~S|Minutes as `45m`, `2h` or `2h 05m` — the project page's own shape.|
  @spec duration(number()) :: String.t()
  def duration(minutes) do
    minutes = round(minutes)
    h = div(minutes, 60)
    rest = rem(minutes, 60)

    cond do
      h == 0 -> gettext("%{m}m", m: rest)
      rest == 0 -> gettext("%{h}h", h: h)
      true -> gettext("%{h}h %{m}m", h: h, m: String.pad_leading(to_string(rest), 2, "0"))
    end
  end

  @doc ~S|Minutes as decimal hours with two places (`1.50`) — a column a spreadsheet can sum.|
  @spec decimal_hours(number()) :: String.t()
  def decimal_hours(minutes), do: :erlang.float_to_binary(minutes / 60, decimals: 2)

  @doc ~S|Minutes as decimal hours on the page: `1.50`, or `1,50` in a decimal-comma language (`L10n.format_decimal/2`). The CSV keeps `decimal_hours/1`.|
  @spec hours_shown(number()) :: String.t()
  def hours_shown(minutes), do: L10n.format_decimal(minutes / 60, decimals: 2, trim: false)

  @doc ~S|Tokens as `12`, `3.4k` or `1.2M` (`3,4k` in a decimal-comma language).|
  @spec tokens(number()) :: String.t()
  def tokens(t) when t >= 1_000_000, do: L10n.format_decimal(t / 1_000_000, trim: false) <> "M"
  def tokens(t) when t >= 1_000, do: L10n.format_decimal(t / 1_000, trim: false) <> "k"
  def tokens(t), do: to_string(round(t))

  @doc "Cents as a dollar figure, the unit the ledger's cost entries are shown in."
  @spec cost(number()) :: String.t()
  def cost(cents), do: "$" <> L10n.format_decimal(cents / 100, decimals: 2, trim: false)

  @doc """
  What a person types for an amount of time, as whole minutes:

    * `90`, `90m`, `90 min` — minutes
    * `1h`, `1h 30m`, `1h30`, `1 h 30 min` — hours and minutes
    * `1.5h`, `1,5 h` — decimal hours
    * `1:30` — hours and minutes

  `:error` for anything else, for nothing, and for more than one entry
  holds.
  """
  @spec parse_duration(term()) :: {:ok, pos_integer()} | :error
  def parse_duration(value) when is_binary(value) do
    text = value |> String.trim() |> String.downcase() |> String.replace(",", ".")

    minutes =
      cond do
        m = Regex.run(~r/^(\d+):([0-5]?\d)$/, text) ->
          int(Enum.at(m, 1)) * 60 + int(Enum.at(m, 2))

        m = Regex.run(~r/^(\d+(?:\.\d+)?)\s*(?:h|hr|hrs|hour|hours)$/, text) ->
          round(float(Enum.at(m, 1)) * 60)

        m =
            Regex.run(
              ~r/^(\d+)\s*(?:h|hr|hrs|hour|hours)\s*(\d+)\s*(?:m|min|mins|minutes)?$/,
              text
            ) ->
          int(Enum.at(m, 1)) * 60 + int(Enum.at(m, 2))

        m = Regex.run(~r/^(\d+)\s*(?:m|min|mins|minutes)?$/, text) ->
          int(Enum.at(m, 1))

        true ->
          0
      end

    if minutes > 0 and minutes <= WorkEntry.max_minutes(), do: {:ok, minutes}, else: :error
  end

  def parse_duration(_), do: :error

  defp int(s), do: String.to_integer(s)

  defp float(s) do
    {f, _} = Float.parse(s)
    f
  end
end
