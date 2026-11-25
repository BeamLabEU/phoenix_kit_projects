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
  const window = { document, addEventListener() {}, removeEventListener() {}, CSS: { escape: (s) => s } };
  window.window = window;
  const ctx = vm.createContext({
    window, document, console, CSS: { escape: (s) => s },
    setTimeout, clearTimeout, MutationObserver: function () { return stub(); },
    getComputedStyle: () => stub(), navigator: stub(), location: stub(), history: stub()
  });
  const src = fs.readFileSync(path.join(__dirname, "../../priv/static/assets/phoenix_kit_projects.js"), "utf8");
  vm.runInContext(src, ctx);
  loaded = window;
  return window.PhoenixKitProjectsInternals.listDropTarget;
}

let loaded = null;

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


// The preview's card: a top-level card reaches into the arrows' gutter
// (`pkp-row-card`, -2rem) and a subtask's does not. The card keeps the class
// of the level it will land at, or the indent was cancelled (Max,
// 2026-11-25: "they aren't deep enough").
function fakeClassList(initial) {
  const set = new Set(initial);
  return {
    contains: (c) => set.has(c),
    add: (c) => set.add(c),
    remove: (c) => set.delete(c),
    toggle: (c, on) => (on ? set.add(c) : set.delete(c)),
    has: (c) => set.has(c)
  };
}

function previewAt(depth, cardClasses) {
  const hook = loaded.PhoenixKitProjectsHooks.PkpListDrag;
  const card = { classList: fakeClassList(cardClasses) };
  const item = { style: { marginLeft: "" } };
  const self = {
    el: { querySelector: () => null, querySelectorAll: () => [] },
    dragging: { item, nest: true, card, rowCard: cardClasses.includes("pkp-row-card") },
    target: () => ({ depth, parent: depth > 0 ? "P" : null, after: null }),
    clearParentMark: hook.clearParentMark
  };
  hook.preview.call(self);
  return { margin: item.style.marginLeft, rowCard: card.classList.has("pkp-row-card") };
}

test("a top-level card previewed one level in drops its gutter reach", () => {
  assert.deepEqual(previewAt(1, ["card", "pkp-row-card"]), { margin: "2rem", rowCard: false });
});

test("a subtask previewed at the top level takes the gutter reach", () => {
  assert.deepEqual(previewAt(0, ["card"]), { margin: "0rem", rowCard: true });
});


// The drop itself is optimistic (Max, 2026-11-25: dropping a task showed it
// "in its old place for a bit and then it going to the new place"): a drop
// that moves leaves every row as the server will draw it — the card at its
// new level, the subtasks it carried right under it, shifted by as many
// levels — and a refusal puts each row back as it was.
function fakeList(spec) {
  const list = { children: [] };
  const at = (n) => list.children.indexOf(n);
  list.insertBefore = (n, ref) => {
    const i = at(n);
    if (i >= 0) list.children.splice(i, 1);
    const j = ref ? at(ref) : -1;
    list.children.splice(j >= 0 ? j : list.children.length, 0, n);
  };
  const rows = spec.map(([id, depth]) => {
    const card = { classList: fakeClassList(depth === 0 ? ["card", "pkp-row-card"] : ["card"]) };
    const row = {
      id,
      dataset: { id, depth: String(depth) },
      style: { marginLeft: depth * 2 + "rem" },
      classList: fakeClassList([]),
      isConnected: true,
      querySelector: () => card,
      card,
      after(n) {
        const i = at(n);
        if (i >= 0) list.children.splice(i, 1);
        list.children.splice(at(row) + 1, 0, n);
      }
    };
    list.children.push(row);
    return row;
  });
  const byId = Object.fromEntries(rows.map((x) => [x.id, x]));
  const state = () =>
    list.children.map((x) => `${x.id}:${x.dataset.depth}:${x.style.marginLeft}:${x.card.classList.has("pkp-row-card") ? "gutter" : "-"}`);
  return { list, byId, state };
}

const internals = () => loaded.PhoenixKitProjectsInternals;

test("a drop that nests leaves the card and its branch as the server draws them", () => {
  // A, B (with subtask B1), C — B dragged under A, B1 carried along.
  const { list, byId, state } = fakeList([["A", 0], ["B", 0], ["B1", 1], ["C", 0]]);
  const { saveRowLevel, landListMove } = internals();
  const B = byId.B;
  const d = { item: B, start: { id: "B", depth: 0 }, lifted: [byId.B1], savedItem: saveRowLevel(B) };
  // While dragging the branch's row is out of the list; the card sits after A.
  list.children.splice(list.children.indexOf(byId.B1), 1);
  list.children.push(byId.B1); // wherever the lift left it
  landListMove(d, { depth: 1, parent: "A", after: null });
  assert.deepEqual(state(), ["A:0:0rem:gutter", "B:1:2rem:-", "B1:2:4rem:-", "C:0:0rem:gutter"]);
});

test("a refused drop puts every row back at its old place and level", () => {
  const { list, byId, state } = fakeList([["A", 0], ["B", 0], ["B1", 1], ["C", 0]]);
  const { saveRowLevel, landListMove, revertListMove } = internals();
  const before = state();
  const B = byId.B;
  // As onStart records it: the row after the whole branch.
  const last = { item: B, prev: byId.A, next: byId.C, index: 1 };
  const d = { item: B, start: { id: "B", depth: 0 }, lifted: [byId.B1], savedItem: saveRowLevel(B) };
  // Dragged below C, out one level would be impossible; take: B after C, nested under C.
  list.insertBefore(B, null);
  last.saved = landListMove(d, { depth: 1, parent: "C", after: null });
  assert.deepEqual(state(), ["A:0:0rem:gutter", "C:0:0rem:gutter", "B:1:2rem:-", "B1:2:4rem:-"]);
  revertListMove(list, last);
  assert.deepEqual(state(), before);
});

test("a subtask dropped out to the top level takes the gutter reach", () => {
  const { list, byId, state } = fakeList([["A", 0], ["A1", 1], ["B", 0]]);
  const { saveRowLevel, landListMove } = internals();
  const A1 = byId.A1;
  const d = { item: A1, start: { id: "A1", depth: 1 }, lifted: [], savedItem: saveRowLevel(A1) };
  list.insertBefore(A1, null); // dropped last
  landListMove(d, { depth: 0, parent: null, after: "B" });
  assert.deepEqual(state(), ["A:0:0rem:gutter", "B:0:0rem:gutter", "A1:0:0rem:gutter"]);
});
