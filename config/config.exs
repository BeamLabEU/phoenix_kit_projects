import Config

# This module wires phoenix_live_calendar's CSS via `css_sources/0` (core's
# Tailwind sources compiler), not the package's own `mix phoenix_live_calendar.install`
# @source line — so silence its compile-time "CSS not detected" check, which only
# knows how to look for that line. (Mirrors the host-side config.)
config :phoenix_live_calendar, skip_install_check: true

if config_env() == :test do
  import_config "test.exs"
end
