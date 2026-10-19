defmodule PhoenixKitProjects.Web.ApiKeysFilters do
  @moduledoc """
  The Keys page's filters (Max, 2026-10-19: "some kind of filter by
  status… only really show them if there's like more than 5 different API
  keys, and only show the relevant filters").

    * The bar shows only above `threshold/0` keys; at or below it every
      key is listed, the revoked and expired ones last.
    * Each filter shows only when it can tell keys apart — status when the
      keys are in two or more states, kind when there are personal and
      shared keys, person (administrators) when keys act for two or more
      people, project when they reach two or more projects — and offers
      only the values present.
    * Status starts at Active when the bar shows, so revoked keys are out
      of the way unless asked for. Every filter lives in the address.

  Pure: `ApiKeysLive` hands over its rows (`%{key, grants, …}`) and gets
  back the options to draw and the rows to show.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitProjects.Gettext

  import PhoenixKitWeb.Components.Core.Select, only: [select: 1]
  import PhoenixKitWeb.Components.Core.TableDefault, only: [search_toolbar: 1]

  alias PhoenixKitProjects.Schemas.ApiKey

  @threshold 5
  @fields ~w(status kind person project q)

  @doc "Above this many keys the filters show."
  def threshold, do: @threshold

  @doc "The filter params the page reads from the address."
  def fields, do: @fields

  @doc "A key's state: `:active`, `:expired` or `:revoked`."
  @spec status(ApiKey.t(), DateTime.t()) :: :active | :expired | :revoked
  def status(%ApiKey{revoked_at: %DateTime{}}, _now), do: :revoked

  def status(%ApiKey{} = key, now),
    do: if(ApiKey.active?(key, now), do: :active, else: :expired)

  @doc """
  The filters from the address, cleaned: unknown fields dropped, blanks
  dropped, and status Active when the bar shows and nothing was chosen.
  """
  @spec from_params(map(), [map()]) :: map()
  def from_params(params, rows) do
    chosen =
      params
      |> Map.take(@fields)
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
      |> Map.new()

    if shown?(rows) and not Map.has_key?(chosen, "status") and
         Enum.any?(rows, &(status(&1.key, DateTime.utc_now()) == :active)),
       do: Map.put(chosen, "status", "active"),
       else: chosen
  end

  @doc "Whether the bar shows at all."
  def shown?(rows), do: length(rows) > @threshold

  @doc """
  The filters worth showing for these rows: `%{status: [...], kind: [...],
  person: [...], project: [...]}`, each a list of `{label, value}` with two
  or more entries, or absent.
  """
  @spec options([map()], keyword()) :: map()
  def options(rows, opts) do
    now = DateTime.utc_now()
    names = Keyword.get(opts, :names, %{})
    projects = Keyword.get(opts, :projects, %{})
    admin? = Keyword.get(opts, :admin?, false)

    statuses =
      rows |> Enum.map(&status(&1.key, now)) |> Enum.uniq() |> Enum.sort_by(&status_rank/1)

    kinds = rows |> Enum.map(&kind(&1.key)) |> Enum.uniq() |> Enum.sort()
    people = rows |> Enum.map(& &1.key.user_uuid) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    project_uuids =
      rows |> Enum.flat_map(fn r -> Enum.map(r.grants, & &1.project_uuid) end) |> Enum.uniq()

    %{}
    |> put_if(
      length(statuses) > 1,
      :status,
      Enum.map(statuses, &{status_label(&1), Atom.to_string(&1)})
    )
    |> put_if(length(kinds) > 1, :kind, Enum.map(kinds, &{kind_label(&1), &1}))
    |> put_if(
      admin? and length(people) > 1,
      :person,
      people |> Enum.map(&{Map.get(names, &1, "—"), &1}) |> Enum.sort()
    )
    |> put_if(
      length(project_uuids) > 1,
      :project,
      project_uuids |> Enum.map(&{project_name(projects, &1), &1}) |> Enum.sort()
    )
  end

  @doc "The rows these filters let through; revoked and expired last."
  @spec apply([map()], map()) :: [map()]
  def apply(rows, filters) do
    now = DateTime.utc_now()
    q = filters |> Map.get("q", "") |> String.downcase() |> String.trim()

    rows
    |> Enum.filter(fn %{key: key, grants: grants} ->
      passes?(filters["status"], fn s -> s == "all" or Atom.to_string(status(key, now)) == s end) and
        passes?(filters["kind"], &(kind(key) == &1)) and
        passes?(filters["person"], &(key.user_uuid == &1)) and
        passes?(filters["project"], fn p -> Enum.any?(grants, &(&1.project_uuid == p)) end) and
        (q == "" or String.contains?(String.downcase(key.name || ""), q))
    end)
    |> Enum.sort_by(&status_rank(status(&1.key, now)))
  end

  # A filter not set lets everything through.
  defp passes?(nil, _fun), do: true
  defp passes?(value, fun), do: fun.(value)

  defp put_if(map, true, k, v), do: Map.put(map, k, v)
  defp put_if(map, false, _k, _v), do: map

  defp kind(%ApiKey{user_uuid: nil}), do: "shared"
  defp kind(%ApiKey{}), do: "personal"

  defp status_rank(:active), do: 0
  defp status_rank(:expired), do: 1
  defp status_rank(:revoked), do: 2

  defp status_label(:active), do: gettext("Active")
  defp status_label(:expired), do: gettext("Expired")
  defp status_label(:revoked), do: gettext("Revoked")

  defp kind_label("personal"), do: gettext("Personal")
  defp kind_label("shared"), do: gettext("Shared")

  defp project_name(projects, uuid) do
    case Map.get(projects, uuid) do
      %{name: name} -> name
      _ -> "—"
    end
  end

  attr(:options, :map, required: true)
  attr(:filters, :map, required: true)
  attr(:shown, :integer, required: true)
  attr(:total, :integer, required: true)

  @doc "The bar: search, then each filter worth showing, then the count."
  def filter_bar(assigns) do
    ~H"""
    <div id="api-key-filters" class="flex flex-wrap items-center gap-2">
      <.search_toolbar
        id="api-key-search"
        value={@filters["q"] || ""}
        name="q"
        on_change="key_search"
        placeholder={gettext("Search keys...")}
        class="w-48"
      />
      <form id="api-key-filter-form" phx-change="key_filter" class="flex flex-wrap items-center gap-2">
        <.select
          :if={@options[:status]}
          name="status"
          class="select-sm"
          value={@filters["status"] || "all"}
          options={[{gettext("Any status"), "all"} | @options[:status]]}
        />
        <.select
          :if={@options[:kind]}
          name="kind"
          class="select-sm"
          value={@filters["kind"] || ""}
          prompt={gettext("Personal and shared")}
          options={@options[:kind]}
        />
        <.select
          :if={@options[:person]}
          name="person"
          class="select-sm"
          value={@filters["person"] || ""}
          prompt={gettext("Anyone's")}
          options={@options[:person]}
        />
        <.select
          :if={@options[:project]}
          name="project"
          class="select-sm"
          value={@filters["project"] || ""}
          prompt={gettext("Any project")}
          options={@options[:project]}
        />
      </form>
      <span class="text-xs text-base-content/60 ml-auto tabular-nums">
        {gettext("%{shown} of %{total} keys", shown: @shown, total: @total)}
      </span>
    </div>
    """
  end
end
