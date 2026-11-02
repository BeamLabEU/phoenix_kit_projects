defmodule PhoenixKitProjects.BatchedReadsTest do
  @moduledoc """
  The per-item reads the 2026-09-05 N+1 audit found on hot paths (page
  mounts, broadcasts, refresh ticks), each replaced by a grouped read.
  Every test pins two things: the batched answer equals the per-item one,
  and the statement count does not grow with the number of items.
  """

  use PhoenixKitProjects.DataCase, async: false

  alias PhoenixKitProjects.{
    Attachments,
    Extensions,
    Features,
    Grants,
    Portal,
    Projects,
    QueryCounter
  }

  alias PhoenixKit.Modules.Storage.{File, FileInstance, Library}
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.LiveCase
  alias PhoenixKitProjects.Test.Repo

  describe "Extensions.enabled_map/1" do
    test "answers like enabled?/3 for every extension, from one rows read" do
      project = fixture_project()
      {:ok, _} = Extensions.enable(project, "whiteboards")
      {:ok, _} = Extensions.disable(project, "files")

      {map, queries} = QueryCounter.count(fn -> Extensions.enabled_map(project.uuid) end)
      assert queries == 1

      for ext <- Extensions.list_types() do
        assert Map.fetch!(map, ext.key) == Extensions.enabled?(project, ext.key),
               "#{ext.key} disagrees with enabled?/3"
      end

      assert map["whiteboards"] == true
      assert map["files"] == false
      assert map["tasks"] == true
    end
  end

  describe "Features.gates/1 and flags/1" do
    test "resolve every flag from one context — two reads, not one per flag and hop" do
      project = fixture_project()
      {:ok, project} = Features.set_flags(project, %{"assignees" => false, "estimates" => false})

      {gates, q_gates} = QueryCounter.count(fn -> Features.gates(project) end)
      # The extension map (one read) and the site's feature defaults (one
      # batch read, cached in production); the flag values ride on the struct.
      assert q_gates <= 2

      # Same answer as the per-flag path, for every gate.
      for {gate, value} <- gates, gate != :tasks do
        assert value == Features.on?(project, to_string(gate)), "#{gate} disagrees with on?/2"
      end

      assert gates.assignees == false
      # `scheduling` requires `estimates`, which is off: the requires hop
      # resolves from the same context.
      assert gates.scheduling == false
      assert gates.tasks == true

      {flags, q_flags} = QueryCounter.count(fn -> Features.flags(project) end)
      assert q_flags <= 2
      assert flags["assignees"] == false
      assert flags["labels"] == true
      assert map_size(flags) == map_size(Features.catalog())
    end

    test "a bare uuid costs one more read (the settings row), still not one per flag" do
      project = fixture_project()
      {_, queries} = QueryCounter.count(fn -> Features.gates(project.uuid) end)
      assert queries <= 3
    end

    test "tasks off turns every task flag off in one go" do
      project = fixture_project()
      {:ok, _} = Extensions.disable(project, "tasks")
      gates = Features.gates(project)
      refute Enum.any?(gates, fn {_gate, on?} -> on? end)
    end
  end

  describe "Projects.list_all_dependencies/1 over a list" do
    test "the list form returns the union of the per-project reads in one statement" do
      p1 = fixture_project(%{"name" => "Deps 1"})
      p2 = fixture_project(%{"name" => "Deps 2"})

      for p <- [p1, p2] do
        [a, b] =
          for title <- ["first", "second"] do
            task = fixture_task(%{"title" => "#{p.name} #{title}"})

            {:ok, a} =
              Projects.create_assignment(%{"project_uuid" => p.uuid, "task_uuid" => task.uuid})

            a
          end

        {:ok, _} = Projects.add_dependency(b.uuid, a.uuid)
      end

      {both, queries} =
        QueryCounter.count(fn -> Projects.list_all_dependencies([p1.uuid, p2.uuid]) end)

      {one, q_one} = QueryCounter.count(fn -> Projects.list_all_dependencies([p1.uuid]) end)
      assert queries == q_one

      singles = Projects.list_all_dependencies(p1.uuid) ++ Projects.list_all_dependencies(p2.uuid)
      assert Enum.sort(Enum.map(both, & &1.uuid)) == Enum.sort(Enum.map(singles, & &1.uuid))
      assert length(one) == 1
    end
  end

  describe "Portal.review_details_for/1" do
    test "an assignment without a submission gets the empty details; the map covers every input" do
      task = fixture_task()
      project = fixture_project()

      {:ok, a} =
        Projects.create_assignment(%{"project_uuid" => project.uuid, "task_uuid" => task.uuid})

      details = Portal.review_details_for([a.uuid])
      assert details == %{a.uuid => %{images: [], submitted_by: nil}}
      assert Portal.review_details_for([]) == %{}
    end
  end

  describe "Grants.subject_reaches/1" do
    test "counts every team and department in fixed reads, matching subject_reach/2" do
      n = System.unique_integer([:positive])
      {:ok, dept} = PhoenixKitStaff.Departments.create(%{"name" => "Reach dept #{n}"})

      teams =
        for i <- 1..3 do
          {:ok, team} =
            PhoenixKitStaff.Teams.create(%{
              "name" => "Reach team #{n}-#{i}",
              "department_uuid" => dept.uuid
            })

          team
        end

      grants =
        Enum.map(teams, &%{subject_type: "team", subject_uuid: &1.uuid}) ++
          [%{subject_type: "department", subject_uuid: dept.uuid}]

      {reaches, queries} = QueryCounter.count(fn -> Grants.subject_reaches(grants) end)
      {_, q_one} = QueryCounter.count(fn -> Grants.subject_reaches(Enum.take(grants, 1)) end)

      # Teams: one grouped read whether one team or three.
      assert queries <= q_one + 1

      for g <- grants do
        assert Map.fetch!(reaches, {g.subject_type, g.subject_uuid}) ==
                 Grants.subject_reach(g.subject_type, g.subject_uuid)
      end
    end
  end

  describe "Assignees.recent_for_viewer/4" do
    defp staff_person!(name) do
      {:ok, user} =
        Auth.register_user(%{
          "email" => "#{name}-#{System.unique_integer([:positive])}@example.com",
          "password" => "ValidPassword123!"
        })

      Repo.insert!(%PhoenixKitStaff.Schemas.Person{
        user_uuid: user.uuid,
        status: "active",
        name: name
      })
    end

    test "reads do not grow with the chips" do
      me = LiveCase.embed_user_uuid!()
      project = fixture_project()

      count = fn n ->
        Repo.update_all(PhoenixKit.Users.Auth.User |> Ecto.Query.where(uuid: ^me),
          set: [custom_fields: %{}]
        )

        for i <- 1..n do
          PhoenixKitProjects.Assignees.remember_pick(
            me,
            "person",
            staff_person!("p#{n}-#{i}").uuid
          )
        end

        {rows, queries} =
          QueryCounter.count(fn ->
            PhoenixKitProjects.Assignees.recent_for_viewer(me, project.uuid, 8)
          end)

        assert length(rows) == n
        queries
      end

      one = count.(1)
      six = count.(6)
      assert six <= one, "#{six} reads for six chips, #{one} for one"
    end
  end

  describe "Attachments.download_urls/1" do
    defp stored_file!(owner_uuid, attrs \\ %{}) do
      n = System.unique_integer([:positive])

      file =
        %File{}
        |> Ecto.Changeset.change(
          Map.merge(
            %{
              user_uuid: owner_uuid,
              original_file_name: "spec.pdf",
              file_name: "spec-#{n}.pdf",
              file_path: "/tmp/spec-#{n}.pdf",
              ext: "pdf",
              file_type: "document",
              mime_type: "application/pdf",
              file_checksum: "dl-checksum-#{n}",
              user_file_checksum: "dl-user-checksum-#{n}",
              size: 123,
              status: "active"
            },
            attrs
          )
        )
        |> Repo.insert!()

      %FileInstance{}
      |> Ecto.Changeset.change(%{
        variant_name: "original",
        file_name: "dl/#{n}/spec-#{n}.pdf",
        mime_type: "application/pdf",
        ext: "pdf",
        checksum: "dl-instance-#{n}",
        size: 123,
        file_uuid: file.uuid
      })
      |> Repo.insert!()

      file
    end

    test "answers what core's per-file rule answers, in reads that do not grow with the files" do
      owner = LiveCase.embed_user_uuid!()
      ordinary = stored_file!(owner)
      editing = stored_file!(owner, %{edit_state: "pending"})
      hidden = stored_file!(owner, %{system_managed: true})

      library =
        %Library{}
        |> Ecto.Changeset.change(%{
          name: "Private",
          key_prefix: "pk-#{System.unique_integer([:positive])}",
          slug: "private-#{System.unique_integer([:positive])}",
          kind: "user",
          visibility: "private",
          owner_uuid: owner
        })
        |> Repo.insert!()

      private = stored_file!(owner, %{library_uuid: library.uuid})
      files = [ordinary, editing, hidden, private]

      urls = Attachments.download_urls(files)

      # The reads the module owns (instances, library privacy) are fixed;
      # `Manager.public_url/2` resolves the bucket per file in core, so the
      # count is taken over files the app serves itself.
      {_, q_one} = QueryCounter.count(fn -> Attachments.download_urls([private]) end)

      {_, q_three} =
        QueryCounter.count(fn -> Attachments.download_urls([private, editing, hidden]) end)

      assert q_three <= q_one

      # Core's rule, file by file: a hidden original gets no link; a file
      # mid-edit is served by the app (never the bucket's object URL).
      for file <- files -- [private] do
        assert Map.get(urls, file.uuid) == Attachments.download_url(file)
      end

      # A private library's file: the time-window token, which the file
      # route takes (its permanent one is refused) — on both paths.
      for url <- [urls[private.uuid], Attachments.download_url(private)] do
        [token] = Regex.run(~r{/original/([^/?]+)}, url, capture: :all_but_first)
        assert URLSigner.private_token?(token)
      end

      refute Map.has_key?(urls, hidden.uuid)
      assert is_binary(urls[editing.uuid])
      assert is_binary(urls[private.uuid])
      assert Attachments.download_urls([]) == %{}
    end
  end
end
