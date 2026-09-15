defmodule PhoenixKitProjects.MediaReorganizerTest do
  @moduledoc false
  use PhoenixKitProjects.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.MediaReorganizer
  alias PhoenixKitProjects.Projects
  alias PhoenixKitProjects.QueryCounter
  alias PhoenixKitProjects.Schemas.Project

  defmodule Hook do
    @moduledoc false
    def parent(:project, _actor, %Project{} = resource) do
      bump(:parent_calls)
      Process.put(:last_parent_resource, resource)
      parent_result(resource)
    end

    def parent(_kind, _actor, _resource), do: nil

    def name(%Project{} = resource, _actor) do
      bump(:name_calls)
      name_result(resource)
    end

    def name(_resource, _actor), do: nil

    defp parent_result(_resource), do: {:ok, Process.get(:target_folder)}
    defp name_result(_resource), do: {:ok, Process.get(:target_name) || nil}

    defp bump(key), do: Process.put(key, (Process.get(key) || 0) + 1)
  end

  defmodule RaisingHook do
    @moduledoc false
    def parent(:project, _actor, _resource), do: raise("boom")
  end

  defmodule BadReturnHook do
    @moduledoc false
    def parent(:project, _actor, _resource), do: {:error, :timeout}
  end

  defmodule BareNilHook do
    @moduledoc false
    def parent(:project, _actor, _resource), do: nil
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:phoenix_kit_projects, :attachments_parent_folder)
      Application.delete_env(:phoenix_kit_projects, :attachments_folder_name)
    end)

    :ok
  end

  defp project!(attrs \\ %{}) do
    {:ok, project} =
      Projects.create_project(
        Map.merge(
          %{"name" => "P #{System.unique_integer([:positive])}", "start_mode" => "immediate"},
          attrs
        )
      )

    project
  end

  defp configure_parent_hook(target_folder_uuid) do
    Process.put(:target_folder, target_folder_uuid)
    Application.put_env(:phoenix_kit_projects, :attachments_parent_folder, {Hook, :parent})
  end

  defp configure_name_hook(name) do
    Process.put(:target_name, name)
    Application.put_env(:phoenix_kit_projects, :attachments_folder_name, {Hook, :name})
  end

  test "no hooks configured, legacy folder at root → nothing planned" do
    project = project!()
    {:ok, _folder} = Storage.create_folder(%{name: "project-#{project.uuid}"})

    actions = MediaReorganizer.plan(nil, [])
    refute Enum.any?(actions, &(&1.kind == :project and &1.label == project.name))
  end

  test "no hook, no legacy folder → no action" do
    project = project!()

    actions = MediaReorganizer.plan(nil, [])
    refute Enum.any?(actions, &(&1.kind == :project and &1.label == project.name))
  end

  test "no hook configured, legacy folder relocated away from root → left untouched" do
    project = project!()
    {:ok, elsewhere} = Storage.create_folder(%{name: "Somewhere else"})

    {:ok, _relocated} =
      Storage.create_folder(%{name: "project-#{project.uuid}", parent_uuid: elsewhere.uuid})

    actions = MediaReorganizer.plan(nil, [])
    refute Enum.any?(actions, &(&1.label == project.name))
  end

  test "parent hook resolves nil, name hook resolves a host name → root legacy folder is not renamed" do
    project = project!(%{"name" => "Käepide"})
    {:ok, _folder} = Storage.create_folder(%{name: "project-#{project.uuid}"})

    configure_parent_hook(nil)
    configure_name_hook("Host Name")

    actions = MediaReorganizer.plan(nil, [])
    refute Enum.any?(actions, &(&1.label == project.name))
  end

  test "parent hook configured, legacy folder at root → one move action, name kept" do
    project = project!(%{"name" => "Käepide"})
    {:ok, target} = Storage.create_folder(%{name: "Projects"})
    {:ok, folder} = Storage.create_folder(%{name: "project-#{project.uuid}"})

    configure_parent_hook(target.uuid)

    actions = MediaReorganizer.plan(nil, [])
    action = Enum.find(actions, &(&1.kind == :project and &1.label == project.name))

    refute is_nil(action)
    assert action.source == "projects"
    assert action.op == :move
    assert action.folder.uuid == folder.uuid
    assert action.parent_uuid == target.uuid
    assert action.name == folder.name
    assert action.on_conflict == :report
    assert action.counts == {0, 0}
    assert is_nil(action.after_move)
  end

  test "parent + name hooks configured → move and rename" do
    project = project!(%{"name" => "Käepide"})
    {:ok, target} = Storage.create_folder(%{name: "Projects"})
    {:ok, folder} = Storage.create_folder(%{name: "project-#{project.uuid}"})

    configure_parent_hook(target.uuid)
    configure_name_hook("Nice project")

    actions = MediaReorganizer.plan(nil, [])
    action = Enum.find(actions, &(&1.kind == :project and &1.label == project.name))

    refute is_nil(action)
    assert action.folder.uuid == folder.uuid
    assert action.parent_uuid == target.uuid
    assert action.name == "Nice project"
  end

  test "folder already at the right parent/name → nothing planned (no pointer, so never an after_move)" do
    project = project!()
    {:ok, target} = Storage.create_folder(%{name: "Projects"})

    {:ok, _folder} =
      Storage.create_folder(%{name: "project-#{project.uuid}", parent_uuid: target.uuid})

    configure_parent_hook(target.uuid)

    actions = MediaReorganizer.plan(nil, [])
    refute Enum.any?(actions, &(&1.kind == :project and &1.label == project.name))
  end

  test "folder already at right parent under an accepted 'name (N)' suffix variant → nothing planned" do
    project = project!()
    {:ok, target} = Storage.create_folder(%{name: "Projects"})

    {:ok, _folder} =
      Storage.create_folder(%{
        name: "project-#{project.uuid} (2)",
        parent_uuid: target.uuid
      })

    configure_parent_hook(target.uuid)

    actions = MediaReorganizer.plan(nil, [])
    refute Enum.any?(actions, &(&1.kind == :project and &1.label == project.name))
  end

  test "hook configured, legacy folder lives away from root/resolved parent → reported relocated, not moved" do
    project = project!()
    {:ok, target} = Storage.create_folder(%{name: "Projects"})
    {:ok, elsewhere} = Storage.create_folder(%{name: "Somewhere else"})

    {:ok, relocated} =
      Storage.create_folder(%{name: "project-#{project.uuid}", parent_uuid: elsewhere.uuid})

    configure_parent_hook(target.uuid)

    actions = MediaReorganizer.plan(nil, [])
    refute Enum.any?(actions, &(&1.op == :move and &1.label == project.name))

    action = Enum.find(actions, &(&1.kind == :relocated and &1.label == project.name))
    refute is_nil(action)
    assert action.op == :report
    assert action.folder.uuid == relocated.uuid
  end

  test "legacy folder live at both root and under the resolved parent → one duplicate report, no move" do
    project = project!()
    {:ok, target} = Storage.create_folder(%{name: "Projects"})
    {:ok, _root_folder} = Storage.create_folder(%{name: "project-#{project.uuid}"})

    {:ok, _under_folder} =
      Storage.create_folder(%{name: "project-#{project.uuid}", parent_uuid: target.uuid})

    configure_parent_hook(target.uuid)

    actions = MediaReorganizer.plan(nil, [])
    refute Enum.any?(actions, &(&1.op == :move and &1.label == project.name))

    action = Enum.find(actions, &(&1.kind == :duplicate and &1.label == project.name))
    refute is_nil(action)
    assert action.op == :report
  end

  test "hooks run exactly once per project across a batch, not once per project per lookup tier" do
    project1 = project!()
    project2 = project!()
    {:ok, target} = Storage.create_folder(%{name: "Projects"})
    {:ok, _f1} = Storage.create_folder(%{name: "project-#{project1.uuid}"})
    {:ok, _f2} = Storage.create_folder(%{name: "project-#{project2.uuid}"})

    configure_parent_hook(target.uuid)
    configure_name_hook("Nice project")

    _actions = MediaReorganizer.plan(nil, [])

    assert Process.get(:parent_calls) == 2
    assert Process.get(:name_calls) == 2
  end

  test "project without any legacy folder never triggers the hooks; a candidate triggers them once" do
    {:ok, target} = Storage.create_folder(%{name: "Projects"})
    configure_parent_hook(target.uuid)
    configure_name_hook("Nice project")

    _no_folder_project = project!()
    candidate = project!()
    {:ok, _folder} = Storage.create_folder(%{name: "project-#{candidate.uuid}"})

    _actions = MediaReorganizer.plan(nil, [])

    assert Process.get(:parent_calls) == 1
    assert Process.get(:name_calls) == 1
  end

  test "current-folder resolution is batched — statement count is flat regardless of project count needing a move" do
    {:ok, target} = Storage.create_folder(%{name: "Projects"})
    configure_parent_hook(target.uuid)

    project1 = project!()
    {:ok, _folder1} = Storage.create_folder(%{name: "project-#{project1.uuid}"})

    {actions_one, one_project_queries} =
      QueryCounter.count(fn -> MediaReorganizer.plan(nil, []) end)

    assert Enum.count(actions_one, &(&1.op == :move)) == 1

    for _ <- 1..4 do
      project = project!()
      {:ok, _folder} = Storage.create_folder(%{name: "project-#{project.uuid}"})
    end

    {actions_five, five_project_queries} =
      QueryCounter.count(fn -> MediaReorganizer.plan(nil, []) end)

    assert Enum.count(actions_five, &(&1.op == :move)) == 5
    assert five_project_queries == one_project_queries
  end

  describe "orphan folders" do
    test "legacy folder with no matching project record → orphan report with counts" do
      folder_uuid = Ecto.UUID.generate()
      {:ok, folder} = Storage.create_folder(%{name: "project-#{folder_uuid}"})

      actions = MediaReorganizer.plan(nil, [])
      action = Enum.find(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))

      refute is_nil(action)
      assert action.source == "projects"
      assert action.op == :report
      assert action.counts == {0, 0}
      assert action.reason =~ "missing"
    end

    test "legacy folder with an uppercase uuid still matches its live project (not a false orphan)" do
      project = project!()
      {:ok, folder} = Storage.create_folder(%{name: "project-" <> String.upcase(project.uuid)})

      actions = MediaReorganizer.plan(nil, [])
      refute Enum.any?(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))
    end

    test "malformed legacy-looking folder name is not treated as an orphan" do
      {:ok, folder} = Storage.create_folder(%{name: "project-not-a-real-uuid"})

      actions = MediaReorganizer.plan(nil, [])
      refute Enum.any?(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))
    end

    test "legacy folder of a live project → not reported as orphan" do
      project = project!()
      {:ok, folder} = Storage.create_folder(%{name: "project-#{project.uuid}"})

      actions = MediaReorganizer.plan(nil, [])
      refute Enum.any?(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))
    end

    test "legacy folder of an archived project → not reported as orphan (archived is live)" do
      project = project!()
      {:ok, folder} = Storage.create_folder(%{name: "project-#{project.uuid}"})
      {:ok, _project} = Projects.archive_project(project)

      actions = MediaReorganizer.plan(nil, [])
      refute Enum.any?(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))
    end

    test "archived project's legacy folder still gets a move action (archived is live)" do
      project = project!()
      {:ok, project} = Projects.archive_project(project)
      {:ok, target} = Storage.create_folder(%{name: "Projects"})
      {:ok, folder} = Storage.create_folder(%{name: "project-#{project.uuid}"})

      configure_parent_hook(target.uuid)

      actions = MediaReorganizer.plan(nil, [])
      action = Enum.find(actions, &(&1.kind == :project and &1.label == project.name))

      refute is_nil(action)
      assert action.folder.uuid == folder.uuid
    end

    test "orphan candidates are also scanned under a resolved parent" do
      {:ok, target} = Storage.create_folder(%{name: "Projects"})
      configure_parent_hook(target.uuid)

      stray_uuid = Ecto.UUID.generate()

      {:ok, folder} =
        Storage.create_folder(%{name: "project-#{stray_uuid}", parent_uuid: target.uuid})

      # A live project with its own legacy folder so the hook resolves
      # `target` into `desired` and it lands in `resolved_parents`.
      project = project!()
      {:ok, _own_folder} = Storage.create_folder(%{name: "project-#{project.uuid}"})

      actions = MediaReorganizer.plan(nil, [])
      action = Enum.find(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))

      refute is_nil(action)
    end

    test "a folder claimed via an ambiguous match is not also reported orphan (R4)" do
      project = project!()
      {:ok, target} = Storage.create_folder(%{name: "Projects"})
      {:ok, _own_folder} = Storage.create_folder(%{name: "project-#{project.uuid}"})

      # A different, deleted project's leftover legacy folder — live under
      # the resolved parent.
      other_uuid = Ecto.UUID.generate()

      {:ok, stray} =
        Storage.create_folder(%{name: "project-#{other_uuid}", parent_uuid: target.uuid})

      configure_parent_hook(target.uuid)
      # A naive host-name hook that (mis)resolves every project to the
      # same fixed string — here it happens to collide with the deleted
      # project's legacy folder name.
      configure_name_hook("project-#{other_uuid}")

      actions = MediaReorganizer.plan(nil, [])

      dup = Enum.find(actions, &(&1.kind == :duplicate and &1.op == :report))
      refute is_nil(dup)
      assert dup.reason =~ stray.uuid

      refute Enum.any?(actions, &(&1.kind == :orphan and &1.folder.uuid == stray.uuid))
    end
  end

  describe "shared destinations (X5)" do
    test "two projects whose current folder resolves to the same live folder → one duplicate report, no moves" do
      project1 = project!()
      project2 = project!()
      {:ok, target} = Storage.create_folder(%{name: "Projects"})
      {:ok, shared} = Storage.create_folder(%{name: "Shared name", parent_uuid: target.uuid})
      {:ok, elsewhere} = Storage.create_folder(%{name: "Elsewhere"})

      # Each project's own legacy folder lives somewhere unrelated to the
      # resolved parent/root — enough to make it a candidate, but never a
      # tier match, so only the shared "Shared name" folder resolves.
      {:ok, _folder1} =
        Storage.create_folder(%{name: "project-#{project1.uuid}", parent_uuid: elsewhere.uuid})

      {:ok, _folder2} =
        Storage.create_folder(%{name: "project-#{project2.uuid}", parent_uuid: elsewhere.uuid})

      configure_parent_hook(target.uuid)
      configure_name_hook("Shared name")

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.op == :move))

      dup =
        Enum.find(
          actions,
          &(&1.kind == :duplicate and &1.op == :report and &1.label == shared.name)
        )

      refute is_nil(dup)
      assert dup.reason =~ project1.name
      assert dup.reason =~ project2.name
    end
  end

  test "counts include a trashed file — the engine re-measures the same way at apply time" do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "reorg-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    project = project!()
    {:ok, target} = Storage.create_folder(%{name: "Projects"})
    {:ok, folder} = Storage.create_folder(%{name: "project-#{project.uuid}"})

    {:ok, _trashed_file} =
      Storage.create_file(%{
        original_file_name: "old.pdf",
        file_name: "old.pdf",
        mime_type: "application/pdf",
        file_type: "document",
        ext: "pdf",
        file_checksum: "checksum-trashed-#{System.unique_integer([:positive])}",
        user_file_checksum: "user-checksum-trashed-#{System.unique_integer([:positive])}",
        size: 10,
        status: "trashed",
        folder_uuid: folder.uuid,
        user_uuid: user.uuid
      })

    configure_parent_hook(target.uuid)

    actions = MediaReorganizer.plan(nil, [])
    action = Enum.find(actions, &(&1.kind == :project and &1.label == project.name))

    refute is_nil(action)
    assert action.counts == {1, 0}
  end

  describe "converging targets (R7)" do
    test "two projects whose desired destination coincides → one duplicate report, no moves" do
      project1 = project!()
      project2 = project!()
      {:ok, target} = Storage.create_folder(%{name: "Projects"})
      {:ok, _folder1} = Storage.create_folder(%{name: "project-#{project1.uuid}"})
      {:ok, _folder2} = Storage.create_folder(%{name: "project-#{project2.uuid}"})

      configure_parent_hook(target.uuid)
      # Both projects resolve to the very same host name — a naive host hook.
      configure_name_hook("Shared name")

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.op == :move))

      dup = Enum.find(actions, &(&1.kind == :duplicate and &1.op == :report))
      refute is_nil(dup)
      assert dup.label =~ project1.name
      assert dup.label =~ project2.name
    end

    test "two projects resolving to different destinations still move independently" do
      project1 = project!()
      project2 = project!()
      {:ok, target} = Storage.create_folder(%{name: "Projects"})
      {:ok, _folder1} = Storage.create_folder(%{name: "project-#{project1.uuid}"})
      {:ok, _folder2} = Storage.create_folder(%{name: "project-#{project2.uuid}"})

      configure_parent_hook(target.uuid)

      actions = MediaReorganizer.plan(nil, [])

      assert Enum.count(actions, &(&1.op == :move)) == 2
      refute Enum.any?(actions, &(&1.kind == :duplicate))
    end
  end

  describe "hook failures (R2)" do
    test "a parent hook that raises is a failure, not root — project skipped, reported once" do
      project = project!()
      {:ok, _folder} = Storage.create_folder(%{name: "project-#{project.uuid}"})

      Application.put_env(
        :phoenix_kit_projects,
        :attachments_parent_folder,
        {RaisingHook, :parent}
      )

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :project and &1.label == project.name))

      error_action = Enum.find(actions, &(&1.kind == :hook_error))
      refute is_nil(error_action)
      assert error_action.op == :report
      assert error_action.reason =~ "1"
    end

    test "a parent hook returning {:error, _} is a failure, not root" do
      project = project!()
      {:ok, _folder} = Storage.create_folder(%{name: "project-#{project.uuid}"})

      Application.put_env(
        :phoenix_kit_projects,
        :attachments_parent_folder,
        {BadReturnHook, :parent}
      )

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :project and &1.label == project.name))
      assert Enum.any?(actions, &(&1.kind == :hook_error))
    end

    test "a parent hook returning a bare nil is an explicit root, not a failure" do
      project = project!(%{"name" => "Käepide"})
      {:ok, folder} = Storage.create_folder(%{name: "project-#{project.uuid}"})

      Application.put_env(
        :phoenix_kit_projects,
        :attachments_parent_folder,
        {BareNilHook, :parent}
      )

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :hook_error))
      refute Enum.any?(actions, &(&1.kind == :project and &1.label == project.name))
      assert folder.parent_uuid == nil
    end

    test "two failing candidates are counted into one hook_error report" do
      project1 = project!()
      project2 = project!()
      {:ok, _folder1} = Storage.create_folder(%{name: "project-#{project1.uuid}"})
      {:ok, _folder2} = Storage.create_folder(%{name: "project-#{project2.uuid}"})

      Application.put_env(
        :phoenix_kit_projects,
        :attachments_parent_folder,
        {RaisingHook, :parent}
      )

      actions = MediaReorganizer.plan(nil, [])

      error_actions = Enum.filter(actions, &(&1.kind == :hook_error))
      assert length(error_actions) == 1
      assert hd(error_actions).reason =~ "2"
    end
  end

  test "relocated report mentions the hook may still resolve it for other actors (E6)" do
    project = project!()
    {:ok, target} = Storage.create_folder(%{name: "Projects"})
    {:ok, elsewhere} = Storage.create_folder(%{name: "Somewhere else"})

    {:ok, _relocated} =
      Storage.create_folder(%{name: "project-#{project.uuid}", parent_uuid: elsewhere.uuid})

    configure_parent_hook(target.uuid)

    actions = MediaReorganizer.plan(nil, [])
    action = Enum.find(actions, &(&1.kind == :relocated and &1.label == project.name))

    refute is_nil(action)
    assert action.reason =~ "actor"
  end

  test "candidate projects are light-selected — the hook's resource excludes heavy fields (R9)" do
    project = project!(%{"description" => "a very long description that should not be selected"})
    {:ok, target} = Storage.create_folder(%{name: "Projects"})
    {:ok, _folder} = Storage.create_folder(%{name: "project-#{project.uuid}"})

    configure_parent_hook(target.uuid)

    _actions = MediaReorganizer.plan(nil, [])

    resource = Process.get(:last_parent_resource)
    refute is_nil(resource)
    assert resource.uuid == project.uuid
    assert resource.name == project.name
    assert is_nil(resource.description)
  end
end
