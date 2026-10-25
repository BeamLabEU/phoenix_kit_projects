defmodule PhoenixKitProjects.L10nZoneTest do
  @moduledoc """
  `L10n` prints instants in the viewer's zone (settled per process) and reads
  a typed wall clock in it; with no zone set it is UTC, as before.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitProjects.L10n

  setup do
    on_exit(fn -> L10n.reset_viewer_zone() end)
  end

  @summer ~U[2026-07-01 21:30:00Z]

  test "without a zone, instants print as UTC" do
    L10n.reset_viewer_zone()
    assert L10n.local_time(@summer) == "21:30"
    assert L10n.local_date(@summer) == ~D[2026-07-01]
  end

  test "a viewer's zone shifts every printed instant, across midnight too" do
    L10n.put_viewer_zone(%{user_timezone: "Europe/Tallinn"})

    assert L10n.local_time(@summer) == "00:30"
    assert L10n.local_date(@summer) == ~D[2026-07-02]
    assert L10n.format_month_day_time(@summer) =~ "00:30"
    assert L10n.format_datetime(@summer) =~ "00:30"
    assert L10n.format_date(@summer) =~ "2"
    refute L10n.format_date(@summer) =~ "1,"
  end

  test "a typed wall clock is read in the viewer's zone, and prints back as typed" do
    L10n.put_viewer_zone(%{user_timezone: "Europe/Tallinn"})

    at = L10n.from_wall(~N[2026-07-01 10:00:00])
    assert at == ~U[2026-07-01 07:00:00Z]
    assert L10n.local_time(at) == "10:00"

    # Winter: the same place is UTC+2.
    assert L10n.from_wall(~N[2026-01-15 10:00:00]) == ~U[2026-01-15 08:00:00Z]
  end

  test "reset forgets the zone (an API request after a page on one connection)" do
    L10n.put_viewer_zone(%{user_timezone: "Europe/Tallinn"})
    L10n.reset_viewer_zone()
    assert L10n.local_time(@summer) == "21:30"
  end
end
