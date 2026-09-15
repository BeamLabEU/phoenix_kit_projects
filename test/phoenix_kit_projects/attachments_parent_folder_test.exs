defmodule PhoenixKitProjects.AttachmentsParentFolderTest do
  @moduledoc false
  use PhoenixKitProjects.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Folder
  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{Attachments, Members, Portal, Projects}
  alias PhoenixKitProjects.Schemas.Project

  defmodule Hook do
    @moduledoc false
    def parent(:project, _actor, %Project{}), do: {:ok, Process.get(:parent)}
    def parent(:project, _actor, {:ensure, %Project{}}), do: {:ok, Process.get(:parent)}
    def parent(_kind, _actor, _resource), do: nil

    def name(%Project{}, _actor), do: {:ok, "Project"}
    def name(_resource, _actor), do: nil
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:phoenix_kit_projects, :attachments_parent_folder)
      Application.delete_env(:phoenix_kit_projects, :attachments_folder_name)
    end)

    :ok
  end

  defp project! do
    {:ok, p} =
      Projects.create_project(%{
        "name" => "P #{System.unique_integer([:positive])}",
        "status" => "active",
        "start_mode" => "immediate"
      })

    p
  end

  defp container!(name), do: elem(Storage.create_folder(%{name: name}), 1)

  defp configure_parent_hook(container_uuid) do
    Process.put(:parent, container_uuid)
    Application.put_env(:phoenix_kit_projects, :attachments_parent_folder, {Hook, :parent})
  end

  defp configure_name_hook do
    Application.put_env(:phoenix_kit_projects, :attachments_folder_name, {Hook, :name})
  end

  # ── parent_folder_uuid/2 ──

  test "parent_folder_uuid/2 is nil without config" do
    assert Attachments.parent_folder_uuid(project!(), nil) == nil
  end

  test "parent_folder_uuid/2 consults the host hook when configured" do
    container = container!("Projects")
    configure_parent_hook(container.uuid)

    assert Attachments.parent_folder_uuid(project!(), nil) == container.uuid
  end

  # ── folder_name/2 ──

  test "folder_name/2 falls back to the deterministic name without config" do
    project = project!()
    assert Attachments.folder_name(project, nil) == "project-#{project.uuid}"
  end

  test "folder_name/2 uses the host name hook when configured" do
    configure_name_hook()
    assert Attachments.folder_name(project!(), nil) == "Project"
  end

  # ── ensure_folder/2 ──

  test "ensure_folder/2 creates 'Project' under the configured parent when both hooks are on" do
    container = container!("Projects")
    configure_parent_hook(container.uuid)
    configure_name_hook()

    project = project!()
    assert {:ok, folder_uuid} = Attachments.ensure_folder(project, nil)

    folder = Repo.get!(Folder, folder_uuid)
    assert folder.name == "Project"
    assert folder.parent_uuid == container.uuid
  end

  test "ensure_folder/2 creates 'project-<uuid>' at root when the hooks are off" do
    project = project!()
    assert {:ok, folder_uuid} = Attachments.ensure_folder(project, nil)

    folder = Repo.get!(Folder, folder_uuid)
    assert folder.name == "project-#{project.uuid}"
    assert folder.parent_uuid == nil
  end

  # ── legacy compatibility ──

  test "folder_uuid/2 finds a legacy root folder with hooks on, and ensure_folder/2 does not twin it" do
    container = container!("Projects")
    configure_parent_hook(container.uuid)
    configure_name_hook()

    project = project!()
    {:ok, legacy} = Storage.create_folder(%{name: "project-#{project.uuid}"})

    assert Attachments.folder_uuid(project, nil) == legacy.uuid

    assert {:ok, folder_uuid} = Attachments.ensure_folder(project, nil)
    assert folder_uuid == legacy.uuid

    assert Repo.aggregate(from(f in Folder, where: f.name == ^"project-#{project.uuid}"), :count) ==
             1
  end

  test "folder_uuid/2 is render-safe for a malformed uuid input" do
    refute Attachments.folder_uuid("not-a-real-uuid", nil)
  end

  # ── actor threading (attach_files/3, list_files/2) ──

  test "attach_files/3 attributes a lazily created folder to the given actor" do
    project = project!()

    {:ok, user} =
      Auth.register_user(%{
        "email" => "pf-actor-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    assert :ok = Attachments.attach_files(project.uuid, [], user.uuid)

    folder = Repo.get_by!(Folder, name: "project-#{project.uuid}")
    assert folder.user_uuid == user.uuid
  end

  test "list_files/2 resolves the folder created under a host-configured parent when an actor is given" do
    container = container!("Projects")
    configure_parent_hook(container.uuid)

    project = project!()

    {:ok, user} =
      Auth.register_user(%{
        "email" => "pf-list-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    {:ok, _folder_uuid} = Attachments.ensure_folder(project, user.uuid)

    assert Attachments.list_files(project.uuid, user.uuid) == []
  end

  # ── portal submissions ──

  @tag :tmp_dir
  test "portal: a stored submission attachment lands under <project folder>/Portal submissions when the parent hook is configured",
       %{tmp_dir: dir} do
    container = container!("Projects")
    configure_parent_hook(container.uuid)

    project = project!()

    # An uploaded file needs an owner — core's invariant — and this fixture
    # creates the project without an actor, so it has to say so explicitly
    # (same pattern as portal_access_test.exs).
    {:ok, user} =
      Auth.register_user(%{
        "email" => "pf-owner-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    {:ok, _} = Members.add_member(project, user.uuid, role: "owner")

    path = Path.join(dir, "shot.png")
    {_, 0} = System.cmd("convert", ["-size", "40x40", "xc:red", path], stderr_to_stdout: true)

    assert {:ok, [file_uuid]} =
             Portal.store_attachments([%{path: path, name: "shot.png"}], project.uuid)

    file = Repo.get!(PhoenixKit.Modules.Storage.File, file_uuid)
    refute is_nil(file.folder_uuid)

    submission_folder = Repo.get!(Folder, file.folder_uuid)
    assert submission_folder.name == "Portal submissions"

    project_folder_uuid = Attachments.folder_uuid(project, nil)
    assert submission_folder.parent_uuid == project_folder_uuid
  end
end
