defmodule PhoenixKitProjects.Web.Components.AccessPanel do
  @moduledoc """
  "Who can see this project, and what can they do" — the access controls,
  in one place, shared by the surfaces that set them.

  Both the creation form and the members page ask exactly this question,
  and they used to be able to answer it differently: creation had the
  whole panel, and after creation there was no way to reach visibility or
  the work floors at all. Rendering them from one component is what keeps
  the two surfaces honest — the same wording, the same choices, the same
  conditional rows.

  The floors offered are only the ones `Authz` actually lets a project
  override. This is a "who can X" panel, not a permission-scheme editor:
  the rules that never move (settings, membership, archiving and deletion
  stay with owners) are stated in plain language rather than hidden,
  because they are what most people are checking for when they come
  looking for permissions at all.

  ## Conditional rows

  A project whose tasks are simple enough not to need comments shouldn't
  be asked who may comment — and a project with no task list at all
  shouldn't be asked who may create tasks: the question is noise, and
  answering it stores a floor for a capability that isn't there.
  `visible_actions/3` filters against the same flags and extensions the
  rest of the module toggles, so rows appear and disappear as those change.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitProjects.Gettext

  # What each floor DEPENDS on, keyed on the flags/extensions that provide
  # the capability — ALL of a row's requirements must hold. Every task
  # floor needs the task list itself (a project can be only its
  # whiteboards since 2026-09-05; asking who may create tasks there is a
  # question with no meaning — grok's find). Absent = always relevant.
  @requires %{
    "create_tasks" => [{:ext, "tasks"}],
    "edit_tasks" => [{:ext, "tasks"}],
    "delete_tasks" => [{:ext, "tasks"}],
    "assign_tasks" => [{:ext, "tasks"}, {:flag, "assignees"}],
    "update_status" => [{:ext, "tasks"}, {:flag, "statuses"}],
    "log_time" => [{:ext, "tasks"}, {:flag, "ledger"}],
    "set_health" => [{:ext, "tasks"}, {:flag, "lifecycle"}],
    "comment" => [{:ext, "discussions"}],
    "upload_files" => [{:ext, "files"}]
  }

  @doc """
  The subset of `actions` whose capability is actually present.

  `flag_states` and `ext_states` are the maps the caller already keeps for
  its own toggles. A flag defaults to ON when absent (flags are opt-out),
  an extension defaults to OFF (extensions are opt-in) — matching how each
  resolves everywhere else.
  """
  @spec visible_actions([map()], map(), map()) :: [map()]
  def visible_actions(actions, flag_states, ext_states) do
    Enum.filter(actions, fn action ->
      @requires
      |> Map.get(action.settings_key, [])
      |> Enum.all?(fn
        {:flag, key} -> Map.get(flag_states, key, true) != false
        {:ext, key} -> Map.get(ext_states, key, false) == true
      end)
    end)
  end

  @doc "The capabilities a floor depends on — `[]` when it always applies."
  @spec requirements(String.t()) :: [{:flag | :ext, String.t()}]
  def requirements(settings_key), do: Map.get(@requires, settings_key, [])

  attr(:authz_choices, :map, required: true)
  attr(:authz_actions, :list, required: true)
  attr(:visibility, :string, required: true)
  attr(:public_link?, :boolean, default: false)

  attr(:ownership_note, :boolean,
    default: true,
    doc: "show the \"you own what you create\" line — true while creating, false after"
  )

  def access_panel(assigns) do
    ~H"""
    <div class="flex flex-col gap-4">
      <%!-- Visibility first: it answers "who can even see this", which comes
           before any question about what they may do. Everything below is
           about people who already have access. --%>
      <div>
        <h4 class="mb-1 text-xs font-semibold uppercase opacity-50">{gettext("Who can see it")}</h4>
        <div class="grid grid-cols-1 gap-2 sm:grid-cols-2">
          <label
            :for={{value, title, hint} <- visibility_choices()}
            class="flex cursor-pointer items-start gap-2 rounded-lg border border-base-300 p-2 transition-colors has-[:checked]:border-primary has-[:checked]:bg-primary/5"
          >
            <input
              type="radio"
              name="visibility"
              value={value}
              checked={@visibility == value}
              class="radio radio-primary radio-xs mt-0.5 shrink-0"
            />
            <span class="min-w-0">
              <span class="block text-sm font-medium">{title}</span>
              <span class="block text-xs opacity-60">{hint}</span>
            </span>
          </label>
        </div>
      </div>

      <div>
        <h4 class="mb-1 text-xs font-semibold uppercase opacity-50">{gettext("What they can do")}</h4>
        <p class="mb-2 text-xs opacity-60">
          {gettext("Everyone with access can do everything by default. Restrict anything you'd rather keep to managers.")}
        </p>

        <div class="divide-y divide-base-200 rounded-lg border border-base-200">
          <div
            :for={action <- @authz_actions}
            class="flex flex-wrap items-center justify-between gap-2 px-3 py-2"
            id={"authz-row-#{action.settings_key}"}
          >
            <span class="text-sm">{action_label(action.settings_key)}</span>
            <label class="select select-sm w-56 shrink-0">
              <select name={"authz[#{action.settings_key}]"}>
                <option
                  :for={{value, label} <- choice_labels()}
                  value={value}
                  selected={Map.get(@authz_choices, action.settings_key, action.default) == value}
                >
                  {label}
                </option>
              </select>
            </label>
          </div>
        </div>
      </div>

      <ul class="flex flex-col gap-1 text-xs opacity-60">
        <li :if={@ownership_note}>
          {gettext("You create the project, so you own it — you can do everything.")}
        </li>
        <li>
          {gettext("Settings, membership, archiving and deletion always stay with owners.")}
        </li>
      </ul>

      <%!-- The other axis entirely: the portal publishes a link that needs
           no account at all. It is the biggest access decision this page
           makes, so it says so here, where someone checking permissions
           looks — not only as an extension toggle further down. --%>
      <p :if={@public_link?} class="rounded-lg bg-warning/10 p-2 text-xs">
        {gettext("Anyone with this project's portal link will be able to reach it without signing in. Choose what that link exposes under Extensions → Public portal.")}
      </p>
    </div>
    """
  end

  defp visibility_choices do
    [
      {"private", gettext("Just the people on it"),
       gettext("Members, the teams and departments you add, and site admins.")},
      {"everyone", gettext("Everyone who can open Projects"),
       gettext("Anyone with access to the Projects module can see it, as a viewer.")}
    ]
  end

  defp choice_labels do
    [
      {"anyone", gettext("Anyone with access")},
      {"members", gettext("Members and up")},
      {"managers", gettext("Managers and owners")}
    ]
  end

  defp action_label("create_tasks"), do: gettext("Add tasks")
  defp action_label("edit_tasks"), do: gettext("Edit anyone's task")
  defp action_label("delete_tasks"), do: gettext("Delete tasks")
  defp action_label("assign_tasks"), do: gettext("Assign tasks")
  defp action_label("update_status"), do: gettext("Change task status")
  defp action_label("log_time"), do: gettext("Log time")
  defp action_label("comment"), do: gettext("Comment")
  defp action_label("upload_files"), do: gettext("Upload files")
  defp action_label("set_health"), do: gettext("Set project health")
  defp action_label(key), do: key
end
