defmodule PhoenixKitProjects.Web.Components.SmartMenuLink do
  @moduledoc """
  Embed-mode aware `<li>` entry for use inside `<.table_row_menu>`.

  Behaves like `<.smart_link>` (renders a real `<a href>` in navigate
  mode, fires the shared `open_embed` event in emit mode), but produces
  the menu-item styling that `<.table_row_menu_link>` /
  `<.table_row_menu_button>` apply.

  Use everywhere this module's tables need an Edit / View / per-row
  navigation entry inside a 3-dots dropdown.

  ## Example

      <.table_row_menu id={"row-menu-\#{task.uuid}"}>
        <.smart_menu_link
          navigate={Paths.edit_task(task.uuid)}
          emit={{PhoenixKitProjects.Web.TaskFormLive,
                 %{"live_action" => "edit", "id" => task.uuid}}}
          embed_mode={@embed_mode}
          icon="hero-pencil"
          label={gettext("Edit")}
        />
        <.table_row_menu_button
          phx-click="delete"
          phx-value-uuid={task.uuid}
          icon="hero-trash"
          label={gettext("Delete")}
          variant="error"
        />
      </.table_row_menu>
  """

  use Phoenix.Component

  import PhoenixKitWeb.Components.Core.TableRowMenu,
    only: [table_row_menu_link: 1, table_row_menu_button: 1]

  attr(:navigate, :string, required: true)

  attr(:emit, :any,
    required: true,
    doc: "{TargetLV :: module(), session_overrides :: map()}"
  )

  attr(:embed_mode, :atom, default: :navigate, values: [:navigate, :emit])
  attr(:icon, :string, default: nil)
  attr(:label, :string, required: true)
  attr(:variant, :string, default: "default")
  attr(:rest, :global, include: ~w(data-id title aria-label))

  def smart_menu_link(%{embed_mode: :emit} = assigns) do
    {target_lv, session_overrides} = assigns.emit

    assigns =
      assigns
      |> assign(:lv_str, Atom.to_string(target_lv))
      |> assign(:session_json, Jason.encode!(session_overrides))

    ~H"""
    <.table_row_menu_button
      icon={@icon}
      label={@label}
      variant={@variant}
      phx-click="open_embed"
      phx-value-lv={@lv_str}
      phx-value-session={@session_json}
      {@rest}
    />
    """
  end

  def smart_menu_link(assigns) do
    ~H"""
    <.table_row_menu_link
      navigate={@navigate}
      icon={@icon}
      label={@label}
      variant={@variant}
      {@rest}
    />
    """
  end
end
