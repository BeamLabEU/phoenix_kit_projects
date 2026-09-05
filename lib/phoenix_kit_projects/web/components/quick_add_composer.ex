defmodule PhoenixKitProjects.Web.Components.QuickAddComposer do
  @moduledoc """
  The "Add a task" row at the foot of a project's task list.

  It used to be an inline Todoist-style input (2026-09-04). Max, the day
  after, once the add-task form had become a right-hand sheet beside
  the list: "the add a task should both open the popup and inside there
  should we have that stuff setup." So the row is now the second way
  into the same sheet as the "Add task" button at the top — it opens
  `AssignmentFormLive` in Create-new with the cursor in the title, and
  the keyboard loop lives in the form: **Enter** adds and closes,
  **Shift+Enter** adds and starts the next task on a fresh form, **Esc**
  closes a clean form. The sheet sits beside the list, so the list is
  still watched growing — the inline row's one advantage — with the full
  fields a glance away for the one task in ten that needs them.

  In popup / emit mode this is a popup button; on a host page in
  navigate mode it is a link to the add page. It must stay OUTSIDE the
  sortable container so a drag never treats it as a row.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitProjects.Gettext

  import PhoenixKitProjects.Web.Components.SmartLink
  import PhoenixKitWeb.Components.Core.Icon

  alias PhoenixKitProjects.Paths

  attr(:project_uuid, :string, required: true)
  attr(:embed_mode, :any, default: nil)
  attr(:id, :string, default: "quick-add")

  def quick_add_composer(assigns) do
    ~H"""
    <div id={@id} class="mt-2">
      <.smart_link
        navigate={Paths.new_assignment(@project_uuid)}
        emit={{PhoenixKitProjects.Web.AssignmentFormLive, %{"live_action" => "new", "project_id" => @project_uuid}}}
        embed_mode={@embed_mode}
        class="btn btn-ghost btn-sm w-full justify-start border border-dashed border-base-300 text-base-content/60 hover:text-base-content hover:border-base-content/40"
      >
        <.icon name="hero-plus" class="w-4 h-4" /> {gettext("Add a task")}
      </.smart_link>
    </div>
    """
  end
end
