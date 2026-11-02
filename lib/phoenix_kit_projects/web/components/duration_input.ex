defmodule PhoenixKitProjects.Web.Components.DurationInput do
  @moduledoc """
  Every amount-of-time input of the module: a number and a unit — minutes,
  hours or days — and nothing typed as text (the boss, 2026-10-30: "1 час"
  was refused by the old free-text field, and its hint was English only).
  A day is 8 hours, as the module counts a working day
  (`PhoenixKitProjects.Schemas.Task.to_hours/3`). Decimals are fine: `1.5`
  hours is 90 minutes.

  ## Logged time

      <.duration_input id="log-duration" name="duration" label={gettext("How long")} />

  posts `duration[amount]` and `duration[unit]`; `to_minutes/1` reads them:

      {:ok, minutes} = DurationInput.to_minutes(params["duration"])

  ## The estimate

  An estimate is two columns of its own (`estimated_duration`, an integer,
  and `estimated_duration_unit`), so the component takes the two fields:

      <.duration_input id="estimate" amount_field={@form[:estimated_duration]}
                       unit_field={@form[:estimated_duration_unit]} label={gettext("Estimate")} />

  and `estimate_attrs/1` turns a decimal into a whole number of a smaller
  unit before the cast (`1.5` hours → `90` minutes).
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitProjects.Gettext

  alias PhoenixKitProjects.Schemas.WorkEntry
  alias PhoenixKitWeb.Components.Core.Input

  @minutes_per %{"minutes" => 1, "hours" => 60, "days" => 8 * 60}
  @units ~w(minutes hours days)

  @doc "The units offered, in order."
  @spec units() :: [String.t()]
  def units, do: @units

  @doc "A unit's translated name for the select."
  @spec unit_label(String.t()) :: String.t()
  def unit_label("minutes"), do: gettext("Minutes")
  def unit_label("hours"), do: gettext("Hours")
  def unit_label("days"), do: gettext("Days")
  def unit_label("weeks"), do: gettext("Weeks")
  def unit_label("fortnights"), do: gettext("Fortnights")
  def unit_label("months"), do: gettext("Months")
  def unit_label("years"), do: gettext("Years")
  def unit_label(other), do: other

  # ── Reading what was posted ─────────────────────────────────────────

  @doc """
  The posted `%{"amount" => …, "unit" => …}` as whole minutes: `{:ok, n}`
  for a positive amount within what one entry may hold, `:error` for
  anything else (nothing, zero, text, an unknown unit, a bare string).
  """
  @spec to_minutes(term()) :: {:ok, pos_integer()} | :error
  def to_minutes(%{"amount" => amount, "unit" => unit}) when is_map_key(@minutes_per, unit) do
    with {:ok, n} <- parse_amount(amount),
         minutes = round(n * Map.fetch!(@minutes_per, unit)),
         true <- minutes > 0 and minutes <= WorkEntry.max_minutes() do
      {:ok, minutes}
    else
      _ -> :error
    end
  end

  def to_minutes(_), do: :error

  @doc """
  The amount typed, as a number: `"1.5"`, `"1,5"` (a comma is a decimal
  point in Estonian and Russian), `"2"`. `:error` for anything else.
  """
  @spec parse_amount(term()) :: {:ok, number()} | :error
  def parse_amount(value) when is_binary(value) do
    case value |> String.trim() |> String.replace(",", ".") |> Float.parse() do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> :error
    end
  end

  def parse_amount(n) when is_number(n) and n >= 0, do: {:ok, n}
  def parse_amount(_), do: :error

  @doc """
  Minutes as the amount and unit the inputs show: whole days, else whole
  hours, else hours with a decimal or minutes. `{nil, "hours"}` for none.
  """
  @spec from_minutes(number() | nil) :: {number() | nil, String.t()}
  def from_minutes(nil), do: {nil, "hours"}

  def from_minutes(minutes) do
    minutes = round(minutes)

    cond do
      minutes > 0 and rem(minutes, 480) == 0 -> {div(minutes, 480), "days"}
      rem(minutes, 60) == 0 -> {div(minutes, 60), "hours"}
      rem(minutes, 30) == 0 -> {minutes / 60, "hours"}
      true -> {minutes, "minutes"}
    end
  end

  @doc """
  The estimate's two fields as the changeset takes them: an amount with a
  decimal becomes a whole number of a smaller unit (`1.5` days → `12`
  hours, `1.25` hours → `75` minutes); a comma reads as a decimal point.
  Anything it cannot read is left for the changeset to refuse.
  """
  @spec estimate_attrs(map()) :: map()
  def estimate_attrs(%{"estimated_duration" => amount} = attrs) when is_binary(amount) do
    unit = attrs["estimated_duration_unit"]

    case parse_amount(amount) do
      {:ok, n} when n == trunc(n) ->
        Map.put(attrs, "estimated_duration", Integer.to_string(trunc(n)))

      {:ok, n} ->
        {whole, unit} = step_down(n, unit)

        attrs
        |> Map.put("estimated_duration", Integer.to_string(whole))
        |> Map.put("estimated_duration_unit", unit)

      :error ->
        attrs
    end
  end

  def estimate_attrs(attrs), do: attrs

  defp step_down(n, "days"), do: whole_or_down(n * 8, "hours")
  defp step_down(n, "hours"), do: whole_or_down(n * 60, "minutes")
  defp step_down(n, unit), do: {round(n), unit}

  defp whole_or_down(n, unit) when n == trunc(n), do: {trunc(n), unit}
  defp whole_or_down(n, unit), do: step_down(n, unit)

  # ── The component ───────────────────────────────────────────────────

  @doc """
  A number and a unit. Either `name` (posts `name[amount]`, `name[unit]`,
  read with `to_minutes/1`; `minutes` prefills it) or `amount_field` +
  `unit_field` (two form fields of their own, as the estimate's).
  """
  attr(:id, :string, required: true)
  attr(:name, :string, default: nil)
  attr(:minutes, :any, default: nil, doc: "a prefill for the `name` form, in minutes")
  attr(:amount, :any, default: nil, doc: "a prefill as typed (a form's own echo)")
  attr(:unit, :string, default: nil)
  attr(:amount_field, Phoenix.HTML.FormField, default: nil)
  attr(:unit_field, Phoenix.HTML.FormField, default: nil)
  attr(:units, :list, default: nil, doc: "default: minutes, hours, days (plus a stored other)")
  attr(:label, :string, default: nil)
  attr(:required, :boolean, default: false)
  attr(:form, :string, default: nil, doc: "the `form=` owner, for inputs drawn outside it")
  attr(:size, :string, default: "sm", values: ~w(xs sm md))
  attr(:class, :any, default: nil)

  def duration_input(assigns) do
    {amount_name, unit_name, amount, unit, errors} = wiring(assigns)
    units = assigns.units || @units
    # A stored unit the default list does not offer (an estimate in weeks)
    # stays a choice, so opening the form loses nothing.
    units = if unit in [nil, ""] or unit in units, do: units, else: units ++ [unit]

    assigns =
      assign(assigns,
        amount_name: amount_name,
        unit_name: unit_name,
        amount_value: amount,
        unit_value: if(unit in [nil, ""], do: "hours", else: unit),
        unit_options: Enum.map(units, &{unit_label(&1), &1}),
        errors: errors
      )

    ~H"""
    <fieldset id={@id} class={["flex flex-col gap-1", @class]} data-duration-input>
      <legend :if={@label} class="label mb-1">
        <span class="font-semibold">{@label}</span>
        <span :if={@required} class="text-error ml-0.5" aria-hidden="true">*</span>
      </legend>
      <div class="join w-full">
        <input
          type="number"
          id={"#{@id}-amount"}
          name={@amount_name}
          value={@amount_value}
          form={@form}
          min="0"
          step="any"
          inputmode="decimal"
          autocomplete="off"
          aria-label={gettext("Amount")}
          class={["input join-item w-full min-w-0", "input-#{@size}", @errors != [] && "input-error"]}
        />
        <select
          id={"#{@id}-unit"}
          name={@unit_name}
          form={@form}
          aria-label={gettext("Unit")}
          class={["select join-item w-auto", "select-#{@size}"]}
        >
          <option :for={{label, value} <- @unit_options} value={value} selected={value == @unit_value}>
            {label}
          </option>
        </select>
      </div>
      <p :for={msg <- @errors} class="text-error text-xs">{msg}</p>
    </fieldset>
    """
  end

  defp wiring(%{
         amount_field: %Phoenix.HTML.FormField{} = a,
         unit_field: %Phoenix.HTML.FormField{} = u
       }) do
    errors = Enum.map(a.errors ++ u.errors, &translate_error/1)
    {a.name, u.name, a.value, to_string(u.value || ""), errors}
  end

  defp wiring(%{name: name} = assigns) when is_binary(name) do
    {amount, unit} =
      cond do
        assigns.amount not in [nil, ""] -> {assigns.amount, assigns.unit}
        is_number(assigns.minutes) -> from_minutes(assigns.minutes)
        true -> {nil, assigns.unit}
      end

    {name <> "[amount]", name <> "[unit]", amount, unit, []}
  end

  # Core's, so a changeset error reads as in every other field.
  defp translate_error(error), do: Input.translate_error(error)
end
