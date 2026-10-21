defmodule PhoenixKitProjects.Web.Components.VizPalette do
  @moduledoc """
  The charts' colours: eight categorical slots (a validated palette, the
  dark steps chosen for a dark surface) as CSS variables on `.pk-hours-viz`,
  written once so the bars, the legends and the timesheet share them. Slot
  0 is "Others", a neutral. Used by the Hours tab and the API keys page.

      <.viz_palette />
      <section class="pk-hours-viz">
        <.bar_chart … data={[%{label: "Mon", parts: [%{value: 3, class: viz_slot_class(1)}]}]} />
        <span style={viz_slot_style(1)}></span>
      </section>
  """

  use Phoenix.Component

  @doc "The palette's `<style>`; render it once on the page."
  def viz_palette(assigns) do
    ~H"""
    <style>
      .pk-hours-viz{--pkh-0:#8a8985;--pkh-1:#2a78d6;--pkh-2:#eb6834;--pkh-3:#1baf7a;--pkh-4:#eda100;--pkh-5:#e87ba4;--pkh-6:#008300;--pkh-7:#4a3aa7}
      [data-theme*="dark"] .pk-hours-viz,[data-theme="night"] .pk-hours-viz,[data-theme="dim"] .pk-hours-viz{--pkh-0:#8a8985;--pkh-1:#3987e5;--pkh-2:#d95926;--pkh-3:#199e70;--pkh-4:#c98500;--pkh-5:#d55181;--pkh-6:#008300;--pkh-7:#9085e9}
    </style>
    """
  end

  @doc """
  A slot's colour as a text colour (core's charts draw in currentColor).
  Spelled out: Tailwind only ships the classes it can read in the source.
  """
  @spec viz_slot_class(integer()) :: String.t()
  def viz_slot_class(1), do: "text-[var(--pkh-1)]"
  def viz_slot_class(2), do: "text-[var(--pkh-2)]"
  def viz_slot_class(3), do: "text-[var(--pkh-3)]"
  def viz_slot_class(4), do: "text-[var(--pkh-4)]"
  def viz_slot_class(5), do: "text-[var(--pkh-5)]"
  def viz_slot_class(6), do: "text-[var(--pkh-6)]"
  def viz_slot_class(7), do: "text-[var(--pkh-7)]"
  def viz_slot_class(_), do: "text-[var(--pkh-0)]"

  @doc "A slot's colour as a background, for a legend swatch."
  @spec viz_slot_style(integer()) :: String.t()
  def viz_slot_style(slot) when slot in 1..7, do: "background: var(--pkh-#{slot})"
  def viz_slot_style(_), do: "background: var(--pkh-0)"
end
