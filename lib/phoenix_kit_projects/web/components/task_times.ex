defmodule PhoenixKitProjects.Web.Components.TaskTimes do
  @moduledoc """
  A task's times as its row, its board card and its view say them (V26):
  the deadline — the promise, and the only thing that makes a task
  overdue — and the planned days, which are a plan and so never turn red.

  The deadline is a moment, stored in UTC and shown on the viewer's clock
  (`PhoenixKitProjects.L10n`); the planned days and their times are
  zone-free, shown as typed.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitProjects.Gettext

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  alias PhoenixKitProjects.L10n
  alias PhoenixKitProjects.Schemas.Assignment

  @doc """
  A deadline, short enough for a chip: `Today 15:00`, `Tomorrow 09:00`,
  `Oct 31 15:00` — with the year only when it is not this one.
  """
  @spec deadline_label(DateTime.t() | nil, DateTime.t()) :: String.t() | nil
  def deadline_label(deadline, now \\ DateTime.utc_now())
  def deadline_label(nil, _now), do: nil

  def deadline_label(%DateTime{} = deadline, %DateTime{} = now) do
    local = L10n.local(deadline)
    time = L10n.format_time(local)

    case Date.diff(DateTime.to_date(local), L10n.local_date(now)) do
      0 ->
        gettext("Today %{time}", time: time)

      1 ->
        gettext("Tomorrow %{time}", time: time)

      _ ->
        if local.year == L10n.local_date(now).year,
          do: L10n.format_month_day_time(deadline),
          else: L10n.format_datetime(deadline)
    end
  end

  @doc """
  The planned days with their times when set: `Oct 12 14:00 – Oct 14
  17:00`, `Oct 12 14:00 – 17:00` within one day, `from Oct 12` or
  `until Oct 14` when only one end is set; `nil` when none is.
  """
  @spec planned_label(Assignment.t() | map()) :: String.t() | nil
  def planned_label(%{start_date: nil, end_date: nil}), do: nil

  def planned_label(%{start_date: %Date{} = from, end_date: nil} = a),
    do: gettext("from %{date}", date: day(from, a.start_time))

  def planned_label(%{start_date: nil, end_date: %Date{} = to} = a),
    do: gettext("until %{date}", date: day(to, a.end_time))

  def planned_label(%{start_date: %Date{} = from, end_date: %Date{} = to} = a) do
    cond do
      from == to and match?(%Time{}, a.end_time) ->
        "#{day(from, a.start_time)} – #{hm(a.end_time)}"

      from == to ->
        day(from, a.start_time)

      true ->
        "#{day(from, a.start_time)} – #{day(to, a.end_time)}"
    end
  end

  def planned_label(_), do: nil

  defp day(%Date{} = d, time) do
    day =
      if d.year == L10n.local_date(DateTime.utc_now()).year,
        do: gettext("%{month} %{day}", month: L10n.short_month(d.month), day: d.day),
        else: L10n.format_date(d)

    case time do
      %Time{} = t -> "#{day} #{hm(t)}"
      _ -> day
    end
  end

  defp hm(%Time{hour: h, minute: m}),
    do: :io_lib.format("~2..0B:~2..0B", [h, m]) |> IO.iodata_to_binary()

  @doc """
  The deadline chip: red once it has passed (and the task is not done),
  amber when it is close, an outline otherwise. Nothing without one.
  """
  attr(:a, :map, required: true)
  attr(:size, :string, default: "sm", values: ~w(xs sm))
  attr(:now, :any, default: nil)

  attr(:tone, :string,
    default: "solid",
    values: ~w(solid outline),
    doc: "`outline` keeps a board card calm: the colour is in the border and the text"
  )

  def deadline_chip(%{a: %{deadline: %DateTime{}}} = assigns) do
    now = assigns.now || DateTime.utc_now()

    assigns =
      assign(assigns,
        state: Assignment.deadline_state(assigns.a, now),
        label: deadline_label(assigns.a.deadline, now)
      )

    ~H"""
    <span
      data-deadline={@state}
      class={[
        "badge gap-1 whitespace-nowrap",
        @size == "xs" && "badge-xs",
        @size == "sm" && "badge-sm",
        @tone == "solid" && @state == :overdue && "badge-error",
        @tone == "solid" && @state == :soon && "badge-warning",
        (@tone == "outline" or @state == :set) && "badge-outline",
        @tone == "outline" && @state == :overdue && "text-error border-error",
        @tone == "outline" && @state == :soon && "text-warning border-warning"
      ]}
      title={deadline_title(@state)}
    >
      <span aria-hidden="true">⏰</span> {@label}
    </span>
    """
  end

  def deadline_chip(assigns), do: ~H""

  defp deadline_title(:overdue), do: gettext("Past its deadline")
  defp deadline_title(:soon), do: gettext("Its deadline is close")
  defp deadline_title(_), do: gettext("Deadline")

  @doc """
  The planned-days chip: always neutral — a plan that slipped is not
  overdue, the deadline says that.
  """
  attr(:a, :map, required: true)
  attr(:size, :string, default: "sm", values: ~w(xs sm))

  def planned_chip(assigns) do
    assigns = assign(assigns, :label, planned_label(assigns.a))

    ~H"""
    <span
      :if={@label}
      class={["badge badge-outline gap-1 whitespace-nowrap", @size == "xs" && "badge-xs", @size == "sm" && "badge-sm"]}
      title={gettext("Planned")}
    >
      <.icon name="hero-calendar-days" class="w-3 h-3" /> {@label}
    </span>
    """
  end
end
