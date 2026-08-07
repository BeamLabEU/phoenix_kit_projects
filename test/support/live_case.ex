defmodule PhoenixKitProjects.LiveCase do
  @moduledoc """
  Test case for LiveView tests. Wires up the test Endpoint, imports
  `Phoenix.LiveViewTest` helpers, and sets up an Ecto SQL sandbox
  connection.

  Tests using this case are tagged `:integration` automatically and
  get excluded when the test DB isn't available.

  ## Example

      defmodule PhoenixKitProjects.Web.TaskFormLiveTest do
        use PhoenixKitProjects.LiveCase

        test "renders", %{conn: conn} do
          {:ok, _view, html} = live(conn, "/en/admin/projects/tasks/new")
          assert html =~ "New task"
        end
      end
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :integration
      @endpoint PhoenixKitProjects.Test.Endpoint

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import PhoenixKitProjects.ActivityLogAssertions

      import PhoenixKitProjects.DataCase,
        only: [
          fixture_task: 0,
          fixture_task: 1,
          fixture_project: 0,
          fixture_project: 1,
          fixture_template: 0,
          fixture_template: 1,
          errors_on: 1
        ]

      import PhoenixKitProjects.LiveCase
    end
  end

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitProjects.Test.Repo, as: TestRepo

  setup tags do
    pid = Sandbox.start_owner!(TestRepo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{})

    {:ok, conn: conn}
  end

  @doc """
  Returns a real `PhoenixKit.Users.Auth.Scope` struct for testing.

  Projects LVs read `socket.assigns[:phoenix_kit_current_user]` (via
  `Activity.actor_uuid/1`) to thread the user UUID into activity
  logging. They don't call `Scope.admin?/1` themselves — production
  `live_session :phoenix_kit_admin` gates that — but per workspace
  AGENTS.md `cached_roles` must be a list if `admin?/1` ever fires.

  ## Options

    * `:user_uuid` — defaults to a fresh UUIDv4
    * `:email` — defaults to a unique-suffix string
    * `:roles` — list of role-name strings; defaults to `["Owner"]`
    * `:permissions` — list of module-key strings; defaults to `["projects"]`
    * `:authenticated?` — defaults to `true`
  """
  def fake_scope(opts \\ []) do
    user_uuid = Keyword.get(opts, :user_uuid, Ecto.UUID.generate())
    email = Keyword.get(opts, :email, "test-#{System.unique_integer([:positive])}@example.com")
    roles = Keyword.get(opts, :roles, ["Owner"])
    # The default fixture is a SITE ADMIN: it holds the module key AND the
    # `projects.admin_all` sub-key, which is what "may administer projects
    # I'm not a member of" now requires. Pass `permissions: ["projects"]` to
    # build a plain module-reacher instead — the contractor shape.
    permissions = Keyword.get(opts, :permissions, ["projects", "projects.admin_all"])
    authenticated? = Keyword.get(opts, :authenticated?, true)

    user = %{uuid: user_uuid, email: email}

    %PhoenixKit.Users.Auth.Scope{
      user: user,
      authenticated?: authenticated?,
      cached_roles: roles,
      cached_permissions: MapSet.new(permissions)
    }
  end

  @doc """
  Plugs a fake scope into the test conn's session so the
  `:assign_scope` `on_mount` hook can put it on socket assigns at
  mount time. Pair with `fake_scope/1`.
  """
  def put_test_scope(conn, scope) do
    Plug.Test.init_test_session(conn, %{"phoenix_kit_test_scope" => scope})
  end
end
