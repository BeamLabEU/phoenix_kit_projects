// PkpKeepStack's rich editors (phoenix_kit_projects.js): a dropped connection
// keeps each open frame's Leaf text, and the rejoin puts it back through
// Leaf's own `set_content` command — only while the server's value is still
// the one the page had (Max, 2026-11-25: fields came back, the description
// did not). Run with `node --test test/js` (also from `mix test`).
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

// A tiny DOM: elements answer the selectors the hook uses.
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
  return false;
}

function load(byId) {
  const events = [];
  const document = Object.assign(stub(), {});
  const window = {
    document,
    addEventListener() {},
    removeEventListener() {},
    dispatchEvent: (e) => events.push({ type: e.type, detail: e.detail }),
    CSS: { escape: (s) => s }
  };
  window.window = window;
  function CustomEvent(type, init) { this.type = type; this.detail = init && init.detail; }
  const docProxy = new Proxy(document, {
    get: (t, k) => (k === "getElementById" ? (id) => byId[id] || null : t[k])
  });
  window.document = docProxy;
  const ctx = vm.createContext({
    window, document: docProxy, console, CustomEvent, CSS: { escape: (s) => s },
    setTimeout, clearTimeout, MutationObserver: function () { return stub(); },
    getComputedStyle: () => stub(), navigator: stub(), location: stub(), history: stub()
  });
  const src = fs.readFileSync(path.join(__dirname, "../../priv/static/assets/phoenix_kit_projects.js"), "utf8");
  vm.runInContext(src, ctx);
  return { api: window.PhoenixKitProjectsInternals, events };
}

function frame(id, { typed, server, visualHtml = "<p>x</p>" }) {
  const visual = el({ "data-editor-visual": "" });
  visual.innerHTML = visualHtml;
  const editor = el({ "data-editor-id": id }, [visual]);
  const sync = el({ type: "hidden", "data-leaf-sync-input": id, value: server });
  sync.value = typed;
  const md = { value: typed };
  return { dialog: el({}, [editor, sync]), sync, md };
}

test("an edited editor is kept with the server's value beside it; an untouched one is not", () => {
  const a = frame("ed-a", { typed: "My new text", server: "Old text" });
  const b = frame("ed-b", { typed: "Same", server: "Same" });
  const dialog = el({}, [...a.dialog.children, ...b.dialog.children]);
  const { api } = load({ "ed-a-markdown-textarea": a.md, "ed-b-markdown-textarea": b.md });
  const kept = JSON.parse(JSON.stringify(api.keepRich(dialog)));
  assert.equal(kept.length, 1);
  assert.equal(kept[0].id, "ed-a");
  assert.equal(kept[0].markdown, "My new text");
  assert.equal(kept[0].server, "Old text");
});

test("the rejoin restores through Leaf's set_content while the server's value is unchanged", () => {
  const a = frame("ed-a", { typed: "Old text", server: "Old text" });
  const { api, events } = load({});
  const last = api.restoreRich(a.dialog, [{ id: "ed-a", markdown: "My new text", html: "<p>My new text</p>", server: "Old text" }]);
  assert.equal(events.length, 1);
  assert.equal(events[0].type, "phx:leaf-command:ed-a");
  assert.equal(events[0].detail.action, "set_content");
  assert.equal(events[0].detail.content, "My new text");
  assert.equal(a.sync.value, "My new text");
  assert.equal(last, a.sync);
});

test("a newer server value is never overwritten", () => {
  const a = frame("ed-a", { typed: "Someone else's", server: "Someone else's" });
  const { api, events } = load({});
  const last = api.restoreRich(a.dialog, [{ id: "ed-a", markdown: "My new text", html: "", server: "Old text" }]);
  assert.equal(events.length, 0);
  assert.equal(a.sync.value, "Someone else's");
  assert.equal(last, null);
});
