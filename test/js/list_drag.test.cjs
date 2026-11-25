// The card list's drop rule (`PkpListDrag`, phoenix_kit_projects.js):
// where a dropped row lands — its level, parent and the sibling it goes
// after. Run with `node --test test/js` (also from `mix test`, js_hooks_test.exs).
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

// Anything the bundle touches while it loads answers harmlessly: a callable
// object whose every property is another one.
function stub() {
  const f = function () { return stub(); };
  return new Proxy(f, {
    get: (t, k) => (k === Symbol.toPrimitive ? () => "" : k === "then" ? undefined : stub()),
    apply: () => stub()
  });
}

function load() {
  const document = stub();
  const window = { document, addEventListener() {}, removeEventListener() {} };
  window.window = window;
  const ctx = vm.createContext({
    window, document, console, CSS: { escape: (s) => s },
    setTimeout, clearTimeout, MutationObserver: function () { return stub(); },
    getComputedStyle: () => stub(), navigator: stub(), location: stub(), history: stub()
  });
  const src = fs.readFileSync(path.join(__dirname, "../../priv/static/assets/phoenix_kit_projects.js"), "utf8");
  vm.runInContext(src, ctx);
  return window.PhoenixKitProjectsInternals.listDropTarget;
}

// The bundle runs in its own context: plain copies, so its objects compare.
const raw = load();
const target = (...args) => JSON.parse(JSON.stringify(raw(...args)));
const I = 32; // one level, px
const r = (id, depth, extra = {}) => Object.assign({ id, depth, sub: false, folded: false }, extra);

test("a straight drag keeps the level; small sideways jitter too", () => {
  const rows = [r("A", 0), r("X", 0), r("B", 0)];
  assert.deepEqual(target(rows, 1, 0, 0, I), { depth: 0, parent: null, after: "A" });
  assert.deepEqual(target(rows, 1, 0, 10, I), { depth: 0, parent: null, after: "A" });
});

test("right by a level makes it the last subtask of the row above", () => {
  const rows = [r("A", 0), r("X", 0), r("B", 0)];
  assert.deepEqual(target(rows, 1, 0, 40, I), { depth: 1, parent: "A", after: null });
});

test("never deeper than one below the row above", () => {
  const rows = [r("A", 0), r("X", 0)];
  assert.equal(target(rows, 1, 0, 200, I).depth, 1);
});

test("left brings a subtask out to the top level, after its old parent", () => {
  const rows = [r("A", 0), r("A1", 1), r("X", 1), r("B", 0)];
  assert.deepEqual(target(rows, 2, 1, -40, I), { depth: 0, parent: null, after: "A" });
});

test("not shallower than the row below, which would lose its place", () => {
  const rows = [r("A", 0), r("X", 1), r("A1", 1)];
  // X between A and A1: dragging left would put X after A's branch while it
  // sits above A1 — kept at A1's level, a subtask of A.
  assert.deepEqual(target(rows, 1, 1, -80, I), { depth: 1, parent: "A", after: null });
});

test("the very top is the top level, first", () => {
  const rows = [r("X", 1), r("A", 0)];
  assert.deepEqual(target(rows, 0, 1, 0, I), { depth: 0, parent: null, after: null });
});

test("a sub-project's row is never a parent", () => {
  const rows = [r("S", 0, { sub: true }), r("X", 0)];
  assert.deepEqual(target(rows, 1, 0, 64, I), { depth: 0, parent: null, after: "S" });
});

test("into a folded task, as its last subtask", () => {
  const rows = [r("A", 0, { folded: true }), r("X", 0)];
  assert.deepEqual(target(rows, 1, 0, 40, I), { depth: 1, parent: "A", after: "last" });
});

test("between deeper rows, the sibling it goes after is found at its own level", () => {
  const rows = [r("A", 0), r("A1", 1), r("A1a", 2), r("X", 2)];
  assert.deepEqual(target(rows, 3, 2, -40, I), { depth: 1, parent: "A", after: "A1" });
});

test("a dragged row's own subtasks are left out: dropping it in place changes nothing", () => {
  // The hook measures with the branch lifted out of the list.
  const rows = [r("A", 0), r("X", 0), r("B", 0)];
  assert.deepEqual(target(rows, 1, 0, 0, I), { depth: 0, parent: null, after: "A" });
  // With X's subtask X1 still in the list the row below would force a level.
  const unlifted = [r("A", 0), r("X", 0), r("X1", 1), r("B", 0)];
  assert.equal(target(unlifted, 1, 0, 0, I).depth, 1);
});
