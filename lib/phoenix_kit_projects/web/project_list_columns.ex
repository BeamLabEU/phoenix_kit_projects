defmodule PhoenixKitProjects.Web.ProjectListColumns do
  @moduledoc """
  The projects list's optional columns, as data: what each one is called,
  which read answers it (`PhoenixKitProjects.ListMetrics`' families), what
  it sorts by, and the filters the list offers over the same values.

  `ProjectsLive` draws the cells (one `column_cell/3` clause per id); this
  module owns everything that is not markup, so the list can sort and
  filter by a column whether or not it is on screen.

  ## Adding a column

    1. One entry in `specs/0` — `id`, `label`, the `family` its value comes
       from (`nil` when the project row is enough) and, when it has an
       order, a `sort` atom.
    2. For a sortable one, a `sort_value/4` clause for that atom.
    3. A `column_cell/3` clause in `ProjectsLive`, and a drop priority in
       `ListUi.column_priority/1` when the default (last to stay) is wrong.

  Extension columns (`Extensions.project_columns/2`, id
  `"ext:<ext_key>:<key>"`) need none of this: they are text with an
  optional link, sorted by the text and filtered by its distinct values.

  ## Sorting

  `:position`, `:name`, `:inserted_at` and `:updated_at` are ordered by the
  database (`sql_sort?/1`), so they page there. Every other sort is over a
  value read for the listed projects, so the list sorts in memory
  (`sort/5`): a project with no value always goes last, whichever
  direction, and ties fall back to the name.
  """

  use Gettext, backend: PhoenixKitProjects.Gettext

  alias PhoenixKitProjects.Health
  alias PhoenixKitProjects.ListMetrics
  alias PhoenixKitProjects.Schemas.Project

  @sql_sorts ~w(position name inserted_at updated_at)a
  @computed_sorts ~w(state progress tasks open_tasks overdue next_due next_event subprojects
                     members owner assignee started eta completed hours billable_hours
                     ai_hours total_hours tokens cost last_activity health created_by
                     external_id key ext)a
  @sort_fields @sql_sorts ++ @computed_sorts

  @states ~w(running ongoing setup scheduled overdue completed)
  @default_columns ~w(key status progress tasks hours updated)

  @type spec :: %{
          id: String.t(),
          label: String.t(),
          family: ListMetrics.family() | nil,
          sort: atom() | nil,
          align: :left | :right
        }

  @doc "Every sort the list accepts (the URL's whitelist)."
  @spec sort_fields() :: [atom()]
  def sort_fields, do: @sort_fields

  @doc "Whether the database orders this sort (and so can page it)."
  @spec sql_sort?(atom()) :: boolean()
  def sql_sort?(sort), do: sort in @sql_sorts

  @doc "The derived states the state filter offers, as the URL spells them."
  @spec states() :: [String.t()]
  def states, do: @states

  @doc "The label of a derived-state filter value."
  @spec state_label(String.t()) :: String.t()
  def state_label("running"), do: gettext("Running")
  def state_label("ongoing"), do: gettext("Ongoing")
  def state_label("setup"), do: gettext("Not started")
  def state_label("scheduled"), do: gettext("Scheduled")
  def state_label("overdue"), do: gettext("Late to start")
  def state_label("completed"), do: gettext("Completed")
  def state_label(other), do: other

  @doc "The native columns shown to a viewer who has not chosen (extension columns join them)."
  @spec default_columns() :: [String.t()]
  def default_columns, do: @default_columns

  @doc "The native optional columns, in the order the picker offers them."
  @spec specs() :: [spec()]
  def specs do
    [
      # The project's short name (`ACME`, `PhoenixKitProjects.Refs`).
      col("key", gettext("Key"), nil, :key),
      col("status", gettext("Status"), nil, :state),
      col("progress", gettext("Progress"), :tasks, :progress),
      col("tasks", gettext("Tasks"), :tasks, :tasks, :right),
      col("open_tasks", gettext("Open tasks"), :tasks, :open_tasks, :right),
      col("overdue", gettext("Overdue tasks"), :due, :overdue, :right),
      col("next_due", gettext("Next due"), :due, :next_due),
      col("next_event", gettext("Next event"), :events, :next_event),
      col("subprojects", gettext("Sub-projects"), :tasks, :subprojects, :right),
      col("members", gettext("Members"), :members, :members, :right),
      col("owner", gettext("Owner"), :members, :owner),
      col("assignee", gettext("Assignee"), :assignee, :assignee),
      col("started", gettext("Started"), nil, :started),
      col("eta", gettext("Planned end"), :tasks, :eta),
      col("completed", gettext("Completed"), nil, :completed),
      # People's time, an agent's own, and the two together: an agent's
      # hours are not people's (the ledger keeps them apart), so each has
      # its column and nothing is hidden inside a sum.
      # Its header is shortened (`header/1`): the full name is as wide as
      # three of the figures under it.
      col("hours", gettext("Human hours"), :ledger, :hours, :right),
      col("ai_hours", gettext("AI hours"), :ledger, :ai_hours, :right),
      col("total_hours", gettext("Total hours"), :ledger, :total_hours, :right),
      col("billable_hours", gettext("Billable hours"), :ledger, :billable_hours, :right),
      col("tokens", gettext("AI tokens"), :ledger, :tokens, :right),
      col("cost", gettext("AI cost"), :ledger, :cost, :right),
      col("last_activity", gettext("Last activity"), :activity, :last_activity),
      col("health", gettext("Health"), nil, :health),
      col("created", gettext("Created"), nil, :inserted_at),
      col("updated", gettext("Last edited"), nil, :updated_at),
      col("created_by", gettext("Created by"), :creators, :created_by),
      col("external_id", gettext("External ID"), nil, :external_id)
    ]
  end

  defp col(id, label, family, sort, align \\ :left),
    do: %{id: id, label: label, family: family, sort: sort, align: align}

  @doc """
  What a column's header cell says: its label, or a shorter form where the
  label would make the column much wider than its values. The picker, the
  sort selector and the header's tooltip keep the full label.
  """
  @spec header(spec()) :: String.t()
  def header(%{id: "hours"}), do: gettext("H. hours")
  def header(%{label: label}), do: label

  @doc "A native column's spec by id, or nil."
  @spec spec(String.t()) :: spec() | nil
  def spec(id), do: Enum.find(specs(), &(&1.id == id))

  @doc "Whether an id names an extension's column."
  @spec ext?(term()) :: boolean()
  def ext?("ext:" <> _), do: true
  def ext?(_), do: false

  @doc "The families the given column ids read (extension columns read `:ext`)."
  @spec families_for([String.t()]) :: [ListMetrics.family()]
  def families_for(column_ids) do
    by_id = Map.new(specs(), &{&1.id, &1.family})

    column_ids
    |> Enum.map(fn id -> if ext?(id), do: :ext, else: Map.get(by_id, id) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @doc "The family a sort reads, or nil when the project row is enough."
  @spec sort_family(atom()) :: ListMetrics.family() | nil
  def sort_family(:ext), do: :ext

  def sort_family(sort) do
    case Enum.find(specs(), &(&1.sort == sort)) do
      %{family: family} -> family
      nil -> nil
    end
  end

  @doc "The sort selector's options: every sortable native column, then the extensions' columns."
  @spec sort_options([map()]) :: [{atom() | String.t(), String.t()}]
  def sort_options(ext_columns) do
    native =
      for %{sort: sort, label: label} <- specs(), sort not in [nil, :inserted_at, :updated_at] do
        {sort, label}
      end

    [
      {:position, gettext("Manual")},
      {:name, gettext("Name")},
      {:inserted_at, gettext("Date created")},
      {:updated_at, gettext("Last edited")}
    ] ++ native ++ Enum.map(ext_columns, &{&1.id, &1.label})
  end

  # ── Sorting ─────────────────────────────────────────────────────

  @doc """
  `projects` ordered by `sort` in `dir`, in memory. `ext_id` names the
  extension column when `sort` is `:ext`.
  """
  @spec sort([Project.t()], atom(), :asc | :desc, ListMetrics.t(), String.t() | nil) ::
          [Project.t()]
  def sort(projects, sort, dir, metrics, ext_id \\ nil) do
    projects
    |> Enum.map(&{sort_value(sort, &1, metrics, ext_id), &1})
    |> Enum.sort(fn {a, pa}, {b, pb} -> before?(a, b, dir, pa, pb) end)
    |> Enum.map(&elem(&1, 1))
  end

  # nil last whichever way; equal values by name, then uuid, so the order
  # is the same on every load.
  defp before?(nil, nil, _dir, pa, pb), do: tiebreak(pa, pb)
  defp before?(nil, _b, _dir, _pa, _pb), do: false
  defp before?(_a, nil, _dir, _pa, _pb), do: true

  defp before?(a, b, dir, pa, pb) do
    case {compare(a, b), dir} do
      {:eq, _} -> tiebreak(pa, pb)
      {:lt, :asc} -> true
      {:gt, :desc} -> true
      _ -> false
    end
  end

  defp tiebreak(pa, pb),
    do: {String.downcase(pa.name || ""), pa.uuid} <= {String.downcase(pb.name || ""), pb.uuid}

  defp compare(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b)
  defp compare(%NaiveDateTime{} = a, %NaiveDateTime{} = b), do: NaiveDateTime.compare(a, b)
  defp compare(%Date{} = a, %Date{} = b), do: Date.compare(a, b)

  defp compare(a, b) do
    cond do
      a < b -> :lt
      a > b -> :gt
      true -> :eq
    end
  end

  @state_rank %{
    running: 0,
    ongoing: 0,
    overdue: 1,
    scheduled: 2,
    setup: 3,
    completed: 4,
    archived: 5
  }
  @health_rank Health.statuses() |> Enum.with_index() |> Map.new()

  @doc """
  What a project sorts by under `sort`; `nil` means "no value" and goes
  last. Text is lowercased so the order ignores case.
  """
  @spec sort_value(atom(), Project.t(), ListMetrics.t(), String.t() | nil) :: term()
  def sort_value(:position, p, _m, _ext), do: p.position
  def sort_value(:name, p, _m, _ext), do: text(p.name)
  def sort_value(:inserted_at, p, _m, _ext), do: p.inserted_at
  def sort_value(:updated_at, p, _m, _ext), do: p.updated_at
  def sort_value(:state, p, _m, _ext), do: Map.get(@state_rank, Project.derived_status(p), 9)
  def sort_value(:started, p, _m, _ext), do: p.started_at
  def sort_value(:completed, p, _m, _ext), do: p.completed_at
  def sort_value(:external_id, p, _m, _ext), do: text(p.external_id)
  def sort_value(:key, p, _m, _ext), do: text(p.key)

  def sort_value(:health, p, _m, _ext) do
    case Health.get(p) do
      %{"status" => status} -> Map.get(@health_rank, status)
      _ -> nil
    end
  end

  # A project with no tasks and no sub-projects has no progress to order by.
  def sort_value(:progress, p, m, _ext) do
    case get(m, :tasks, p) do
      %{has_work: true, progress_pct: pct} -> pct
      _ -> nil
    end
  end

  def sort_value(:tasks, p, m, _ext), do: field(m, :tasks, p, :total)
  def sort_value(:open_tasks, p, m, _ext), do: field(m, :tasks, p, :open)
  def sort_value(:subprojects, p, m, _ext), do: field(m, :tasks, p, :subprojects)
  def sort_value(:eta, p, m, _ext), do: field(m, :tasks, p, :planned_end)
  def sort_value(:overdue, p, m, _ext), do: field(m, :due, p, :overdue) || 0
  def sort_value(:next_due, p, m, _ext), do: field(m, :due, p, :next_due)
  def sort_value(:next_event, p, m, _ext), do: get(m, :events, p)
  def sort_value(:members, p, m, _ext), do: field(m, :members, p, :count) || 0
  def sort_value(:owner, p, m, _ext), do: p |> owners(m) |> List.first() |> text()
  def sort_value(:assignee, p, m, _ext), do: m |> field(:assignee, p, :label) |> text()
  def sort_value(:hours, p, m, _ext), do: field(m, :ledger, p, :minutes) || 0.0
  def sort_value(:ai_hours, p, m, _ext), do: field(m, :ledger, p, :ai_minutes) || 0.0
  def sort_value(:total_hours, p, m, _ext), do: total_minutes(m, p)
  def sort_value(:billable_hours, p, m, _ext), do: field(m, :ledger, p, :billable_minutes) || 0.0
  def sort_value(:tokens, p, m, _ext), do: field(m, :ledger, p, :tokens) || 0.0
  def sort_value(:cost, p, m, _ext), do: field(m, :ledger, p, :cost_cents) || 0.0
  def sort_value(:last_activity, p, m, _ext), do: get(m, :activity, p) || p.updated_at
  def sort_value(:created_by, p, m, _ext), do: m |> get(:creators, p) |> text()
  def sort_value(:ext, p, m, ext_id), do: m |> ext_value(ext_id, p) |> ext_text() |> text()
  def sort_value(_unknown, p, _m, _ext), do: p.position

  # ── Values ──────────────────────────────────────────────────────

  @doc "A family's value for a project, or nil."
  @spec get(ListMetrics.t(), ListMetrics.family(), Project.t()) :: term()
  def get(metrics, family, %Project{uuid: uuid}) do
    case Map.get(metrics, family) do
      %{} = by_project -> Map.get(by_project, uuid)
      _ -> nil
    end
  end

  @doc "One key of a family's value for a project, or nil."
  @spec field(ListMetrics.t(), ListMetrics.family(), Project.t(), atom()) :: term()
  def field(metrics, family, project, key) do
    case get(metrics, family, project) do
      %{} = value -> Map.get(value, key)
      _ -> nil
    end
  end

  @doc "People's time and an agent's together, in minutes."
  @spec total_minutes(ListMetrics.t(), Project.t()) :: float()
  def total_minutes(metrics, project) do
    (field(metrics, :ledger, project, :minutes) || 0.0) +
      (field(metrics, :ledger, project, :ai_minutes) || 0.0)
  end

  @doc "The names of a project's owners, oldest membership first."
  @spec owners(Project.t(), ListMetrics.t()) :: [String.t()]
  def owners(project, metrics) do
    for %{role: "owner", name: name} <- field(metrics, :members, project, :people) || [],
        do: name
  end

  @doc "An extension column by id, from the loaded `:ext` family."
  @spec ext_column(ListMetrics.t(), String.t() | nil) :: map() | nil
  def ext_column(metrics, id) do
    metrics |> Map.get(:ext, []) |> Enum.find(&(&1.id == id))
  end

  @doc "An extension column's value for a project: `%{text, url}` or nil."
  @spec ext_value(ListMetrics.t(), String.t() | nil, Project.t()) :: map() | nil
  def ext_value(metrics, id, %Project{uuid: uuid}) do
    case ext_column(metrics, id) do
      %{values: values} -> Map.get(values, uuid)
      nil -> nil
    end
  end

  defp ext_text(%{text: text}), do: text
  defp ext_text(_), do: nil

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> String.downcase(trimmed)
    end
  end

  defp text(_), do: nil

  # ── Filters ─────────────────────────────────────────────────────

  @typedoc """
  The list's filters beyond search and the workflow status: `state` (a
  derived state or `""` — "ongoing" is one of them, the only place ongoing
  work is filtered), `who` (`""`, `"mine"` or a user uuid), `overdue`
  (only projects with overdue tasks), and one extension column's value
  (`ext_col` + `ext_val`).
  """
  @type filters :: %{
          state: String.t(),
          who: String.t(),
          overdue: boolean(),
          ext_col: String.t(),
          ext_val: String.t()
        }

  @doc "How many of the filters are set."
  @spec active_count(filters()) :: non_neg_integer()
  def active_count(filters) do
    Enum.count(
      [
        filters.state != "",
        filters.who != "",
        filters.overdue,
        ext_filter?(filters)
      ],
      & &1
    )
  end

  @doc "Whether an extension column's value is being filtered on."
  @spec ext_filter?(filters()) :: boolean()
  def ext_filter?(filters), do: filters.ext_col != "" and filters.ext_val != ""

  @doc "The families the set filters read."
  @spec filter_families(filters()) :: [ListMetrics.family()]
  def filter_families(filters) do
    [
      filters.who != "" && :members,
      filters.overdue && :due,
      ext_filter?(filters) && :ext
    ]
    |> Enum.filter(& &1)
  end

  @doc """
  The projects that pass every set filter. `viewer_uuid` is who `"mine"`
  means; with nobody signed in it matches nothing.
  """
  @spec filter([Project.t()], filters(), ListMetrics.t(), String.t() | nil) :: [Project.t()]
  def filter(projects, filters, metrics, viewer_uuid) do
    Enum.filter(projects, fn p ->
      state?(p, filters.state) and
        who?(p, filters.who, metrics, viewer_uuid) and
        overdue?(p, filters.overdue, metrics) and ext?(p, filters, metrics)
    end)
  end

  defp state?(_p, ""), do: true
  defp state?(p, state), do: Atom.to_string(Project.derived_status(p)) == state

  defp who?(_p, "", _metrics, _viewer), do: true
  defp who?(_p, "mine", _metrics, nil), do: false
  defp who?(p, "mine", metrics, viewer), do: who?(p, viewer, metrics, viewer)

  defp who?(p, user_uuid, metrics, _viewer) do
    Enum.any?(field(metrics, :members, p, :people) || [], &(&1.uuid == user_uuid))
  end

  defp overdue?(_p, false, _metrics), do: true
  defp overdue?(p, true, metrics), do: (field(metrics, :due, p, :overdue) || 0) > 0

  defp ext?(p, filters, metrics) do
    if ext_filter?(filters) do
      case ext_value(metrics, filters.ext_col, p) do
        %{text: text} -> text == filters.ext_val
        _ -> false
      end
    else
      true
    end
  end

  @doc "The people on any of the listed projects, by name — the person filter's options."
  @spec people_options(ListMetrics.t()) :: [{String.t(), String.t()}]
  def people_options(metrics) do
    metrics
    |> Map.get(:members, %{})
    |> Enum.flat_map(fn {_uuid, %{people: people}} -> people end)
    |> Enum.uniq_by(& &1.uuid)
    |> Enum.sort_by(&String.downcase(&1.name || ""))
    |> Enum.map(&{&1.name, &1.uuid})
  end

  @doc "An extension column's distinct values among the listed projects, in order."
  @spec ext_options(map()) :: [String.t()]
  def ext_options(%{values: values}) do
    values
    |> Map.values()
    |> Enum.map(& &1.text)
    |> Enum.uniq()
    |> Enum.sort_by(&String.downcase/1)
  end
end
