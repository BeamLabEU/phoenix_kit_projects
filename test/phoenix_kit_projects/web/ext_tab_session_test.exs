defmodule PhoenixKitProjects.Web.ExtTabSessionTest do
  @moduledoc """
  The session a contributed extension tab is mounted with is exactly the
  one `PhoenixKitProjects.Extensions.Extension`'s moduledoc lists — the one
  place the contract is written down (AGENTS.md points there).
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKitProjects.Extensions.Registry

  defmodule ProbeLive do
    @moduledoc false
    use Phoenix.LiveView

    @impl true
    def mount(:not_mounted_at_router, session, socket) do
      send(:persistent_term.get({__MODULE__, :pid}), {:ext_session, session})
      {:ok, socket}
    end

    @impl true
    def render(assigns), do: ~H"<div>probe</div>"
  end

  defmodule Provider do
    @moduledoc false
    def phoenix_kit_project_extensions do
      [
        %{
          key: "probe",
          name: "Probe",
          default_enabled: true,
          tabs: [%{key: "probe", label: "Probe", lv: ProbeLive}]
        }
      ]
    end
  end

  setup %{conn: conn} do
    :persistent_term.put({ProbeLive, :pid}, self())
    Application.put_env(:phoenix_kit_projects, :extension_providers, [Provider])
    Registry.refresh()

    on_exit(fn ->
      Application.delete_env(:phoenix_kit_projects, :extension_providers)
      Registry.refresh()
    end)

    {:ok, conn: put_test_scope(conn, fake_scope()), project: fixture_project()}
  end

  defp documented_keys do
    {:docs_v1, _, _, _, %{"en" => doc}, _, _} =
      Code.fetch_docs(PhoenixKitProjects.Extensions.Extension)

    [_, section] = String.split(doc, "with this session:", parts: 2)
    [section | _] = String.split(section, "A tab may name", parts: 2)

    ~r/^\s*\* (.+?) — /m
    |> Regex.scan(section, capture: :all_but_first)
    |> Enum.flat_map(fn [names] ->
      Regex.scan(~r/`"([a-z_]+)"`/, names, capture: :all_but_first)
    end)
    |> List.flatten()
    |> Enum.sort()
  end

  test "the tab gets every documented key and no other", ctx do
    {:ok, view, _html} = live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}")
    render_click(view, "switch_tab", %{"tab" => "ext:probe:probe"})

    assert_receive {:ext_session, session}
    assert documented_keys() != []
    # The connection's own session (CSRF token, the test scope) is merged
    # in by LiveView; the hub's keys are the rest.
    hub_keys = session |> Map.drop(["_csrf_token", "phoenix_kit_test_scope"]) |> Map.keys()
    assert Enum.sort(hub_keys) == documented_keys()
  end
end
