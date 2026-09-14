# Whiteboards

How a project's drawing boards are stored and rendered, and what a board's
shapes are anchored to.

Rules for this live in [AGENTS.md](../../AGENTS.md) → Feature notes.

A board is its row (`phoenix_kit_project_whiteboards`); its shapes are core
annotation rows anchored to the board — `target_type: "projects_whiteboard"`,
`target_uuid: board.uuid` (`Whiteboards.target_type/0`) — and drawn by
core's `MediaCanvasViewer` in **board mode**
(`board={Whiteboards.viewer_board(board)}`: an empty, infinite Fresco canvas
with the Etcher tools; no file, no Storage, no folder). The older **blank-background
bridge** (a salted white PNG per board registered as a Storage file and drawn
over as a photo) is gone from `create/3`.

`file_uuid` is nullable: boards made by the bridge, and boards over a real
image (`create_board_for_file/3`), keep their file and render through the
file viewer exactly as before — the tab LV picks by `file_uuid`. Deleting a
file-less board deletes its shapes
(`PhoenixKit.Annotations.delete_for_target/2`); a file-backed board's shapes
stay with the file.

The board surface is a contributed tab from the built-in `whiteboards`
extension, which is **off by default** — drawing boards are an opt-in
capability, not part of the base task surface. The extension declares its tab
through the same provider contract external modules use.

**Core gate:** annotations anchored by `target_type` / `target_uuid`, the
polymorphic `EtcherAdapter`, and the viewer's `:board` assign. Below the core
floor recorded in `mix.exs`, `Whiteboards.delete/2` raises.
