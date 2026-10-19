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

  alias PhoenixKitProjects.{ApiAccess, ApiKeys, ApiUsage, Authz, L10n, Paths, Projects}
  alias PhoenixKitProjects.Hours.Format
  alias PhoenixKitProjects.Schemas.{ApiKey, Assignment, Project}
  alias PhoenixKitProjects.Web.Api.Docs
  alias PhoenixKitProjects.Web.{ApiKeyPanel, ApiKeysUsage}
  alias PhoenixKitProjects.Web.Helpers, as: WebHelpers

  @default_wrapper_class "flex flex-col mx-auto max-w-5xl px-4 py-6 gap-6"

  # How far back each key's one-line usage looks, in UTC days.
  @usage_days 30

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
       new_key: %{"project" => params["project"]},
       key_totals: %{},
       u: nil,
       add_drafts: %{}
     )
     |> load()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      case params["project"] do
        uuid when is_binary(uuid) -> update(socket, :new_key, &Map.put(&1, "project", uuid))
        _ -> socket
      end

    case socket.assigns.live_action do
      :usage ->
        {:noreply,
         socket
         |> assign(page_title: gettext("API key usage"), usage_params: params)
         |> load_usage()}

      _ ->
        {:noreply, assign(socket, page_title: gettext("API keys"))}
    end
  end

  defp load(socket) do
    %{me: me, admin?: admin?, show_all?: all?} = socket.assigns
    keys = if admin? and all?, do: ApiKeys.list_all(), else: ApiKeys.list_mine(me)

    rows =
      Enum.map(keys, fn key ->
        grants = ApiKeys.grants(key)

        %{
          key: key,
          grants: grants,
          editable?: editable?(socket, key),
          addable: addable(socket, key, grants)
        }
      end)

    project_names =
      rows
      |> Enum.flat_map(fn r -> Enum.map(r.grants, & &1.project_uuid) end)
      |> Enum.uniq()
      |> Projects.get_projects()

    assign(socket,
      rows: rows,
      key_totals: keys |> Enum.map(& &1.uuid) |> ApiUsage.rows(@usage_days) |> ApiUsage.by_key(),
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
    [viewer: user_uuid, include_subprojects: true]
    |> Projects.list_projects()
    |> Enum.reject(& &1.is_template)
  rescue
    _ -> []
  end

  defp grant_options(socket, %ApiKey{user_uuid: nil}),
    do:
      if(socket.assigns.admin?,
        do: Enum.reject(Projects.list_projects(include_subprojects: true), & &1.is_template),
        else: []
      )

  defp grant_options(_socket, %ApiKey{user_uuid: uuid}), do: projects_for(uuid)

  # The projects a key's "Add a project" offers: what it may be given,
  # minus what it already has.
  defp addable(socket, %ApiKey{revoked_at: nil} = key, grants) do
    if editable?(socket, key) do
      granted = MapSet.new(grants, & &1.project_uuid)

      for p <- grant_options(socket, key), not MapSet.member?(granted, p.uuid) do
        {Project.localized_name(p, L10n.current_content_lang()), p.uuid}
      end
    else
      []
    end
  end

  defp addable(_socket, _key, _grants), do: []

  defp names(uuids), do: Map.new(uuids, &{&1, ApiKeyPanel.user_name(&1)})

  # Who may change a key: the person it acts for, and administrators
  # (the only ones who make shared keys). Whoever MADE a key for somebody
  # else does not keep a hand on it — it is that person's now.
  defp editable?(socket, %ApiKey{} = key) do
    me = socket.assigns.me
    socket.assigns.admin? or (is_binary(me) and key.user_uuid == me)
  end

  # ── events ─────────────────────────────────────────────────────────

  @impl true
  def handle_event("usage_filter", params, socket) do
    u = socket.assigns.u

    # Whose keys (administrators): which keys the page shows at all.
    socket =
      case params["whose"] do
        whose when whose in ["mine", "all"] and socket.assigns.admin? ->
          socket |> assign(show_all?: whose == "all") |> load()

        _ ->
          socket
      end

    {:noreply,
     push_patch(socket,
       to:
         Paths.api_keys_usage(
           days: params["days"] || u.days,
           key: blank_to_nil(params["key"]),
           metric: u.metric
         )
     )}
  end

  def handle_event("toggle_all", _params, socket) do
    socket = socket |> assign(show_all?: not socket.assigns.show_all?) |> load()

    if socket.assigns.live_action == :usage,
      do: {:noreply, load_usage(socket)},
      else: {:noreply, socket}
  end

  # The two add forms keep what was typed in assigns, so a save on another
  # row (which re-renders every card) does not reset them.
  def handle_event("draft_key", %{"key" => params}, socket) do
    {:noreply, assign(socket, new_key: params)}
  end

  def handle_event("draft_grant", %{"grant" => %{"key" => key_uuid} = params}, socket) do
    {:noreply, update(socket, :add_drafts, &Map.put(&1, key_uuid, params))}
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
           |> assign(
             api_token: %{token: token, key: key, action: :created, project: project},
             new_key: %{}
           )
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
          |> flash_result(
            update(socket, :add_drafts, &Map.delete(&1, key.uuid)),
            gettext("Access added.")
          )

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
    with_grant(socket, key_uuid, project_uuid, fn
      # A personal key's role there is its person's; only a shared key has one.
      %ApiKey{user_uuid: user} = _key, _grant when not is_nil(user) ->
        {:noreply, socket}

      key, grant ->
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
    with_grant(socket, key_uuid, project_uuid, fn key, _grant ->
      case ApiKeys.set_home(key, project_uuid) do
        {:ok, _} ->
          {:noreply, load(socket)}

        _ ->
          {:noreply,
           put_flash(socket, :error, gettext("The default project needs some access there."))}
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

  # A grant the viewer may change: on a key they may change, and in a
  # project that key may still be given (`allowed_project/4`) — a grant
  # left over on a project its person can no longer see is only removed.
  defp with_grant(socket, key_uuid, project_uuid, fun) do
    with_key(socket, key_uuid, fn key ->
      grant = Enum.find(ApiKeys.grants(key), &(&1.project_uuid == project_uuid))
      allowed? = allowed_project(socket, project_uuid, is_nil(key.user_uuid), key.user_uuid)

      if grant && allowed?, do: fun.(key, grant), else: {:noreply, socket}
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
      <.viz_palette />


      <ApiKeysUsage.usage_tab :if={@live_action == :usage} u={@u} admin?={@admin?} show_all?={@show_all?} />

      <%= if @live_action != :usage do %>

      <%!-- A new key: a name, the project it starts in and how much it
           may do there; more projects are added on its card. The form
           keeps its draft in assigns (`draft_key`), so a save elsewhere
           does not clear it. --%>
      <form id="api-key-new" phx-change="draft_key" phx-submit="create_key" class="card bg-base-100 shadow-sm">
        <div class="card-body gap-3">
          <div class="flex flex-wrap items-center justify-between gap-2">
            <h2 class="card-title text-lg">
              <.icon name="hero-plus-circle" class="w-5 h-5" /> {gettext("New key")}
            </h2>
            <a href={Docs.url("/llms.txt")} target="_blank" rel="noopener" class="link link-hover text-sm">
              {gettext("Agent guide")} <.icon name="hero-arrow-top-right-on-square" class="w-3.5 h-3.5" />
            </a>
          </div>
          <div class="flex flex-wrap items-end gap-3">
            <div class="flex-1 min-w-48">
              <.input name="key[name]" value={@new_key["name"] || ""} label={gettext("Name")} placeholder={gettext("e.g. Coding assistant")} required maxlength="80" />
            </div>
            <div class="w-56">
              <.select
                name="key[project]"
                label={gettext("Project")}
                value={@new_key["project"]}
                prompt={gettext("Pick a project")}
                options={Enum.map(@my_projects, &{Project.localized_name(&1, L10n.current_content_lang()), &1.uuid})}
              />
            </div>
            <div class="w-60">
              <.select name="key[preset]" label={gettext("Access")} value={@new_key["preset"] || "full"} options={preset_options()} />
            </div>
            <div :if={@admin?} class="w-40">
              <.select name="key[kind]" label={gettext("Acts for")} value={@new_key["kind"] || "personal"} options={[{gettext("Me"), "personal"}, {gettext("Nobody (shared)"), "shared"}]} />
            </div>
            <div :if={@admin? and @new_key["kind"] == "shared"} class="w-32">
              <.select name="key[role]" label={gettext("Shared key's role")} value={@new_key["role"] || "member"} options={Enum.map(ApiKey.roles(), &{&1, &1})} />
            </div>
            <.button type="submit" phx-disable-with={gettext("Creating…")}>
              <.icon name="hero-plus" class="w-4 h-4" /> {gettext("Create key")}
            </.button>
          </div>
          <p class="text-xs text-base-content/60">{gettext("You can give the key more projects once it is made.")}</p>
        </div>
      </form>

      <div :if={@admin?} class="flex justify-end">
        <.checkbox
          id="api-keys-show-all"
          name="show_all"
          variant="toggle"
          label={gettext("Show everyone's keys")}
          checked={@show_all?}
          phx-click="toggle_all"
        />
      </div>

      <.empty_state :if={@rows == []} icon="hero-key" title={gettext("No keys yet.")} />

      <div :for={row <- @rows} id={"api-key-#{row.key.uuid}"} class={["card bg-base-100 shadow-sm", row.key.revoked_at && "opacity-60"]}>
        <% several? = length(row.grants) > 1 %>
        <% live? = row.editable? and is_nil(row.key.revoked_at) %>
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
            <div :if={live?} class="flex items-center gap-1">
              <.button type="button" variant="ghost" size="xs" phx-click="rotate" phx-value-key={row.key.uuid} phx-disable-with={gettext("Rotating…")} data-confirm={gettext("Make a new token for this key? The old one stops working at once.")}>
                <.icon name="hero-arrow-path" class="w-3.5 h-3.5" /> {gettext("Rotate")}
              </.button>
              <.button type="button" variant="ghost" size="xs" class="text-error" phx-click="revoke" phx-value-key={row.key.uuid} phx-disable-with={gettext("Revoking…")} data-confirm={gettext("Revoke this key? Everything using it stops working, in every project.")}>
                <.icon name="hero-no-symbol" class="w-3.5 h-3.5" /> {gettext("Revoke")}
              </.button>
            </div>
          </div>

          <%!-- What this key did in the last 30 days, in one line; the
               Usage tab has the rest. --%>
          <% t = Map.get(@key_totals, row.key.uuid) %>
          <div id={"usage-#{row.key.uuid}"} class="flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-base-content/60">
            <span :if={!t}>{gettext("No use in the last 30 days.")}</span>
            <span :if={t} class="tabular-nums">
              {gettext("Last 30 days:")}
              <span class="text-base-content">{ngettext("%{count} request", "%{count} requests", t.requests)}</span>
              <span :if={t.errors > 0} class="text-warning">{" · "}{gettext("%{count} failed", count: t.errors)}</span>
              · {Format.tokens(t.tokens)} {gettext("tokens")}
              <span :if={t.cost_cents > 0}>· {Format.cost(t.cost_cents)}</span>
              · {Format.duration(t.minutes)}
            </span>
            <.link :if={t} patch={Paths.api_keys_usage(key: row.key.uuid)} class="link link-hover text-primary">
              {gettext("Usage")} →
            </.link>
          </div>


          <%!-- Per project: how much it may do. A grant covers the
               project's sub-projects unless switched off in Details. The
               default project (the key's home: where a call without
               `project` acts) only means something once there are two. --%>
          <.table_default size="sm" wrapper_class="overflow-x-auto">
            <.table_default_header>
              <.table_default_row>
                <.table_default_header_cell>{gettext("Project")}</.table_default_header_cell>
                <.table_default_header_cell>{gettext("Access")}</.table_default_header_cell>
                <.table_default_header_cell :if={is_nil(row.key.user_uuid)}>{gettext("Role")}</.table_default_header_cell>
                <.table_default_header_cell></.table_default_header_cell>
              </.table_default_row>
            </.table_default_header>
            <.table_default_body>
              <%= for grant <- row.grants do %>
                <% project = Map.get(@projects_by_uuid, grant.project_uuid) %>
                <% open? = @open_grid == {row.key.uuid, grant.project_uuid} %>
                <% home? = row.key.project_uuid == grant.project_uuid %>
                <.table_default_row id={"grant-#{row.key.uuid}-#{grant.project_uuid}"} hover={false}>
                  <.table_default_cell>
                    <div class="flex flex-wrap items-center gap-1.5">
                      <span class="font-medium">{(project && Project.localized_name(project, L10n.current_content_lang())) || "—"}</span>
                      <span :if={project && project.key} class="font-mono text-xs text-base-content/50">{project.key}</span>
                      <span :if={home? and several?} class="badge badge-sm badge-primary badge-outline" title={gettext("Calls that name no project act here")}>{gettext("Default")}</span>
                      <span :if={not grant.inherit} class="badge badge-sm badge-ghost" title={gettext("Its sub-projects are not covered")}>{gettext("This project only")}</span>
                    </div>
                  </.table_default_cell>
                  <.table_default_cell>
                    <form id={"preset-#{row.key.uuid}-#{grant.project_uuid}"} phx-change="set_preset" class="flex items-center gap-2">
                      <input type="hidden" name="key" value={row.key.uuid} />
                      <input type="hidden" name="project" value={grant.project_uuid} />
                      <div class="min-w-40">
                        <.select
                          name="preset"
                          class="select-sm"
                          value={ApiAccess.preset_of(grant.scopes)}
                          options={preset_options() ++ [{gettext("Custom…"), "custom"}]}
                          disabled={not live?}
                        />
                      </div>
                      <.button type="button" variant="ghost" size="xs" phx-click="toggle_grid" phx-value-key={row.key.uuid} phx-value-project={grant.project_uuid}>
                        <.icon name={if open?, do: "hero-chevron-up", else: "hero-adjustments-horizontal"} class="w-3.5 h-3.5" />
                        {if open?, do: gettext("Hide details"), else: gettext("Details")}
                      </.button>
                    </form>
                    <p :if={not open? and ApiAccess.preset_of(grant.scopes) == "custom"} class="text-xs text-base-content/60 mt-1">
                      {access_summary(grant.scopes)}
                    </p>
                  </.table_default_cell>
                  <.table_default_cell :if={is_nil(row.key.user_uuid)}>
                    <form id={"role-#{row.key.uuid}-#{grant.project_uuid}"} phx-change="set_role" class="min-w-28">
                      <input type="hidden" name="key" value={row.key.uuid} />
                      <input type="hidden" name="project" value={grant.project_uuid} />
                      <.select name="role" class="select-sm" value={grant.role} options={Enum.map(ApiKey.roles(), &{&1, &1})} disabled={not live?} />
                    </form>
                  </.table_default_cell>
                  <.table_default_cell class="text-right whitespace-nowrap">
                    <.button :if={live? and several? and not home? and grant.scopes != []} type="button" variant="ghost" size="xs" phx-click="set_home" phx-value-key={row.key.uuid} phx-value-home={grant.project_uuid} title={gettext("Calls that name no project act here")}>
                      {gettext("Make default")}
                    </.button>
                    <.button :if={live?} type="button" variant="ghost" size="xs" class="text-error" phx-click="remove_grant" phx-value-key={row.key.uuid} phx-value-project={grant.project_uuid} data-confirm={gettext("Take this project away from the key?")} aria-label={gettext("Remove")}>
                      <.icon name="hero-x-mark" class="w-4 h-4" />
                    </.button>
                  </.table_default_cell>
                </.table_default_row>
                <.table_default_row :if={open?} id={"grid-#{row.key.uuid}-#{grant.project_uuid}"} hover={false}>
                  <.table_default_cell colspan={4} class="bg-base-200/40">
                    <form id={"grid-form-#{row.key.uuid}-#{grant.project_uuid}"} phx-change="set_grid" class="grid grid-cols-1 sm:grid-cols-2 gap-x-6 gap-y-2 py-2">
                      <input type="hidden" name="key" value={row.key.uuid} />
                      <input type="hidden" name="project" value={grant.project_uuid} />
                      <% grid = ApiAccess.grid(grant.scopes) %>
                      <div :for={area <- ApiAccess.areas()} class="flex items-center justify-between gap-3 text-sm">
                        <span>
                          {area.label}
                          <span :if={area.hint} class="block text-xs text-base-content/50">{area.hint}</span>
                        </span>
                        <div class="w-40 shrink-0">
                          <.select
                            id={"grid-#{row.key.uuid}-#{grant.project_uuid}-#{area.key}"}
                            name={"grid[#{area.key}]"}
                            class="select-xs"
                            value={grid[area.key]}
                            options={level_options(area)}
                            disabled={not live?}
                            aria-label={area.label}
                          />
                        </div>
                      </div>
                    </form>
                    <div class="border-t border-base-300 pt-2 mt-1">
                      <.checkbox
                        id={"inherit-#{row.key.uuid}-#{grant.project_uuid}"}
                        name="inherit"
                        label={gettext("Also covers its sub-projects")}
                        checked={grant.inherit}
                        disabled={not live?}
                        phx-click="toggle_inherit"
                        phx-value-key={row.key.uuid}
                        phx-value-project={grant.project_uuid}
                      >
                        <:description>
                          {gettext("On unless you want this project alone. A sub-project with its own row here uses that row instead.")}
                        </:description>
                      </.checkbox>
                    </div>
                  </.table_default_cell>
                </.table_default_row>
              <% end %>
            </.table_default_body>
          </.table_default>

          <% draft = Map.get(@add_drafts, row.key.uuid, %{}) %>
          <form :if={live? and row.addable != []} id={"grant-add-#{row.key.uuid}"} phx-change="draft_grant" phx-submit="add_grant" class="flex flex-wrap items-end gap-2">
            <input type="hidden" name="grant[key]" value={row.key.uuid} />
            <div class="w-56">
              <.select name="grant[project]" label={gettext("Add a project")} value={draft["project"] || ""} prompt={gettext("Pick a project")} options={row.addable} />
            </div>
            <div class="w-60">
              <.select name="grant[preset]" label={gettext("Access")} value={draft["preset"] || "read"} options={preset_options()} />
            </div>
            <.button type="submit" size="sm" phx-disable-with={gettext("Adding…")}>{gettext("Add")}</.button>
          </form>
        </div>
      </div>

      <% end %>

      <.api_token_modal
        :if={@api_token}
        id="api-keys-token-modal"
        api_token={@api_token}
        project_name={(@api_token[:project] && @api_token.project.name) || ""}
      />
    </div>
    """
  end

  # ── the Usage tab ──

  # Everything the Usage tab draws (`ApiKeysUsage`), for the keys this page
  # shows (yours; everyone's for an administrator who asked): the period
  # and the one before it, the main chart by key — or by project for one
  # key — the failures, and the breakdowns.
  defp load_usage(socket) do
    params = socket.assigns[:usage_params] || %{}
    keys = Enum.map(socket.assigns.rows, & &1.key)
    key_names = Map.new(keys, &{&1.uuid, &1.name})

    days = pick(params["days"], ApiKeysUsage.periods(), 30, &String.to_integer/1)
    key = if Map.has_key?(key_names, params["key"]), do: params["key"]

    uuids = if key, do: [key], else: Map.keys(key_names)
    all = ApiUsage.rows(uuids, 2 * days)

    # Cost is for agents paid per call through an API; with no cost
    # reported (a subscription) the page leaves it out altogether.
    cost? = Enum.any?(all, &(&1.cost_cents > 0))
    metrics = if cost?, do: ApiKeysUsage.metrics(), else: ApiKeysUsage.metrics() -- [:cost_cents]
    metric = pick(params["metric"], metrics, :requests, &String.to_existing_atom/1)
    now = ApiUsage.within(all, days)
    by = if key, do: :project, else: :key

    projects = all |> Enum.map(& &1.project) |> Projects.get_projects()
    project_names = Map.new(projects, fn {uuid, p} -> {uuid, project_name(p)} end)
    names = if key, do: project_names, else: key_names

    totals = if key, do: ApiUsage.by_project(now), else: ApiUsage.by_key(now)

    # Colours follow the busiest series (by requests, then cost), so they
    # do not move when the figure is switched.
    slots =
      totals
      |> Enum.sort_by(fn {uuid, t} -> {-t.requests, -t.cost_cents, uuid} end)
      |> Enum.with_index(1)
      |> Map.new(fn {{uuid, _t}, i} -> {uuid, if(i <= 7, do: i, else: 0)} end)

    days_main = ApiUsage.days(now, metric, days, by)

    assign(socket,
      u: %{
        days: days,
        key: key,
        metric: metric,
        metrics: metrics,
        cost?: cost?,
        rows: now,
        key_options: Enum.map(keys, &{&1.uuid, &1.name}),
        now: ApiUsage.totals(now),
        before: all |> ApiUsage.previous(days) |> ApiUsage.totals(),
        slots: slots,
        series_names: names,
        series:
          totals
          |> Enum.map(fn {uuid, t} ->
            %{uuid: uuid, name: Map.get(names, uuid, "—"), value: Map.fetch!(t, metric)}
          end)
          |> Enum.filter(&(&1.value > 0))
          |> Enum.sort_by(&(-&1.value)),
        days_main: days_main,
        top_main:
          days_main |> Enum.map(&day_sum/1) |> Enum.max(fn -> 0 end) |> ApiKeysUsage.nice_top(),
        failure_bars: failure_bars(now, days),
        top_failures:
          now
          |> ApiUsage.days(:errors, days, :key)
          |> Enum.map(&day_sum/1)
          |> Enum.max(fn -> 0 end)
          |> ApiKeysUsage.nice_top(),
        by_key:
          now
          |> ApiUsage.by_key()
          |> Enum.map(fn {uuid, t} ->
            Map.merge(t, %{
              uuid: uuid,
              name: Map.get(key_names, uuid, "—"),
              href: Paths.api_keys_usage(days: days, key: uuid, metric: metric)
            })
          end)
          |> Enum.sort_by(&(-Map.fetch!(&1, metric))),
        by_project:
          now
          |> ApiUsage.by_project()
          |> Enum.map(fn {uuid, t} ->
            Map.merge(t, %{
              uuid: uuid,
              name: Map.get(project_names, uuid, gettext("(deleted project)"))
            })
          end)
          |> Enum.sort_by(&(-Map.fetch!(&1, metric))),
        by_task: uuids |> ApiUsage.by_task(days) |> Enum.map(&task_row(&1, projects))
      }
    )
  end

  defp pick(value, allowed, default, parse) when is_binary(value) do
    parsed = parse.(value)
    if parsed in allowed, do: parsed, else: default
  rescue
    _ -> default
  end

  defp pick(_value, _allowed, default, _parse), do: default

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v

  defp day_sum(%{parts: parts}), do: parts |> Enum.map(&elem(&1, 1)) |> Enum.sum()

  defp project_name(%Project{} = p), do: Project.localized_name(p, L10n.current_content_lang())

  # Failed calls per day: the refused (403) part, then the rest.
  defp failure_bars(rows, days) do
    by_day = Enum.group_by(rows, & &1.day)
    today = Date.utc_today()

    for offset <- (days - 1)..0//-1 do
      date = Date.add(today, -offset)
      t = by_day |> Map.get(date, []) |> ApiUsage.totals()

      %{
        label: L10n.format_date(date),
        parts: [
          %{label: gettext("Refused (403)"), value: t.denied, class: "text-warning"},
          %{label: gettext("Other failures"), value: t.errors - t.denied, class: "text-error"}
        ]
      }
    end
  end

  # A task the reported work went to, ready to print: its ref, title and
  # link (nil when the task is gone).
  defp task_row(t, projects) do
    project = Map.get(projects, t.project)
    a = Projects.get_assignment(t.assignment)

    Map.merge(t, %{
      ref: a && Assignment.ref(a),
      title: a && Assignment.label(a),
      href: a && project && Paths.task(project, a),
      project_name: (project && project_name(project)) || gettext("(deleted project)")
    })
  end

  # The levels an area offers, as a select's options.
  defp level_options(area) do
    [{gettext("No access"), "none"}] ++
      if(area.read, do: [{gettext("Read"), "read"}], else: []) ++
      if(area.write,
        do: [{if(area.read, do: gettext("Read and write"), else: gettext("Write")), "write"}],
        else: []
      )
  end

  # A custom grant in one line: the areas it opens and how far.
  defp access_summary(scopes) do
    grid = ApiAccess.grid(scopes)

    ApiAccess.areas()
    |> Enum.flat_map(fn area ->
      case grid[area.key] do
        "write" -> ["#{area.label}: #{gettext("write")}"]
        "read" -> ["#{area.label}: #{gettext("read")}"]
        _ -> []
      end
    end)
    |> Enum.join(" · ")
  end

  defp preset_options,
    do: Enum.map(ApiAccess.presets(), fn {key, label, _grid} -> {label, key} end)
end
