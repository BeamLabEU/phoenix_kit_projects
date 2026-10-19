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

  import PhoenixKitWeb.Components.Core.Chart, only: [bar_chart: 1]

  alias PhoenixKitProjects.{ApiAccess, ApiKeys, ApiUsage, Authz, L10n, Projects}
  alias PhoenixKitProjects.Hours.Format
  alias PhoenixKitProjects.Schemas.{ApiKey, Project}
  alias PhoenixKitProjects.Web.Api.Docs
  alias PhoenixKitProjects.Web.ApiKeyPanel
  alias PhoenixKitProjects.Web.Helpers, as: WebHelpers

  @default_wrapper_class "flex flex-col mx-auto max-w-5xl px-4 py-6 gap-6"

  # How far back the usage charts look, in UTC days.
  @usage_days 30
  @usage_metrics [:requests, :tokens, :cost_cents, :minutes]

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
       usage_metric: :requests,
       add_drafts: %{}
     )
     |> load()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case params["project"] do
      uuid when is_binary(uuid) ->
        {:noreply, update(socket, :new_key, &Map.put(&1, "project", uuid))}

      _ ->
        {:noreply, socket}
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

    usage = ApiUsage.rows(Enum.map(keys, & &1.uuid), @usage_days)

    project_names =
      rows
      |> Enum.flat_map(fn r -> Enum.map(r.grants, & &1.project_uuid) end)
      |> Enum.concat(Enum.map(usage, & &1.project))
      |> Enum.uniq()
      |> Projects.get_projects()

    assign(socket,
      rows: rows,
      usage: Enum.group_by(usage, & &1.key),
      usage_all: usage,
      usage_slots: usage_slots(usage),
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
  def handle_event("usage_metric", %{"metric" => metric}, socket) do
    case Enum.find(@usage_metrics, &(Atom.to_string(&1) == metric)) do
      nil -> {:noreply, socket}
      m -> {:noreply, assign(socket, usage_metric: m)}
    end
  end

  def handle_event("toggle_all", _params, socket) do
    {:noreply, socket |> assign(show_all?: not socket.assigns.show_all?) |> load()}
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

      <.viz_palette />

      <%!-- What the keys on this page did: the last 7 and 30 days, and the
           figure the charts below draw (one switch for all of them). --%>
      <section :if={@rows != []} id="api-usage-summary" class="card bg-base-100 border border-base-200 shadow-sm">
        <div class="card-body gap-3">
          <div class="flex flex-wrap items-center justify-between gap-2">
            <h2 class="font-medium">{gettext("Usage, last 30 days")}</h2>
            <div class="join" role="group" aria-label={gettext("What the charts show")}>
              <button
                :for={{metric, label} <- usage_metric_options()}
                type="button"
                class={["join-item btn btn-xs", if(@usage_metric == metric, do: "btn-primary", else: "btn-ghost")]}
                phx-click="usage_metric"
                phx-value-metric={metric}
                aria-pressed={to_string(@usage_metric == metric)}
              >
                {label}
              </button>
            </div>
          </div>
          <% month = @usage_all |> within_days(30) |> ApiUsage.totals() %>
          <% week = @usage_all |> within_days(7) |> ApiUsage.totals() %>
          <div class="grid grid-cols-2 sm:grid-cols-5 gap-2">
            <div :for={{label, field, fmt} <- summary_tiles()} class="rounded-box border border-base-200 p-3">
              <div class="text-xs text-base-content/60">{label}</div>
              <div class={["text-xl font-bold tabular-nums", field == :errors and month.denied > 0 && "text-warning"]}>
                {fmt.(Map.fetch!(month, field))}
              </div>
              <div :if={field == :errors and month.denied > 0} class="text-xs text-warning">
                {gettext("%{count} refused", count: month.denied)}
              </div>
              <div class="text-xs text-base-content/50 tabular-nums">
                {gettext("7 days: %{value}", value: fmt.(Map.fetch!(week, field)))}
              </div>
            </div>
          </div>
          <% top = top_key(@usage, @rows, @usage_metric) %>
          <p :if={top} class="text-sm text-base-content/70">
            {gettext("Most: %{key} — %{value}", key: top.name, value: metric_value(@usage_metric, top.value))}
          </p>
          <p class="text-xs text-base-content/50">
            {gettext("Requests are counted for every call. Tokens, cost and AI time are what agents report — an agent that does not report shows requests only. Days are UTC.")}
          </p>
        </div>
      </section>

      <%!-- A new key: a name, the project it starts in and how much it
           may do there; more projects are added on its card. The form
           keeps its draft in assigns (`draft_key`), so a save elsewhere
           does not clear it. --%>
      <form id="api-key-new" phx-change="draft_key" phx-submit="create_key" class="card bg-base-100 border border-base-200 shadow-sm">
        <div class="card-body gap-3">
          <h2 class="font-medium">{gettext("New key")}</h2>
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

      <p :if={@rows == []} class="text-sm text-base-content/60">{gettext("No keys yet.")}</p>

      <div :for={row <- @rows} id={"api-key-#{row.key.uuid}"} class={["card bg-base-100 border shadow-sm", if(row.key.revoked_at, do: "border-base-200 opacity-60", else: "border-base-300")]}>
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
              <button type="button" class="btn btn-ghost btn-xs" phx-click="rotate" phx-value-key={row.key.uuid} phx-disable-with={gettext("Rotating…")} data-confirm={gettext("Make a new token for this key? The old one stops working at once.")}>
                <.icon name="hero-arrow-path" class="w-3.5 h-3.5" /> {gettext("Rotate")}
              </button>
              <button type="button" class="btn btn-ghost btn-xs text-error" phx-click="revoke" phx-value-key={row.key.uuid} phx-disable-with={gettext("Revoking…")} data-confirm={gettext("Revoke this key? Everything using it stops working, in every project.")}>
                <.icon name="hero-no-symbol" class="w-3.5 h-3.5" /> {gettext("Revoke")}
              </button>
            </div>
          </div>

          <%!-- What this key did in the last 30 days: its figures, and the
               switched figure per day, one colour per project. --%>
          <% key_usage = Map.get(@usage, row.key.uuid, []) %>
          <p :if={key_usage == []} class="text-xs text-base-content/50">{gettext("No use in the last 30 days.")}</p>
          <div :if={key_usage != []} id={"usage-#{row.key.uuid}"} class="pk-hours-viz grid gap-3 sm:grid-cols-[13rem_minmax(0,1fr)] items-start">
            <% t = ApiUsage.totals(key_usage) %>
            <dl class="grid grid-cols-[auto_1fr] gap-x-3 gap-y-0.5 text-sm">
              <dt class="text-base-content/60">{gettext("Requests")}</dt>
              <dd class="tabular-nums text-right">{t.requests}</dd>
              <dt class="text-base-content/60">{gettext("Failed")}</dt>
              <dd class={["tabular-nums text-right", t.denied > 0 && "text-warning"]}>{failed_text(t)}</dd>
              <dt class="text-base-content/60">{gettext("AI tokens")}</dt>
              <dd class="tabular-nums text-right">{Format.tokens(t.tokens)}</dd>
              <dt class="text-base-content/60">{gettext("AI cost")}</dt>
              <dd class="tabular-nums text-right">{Format.cost(t.cost_cents)}</dd>
              <dt class="text-base-content/60">{gettext("AI time")}</dt>
              <dd class="tabular-nums text-right">{Format.duration(t.minutes)}</dd>
            </dl>
            <div class="min-w-0 flex flex-col gap-1">
              <%!-- Core's chart draws a row of empty bars for all zeros, so
                   a figure with nothing in the period says so instead. --%>
              <div :if={Map.fetch!(t, @usage_metric) > 0} class="h-24 border-b border-base-300">
                <.bar_chart
                  id={"usage-chart-#{row.key.uuid}"}
                  data={usage_bars(key_usage, @usage_metric, @usage_slots, @projects_by_uuid)}
                  height={96}
                  value_format={&metric_value(@usage_metric, &1)}
                  aria_label={gettext("%{metric} per day, last 30 days", metric: metric_label(@usage_metric))}
                />
              </div>
              <p :if={Map.fetch!(t, @usage_metric) == 0} class="h-24 border-b border-base-300 text-xs text-base-content/50 pt-8 text-center">
                {gettext("None of this in the last 30 days.")}
              </p>
              <div class="flex justify-between text-[10px] text-base-content/50">
                <span>{short_day(chart_start())}</span>
                <span>{gettext("today")}</span>
              </div>
              <ul class="flex flex-wrap gap-x-3 gap-y-1 text-xs text-base-content/70">
                <li :for={{uuid, figures} <- legend(key_usage)} class="flex items-center gap-1">
                  <span class="inline-block w-2.5 h-2.5 rounded-sm" style={viz_slot_style(Map.get(@usage_slots, uuid, 0))}></span>
                  {project_label(@projects_by_uuid, uuid)}
                  <span class="text-base-content/50 tabular-nums">{metric_value(@usage_metric, Map.fetch!(figures, @usage_metric))}</span>
                </li>
              </ul>
            </div>
          </div>

          <%!-- Per project: how much it may do. A grant covers the
               project's sub-projects unless switched off in Details. The
               default project (the key's home: where a call without
               `project` acts) only means something once there are two. --%>
          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>{gettext("Project")}</th>
                  <th>{gettext("Access")}</th>
                  <th :if={is_nil(row.key.user_uuid)}>{gettext("Role")}</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <%= for grant <- row.grants do %>
                  <% project = Map.get(@projects_by_uuid, grant.project_uuid) %>
                  <% open? = @open_grid == {row.key.uuid, grant.project_uuid} %>
                  <% home? = row.key.project_uuid == grant.project_uuid %>
                  <tr id={"grant-#{row.key.uuid}-#{grant.project_uuid}"}>
                    <td>
                      <div class="flex flex-wrap items-center gap-1.5">
                        <span class="font-medium">{(project && Project.localized_name(project, L10n.current_content_lang())) || "—"}</span>
                        <span :if={project && project.key} class="font-mono text-xs text-base-content/50">{project.key}</span>
                        <span :if={home? and several?} class="badge badge-sm badge-primary badge-outline" title={gettext("Calls that name no project act here")}>{gettext("Default")}</span>
                        <span :if={not grant.inherit} class="badge badge-sm badge-ghost" title={gettext("Its sub-projects are not covered")}>{gettext("This project only")}</span>
                      </div>
                    </td>
                    <td>
                      <form id={"preset-#{row.key.uuid}-#{grant.project_uuid}"} phx-change="set_preset" class="flex items-center gap-2">
                        <input type="hidden" name="key" value={row.key.uuid} />
                        <input type="hidden" name="project" value={grant.project_uuid} />
                        <select name="preset" class="select select-sm min-w-36" disabled={not live?}>
                          <option :for={{label, value} <- preset_options() ++ [{gettext("Custom…"), "custom"}]} value={value} selected={ApiAccess.preset_of(grant.scopes) == value}>{label}</option>
                        </select>
                        <button type="button" class="btn btn-ghost btn-xs" phx-click="toggle_grid" phx-value-key={row.key.uuid} phx-value-project={grant.project_uuid}>
                          <.icon name={if open?, do: "hero-chevron-up", else: "hero-adjustments-horizontal"} class="w-3.5 h-3.5" />
                          {if open?, do: gettext("Hide details"), else: gettext("Details")}
                        </button>
                      </form>
                      <p :if={not open? and ApiAccess.preset_of(grant.scopes) == "custom"} class="text-xs text-base-content/60 mt-1">
                        {access_summary(grant.scopes)}
                      </p>
                    </td>
                    <td :if={is_nil(row.key.user_uuid)}>
                      <form id={"role-#{row.key.uuid}-#{grant.project_uuid}"} phx-change="set_role">
                        <input type="hidden" name="key" value={row.key.uuid} />
                        <input type="hidden" name="project" value={grant.project_uuid} />
                        <select name="role" class="select select-sm min-w-28" disabled={not live?}>
                          <option :for={r <- ApiKey.roles()} value={r} selected={grant.role == r}>{r}</option>
                        </select>
                      </form>
                    </td>
                    <td class="text-right whitespace-nowrap">
                      <button :if={live? and several? and not home? and grant.scopes != []} type="button" class="btn btn-ghost btn-xs" phx-click="set_home" phx-value-key={row.key.uuid} phx-value-home={grant.project_uuid} title={gettext("Calls that name no project act here")}>
                        {gettext("Make default")}
                      </button>
                      <button :if={live?} type="button" class="btn btn-ghost btn-xs text-error" phx-click="remove_grant" phx-value-key={row.key.uuid} phx-value-project={grant.project_uuid} data-confirm={gettext("Take this project away from the key?")} aria-label={gettext("Remove")}>
                        <.icon name="hero-x-mark" class="w-4 h-4" />
                      </button>
                    </td>
                  </tr>
                  <tr :if={open?} id={"grid-#{row.key.uuid}-#{grant.project_uuid}"}>
                    <td colspan="4" class="bg-base-200/40">
                      <form id={"grid-form-#{row.key.uuid}-#{grant.project_uuid}"} phx-change="set_grid" class="grid grid-cols-1 sm:grid-cols-2 gap-x-6 gap-y-2 py-2">
                        <input type="hidden" name="key" value={row.key.uuid} />
                        <input type="hidden" name="project" value={grant.project_uuid} />
                        <% grid = ApiAccess.grid(grant.scopes) %>
                        <label :for={area <- ApiAccess.areas()} class="flex items-center justify-between gap-3 text-sm">
                          <span>
                            {area.label}
                            <span :if={area.hint} class="block text-xs text-base-content/50">{area.hint}</span>
                          </span>
                          <select name={"grid[#{area.key}]"} class="select select-xs" disabled={not live?}>
                            <option value="none" selected={grid[area.key] == "none"}>{gettext("No access")}</option>
                            <option :if={area.read} value="read" selected={grid[area.key] == "read"}>{gettext("Read")}</option>
                            <option :if={area.write} value="write" selected={grid[area.key] == "write"}>{if area.read, do: gettext("Read and write"), else: gettext("Write")}</option>
                          </select>
                        </label>
                      </form>
                      <label class="flex items-start gap-2 text-sm border-t border-base-300 pt-2 mt-1 cursor-pointer">
                        <input type="checkbox" class="checkbox checkbox-sm mt-0.5" checked={grant.inherit} disabled={not live?} phx-click="toggle_inherit" phx-value-key={row.key.uuid} phx-value-project={grant.project_uuid} />
                        <span>
                          {gettext("Also covers its sub-projects")}
                          <span class="block text-xs text-base-content/50">{gettext("On unless you want this project alone. A sub-project with its own row here uses that row instead.")}</span>
                        </span>
                      </label>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>

          <% draft = Map.get(@add_drafts, row.key.uuid, %{}) %>
          <form :if={live? and row.addable != []} id={"grant-add-#{row.key.uuid}"} phx-change="draft_grant" phx-submit="add_grant" class="flex flex-wrap items-end gap-2">
            <input type="hidden" name="grant[key]" value={row.key.uuid} />
            <div class="w-56">
              <.select name="grant[project]" label={gettext("Add a project")} value={draft["project"] || ""} prompt={gettext("Pick a project")} options={row.addable} />
            </div>
            <div class="w-60">
              <.select name="grant[preset]" label={gettext("Access")} value={draft["preset"] || "read"} options={preset_options()} />
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

  # ── usage ──

  # The Usage card's figures: label, field, how to print it.
  defp summary_tiles do
    [
      {gettext("Requests"), :requests, &to_string/1},
      {gettext("Failed"), :errors, &to_string/1},
      {gettext("AI tokens"), :tokens, &Format.tokens/1},
      {gettext("AI cost"), :cost_cents, &Format.cost/1},
      {gettext("AI time"), :minutes, &Format.duration/1}
    ]
  end

  defp usage_metric_options do
    Enum.map(@usage_metrics, &{&1, metric_label(&1)})
  end

  defp metric_label(:requests), do: gettext("Requests")
  defp metric_label(:tokens), do: gettext("AI tokens")
  defp metric_label(:cost_cents), do: gettext("AI cost")
  defp metric_label(:minutes), do: gettext("AI time")

  defp metric_value(:requests, v), do: to_string(round(v))
  defp metric_value(:tokens, v), do: Format.tokens(v)
  defp metric_value(:cost_cents, v), do: Format.cost(v)
  defp metric_value(:minutes, v), do: Format.duration(v)

  defp failed_text(%{errors: 0}), do: "0"

  defp failed_text(%{errors: errors, denied: denied}),
    do: gettext("%{errors} (%{denied} refused)", errors: errors, denied: denied)

  defp within_days(rows, days) do
    from = Date.add(Date.utc_today(), 1 - days)
    Enum.filter(rows, &(Date.compare(&1.day, from) != :lt))
  end

  # The key with the most of `metric` in the period, when any has some.
  defp top_key(usage, rows, metric) do
    names = Map.new(rows, &{&1.key.uuid, &1.key.name})

    usage
    |> Enum.map(fn {uuid, rs} ->
      %{name: names[uuid], value: Map.fetch!(ApiUsage.totals(rs), metric)}
    end)
    |> Enum.filter(&(&1.value > 0 and is_binary(&1.name)))
    |> Enum.max_by(& &1.value, fn -> nil end)
  end

  # One colour per project across the page, the busiest first: seven
  # colours, then the neutral "others" slot.
  defp usage_slots(usage) do
    usage
    |> ApiUsage.by_project()
    |> Enum.sort_by(fn {_p, t} -> {-t.requests, -t.cost_cents} end)
    |> Enum.with_index(1)
    |> Map.new(fn {{project, _t}, i} -> {project, if(i <= 7, do: i, else: 0)} end)
  end

  defp usage_bars(rows, metric, slots, projects) do
    rows
    |> ApiUsage.days(metric, @usage_days)
    |> Enum.map(fn day ->
      %{
        label: L10n.format_date(day.date),
        parts:
          Enum.map(day.parts, fn {project, value} ->
            %{
              label: project_label(projects, project),
              value: value,
              class: viz_slot_class(Map.get(slots, project, 0))
            }
          end)
      }
    end)
  end

  # A key's projects for the legend, the most used first.
  defp legend(rows) do
    rows |> ApiUsage.by_project() |> Enum.sort_by(fn {_p, t} -> -t.requests end)
  end

  defp project_label(projects, uuid) do
    case Map.get(projects, uuid) do
      %Project{} = p -> Project.localized_name(p, L10n.current_content_lang())
      _ -> gettext("(deleted project)")
    end
  end

  defp chart_start, do: Date.add(Date.utc_today(), 1 - @usage_days)

  defp short_day(%Date{} = d), do: "#{L10n.short_month(d.month)} #{d.day}"

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
