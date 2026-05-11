defmodule PhoenixKitProjects.Web.Components.TabsStrip do
  @moduledoc """
  daisyUI `tabs tabs-boxed` segment switcher driven by the active
  value + a list of `{value, label, icon}` tuples. Used in
  `AssignmentFormLive` ("From library" / "Create new") and ready
  for reuse anywhere a small set of mutually-exclusive panes shares
  a single LV-managed assign.

  Each tab is a `<button phx-click>` (no form submission) so the
  consumer's `handle_event/3` controls the switch — typical pattern
  is `phx-click="set_task_mode" phx-value-mode="new"`.

  ## Example

      <.tabs_strip
        event="set_task_mode"
        value_attr="mode"
        active={@task_mode}
        tabs={[
          {"existing", gettext("From library"), "hero-rectangle-stack"},
          {"new", gettext("Create new"), "hero-plus"}
        ]}
      />
  """

  use Phoenix.Component

  import PhoenixKitWeb.Components.Core.Icon

  attr :event, :string, required: true
  attr :value_attr, :string, default: "value", doc: "phx-value-<attr> name"
  attr :active, :string, required: true

  attr :tabs, :list,
    required: true,
    doc: "list of {value, label, icon} tuples"

  def tabs_strip(assigns) do
    ~H"""
    <div role="tablist" class="tabs tabs-boxed">
      <button
        :for={{value, label, icon} <- @tabs}
        type="button"
        role="tab"
        phx-click={@event}
        {phx_value(@value_attr, value)}
        class={["tab gap-2", @active == value && "tab-active"]}
      >
        <.icon name={icon} class="w-4 h-4" /> {label}
      </button>
    </div>
    """
  end

  defp phx_value(attr, value), do: %{"phx-value-#{attr}" => value}
end
