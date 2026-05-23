defmodule PhoenixKitProjects.Web.Components.ReorderModal do
  @moduledoc """
  Modal that lets the user pick a sort strategy for bulk reorder.

  Wraps core's `<.modal>` and renders radio buttons for each strategy
  the consumer LV passes in. The scope label shows whether the apply
  will rewrite "all N rows" or "the M selected rows" so the user can
  see the consequence before clicking Apply.

  Strategies are domain-specific (projects sort by `name`, tasks by
  `title`, etc.) so the consumer owns the strategy list — the modal
  is just shell + radio UI.

  ## Example

      <.reorder_modal
        show={@show_reorder}
        on_close="close_reorder"
        on_apply="apply_reorder"
        selected_count={MapSet.size(@selected_uuids)}
        total_count={length(@projects)}
        strategies={[
          {"name_asc", gettext("A → Z by name")},
          {"name_desc", gettext("Z → A by name")},
          {"created_desc", gettext("Newest first")},
          {"created_asc", gettext("Oldest first")},
          {"reverse", gettext("Reverse current order")}
        ]}
        noun_singular={gettext("project")}
        noun_plural={gettext("projects")}
      />

  The Apply button emits `on_apply` with `phx-value-strategy=<value>`,
  where the strategy is the first element of each `{value, label}`
  tuple. Apply is disabled until a strategy is chosen.

  When `selected_count > 0`, the modal labels the scope "M selected
  <noun>". When zero, "All N <noun>" — so the consumer LV picks the
  scope by what's in `selected_uuids`, the modal just reflects it.
  """
  use Phoenix.Component
  use Gettext, backend: PhoenixKitProjects.Gettext

  import PhoenixKitWeb.Components.Core.Modal, only: [modal: 1]
  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  attr :show, :boolean, required: true
  attr :on_close, :string, required: true
  attr :on_apply, :string, required: true
  attr :selected_count, :integer, default: 0
  attr :total_count, :integer, required: true

  attr :strategies, :list,
    required: true,
    doc: "List of `{value :: String.t(), label :: String.t()}` tuples."

  attr :noun_singular, :string, default: "item"
  attr :noun_plural, :string, default: "items"
  attr :id, :string, default: "reorder-modal"

  def reorder_modal(assigns) do
    ~H"""
    <.modal show={@show} on_close={@on_close} id={@id} max_width="md">
      <:title>
        <.icon name="hero-arrows-up-down" class="w-5 h-5 text-primary" />
        {gettext("Reorder")}
      </:title>

      <div class="space-y-3">
        <p class="text-sm text-base-content/70">
          {scope_label(@selected_count, @total_count, @noun_singular, @noun_plural)}
        </p>

        <form id={"#{@id}-form"} phx-submit={@on_apply} class="space-y-2">
          <label
            :for={{value, label} <- @strategies}
            class="flex items-center gap-3 p-2 rounded hover:bg-base-200 cursor-pointer"
          >
            <input
              type="radio"
              name="strategy"
              value={value}
              class="radio radio-sm radio-primary"
            />
            <span class="text-sm">{label}</span>
          </label>
        </form>
      </div>

      <:actions>
        <button type="button" class="btn btn-ghost" phx-click={@on_close}>
          {gettext("Cancel")}
        </button>
        <button type="submit" form={"#{@id}-form"} class="btn btn-primary">
          {gettext("Apply")}
        </button>
      </:actions>
    </.modal>
    """
  end

  defp scope_label(0, total, _singular, plural) do
    gettext("Reorder all %{count} %{noun}.", count: total, noun: plural)
  end

  defp scope_label(1, _total, singular, _plural) do
    gettext("Reorder the 1 selected %{noun} (other rows stay in place).", noun: singular)
  end

  defp scope_label(n, _total, _singular, plural) do
    gettext("Reorder the %{count} selected %{noun} (other rows stay in place).",
      count: n,
      noun: plural
    )
  end
end
