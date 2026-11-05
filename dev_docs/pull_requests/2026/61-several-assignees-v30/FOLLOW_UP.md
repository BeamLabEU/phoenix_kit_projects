# Follow-up — PR #61

2026-11-05: how Claude's findings (`CLAUDE_REVIEW.md`) were resolved.

- **Fixed, with a test that fails when the fix is reverted:** MEDIUM, `GET /project` naming assignees `null`.
- **Fixed, no test:** CRITICAL, the compile failure on OTP 29 (the compile is the check). IMPROVEMENT, the
  briefing's per-row read (behaviour held by the existing test).
- **Left, recorded:** the two NITPICKs, `assign_type` from the mirror and the `default.pot` drift.

Gate on the tree with #62 merged: see `../62-fresh-core3-chain/FOLLOW_UP.md`.
