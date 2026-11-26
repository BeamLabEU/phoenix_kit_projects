// The night review of PR #66 (grok, 2026-11-26): a refused drop next to a
// row another session added, and a reconnect's plain-field restore over a
// newer server value. Harness from grok's proof file.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

function stub() {
  const f = function () { return stub(); };
  return new Proxy(f, {
    get: (t, k) => (k === Symbol.toPrimitive ? () => "" : k === "then" ? undefined : stub()),
    apply: () => stub()
  });
}

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

function loadList() {
  const document = stub();
  const window = { document, addEventListener() {}, removeEventListener() {}, CSS: { escape: (s) => s } };
  window.window = window;
  const ctx = vm.createContext({
    window, document, console, CSS: { escape: (s) => s },
    setTimeout, clearTimeout, MutationObserver: function () { return stub(); },
    getComputedStyle: () => stub(), navigator: stub(), location: stub(), history: stub()
  });
  vm.runInContext(
    fs.readFileSync(path.join(__dirname, "../../priv/static/assets/phoenix_kit_projects.js"), "utf8"),
    ctx
  );
  return window.PhoenixKitProjectsInternals;
}

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
    const card = { classList: fakeClassList(["card", "pkp-row-card"]) };
    const row = {
      id,
      dataset: { id, depth: String(depth), folded: "false" },
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
  const ids = () => list.children.map((x) => x.id);
  return { list, byId, ids };
}

const I = loadList();


test("a refusal keeps a row that arrived between the card and its old next sibling", () => {
  // Drag of B started on A, B, C (next = C). The refusal's redraw drew
  // A, B, X, C before the revert ran: that order stays.
  const { list, byId, ids } = fakeList([["A", 0], ["B", 0], ["X", 0], ["C", 0]]);
  // `others`: the rows besides the card when the drag began.
  const others = [byId.A, byId.C];
  I.revertListMove(list, { item: byId.B, prev: byId.A, next: byId.C, index: 1, others, saved: [I.saveRowLevel(byId.B)] });
  assert.deepEqual(ids(), ["A", "B", "X", "C"]);
});

test("a refusal keeps a row that arrived between a moved branch and the row after it", () => {
  const { list, byId, ids } = fakeList([["A", 0], ["B", 0], ["B1", 1], ["X", 0], ["C", 0]]);
  const saved = [I.saveRowLevel(byId.B), I.saveRowLevel(byId.B1)];
  I.revertListMove(list, { item: byId.B, prev: byId.A, next: byId.C, index: 1, others: [byId.A, byId.C], saved });
  assert.deepEqual(ids(), ["A", "B", "B1", "X", "C"]);
});

test("a refusal keeps a row the redraw put inside the card's old branch", () => {
  // grok's re-review: A, B, B1, C at the start; redrawn A, B, X, B1, C.
  const { list, byId, ids } = fakeList([["A", 0], ["B", 0], ["X", 1], ["B1", 1], ["C", 0]]);
  const saved = [I.saveRowLevel(byId.B), I.saveRowLevel(byId.B1)];
  I.revertListMove(list, { item: byId.B, prev: byId.A, next: byId.C, index: 1, others: [byId.A, byId.C], saved });
  assert.deepEqual(ids(), ["A", "B", "X", "B1", "C"]);
});

test("a refusal after a redraw that removed a neighbour leaves the server's order", () => {
  // A gone, X added: B, X, C stays B, X, C.
  const { list, byId, ids } = fakeList([["B", 0], ["X", 0], ["C", 0]]);
  const A = { id: "A", isConnected: false };
  I.revertListMove(list, { item: byId.B, prev: A, next: byId.C, index: 1, others: [A, byId.C], saved: [I.saveRowLevel(byId.B)] });
  assert.deepEqual(ids(), ["B", "X", "C"]);
});

test("a refusal with no redraw still puts the card back between its neighbours", () => {
  // B dropped below C, nothing redrawn: A, C, B goes back to A, B, C.
  const { list, byId, ids } = fakeList([["A", 0], ["C", 0], ["B", 0]]);
  I.revertListMove(list, { item: byId.B, prev: byId.A, next: byId.C, index: 1, others: [byId.A, byId.C], saved: [I.saveRowLevel(byId.B)] });
  assert.deepEqual(ids(), ["A", "B", "C"]);
});

