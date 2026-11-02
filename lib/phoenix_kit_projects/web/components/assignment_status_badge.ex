defmodule PhoenixKitProjects.Web.Components.AssignmentStatusBadge do
  @moduledoc """
  Status presentation for an `Assignment.status` value (`"waiting"`,
  `"todo"` — shown as "can be started" — `"in_progress"`, `"done"`). Mirrors `DerivedStatusBadge` but for the
  assignment lifecycle instead of the project lifecycle.

  ## Helpers

  All three helpers accept an arbitrary string and fall back to the
  `"waiting"` styling on unknown values so a half-broken DB row still
  renders sensibly.

    * `color/1` — Tailwind `bg-*` class for filled circles/dots.
    * `badge_class/1` — daisyUI `badge-*` variant class.
    * `label/2` — the status's name (falls back to the raw value).
    * `action_label/2` — the step into a status.

  ## Component

      <.assignment_status_badge status={assignment.status} />
      <.assignment_status_badge status={assignment.status} size="sm" />
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitProjects.Gettext

  @doc "Tailwind background-color class for an assignment status."
  @spec color(String.t() | nil) :: String.t()
  def color("waiting"), do: "bg-base-300"
  def color("todo"), do: "bg-info"
  def color("in_progress"), do: "bg-warning"
  def color("done"), do: "bg-success"
  def color(_), do: "bg-base-300"

  @doc """
  Foreground (text) class that pairs with `color/1` on a filled dot. The `todo`
  dot is light (`bg-base-300`), so its number needs dark text — plain `text-white`
  was invisible. Colored states use their daisyUI `*-content` foreground.
  """
  @spec text_color(String.t() | nil) :: String.t()
  def text_color("todo"), do: "text-info-content"
  def text_color("in_progress"), do: "text-warning-content"
  def text_color("done"), do: "text-success-content"
  def text_color(_), do: "text-base-content"

  @doc """
  Outline for a filled dot. The light `todo` dot (`bg-base-300`) is nearly
  invisible on a white page, so it needs a border to define the circle; the
  solid colored states stand on their own.
  """
  @spec ring(String.t() | nil) :: String.t()
  def ring("todo"), do: ""
  def ring("in_progress"), do: ""
  def ring("done"), do: ""
  def ring(_), do: "border border-base-content/25"

  @doc "daisyUI badge variant class for an assignment status."
  @spec badge_class(String.t() | nil) :: String.t()
  def badge_class("waiting"), do: "badge-ghost"
  def badge_class("todo"), do: "badge-info"
  def badge_class("in_progress"), do: "badge-warning"
  def badge_class("done"), do: "badge-success"
  def badge_class(_), do: "badge-ghost"

  @doc """
  The outlined badge of a status that is offered but not chosen (the
  form's status choices, the Change status popup): its own colour, the
  waiting one in plain text.
  """
  @spec outline_class(String.t() | nil) :: String.t()
  def outline_class("todo"), do: "badge-info"
  def outline_class("in_progress"), do: "badge-warning"
  def outline_class("done"), do: "badge-success"
  def outline_class(_), do: "text-base-content/70"

  @doc "The top border of a status's board column."
  @spec column_class(String.t() | nil) :: String.t()
  def column_class("todo"), do: "border-t-info"
  def column_class("in_progress"), do: "border-t-warning"
  def column_class("done"), do: "border-t-success"
  def column_class(_), do: "border-t-base-300"

  @doc """
  A status's bar on the Timeline and the Calendar: stronger than the list's
  dot (a light `bg-base-300` chip washes out on a month grid), and a
  daisyUI semantic class, so the libraries pick a readable text colour.
  """
  @spec bar_color(String.t() | nil) :: String.t()
  def bar_color("done"), do: "bg-success"
  def bar_color("in_progress"), do: "bg-warning"
  def bar_color("waiting"), do: "bg-neutral"
  def bar_color(_), do: "bg-primary"

  @doc """
  The statuses a row may be put in — the form's status choices and the
  project page's Change status popup alike: the four, "in progress" only
  while that step is on (`fx.in_progress`) or the row sits there. A
  sub-project row whose status follows its tasks (`fx.subproject_auto`)
  is left only releasing or holding back before it starts — and nothing
  once it has.
  """
  @spec choices(map() | nil, map()) :: [String.t()]
  def choices(assignment, fx) do
    status = assignment && Map.get(assignment, :status)

    if subproject_row?(assignment) and fx[:subproject_auto] == true do
      if status in ["waiting", "todo"], do: ["waiting", "todo"], else: []
    else
      middle? = fx[:in_progress] == true or status == "in_progress"
      ["waiting", "todo"] ++ if(middle?, do: ["in_progress"], else: []) ++ ["done"]
    end
  end

  defp subproject_row?(%{child_project_uuid: uuid}) when is_binary(uuid), do: true
  defp subproject_row?(_), do: false

  @doc "`choices/2` as `[{label, status}]` for a form's options."
  @spec options(map() | nil, map()) :: [{String.t(), String.t()}]
  def options(assignment, fx) do
    sub? = subproject_row?(assignment)
    Enum.map(choices(assignment, fx), &{label(&1, sub?), &1})
  end

  @doc """
  The status as it is NAMED — the one word used for it everywhere: the
  badge, the board's columns, the filters, the Change status popup and the
  form's status buttons (`pgettext "task status"`). Never the step that
  leads to it: that is `action_label/2`.

  `subproject?` picks the form a sub-project's row takes where a language
  agrees the word with the noun (ru "Выполнена" for a задача, "Выполнен"
  for a подпроект).
  """
  @spec label(String.t() | nil, boolean()) :: String.t()
  def label(status, subproject? \\ false)
  def label("waiting", _), do: pgettext("task status", "Waiting")
  def label("todo", _), do: pgettext("task status", "Can be started")
  def label("in_progress", _), do: pgettext("task status", "In progress")
  def label("done", true), do: pgettext("sub-project status", "Done")
  def label("done", _), do: pgettext("task status", "Done")
  def label(other, _) when is_binary(other), do: other
  def label(_, _), do: pgettext("task status", "Waiting")

  @doc """
  The step that moves a task INTO a status, phrased on the status's own
  root (`pgettext "task action"`): Можно начинать ← Разрешить начать, В работе ← Взять в работу, Выполнена ←
  Отметить выполненной, and Открыть заново out of done.
  """
  @spec action_label(:allow_start | :start | :mark_done | :reopen, boolean()) :: String.t()
  def action_label(action, subproject? \\ false)
  def action_label(:allow_start, _), do: pgettext("task action", "Allow start")
  def action_label(:start, _), do: pgettext("task action", "Start")
  def action_label(:mark_done, true), do: pgettext("sub-project action", "Mark done")
  def action_label(:mark_done, _), do: pgettext("task action", "Mark done")
  def action_label(:reopen, _), do: pgettext("task action", "Reopen")

  @doc """
  ON HOLD — work that started and then had something before it reopened. A
  derived state, never stored, so it has no `label/2` entry; it agrees with
  its item like the stored ones (ru "Приостановлена" / "Приостановлен").
  """
  @spec on_hold_label(boolean()) :: String.t()
  def on_hold_label(true), do: pgettext("sub-project status", "On hold")
  def on_hold_label(_), do: pgettext("task status", "On hold")

  @doc "`on_hold_label/1` naming what it waits for (`tasks`, already quoted)."
  @spec on_hold_waiting_label(String.t(), boolean()) :: String.t()
  def on_hold_waiting_label(tasks, true),
    do: pgettext("sub-project status", "On hold — waiting for %{tasks}", tasks: tasks)

  def on_hold_waiting_label(tasks, _),
    do: pgettext("task status", "On hold — waiting for %{tasks}", tasks: tasks)

  @doc "The question before `:mark_done` hands work on, in the item's gender."
  @spec mark_done_question(String.t(), boolean()) :: String.t()
  def mark_done_question(task, true),
    do: pgettext("sub-project action", "Mark “%{task}” done?", task: task)

  def mark_done_question(task, _), do: pgettext("task action", "Mark “%{task}” done?", task: task)

  attr(:status, :string, required: true)
  attr(:subproject, :boolean, default: false, doc: "a sub-project's row (the word's gender)")
  attr(:size, :string, default: "sm", values: ~w(xs sm md lg))
  attr(:class, :string, default: nil)

  def assignment_status_badge(assigns) do
    ~H"""
    <span class={["badge", size_class(@size), badge_class(@status), @class]}>
      {label(@status, @subproject)}
    </span>
    """
  end

  # Literal per size — an interpolated "badge-#{size}" is invisible to the
  # Tailwind scanner, so the class only exists if some other file happens to
  # spell it out.
  defp size_class("xs"), do: "badge-xs"
  defp size_class("md"), do: "badge-md"
  defp size_class("lg"), do: "badge-lg"
  defp size_class(_), do: "badge-sm"
end
