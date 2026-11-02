defmodule PhoenixKitProjects.Web.ListUi do
  @moduledoc """
  Shared plumbing for the admin list pages (Projects / Tasks /
  Templates): the column picker's spec and the table's column fitting,
  plus search-param coercion and the client-search haystack builder.

  Each list page keeps its own column roster and ViewPrefs key; these
  helpers only own the mechanics so the three pages can't drift apart.

  ## Columns

  Which optional columns a list shows, and in what order, is each
  viewer's own choice, kept by core's `PhoenixKitWeb.TableColumns` (the
  `"columns"` field of their `PhoenixKit.Users.ViewPrefs` for the page's
  key) and edited through core's live `column_settings_modal/1`. Name and
  Actions always render and are not the picker's to remove. Before
  this change the choice was one comma-joined settings row per page
  (`projects_list_columns` / `projects_tasks_columns` /
  `projects_templates_columns`), shared by everyone on the site; those
  rows are no longer read.

  ## Fitting

  The tables use core's column fitting as it is (`<.table_default fit>`,
  core >= 2.54): the name column is the `lead` one — it stays on the left
  and takes the slack — every other column is sized to its content and
  packed against the right edge, and when the table is wider than its
  wrapper the least important columns go first, the last one left saying
  "+N". A column's importance is its header cell's `priority`
  (`column_priority/1`, through `column_attrs/2`); the checkbox and the
  actions carry none and never go.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitProjects.Gettext

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.TableDefault, only: [table_default_header_cell: 1]

  alias PhoenixKitProjects.L10n
  alias PhoenixKitWeb.{Actor, TableColumns}

  @doc """
  Core's `TableColumns` spec for a list page: the ViewPrefs `key`, the
  optional columns as the page lists them (`{id, translated_label}`) and
  the ids shown to a viewer who has not chosen.
  """
  @spec columns_spec(String.t(), [{String.t(), String.t()}], [String.t()]) ::
          TableColumns.spec()
  def columns_spec(key, options, defaults) do
    %{
      key: key,
      columns: Enum.map(options, fn {id, label} -> %{id: id, label: label} end),
      defaults: defaults
    }
  end

  @doc """
  The columns the viewer sees for `spec`: their own choice, else the
  defaults. Call it AFTER the embed user is assigned, so an embedded list
  reads the viewer's choice too (with nobody signed in, a change lasts for
  the page).
  """
  @spec load_columns(Phoenix.LiveView.Socket.t(), TableColumns.spec()) :: [String.t()]
  def load_columns(socket, spec), do: TableColumns.load(Actor.uuid(socket), spec)

  @doc """
  How soon a column is dropped when the table does not fit its width —
  the header cell's `priority` in core's `fit`. The
  highest number goes first, `1` last; what a row IS (its status) outlasts
  what it has (counts, a duration), which outlasts when (dates), which
  outlasts who and the external id. Name and Actions carry none and never
  go.
  """
  @spec column_priority(String.t()) :: pos_integer()
  def column_priority("status"), do: 1
  def column_priority("key"), do: 2
  # An extension's column (the client) says whose the project is: it goes
  # just after what the project is.
  def column_priority("ext:" <> _), do: 2
  def column_priority(id) when id in ~w(tasks uses duration progress overdue), do: 2
  def column_priority(id) when id in ~w(updated last_used hours open_tasks next_due), do: 3

  def column_priority(id)
      when id in ~w(created eta started completed last_activity next_event billable_hours ai_hours
                    total_hours),
      do: 4

  def column_priority(id)
      when id in ~w(created_by weekends owner assignee members subprojects health),
      do: 5

  def column_priority(_id), do: 6

  @doc """
  The attributes an optional column's header cell takes: core's drop
  `priority`, plus `extra` as its class (e.g. `text-right` for a count).
  """
  @spec column_attrs(String.t(), String.t() | nil | false) :: map()
  def column_attrs(id, extra \\ nil) do
    %{priority: column_priority(id), class: extra || ""}
  end

  @doc """
  The ⋮ menu column's header. No visible label: the column is only as wide
  as its button, and the word stays for screen readers (the catalogue's
  shape, boss 2026-09-19).
  """
  def actions_header_cell(assigns) do
    ~H"""
    <.table_default_header_cell>
      <span class="sr-only">{gettext("Actions")}</span>
    </.table_default_header_cell>
    """
  end

  @doc """
  The toolbar's Columns button: opens core's `column_settings_modal/1`
  (`open_column_modal`), which the page renders and whose edits
  `TableColumns.handle_event/5` answers.
  """
  def columns_button(assigns) do
    ~H"""
    <button type="button" class="btn btn-sm" phx-click="open_column_modal">
      <.icon name="hero-view-columns" class="w-4 h-4" /> {gettext("Columns")}
    </button>
    """
  end

  @doc ~S|Minutes as "2h 30m" — the wording the project page uses for logged time.|
  @spec format_minutes(number()) :: String.t()
  def format_minutes(minutes) do
    m = round(minutes)
    h = div(m, 60)
    rest = rem(m, 60)

    cond do
      h == 0 -> gettext("%{m}m", m: rest)
      rest == 0 -> gettext("%{h}h", h: h)
      true -> gettext("%{h}h %{m}m", h: h, m: rest)
    end
  end

  @doc ~S|A token count as "3.9M tokens" / "13.3k tokens".|
  @spec format_tokens(number()) :: String.t()
  def format_tokens(t) when t >= 1_000_000,
    do: gettext("%{n}M tokens", n: L10n.format_decimal(t / 1_000_000, trim: false))

  def format_tokens(t) when t >= 1_000,
    do: gettext("%{n}k tokens", n: L10n.format_decimal(t / 1_000, trim: false))

  def format_tokens(t), do: gettext("%{n} tokens", n: round(t))

  @doc """
  Cents as a dollar string. The ledger stores cents unit-agnostically; the
  display currency is the same v1 simplification the project page makes.
  """
  @spec format_cents(number()) :: String.t()
  def format_cents(cents), do: "$" <> L10n.format_decimal(cents / 100, decimals: 2, trim: false)

  @doc """
  Coerces the search event payload to a binary. A forged `search[x]=y`
  body arrives as a map — the query side would shrug it off, but
  rendering a map back into the input's `value` would crash the LV.
  """
  @spec coerce_search(map()) :: String.t()
  def coerce_search(params) do
    case params["search"] do
      s when is_binary(s) -> s
      _ -> ""
    end
  end

  @doc """
  Lowercased match target for the TableLocalSearch hook: the record's
  primary `fields` plus every language's translated values for the same
  fields — the same coverage as the server-side ilike search, so the
  instant client filter and the authoritative server result agree.

  `fields` are the translation-map keys (strings); each must also name
  a schema field (e.g. `["name", "description"]`, `["title", "description"]`).
  """
  @spec search_haystack(struct(), [String.t()]) :: String.t()
  def search_haystack(record, fields) do
    translated =
      for {_lang, tr_fields} <- record.translations || %{},
          is_map(tr_fields),
          key <- fields,
          val = tr_fields[key],
          is_binary(val),
          do: val

    primary = Enum.map(fields, &Map.get(record, String.to_existing_atom(&1)))

    (primary ++ translated)
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" ")
    |> String.downcase()
  end
end
