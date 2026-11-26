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
  I.revertListMove(list, { item: byId.B, prev: byId.A, next: byId.C, index: 1, saved: [I.saveRowLevel(byId.B)] });
  assert.deepEqual(ids(), ["A", "B", "X", "C"]);
});

test("a refusal keeps a row that arrived between a moved branch and the row after it", () => {
  const { list, byId, ids } = fakeList([["A", 0], ["B", 0], ["B1", 1], ["X", 0], ["C", 0]]);
  const saved = [I.saveRowLevel(byId.B), I.saveRowLevel(byId.B1)];
  I.revertListMove(list, { item: byId.B, prev: byId.A, next: byId.C, index: 1, saved });
  assert.deepEqual(ids(), ["A", "B", "B1", "X", "C"]);
});

test("a refusal with no redraw still puts the card back between its neighbours", () => {
  // B dropped below C, nothing redrawn: A, C, B goes back to A, B, C.
  const { list, byId, ids } = fakeList([["A", 0], ["C", 0], ["B", 0]]);
  I.revertListMove(list, { item: byId.B, prev: byId.A, next: byId.C, index: 1, saved: [I.saveRowLevel(byId.B)] });
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


// A text field as the bundle sees it: its value now, and what the server
// rendered into it (defaultValue).
function field(name, value, rendered) {
  const node = el({ name, type: "text", value });
  node.type = "text";
  node.tagName = "INPUT";
  node.value = value;
  node.defaultValue = rendered;
  node.fired = 0;
  node.dispatchEvent = () => { node.fired += 1; };
  return node;
}

function replayInto(rendered, kept) {
  const input = field("assignment[title]", rendered, rendered);
  const dialog = el({}, [el({ tag: "form" }, [input])]);
  const { api } = loadKeep([dialog]);
  api.noteField(input); // the new form's field entering the page
  api.keepStackReplay([[Object.assign({ name: "assignment[title]", checked: null }, kept)]], [[]]);
  return input;
}

test("a kept plain value goes back while the server still has what the field came with", () => {
  const input = replayInto("Hello", { value: "Hello there", server: "Hello", echo: "Hello there" });
  assert.equal(input.value, "Hello there");
  assert.equal(input.fired, 1);
});

test("a kept plain value goes back over the person's own autosave", () => {
  // Came with "A", autosaved "A plus", then typed on; the new form has "A plus".
  const input = replayInto("A plus", { value: "A plus more", server: "A", echo: "A plus" });
  assert.equal(input.value, "A plus more");
});

test("a kept plain value never overwrites a value the server gained meanwhile", () => {
  const input = replayInto("Hello world", { value: "Hello there", server: "Hello", echo: "Hello" });
  assert.equal(input.value, "Hello world");
  assert.equal(input.fired, 0);
});
