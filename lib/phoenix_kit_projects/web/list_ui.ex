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

  The tables follow the catalogue's shape: every column but the name is
  sized to its content (`column_fit_class/1`) and packed against the
  right edge, so a Status column never floats alone in the middle; the
  name column is marked `data-col-lead` and takes the slack. Core's
  column fitting (`<.table_default fit>`, which also drops the least
  important columns when the table is wider than its wrapper, reading
  `data-col-priority` off the header cells) is passed as a DYNAMIC
  attribute (`table_fit/0`), so a core without it ignores the attrs and
  the table scrolls sideways as it always did — the core floor does not
  move for it.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitProjects.Gettext

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.TableDefault, only: [table_default_header_cell: 1]

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
  `<.table_default>`'s column fitting, as a DYNAMIC attribute so the core
  floor stays put (see the moduledoc). `fit_pack: false` because these
  tables size their own columns (`column_fit_class/1`), like the
  catalogue's.
  """
  @spec table_fit() :: map()
  def table_fit, do: %{fit: true, fit_pack: false}

  @doc """
  The header-cell class that sizes an optional column to its content, so
  the name column takes the slack and the rest pack right.
  """
  @spec column_fit_class(String.t()) :: String.t()
  def column_fit_class(_id), do: "w-px whitespace-nowrap"

  @doc """
  How soon a column is dropped when the table does not fit its width —
  core's `fit` reads it off the header cell as `data-col-priority`. The
  highest number goes first, `1` last; what a row IS (its status) outlasts
  what it has (counts, a duration), which outlasts when (dates), which
  outlasts who and the external id. Name and Actions carry none and never
  go.
  """
  @spec column_priority(String.t()) :: pos_integer()
  def column_priority("status"), do: 1
  def column_priority(id) when id in ~w(tasks uses duration), do: 2
  def column_priority(id) when id in ~w(updated last_used), do: 3
  def column_priority("created"), do: 4
  def column_priority(id) when id in ~w(created_by weekends), do: 5
  def column_priority(_id), do: 6

  @doc """
  The attributes an optional column's header cell takes: its fit class
  (plus `extra`, e.g. `text-right` for a count) and its drop priority.
  """
  @spec column_attrs(String.t(), String.t() | nil) :: map()
  def column_attrs(id, extra \\ nil) do
    %{class: [column_fit_class(id), extra], "data-col-priority": column_priority(id)}
  end

  @doc """
  The ⋮ menu column's header. No visible label: the column is only as wide
  as its button, and the word stays for screen readers (the catalogue's
  shape, boss 2026-09-19).
  """
  def actions_header_cell(assigns) do
    ~H"""
    <.table_default_header_cell class="w-px">
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
