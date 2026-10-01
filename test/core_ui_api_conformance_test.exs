defmodule PhoenixKitProjects.CoreUiApiConformanceTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Guards the core components this module's LiveViews are written against.

  Phoenix verifies a component call's attributes and slots at compile time, and
  an undeclared one is only a WARNING — the build still produces a package whose
  page silently drops the control. Three of these shipped that way once: a
  published core without `form_actions`' `submit_disabled`, `bulk_actions_toolbar`'s
  `:primary` slot and `form_section`'s `:actions` slot rendered every Save
  button enabled while an AI translation was in flight, and no "New …" button on
  the Projects, Tasks or Templates lists.

  `mix compile --warnings-as-errors` catches it for whoever builds this repo; this
  test names the missing piece, and fails the moment the `:phoenix_kit` floor in
  `mix.exs` admits a core that predates it. When it fails, raise the floor to the
  core release that ships the API (and extend `core_pin_conformance_test.exs`) —
  do not delete the entry.
  """

  alias PhoenixKitWeb.Components.Core.{BulkSelect, FormActions, FormSection, Modal, PopoverPanel}

  # {module, component, attrs the LiveViews pass, slots the LiveViews fill}
  @used [
    {FormActions, :form_actions, [:submit_disabled], [:cancel]},
    {BulkSelect, :bulk_actions_toolbar, [], [:primary]},
    {FormSection, :form_section, [:title, :icon, :body_class], [:subtitle, :actions]},
    {Modal, :modal, [:show, :on_close, :close_guard, :placement, :max_width], [:title, :actions]},
    {PopoverPanel, :popover_panel, [:align, :width_class], []}
  ]

  for {module, component, attrs, slots} <- @used do
    test "core's #{inspect(module)}.#{component}/1 declares what the LiveViews pass" do
      declared =
        unquote(module).__components__()
        |> Map.fetch!(unquote(component))

      declared_attrs = Enum.map(declared.attrs, & &1.name)
      declared_slots = Enum.map(declared.slots, & &1.name)

      for attr <- unquote(attrs) do
        assert attr in declared_attrs,
               "core's #{inspect(unquote(module))}.#{unquote(component)}/1 has no `#{attr}` attr — " <>
                 "this module passes it, so the installed `:phoenix_kit` is too old. Raise the floor."
      end

      for slot <- unquote(slots) do
        assert slot in declared_slots,
               "core's #{inspect(unquote(module))}.#{unquote(component)}/1 has no `:#{slot}` slot — " <>
                 "this module fills it, so the installed `:phoenix_kit` is too old. Raise the floor."
      end
    end
  end
end
