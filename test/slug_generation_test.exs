defmodule PhoenixKitProjects.SlugGenerationTest do
  @moduledoc """
  Slug generation goes through core, not a local ASCII-only pipeline.

  ## Why this asserts so little

  The obvious test — `assert slug("Видеопродакшн") == "videoprodakshn"` — is
  **version-dependent and merges red**. What core returns depends on which
  `phoenix_kit` this module resolves, and the lockfile here pins one that predates
  the `:transliterate` option entirely, so non-ASCII is stripped no matter what this
  module passes. phoenix_kit_dashboards#5 shipped exactly that mistake and had to be
  repaired after merge.

  So this pins only what holds at every core version. The non-ASCII cases start
  working on their own once core ships the locale-aware `Slug` **and** this module's
  floor moves to it — see the PR description for that ordering.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitProjects.Schemas.ProjectStatus

  test "ASCII slugs are unchanged" do
    assert ProjectStatus.slugify("In Progress") == "in-progress"
    assert ProjectStatus.slugify("Blocked") == "blocked"
  end

  test "separators collapse and trim" do
    assert ProjectStatus.slugify("  In   Progress  ") == "in-progress"
    refute String.ends_with?(ProjectStatus.slugify("Done !!"), "-")
  end
end
