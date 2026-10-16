defmodule PhoenixKitProjects.Web.ApiKeysLive do
  @moduledoc """
  Projects → API keys (chain V24): every key a person has, and what each
  may do in each project (Max, 2026-10-15: "some kind of configuration
  thing outside of projects, where then we can set up permissions and what
  they can see and do per project").

  A key acts for a person by default (it can never do more than that
  person could; administrators may also make shared keys for a runner
  with no person behind it). Its access is a list of projects, each with a
  grid of areas set to none / read / write (`PhoenixKitProjects.ApiAccess`)
  — presets fill the grid in one click — and whether it covers that
  project's sub-projects. One project is the key's HOME: where an API call
  without `project` acts.

  Everyone sees and edits their own keys; administrators (`admin_all`)
  can switch to everyone's. A project's own pages only show the keys that
  reach it and link here.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitProjects.Gettext
  use PhoenixKitProjects.Web.Components

  alias PhoenixKitProjects.{ApiAccess, ApiKeys, Authz, L10n, Projects}
  alias PhoenixKitProjects.Schemas.{ApiKey, Project}
  alias PhoenixKitProjects.Web.Api.Docs
  alias PhoenixKitProjects.Web.ApiKeyPanel
  alias PhoenixKitProjects.Web.Helpers, as: WebHelpers

  @default_wrapper_class "flex flex-col mx-auto max-w-5xl px-4 py-6 gap-6"

  @impl true
  def mount(params, session, socket) do
    WebHelpers.maybe_put_locale(session)
    scope = socket.assigns[:phoenix_kit_current_scope]
    me = Authz.subject_user_uuid_of(scope)

    {:ok,
     socket
     |> WebHelpers.assign_embed_state(session)
     |> WebHelpers.assign_embed_user(session)
     |> assign(
       page_title: gettext("API keys"),
       wrapper_class: Map.get(session, "wrapper_class", @default_wrapper_class),
       me: me,
       admin?: Authz.admin_all?(scope),
       show_all?: false,
       api_token: nil,
       open_grid: nil,
       new_project: params["project"]
     )
     |> load()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, new_project: params["project"] || socket.assigns.new_project)}
  end

  defp load(socket) do
    %{me: me, admin?: admin?, show_all?: all?} = socket.assigns
    keys = if admin? and all?, do: ApiKeys.list_all(), else: ApiKeys.list_mine(me)

    rows =
      Enum.map(keys, fn key ->
        grants = ApiKeys.grants(key)
        %{key: key, grants: grants, editable?: editable?(socket, key)}
      end)

    project_names =
      rows
      |> Enum.flat_map(fn r -> Enum.map(r.grants, & &1.project_uuid) end)
      |> Enum.uniq()
      |> Projects.get_projects()

    assign(socket,
      rows: rows,
      projects_by_uuid: project_names,
      my_projects: projects_for(me),
      user_names:
        rows |> Enum.map(& &1.key.user_uuid) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> names()
    )
  end

  # The projects a person may give a key access to: those they can see
  # (a personal key can never do more than its person anyway). Templates
  # are not worked in.
  defp projects_for(nil), do: []

  defp projects_for(user_uuid) do
    [viewer: user_uuid]
    |> Projects.list_projects()
    |> Enum.reject(& &1.is_template)
  rescue
    _ -> []
  end

  defp grant_options(socket, %ApiKey{user_uuid: nil}),
    do:
      if(socket.assigns.admin?,
        do: Enum.reject(Projects.list_projects(), & &1.is_template),
        else: []
      )

  defp grant_options(_socket, %ApiKey{user_uuid: uuid}), do: projects_for(uuid)

  defp names(uuids), do: Map.new(uuids, &{&1, ApiKeyPanel.user_name(&1)})

  # Who may change a key: the person it acts for, whoever made it, and
  # administrators.
  defp editable?(socket, %ApiKey{} = key) do
    me = socket.assigns.me

    socket.assigns.admin? or
      (is_binary(me) and (key.user_uuid == me or key.created_by_uuid == me))
  end

  # ── events ─────────────────────────────────────────────────────────

  @impl true
  def handle_event("toggle_all", _params, socket) do
    {:noreply, socket |> assign(show_all?: not socket.assigns.show_all?) |> load()}
  end

  def handle_event("create_key", %{"key" => params}, socket) do
    me = socket.assigns.me
    shared? = params["kind"] == "shared" and socket.assigns.admin?
    project_uuid = params["project"]
    preset = params["preset"] || "full"

    with true <- is_binary(me) || :no_user,
         %Project{} = project <- allowed_project(socket, project_uuid, shared?, me) || :no_project do
      grid = preset_grid(preset)

      attrs = %{
        "name" => params["name"],
        "scopes" => ApiAccess.scopes(grid),
        "role" => if(shared?, do: params["role"] || "member", else: "manager"),
        "user_uuid" => if(shared?, do: nil, else: me)
      }

      case ApiKeys.create(project, attrs, actor_uuid: me) do
        {:ok, key, token} ->
          {:noreply,
           socket
           |> assign(api_token: %{token: token, key: key, action: :created, project: project})
           |> load()}

        {:error, cs} ->
          {:noreply, put_flash(socket, :error, error_text(cs))}
      end
    else
      :no_user ->
        {:noreply, put_flash(socket, :error, gettext("Sign in to make a key."))}

      :no_project ->
        {:noreply, put_flash(socket, :error, gettext("Pick a project the key starts with."))}
    end
  end

  def handle_event("add_grant", %{"grant" => %{"key" => key_uuid} = params}, socket) do
    with_key(socket, key_uuid, fn key ->
      shared? = is_nil(key.user_uuid)

      case allowed_project(socket, params["project"], shared?, key.user_uuid) do
        %Project{} = project ->
          grid = preset_grid(params["preset"] || "read")

          ApiKeys.put_grant(
            key,
            project.uuid,
            %{"scopes" => ApiAccess.scopes(grid), "role" => key.role},
            actor_uuid: socket.assigns.me
          )
          |> flash_result(socket, gettext("Access added."))

        _ ->
          {:noreply, put_flash(socket, :error, gettext("Pick a project."))}
      end
    end)
  end

  def handle_event(
        "set_preset",
        %{"key" => key_uuid, "project" => project_uuid, "preset" => preset},
        socket
      ) do
    with_grant(socket, key_uuid, project_uuid, fn key, grant ->
      if preset == "custom" do
        {:noreply, assign(socket, open_grid: {key.uuid, project_uuid})}
      else
        ApiKeys.put_grant(
          key,
          project_uuid,
          %{"scopes" => ApiAccess.scopes(preset_grid(preset)), "role" => grant.role},
          actor_uuid: socket.assigns.me
        )
        |> flash_result(socket, nil)
      end
    end)
  end

  def handle_event(
        "set_grid",
        %{"key" => key_uuid, "project" => project_uuid, "grid" => grid},
        socket
      ) do
    with_grant(socket, key_uuid, project_uuid, fn key, grant ->
      ApiKeys.put_grant(
        key,
        project_uuid,
        %{"scopes" => ApiAccess.scopes(grid), "role" => grant.role},
        actor_uuid: socket.assigns.me
      )
      |> flash_result(socket, nil)
    end)
  end

  def handle_event(
        "set_role",
        %{"key" => key_uuid, "project" => project_uuid, "role" => role},
        socket
      ) do
    with_grant(socket, key_uuid, project_uuid, fn key, grant ->
      ApiKeys.put_grant(key, project_uuid, %{"scopes" => grant.scopes, "role" => role},
        actor_uuid: socket.assigns.me
      )
      |> flash_result(socket, nil)
    end)
  end

  def handle_event("toggle_inherit", %{"key" => key_uuid, "project" => project_uuid}, socket) do
    with_grant(socket, key_uuid, project_uuid, fn key, grant ->
      ApiKeys.put_grant(
        key,
        project_uuid,
        %{"scopes" => grant.scopes, "role" => grant.role, "inherit" => not grant.inherit},
        actor_uuid: socket.assigns.me
      )
      |> flash_result(socket, nil)
    end)
  end

  def handle_event("toggle_grid", %{"key" => key_uuid, "project" => project_uuid}, socket) do
    open =
      if socket.assigns.open_grid == {key_uuid, project_uuid},
        do: nil,
        else: {key_uuid, project_uuid}

    {:noreply, assign(socket, open_grid: open)}
  end

  def handle_event("remove_grant", %{"key" => key_uuid, "project" => project_uuid}, socket) do
    with_key(socket, key_uuid, fn key ->
      :ok = ApiKeys.delete_grant(key, project_uuid, actor_uuid: socket.assigns.me)
      {:noreply, socket |> put_flash(:info, gettext("Access removed.")) |> load()}
    end)
  end

  def handle_event("set_home", %{"key" => key_uuid, "home" => project_uuid}, socket) do
    with_key(socket, key_uuid, fn key ->
      case ApiKeys.set_home(key, project_uuid) do
        {:ok, _} -> {:noreply, load(socket)}
        _ -> {:noreply, socket}
      end
    end)
  end

  def handle_event("rotate", %{"key" => key_uuid}, socket) do
    with_key(socket, key_uuid, fn key ->
      case ApiKeys.rotate(key, actor_uuid: socket.assigns.me) do
        {:ok, key, token} ->
          project = key.project_uuid && Projects.get_project(key.project_uuid)

          {:noreply,
           socket
           |> assign(api_token: %{token: token, key: key, action: :rotated, project: project})
           |> load()}

        _ ->
          {:noreply, put_flash(socket, :error, gettext("This key cannot be rotated."))}
      end
    end)
  end

  def handle_event("revoke", %{"key" => key_uuid}, socket) do
    with_key(socket, key_uuid, fn key ->
      {:ok, _} = ApiKeys.revoke(key, actor_uuid: socket.assigns.me)
      {:noreply, socket |> put_flash(:info, gettext("Key revoked.")) |> load()}
    end)
  end

  def handle_event("dismiss_api_token", _params, socket),
    do: {:noreply, assign(socket, api_token: nil)}

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # The key, if the viewer may change it; anything else is ignored.
  defp with_key(socket, key_uuid, fun) do
    case ApiKeys.get(key_uuid) do
      %ApiKey{revoked_at: nil} = key ->
        if editable?(socket, key), do: fun.(key), else: {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  defp with_grant(socket, key_uuid, project_uuid, fun) do
    with_key(socket, key_uuid, fn key ->
      case Enum.find(ApiKeys.grants(key), &(&1.project_uuid == project_uuid)) do
        nil -> {:noreply, socket}
        grant -> fun.(key, grant)
      end
    end)
  end

  # A project the key may be given: one its person can see (any, for a
  # shared key an administrator makes).
  defp allowed_project(socket, project_uuid, shared?, user_uuid) when is_binary(project_uuid) do
    options =
      if shared?,
        do: grant_options(socket, %ApiKey{user_uuid: nil}),
        else: projects_for(user_uuid)

    Enum.find(options, &(&1.uuid == project_uuid))
  end

  defp allowed_project(_socket, _project, _shared?, _user), do: nil

  defp preset_grid(preset) do
    case Enum.find(ApiAccess.presets(), fn {key, _label, _grid} -> key == preset end) do
      {_key, _label, grid} -> grid
      nil -> preset_grid("read")
    end
  end

  defp flash_result({:ok, _}, socket, nil), do: {:noreply, load(socket)}

  defp flash_result({:ok, _}, socket, msg),
    do: {:noreply, socket |> put_flash(:info, msg) |> load()}

  defp flash_result({:error, cs}, socket, _msg),
    do: {:noreply, put_flash(socket, :error, error_text(cs))}

  defp error_text(%Ecto.Changeset{} = cs) do
    cs
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
    end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field}: #{Enum.join(msgs, ", ")}" end)
  end

  # ── render ─────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class={@wrapper_class}>
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 class="text-xl font-semibold">{gettext("API keys")}</h1>
          <p class="text-sm text-base-content/70 max-w-2xl">
            {gettext("A key lets an AI or a script work with your projects. Each key acts for you, so it never does more than you can. Set what it may see and do in each project.")}
          </p>
        </div>
        <div class="flex items-center gap-3 text-sm">
          <a href={Docs.url("/llms.txt")} target="_blank" rel="noopener" class="link link-hover">{gettext("Agent guide")}</a>
          <label :if={@admin?} class="flex items-center gap-2 cursor-pointer">
            <input type="checkbox" class="toggle toggle-sm" checked={@show_all?} phx-click="toggle_all" />
            {gettext("Everyone's keys")}
          </label>
        </div>
      </div>

      <%!-- A new key: a name, the project it starts in and how much it
           may do there; more projects are added on its card. --%>
      <form id="api-key-new" phx-submit="create_key" class="card bg-base-100 border border-base-200 shadow-sm">
        <div class="card-body gap-3">
          <h2 class="font-medium">{gettext("New key")}</h2>
          <div class="flex flex-wrap items-end gap-3">
            <div class="flex-1 min-w-48">
              <.input name="key[name]" value="" label={gettext("Name")} placeholder={gettext("e.g. Max's AI")} required maxlength="80" />
            </div>
            <div class="w-56">
              <.select
                name="key[project]"
                label={gettext("Starts in project")}
                value={@new_project}
                prompt={gettext("Pick a project")}
                options={Enum.map(@my_projects, &{Project.localized_name(&1, L10n.current_content_lang()), &1.uuid})}
              />
            </div>
            <div class="w-60">
              <.select name="key[preset]" label={gettext("Access there")} value="full" options={preset_options()} />
            </div>
            <div :if={@admin?} class="w-40">
              <.select name="key[kind]" label={gettext("Acts for")} value="personal" options={[{gettext("Me"), "personal"}, {gettext("Nobody (shared)"), "shared"}]} />
            </div>
            <div :if={@admin?} class="w-32">
              <.select name="key[role]" label={gettext("Shared key's role")} value="member" options={Enum.map(ApiKey.roles(), &{&1, &1})} />
            </div>
            <.button type="submit" phx-disable-with={gettext("Creating…")}>
              <.icon name="hero-plus" class="w-4 h-4" /> {gettext("Create key")}
            </.button>
          </div>
        </div>
      </form>

      <p :if={@rows == []} class="text-sm text-base-content/60">{gettext("No keys yet.")}</p>

      <div :for={row <- @rows} id={"api-key-#{row.key.uuid}"} class={["card bg-base-100 border shadow-sm", if(row.key.revoked_at, do: "border-base-200 opacity-60", else: "border-base-300")]}>
        <div class="card-body gap-3">
          <div class="flex flex-wrap items-center justify-between gap-2">
            <div class="flex flex-wrap items-center gap-2 min-w-0">
              <.icon name="hero-key" class="w-4 h-4 shrink-0" />
              <span class="font-medium">{row.key.name}</span>
              <span class="font-mono text-xs text-base-content/60">{ApiKeyPanel.display_id(row.key)}</span>
              <span class="badge badge-sm badge-ghost">
                {if row.key.user_uuid, do: gettext("Acts for %{name}", name: Map.get(@user_names, row.key.user_uuid, "—")), else: gettext("Shared")}
              </span>
              <span :if={row.key.revoked_at} class="badge badge-sm badge-error">{gettext("Revoked")}</span>
              <span class="text-xs text-base-content/50">
                {if row.key.last_used_at, do: gettext("Last used %{when}", when: L10n.format_datetime(row.key.last_used_at)), else: gettext("Never used")}
              </span>
            </div>
            <div :if={row.editable? and is_nil(row.key.revoked_at)} class="flex items-center gap-1">
              <button type="button" class="btn btn-ghost btn-xs" phx-click="rotate" phx-value-key={row.key.uuid} phx-disable-with={gettext("Rotating…")} data-confirm={gettext("Make a new token for this key? The old one stops working at once.")}>
                <.icon name="hero-arrow-path" class="w-3.5 h-3.5" /> {gettext("Rotate")}
              </button>
              <button type="button" class="btn btn-ghost btn-xs text-error" phx-click="revoke" phx-value-key={row.key.uuid} phx-disable-with={gettext("Revoking…")} data-confirm={gettext("Revoke this key? Everything using it stops working, in every project.")}>
                <.icon name="hero-no-symbol" class="w-3.5 h-3.5" /> {gettext("Revoke")}
              </button>
            </div>
          </div>

          <%!-- Per project: how much, and whether it covers the project's
               sub-projects. The home project is where a call without
               `project` acts. --%>
          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>{gettext("Project")}</th>
                  <th>{gettext("Access")}</th>
                  <th :if={is_nil(row.key.user_uuid)}>{gettext("Role")}</th>
                  <th>{gettext("Sub-projects")}</th>
                  <th>{gettext("Home")}</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <%= for grant <- row.grants do %>
                  <% project = Map.get(@projects_by_uuid, grant.project_uuid) %>
                  <% open? = @open_grid == {row.key.uuid, grant.project_uuid} %>
                  <tr id={"grant-#{row.key.uuid}-#{grant.project_uuid}"}>
                    <td class="font-medium">
                      {project && Project.localized_name(project, L10n.current_content_lang())}
                      <span :if={project && project.key} class="font-mono text-xs text-base-content/50">{project.key}</span>
                    </td>
                    <td>
                      <form phx-change="set_preset" class="flex items-center gap-2">
                        <input type="hidden" name="key" value={row.key.uuid} />
                        <input type="hidden" name="project" value={grant.project_uuid} />
                        <select name="preset" class="select select-sm" disabled={not row.editable? or row.key.revoked_at != nil}>
                          <option :for={{value, label} <- preset_options() ++ [{"custom", gettext("Custom…")}]} value={value} selected={ApiAccess.preset_of(grant.scopes) == value}>{label}</option>
                        </select>
                        <button type="button" class="btn btn-ghost btn-xs" phx-click="toggle_grid" phx-value-key={row.key.uuid} phx-value-project={grant.project_uuid}>
                          {if open?, do: gettext("Hide details"), else: gettext("Details")}
                        </button>
                      </form>
                    </td>
                    <td :if={is_nil(row.key.user_uuid)}>
                      <form phx-change="set_role">
                        <input type="hidden" name="key" value={row.key.uuid} />
                        <input type="hidden" name="project" value={grant.project_uuid} />
                        <select name="role" class="select select-sm" disabled={not row.editable?}>
                          <option :for={r <- ApiKey.roles()} value={r} selected={grant.role == r}>{r}</option>
                        </select>
                      </form>
                    </td>
                    <td>
                      <input type="checkbox" class="checkbox checkbox-sm" checked={grant.inherit} disabled={not row.editable?} phx-click="toggle_inherit" phx-value-key={row.key.uuid} phx-value-project={grant.project_uuid} aria-label={gettext("Covers its sub-projects")} />
                    </td>
                    <td>
                      <input type="radio" class="radio radio-sm" name={"home-#{row.key.uuid}"} checked={row.key.project_uuid == grant.project_uuid} disabled={not row.editable?} phx-click="set_home" phx-value-key={row.key.uuid} phx-value-home={grant.project_uuid} aria-label={gettext("Home project")} />
                    </td>
                    <td class="text-right">
                      <button :if={row.editable? and is_nil(row.key.revoked_at)} type="button" class="btn btn-ghost btn-xs text-error" phx-click="remove_grant" phx-value-key={row.key.uuid} phx-value-project={grant.project_uuid} data-confirm={gettext("Take this project away from the key?")} aria-label={gettext("Remove")}>
                        <.icon name="hero-x-mark" class="w-4 h-4" />
                      </button>
                    </td>
                  </tr>
                  <tr :if={open?} id={"grid-#{row.key.uuid}-#{grant.project_uuid}"}>
                    <td colspan="6">
                      <form phx-change="set_grid" class="grid grid-cols-1 sm:grid-cols-2 gap-x-6 gap-y-2 py-2">
                        <input type="hidden" name="key" value={row.key.uuid} />
                        <input type="hidden" name="project" value={grant.project_uuid} />
                        <% grid = ApiAccess.grid(grant.scopes) %>
                        <label :for={area <- ApiAccess.areas()} class="flex items-center justify-between gap-3 text-sm">
                          <span>
                            {area.label}
                            <span :if={area.hint} class="block text-xs text-base-content/50">{area.hint}</span>
                          </span>
                          <select name={"grid[#{area.key}]"} class="select select-xs" disabled={not row.editable?}>
                            <option value="none" selected={grid[area.key] == "none"}>{gettext("No access")}</option>
                            <option :if={area.read} value="read" selected={grid[area.key] == "read"}>{gettext("Read")}</option>
                            <option :if={area.write} value="write" selected={grid[area.key] == "write"}>{if area.read, do: gettext("Read and write"), else: gettext("Write")}</option>
                          </select>
                        </label>
                      </form>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>

          <form :if={row.editable? and is_nil(row.key.revoked_at)} id={"grant-add-#{row.key.uuid}"} phx-submit="add_grant" class="flex flex-wrap items-end gap-2">
            <input type="hidden" name="grant[key]" value={row.key.uuid} />
            <% granted = MapSet.new(row.grants, & &1.project_uuid) %>
            <div class="w-56">
              <.select
                name="grant[project]"
                label={gettext("Add a project")}
                value=""
                prompt={gettext("Pick a project")}
                options={for p <- grant_options(assigns_socket(assigns), row.key), not MapSet.member?(granted, p.uuid), do: {Project.localized_name(p, L10n.current_content_lang()), p.uuid}}
              />
            </div>
            <div class="w-60">
              <.select name="grant[preset]" label={gettext("Access")} value="read" options={preset_options()} />
            </div>
            <button type="submit" class="btn btn-sm" phx-disable-with={gettext("Adding…")}>{gettext("Add")}</button>
          </form>
        </div>
      </div>

      <.api_token_modal
        :if={@api_token}
        id="api-keys-token-modal"
        api_token={@api_token}
        project_name={(@api_token[:project] && @api_token.project.name) || ""}
      />
    </div>
    """
  end

  # `grant_options/2` reads the socket's admin flag; the template has the
  # assigns, which carry the same flag.
  defp assigns_socket(assigns), do: %{assigns: %{admin?: assigns.admin?}}

  defp preset_options,
    do: Enum.map(ApiAccess.presets(), fn {key, label, _grid} -> {label, key} end)
end
