defmodule PhoenixKitProjects.LibrarySearchTest do
  @moduledoc """
  The library searched as a title is typed (`LibrarySearch.suggest/2`):
  the reusable library only, never a project's one-off tasks, the titles
  that start with the words first.
  """

  use PhoenixKitProjects.DataCase, async: true

  alias PhoenixKitProjects.LibrarySearch

  defp titles(tasks), do: Enum.map(tasks, & &1.title)

  test "library titles that contain the words, the ones starting with them first" do
    tag = "Zq#{System.unique_integer([:positive])}"
    fixture_task(%{"title" => "Measure the #{tag} wall"})
    fixture_task(%{"title" => "#{tag} worktop fitting"})
    fixture_task(%{"title" => "Unrelated"})

    assert titles(LibrarySearch.suggest(tag)) == [
             "#{tag} worktop fitting",
             "Measure the #{tag} wall"
           ]

    assert titles(LibrarySearch.suggest(String.downcase(tag))) |> length() == 2
  end

  test "a project's one-off tasks are never offered" do
    tag = "Yq#{System.unique_integer([:positive])}"
    fixture_task(%{"title" => "#{tag} in the library"})
    fixture_task(%{"title" => "#{tag} typed in a project", "ad_hoc" => true})

    assert titles(LibrarySearch.suggest(tag)) == ["#{tag} in the library"]
  end

  test "a translated title matches too" do
    tag = "Xq#{System.unique_integer([:positive])}"

    task =
      fixture_task(%{
        "title" => "Install the sink",
        "translations" => %{"et" => %{"title" => "Paigalda #{tag} valamu"}}
      })

    assert [found] = LibrarySearch.suggest(tag)
    assert found.uuid == task.uuid
  end

  test "under two characters, wildcards and the limit" do
    fixture_task(%{"title" => "A"})
    assert LibrarySearch.suggest("A") == []
    assert LibrarySearch.suggest(nil) == []
    assert LibrarySearch.suggest("%%") == []

    tag = "Wq#{System.unique_integer([:positive])}"
    for i <- 1..4, do: fixture_task(%{"title" => "#{tag} #{i}"})
    assert length(LibrarySearch.suggest(tag, limit: 2)) == 2
    [first | _] = LibrarySearch.suggest(tag)
    refute first.uuid in Enum.map(LibrarySearch.suggest(tag, exclude: [first.uuid]), & &1.uuid)
  end
end