function el(attrs = {}, children = []) {
  const node = {
    attrs: Object.assign({}, attrs),
    children,
    value: attrs.value,
    dataset: {},
    getAttribute: (k) => (k in node.attrs ? node.attrs[k] : null),
    querySelector: (sel) => node.querySelectorAll(sel)[0] || null,
    querySelectorAll: (sel) => {
      const out = [];
      const walk = (n) => n.children.forEach((c) => { if (matches(c, sel)) out.push(c); walk(c); });
      walk(node);
      return out;
    }
  };
  if (attrs["data-editor-id"]) node.dataset.editorId = attrs["data-editor-id"];
  return node;
}

function matches(n, sel) {
  let m;
  if ((m = sel.match(/^\[data-editor-id(?:="([^"]+)")?\]$/))) return m[1] ? n.attrs["data-editor-id"] === m[1] : "data-editor-id" in n.attrs;
  if ((m = sel.match(/^input\[type="hidden"\]\[data-leaf-sync-input="([^"]+)"\]$/))) return n.attrs.type === "hidden" && n.attrs["data-leaf-sync-input"] === m[1];
  if (sel === "[data-editor-visual]") return "data-editor-visual" in n.attrs;
  if (sel === "form[phx-change]" || sel === ".phx-connected form[phx-change]") return n.attrs.tag === "form";
  if ((m = sel.match(/^\[name="([^"]+)"\]$/))) return n.attrs.name === m[1];
  if (sel === "[data-pkp-kept-note]") return "data-pkp-kept-note" in n.attrs;
  if (sel === "[data-pkp-apply-kept]") return "data-pkp-apply-kept" in n.attrs;
  return false;
}

function loadKeep(dialogs) {
  const listeners = {};
  const rawDocument = {
    body: null,
    addEventListener() {},
    querySelectorAll: (sel) => (sel === "dialog[data-frame-ref]" ? dialogs : [])
  };
  const document = new Proxy(rawDocument, {
    get: (t, k) => (k in t ? t[k] : stub())
  });
  const window = {
    document,
    addEventListener(type, fn) { (listeners[type] = listeners[type] || []).push(fn); },
    removeEventListener() {},
    dispatchEvent(e) {
      (listeners[e.type] || []).forEach((fn) => fn(e));
      return true;
    },
    CSS: { escape: (s) => s }
  };
  window.window = window;
  function CustomEvent(type, init) { this.type = type; this.detail = init && init.detail; }
  const ctx = vm.createContext({
    window, document, console, CustomEvent,
    Event: function (type, init) { this.type = type; this.bubbles = init && init.bubbles; },
    CSS: { escape: (s) => s },
    setTimeout, clearTimeout, MutationObserver: function () { return stub(); },
    getComputedStyle: () => stub(), navigator: stub(), location: stub(), history: stub()
  });
  vm.runInContext(
    fs.readFileSync(path.join(__dirname, "../../priv/static/assets/phoenix_kit_projects.js"), "utf8"),
    ctx
  );
  return { api: window.PhoenixKitProjectsInternals, listeners };
}


// A reconnect's replay into a form whose record is at `nowVersion`, of a
// value kept when it was at `keptVersion` (the panel's per-record rule).
function field(name, value) {
  const node = el({ name, type: "text", value });
  node.type = "text";
  node.value = value;
  node.fired = 0;
  node.dispatchEvent = () => { node.fired += 1; };
  return node;
}

function replayInto(rendered, kept, keptVersion, nowVersion) {
  const input = field("assignment[title]", rendered);
  const button = el({ "data-pkp-apply-kept": "" });
  const note = el({ "data-pkp-kept-note": "" }, [button]);
  note.hidden = true;
  const form = el({ tag: "form", "data-pkp-version": nowVersion }, [input]);
  const dialog = el({}, [note, form]);
  const { api } = loadKeep([dialog]);
  api.keepStackReplay([[{ name: "assignment[title]", checked: null, value: kept }]], [[]], [keptVersion]);
  return { input, note, button };
}

test("a kept value goes back while the record is the version it was typed against", () => {
  const { input, note } = replayInto("Hello", "Hello there", "v1", "v1");
  assert.equal(input.value, "Hello there");
  assert.equal(input.fired, 1);
  assert.equal(note.hidden, true);
});

test("a record changed meanwhile: nothing goes back by itself, the form offers it", () => {
  const { input, note, button } = replayInto("Hello world", "Hello there", "v1", "v2");
  assert.equal(input.value, "Hello world");
  assert.equal(input.fired, 0);
  assert.equal(note.hidden, false);
  button.onclick();
  assert.equal(input.value, "Hello there");
  assert.equal(input.fired, 1);
  assert.equal(note.hidden, true);
});

test("a record changed meanwhile to what was kept: no note", () => {
  const { input, note } = replayInto("Hello there", "Hello there", "v1", "v2");
  assert.equal(input.fired, 0);
  assert.equal(note.hidden, true);
});
