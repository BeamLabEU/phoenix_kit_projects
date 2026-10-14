# Claude (Sonnet 5.5) review — PR #50, after the merge (2026-10-14)

PR #50 (`mdon/main`, merge `bfabfef`): documents every session key the hub hands
a contributed extension tab (`Extensions.Extension` moduledoc + AGENTS.md table),
and drops the `Code.ensure_loaded?(PhoenixKit.Activity)` guard from
`ProjectActivityLive.load_page/1`.

## Verified, no change needed

- **The documented session matches the code.** `ProjectShowLive`'s `live_render`
  for an ext tab passes exactly `project_uuid`, `ext_key`, `instance_key`
  (`"default"`), `config`, `can_write`, `locale`, `wrapper_class` (`""`),
  `current_user_uuid`, `mode`, `pubsub_topic`, `frame_ref` and `host_paths`
  (`new_task`). The new `mode` text ("the decoded atom, not the string a host
  passes the hub") matches `@embed_mode`.
- **The dropped guard is dead.** `PhoenixKit.Activity.list/1` ships in the core
  floor (2.54.0, installed 2.62.2), and `load_page/1` keeps its `rescue`, so a
  failing read is still logged and leaves the feed as it was.

## Noted, not changed

- **NITPICK:** the AGENTS.md table and the moduledoc list the same keys in two
  places; the next key added has to touch both. Acceptable — the moduledoc is the
  provider-facing contract, the table is the host-facing one.
