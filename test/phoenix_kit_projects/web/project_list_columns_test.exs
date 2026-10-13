defmodule PhoenixKitProjects.Web.ProjectListColumnsTest do
  @moduledoc """
  The projects list's sorting and filtering over read values
  (`Web.ProjectListColumns`): pure, so pinned without a database.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitProjects.Schemas.Project
  alias PhoenixKitProjects.Web.ProjectListColumns, as: Columns

  defp project(name, attrs \\ %{}) do
    struct!(
      Project,
      Map.merge(
        %{
          uuid: Ecto.UUID.generate(),
          name: name,
          position: 0,
          settings: %{},
          start_mode: "immediate",
          is_template: false
        },
        attrs
      )
    )
  end

  defp names(projects), do: Enum.map(projects, & &1.name)

  @no_filters %{state: "", who: "", overdue: false, ext_col: "", ext_val: ""}

  describe "the roster" do
    test "every column id is unique, and every sort a column names is whitelisted" do
      ids = Enum.map(Columns.specs(), & &1.id)
      assert ids == Enum.uniq(ids)

      for %{sort: sort} <- Columns.specs(), sort != nil do
        assert sort in Columns.sort_fields()
      end

      assert Enum.all?(Columns.default_columns(), &(&1 in ids))
    end

    test "families_for names the reads behind the visible columns, each once" do
      assert Columns.families_for(~w(status created)) == []

      assert Columns.families_for(~w(progress tasks hours ext:crm_client:client overdue)) ==
               [:tasks, :ledger, :ext, :due]
    end

    test "the database orders only the four plain sorts" do
      assert Enum.filter(Columns.sort_fields(), &Columns.sql_sort?/1) ==
               ~w(position name inserted_at updated_at)a
    end
  end

  describe "sort/5" do
    test "numbers ascend and descend, and a project with no value is last both ways" do
      a = project("A")
      b = project("B")
      c = project("C")

      metrics = %{
        tasks: %{
          a.uuid => %{has_work: true, progress_pct: 80},
          b.uuid => %{has_work: true, progress_pct: 20},
          c.uuid => %{has_work: false, progress_pct: 0}
        }
      }

      assert names(Columns.sort([a, b, c], :progress, :asc, metrics)) == ~w(B A C)
      assert names(Columns.sort([c, b, a], :progress, :desc, metrics)) == ~w(A B C)
    end

    test "dates compare as dates, not as structs" do
      early = project("Early", %{started_at: ~U[2026-01-31 10:00:00Z]})
      late = project("Late", %{started_at: ~U[2026-02-01 09:00:00Z]})
      never = project("Never")

      assert names(Columns.sort([late, never, early], :started, :asc, %{})) ==
               ~w(Early Late Never)

      assert names(Columns.sort([early, never, late], :started, :desc, %{})) ==
               ~w(Late Early Never)
    end

    test "text ignores case, and ties fall back to the name" do
      a = project("alpha")
      b = project("Beta")
      c = project("gamma")
      metrics = %{creators: %{a.uuid => "zoe", b.uuid => "Adam", c.uuid => "adam"}}

      assert names(Columns.sort([a, c, b], :created_by, :asc, metrics)) == ~w(Beta gamma alpha)
    end

    test "an extension column sorts by its text" do
      a = project("A")
      b = project("B")
      c = project("C")

      metrics = %{
        ext: [
          %{
            id: "ext:crm_client:client",
            values: %{a.uuid => %{text: "Zeta OÜ", url: nil}, b.uuid => %{text: "ANDI", url: nil}}
          }
        ]
      }

      assert names(Columns.sort([a, b, c], :ext, :asc, metrics, "ext:crm_client:client")) ==
               ~w(B A C)

      # a column nobody loaded orders by name
      assert names(Columns.sort([c, b, a], :ext, :asc, metrics, "ext:other:x")) == ~w(A B C)
    end

    test "state orders running before not started before completed" do
      running = project("R", %{started_at: ~U[2026-01-01 00:00:00Z]})
      setup = project("S")

      done =
        project("D", %{
          started_at: ~U[2026-01-01 00:00:00Z],
          completed_at: ~U[2026-02-01 00:00:00Z]
        })

      assert names(Columns.sort([done, setup, running], :state, :asc, %{})) == ~w(R S D)
    end
  end

  describe "hours" do
    test "people's time, an agent's and the two together each sort by their own figure" do
      a = project("A")
      b = project("B")

      metrics = %{
        ledger: %{
          a.uuid => %{minutes: 60.0, ai_minutes: 0.0},
          b.uuid => %{minutes: 10.0, ai_minutes: 300.0}
        }
      }

      assert Columns.total_minutes(metrics, b) == 310.0
      assert Columns.total_minutes(%{}, a) == 0.0
      assert names(Columns.sort([a, b], :hours, :desc, metrics)) == ["A", "B"]
      assert names(Columns.sort([a, b], :ai_hours, :desc, metrics)) == ["B", "A"]
      assert names(Columns.sort([a, b], :total_hours, :desc, metrics)) == ["B", "A"]
    end
  end

  describe "filter/4" do
    test "no filter passes everything" do
      projects = [project("A"), project("B")]
      assert Columns.filter(projects, @no_filters, %{}, nil) == projects
      assert Columns.active_count(@no_filters) == 0
    end

    test "state and kind read the project itself" do
      running = project("R", %{started_at: ~U[2026-01-01 00:00:00Z]})
      ongoing = project("O", %{settings: %{"completion" => "manual"}})

      assert names(
               Columns.filter([running, ongoing], %{@no_filters | state: "running"}, %{}, nil)
             ) ==
               ["R"]

      assert names(
               Columns.filter([running, ongoing], %{@no_filters | state: "ongoing"}, %{}, nil)
             ) ==
               ["O"]
    end

    test "mine and a named person read the members; nobody signed in has no projects of theirs" do
      mine = project("Mine")
      theirs = project("Theirs")
      me = Ecto.UUID.generate()
      them = Ecto.UUID.generate()

      metrics = %{
        members: %{
          mine.uuid => %{count: 1, people: [%{uuid: me, name: "Me", role: "owner"}]},
          theirs.uuid => %{count: 1, people: [%{uuid: them, name: "Them", role: "member"}]}
        }
      }

      filters = %{@no_filters | who: "mine"}
      assert names(Columns.filter([mine, theirs], filters, metrics, me)) == ["Mine"]
      assert Columns.filter([mine, theirs], filters, metrics, nil) == []

      assert names(Columns.filter([mine, theirs], %{@no_filters | who: them}, metrics, me)) ==
               ["Theirs"]

      assert Columns.filter_families(filters) == [:members]
      assert Columns.people_options(metrics) == [{"Me", me}, {"Them", them}]
      assert Columns.owners(mine, metrics) == ["Me"]
    end

    test "overdue and an extension value read their families, and combine" do
      a = project("A")
      b = project("B")
      c = project("C")

      col = %{
        id: "ext:crm_client:client",
        values: %{a.uuid => %{text: "ANDI", url: nil}, b.uuid => %{text: "ANDI", url: nil}}
      }

      metrics = %{
        due: %{a.uuid => %{overdue: 2, next_due: nil}, c.uuid => %{overdue: 1, next_due: nil}},
        ext: [col]
      }

      client = %{@no_filters | ext_col: col.id, ext_val: "ANDI"}
      assert names(Columns.filter([a, b, c], client, metrics, nil)) == ~w(A B)

      assert names(Columns.filter([a, b, c], %{@no_filters | overdue: true}, metrics, nil)) ==
               ~w(A C)

      assert names(Columns.filter([a, b, c], %{client | overdue: true}, metrics, nil)) == ["A"]

      assert Columns.active_count(%{client | overdue: true}) == 2
      assert Columns.filter_families(%{client | overdue: true}) == [:due, :ext]
      assert Columns.ext_options(col) == ["ANDI"]
      # half an extension filter is no filter
      assert Columns.active_count(%{@no_filters | ext_col: col.id}) == 0
    end
  end
end
