defmodule PhoenixKitProjects.Web.Components.QuickAddComposer do
  @moduledoc """
  The Todoist-style inline task composer at the foot of a project's task
  list: a dashed "Add a task" row that turns into one title input.

  Keyboard contract (Todoist parity, checked 2026-09-04):

  - **Enter** adds the task and keeps the composer open, focused and
    empty, ready for the next one. **Shift+Enter** does the same — in
    Todoist it is "save and add another below", which for a bottom-of-list
    composer is the same act.
  - **Esc** closes it (bound on the input alone via `phx-keydown`, never on
    the window — a dialog's own Esc must keep working).
  - **Tab** reaches "More options", the very next control, whose Enter
    opens the full add-task form with the typed title carried over. That
    is Todoist's "Tab opens the full editor" without stealing Tab from the
    keyboard's normal job.

  Phoenix-first, no hook of its own:

  - a real `<form phx-submit>`, so Enter is the browser's implicit
    submission — IME composition confirms never submit, and LiveView locks
    the inputs read-only while the submit is in flight, which is what
    makes a fast double Enter add ONE task;
  - after a successful add the host bumps `seq`, the input's DOM id
    changes, morphdom replaces it with a fresh empty element and
    `phx-mounted={JS.focus()}` refocuses — the only reliable way to clear a
    focused input from the server (a patch never overwrites the focused
    element's value);
  - the draft is tracked through `phx-change` so an error keeps the text
    and "More options" can carry it.

  The host owns the state — `%{open:, seq:, draft:, error:}` — and the
  four events (`quick_add_open`, `quick_add_close`, `quick_add_change`,
  `quick_add_task`). The composer must live OUTSIDE the sortable/stream
  container so a drag or a patched row never remounts it.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitProjects.Gettext

  import PhoenixKitProjects.Web.Components.SmartLink
  import PhoenixKitWeb.Components.Core.Button, only: [button: 1]
  import PhoenixKitWeb.Components.Core.Icon
  import PhoenixKitWeb.Components.Core.Input, only: [input: 1]

  alias Phoenix.LiveView.JS
  alias PhoenixKitProjects.Paths

  attr(:project_uuid, :string, required: true)
  attr(:state, :map, required: true, doc: "%{open:, seq:, draft:, error:}")
  attr(:embed_mode, :any, default: nil)
  attr(:id, :string, default: "quick-add")

  def quick_add_composer(assigns) do
    ~H"""
    <div id={@id} class="mt-2">
      <%!-- Core components throughout (button / input): the same look and
           the same small fixes (feedback wrapper, error rendering) as every
           other form in the kit. --%>
      <.button
        :if={not @state.open}
        type="button"
        variant="ghost"
        size="sm"
        phx-click="quick_add_open"
        class="w-full justify-start border border-dashed border-base-300 text-base-content/60 hover:text-base-content hover:border-base-content/40"
      >
        <.icon name="hero-plus" class="w-4 h-4" /> {gettext("Add a task")}
      </.button>

      <form
        :if={@state.open}
        id={"#{@id}-form"}
        phx-submit="quick_add_task"
        phx-change="quick_add_change"
        class="flex flex-col gap-1"
      >
        <div class="flex items-start gap-2">
          <.input
            id={"#{@id}-title-#{@state.seq}"}
            type="text"
            name="title"
            value={@state.draft}
            errors={List.wrap(@state.error)}
            placeholder={gettext("Task title — Enter adds it and keeps going")}
            aria-label={gettext("New task title")}
            autocomplete="off"
            phx-mounted={JS.focus()}
            phx-keydown="quick_add_close"
            phx-key="Escape"
            phx-debounce="150"
            wrapper_class="flex-1"
            class="input-sm"
          />
          <.button type="submit" size="sm" phx-disable-with={gettext("Adding…")}>
            {gettext("Add")}
          </.button>
          <.smart_link
            navigate={more_options_path(@project_uuid, @state.draft)}
            emit={
              {PhoenixKitProjects.Web.AssignmentFormLive,
               %{"live_action" => "new", "project_id" => @project_uuid, "title" => @state.draft}}
            }
            embed_mode={@embed_mode}
            class="btn btn-ghost btn-sm"
            title={gettext("Open the full form (duration, assignee, dependencies)")}
          >
            {gettext("More options")}
          </.smart_link>
          <.button
            type="button"
            variant="ghost"
            size="sm"
            phx-click="quick_add_close"
            class="btn-square"
            aria-label={gettext("Close")}
          >
            <.icon name="hero-x-mark" class="w-4 h-4" />
          </.button>
        </div>
        <p :if={is_nil(@state.error)} class="text-xs text-base-content/50">
          {gettext("Enter adds and stays open · Esc closes · one-off tasks stay out of the library")}
        </p>
      </form>
    </div>
    """
  end

  # The full form prefilled with the draft (`?title=`); an empty draft is
  # the plain add page.
  defp more_options_path(project_uuid, draft) do
    base = Paths.new_assignment(project_uuid)

    case String.trim(draft || "") do
      "" -> base
      title -> base <> "?" <> URI.encode_query(%{"title" => title})
    end
  end
end
