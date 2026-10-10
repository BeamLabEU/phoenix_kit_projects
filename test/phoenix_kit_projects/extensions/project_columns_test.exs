defmodule PhoenixKitProjects.Extensions.ProjectColumnsTest do
  @moduledoc """
  An extension's columns on the projects list (the `project_columns:` of
  an extension declaration — the CRM's Client): asked once for the whole
  page, kept only where the extension is on, and never able to take the
  list down.
  """

  use PhoenixKitProjects.DataCase, async: false

  alias PhoenixKitProjects.{Extensions, QueryCounter}
  alias PhoenixKitProjects.Extensions.Registry

  defmodule Provider do
    @moduledoc false
    def phoenix_kit_project_extensions do
      [
        %{key: "clients", name: "Clients", project_columns: {__MODULE__, :columns}},
        %{
          key: "sites",
          name: "Sites",
          default_enabled: true,
          project_columns: {__MODULE__, :sites}
        },
        %{
          key: "broken",
          name: "Broken",
          default_enabled: true,
          project_columns: {__MODULE__, :boom}
        },
        %{key: "odd", name: "Odd", default_enabled: true, project_columns: {__MODULE__, :odd}},
        %{key: "bad", name: "Bad", project_columns: "not a callback"}
      ]
    end

    def columns(uuids) do
      send(:persistent_term.get({__MODULE__, :pid}), {:asked, uuids})

      [
        %{
          key: "client",
          label: "Client",
          values: Map.new(uuids, &{&1, %{text: "Client of #{&1}", url: "/crm/#{&1}"}})
        }
      ]
    end

    def sites(uuids),
      do: [%{key: "site", label: "Site", values: Map.new(uuids, &{&1, %{text: "Tartu"}})}]

    def boom(_uuids), do: raise("boom")
    # not a list of columns; a column with no label; a value with no text
    def odd(uuids),
      do: [%{key: "x"}, %{key: "y", label: "Y", values: Map.new(uuids, &{&1, %{url: "/"}})}]
  end

  setup do
    :persistent_term.put({Provider, :pid}, self())
    Application.put_env(:phoenix_kit_projects, :extension_providers, [Provider])
    Registry.refresh()

    on_exit(fn ->
      Application.delete_env(:phoenix_kit_projects, :extension_providers)
      Registry.refresh()
    end)

    :ok
  end

  defp column(columns, id), do: Enum.find(columns, &(&1.id == id))

  test "a malformed callback is dropped from the declaration" do
    assert Enum.find(Extensions.list_types(), &(&1.key == "bad")).project_columns == nil

    assert {Provider, :columns} =
             Enum.find(Extensions.list_types(), &(&1.key == "clients")).project_columns
  end

  test "with no projects it is the columns alone, for the picker" do
    columns = Extensions.project_columns([])

    assert %{label: "Client", ext_key: "clients", key: "client", values: %{}} =
             column(columns, "ext:clients:client")

    assert %{values: %{}} = column(columns, "ext:sites:site")
  end

  test "values come back only for the projects the extension is on for" do
    on = fixture_project()
    off = fixture_project()
    {:ok, _} = Extensions.enable(on, "clients")
    {:ok, _} = Extensions.disable(off, "sites")

    columns = Extensions.project_columns([on.uuid, off.uuid])

    # one call for the whole page
    assert_received {:asked, uuids}
    assert Enum.sort(uuids) == Enum.sort([on.uuid, off.uuid])
    refute_received {:asked, _}

    client = column(columns, "ext:clients:client")
    assert client.values == %{on.uuid => %{text: "Client of #{on.uuid}", url: "/crm/#{on.uuid}"}}

    # default-enabled: on with no row, off where it was switched off
    site = column(columns, "ext:sites:site")
    assert site.values == %{on.uuid => %{text: "Tartu", url: nil}}
  end

  test "a provider that raises or answers nonsense contributes nothing" do
    project = fixture_project()
    ids = [project.uuid] |> Extensions.project_columns() |> Enum.map(& &1.id)

    assert "ext:sites:site" in ids
    refute Enum.any?(ids, &String.starts_with?(&1, "ext:broken"))
    # the column with a label survives, its text-less values do not
    assert column(Extensions.project_columns([project.uuid]), "ext:odd:y").values == %{}
    refute "ext:odd:x" in ids
  end

  test "the enablement read does not grow with the number of projects" do
    one = [fixture_project().uuid]
    many = Enum.map(1..5, fn _ -> fixture_project().uuid end)

    {_, q_one} = QueryCounter.count(fn -> Extensions.project_columns(one) end)
    {_, q_many} = QueryCounter.count(fn -> Extensions.project_columns(many) end)
    assert q_one == q_many
    assert q_one == 1
  end
end
