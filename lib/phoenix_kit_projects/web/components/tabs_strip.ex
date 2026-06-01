defmodule PhoenixKitProjects.Web.Components.TabsStrip do
  @moduledoc """
  daisyUI `tabs tabs-boxed` segment switcher driven by the active
  value + a list of `{value, label, icon}` tuples. Used in
  `AssignmentFormLive` ("From library" / "Create new") and ready
  for reuse anywhere a small set of mutually-exclusive panes shares
  a single LV-managed assign.

  Each tab is a `<button phx-click>` (no form submission) so the
  consumer's `handle_event/3` controls the switch. The clicked
  tab's value is delivered as `phx-value-value`, so handlers
  match on `%{"value" => v}`.

  The button also carries a native `value={value}`. LiveView's
  `extractMeta` overwrites `meta.value` with the element's `.value`
  DOM property after reading `phx-value-value` (view.js), so without
  the native attribute a `<button>` (`.value === ""`) would deliver
  an empty `"value"` and the handler would never see the tab. This
  collision is specific to the param key being literally `value`.

  ## Example

      <.tabs_strip
        event="set_task_mode"
        active={@task_mode}
        tabs={[
          {"existing", gettext("From library"), "hero-rectangle-stack"},
          {"new", gettext("Create new"), "hero-plus"}
        ]}
      />
  """

  use Phoenix.Component

  import PhoenixKitWeb.Components.Core.Icon

  attr(:event, :string, required: true)
  attr(:active, :string, required: true)

  attr(:tabs, :list,
    required: true,
    doc: "list of {value, label, icon} tuples"
  )

  def tabs_strip(assigns) do
    ~H"""
    <div role="tablist" class="tabs tabs-boxed">
      <button
        :for={{value, label, icon} <- @tabs}
        type="button"
        role="tab"
        phx-click={@event}
        phx-value-value={value}
        value={value}
        class={["tab gap-2", @active == value && "tab-active"]}
      >
        <.icon name={icon} class="w-4 h-4" /> {label}
      </button>
    </div>
    """
  end
end
