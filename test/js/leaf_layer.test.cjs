// The Leaf layer (phoenix_kit_projects.js): a floating part Leaf appends
// to <body> is moved into the open dialog; one holding a text field (the
// image-address box) gets that field focused again, since Leaf's own focus
// call ran while the box was still outside the modal (inert) — grok, 2026-11-25.
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
  return window.PhoenixKitProjectsInternals.adoptLeafNode;
}

const adopt = load();

function node({ field = null } = {}) {
  const attrs = {};
  return {
    parentNode: "body",
    setAttribute: (k, v) => { attrs[k] = v; },
    attrs,
    matches: () => false,
    querySelector: () => field
  };
}

function dialog() {
  const d = { children: [] };
  d.appendChild = (n) => { d.children.push(n); n.parentNode = d; };
  return d;
}

test("the image-address box is moved into the dialog and its field focused", () => {
  let focused = 0;
  const field = { focus: () => { focused += 1; } };
  const box = node({ field });
  const d = dialog();
  adopt(box, { dialog: d, viewId: "view-1" });
  assert.equal(box.parentNode, d);
  assert.equal(box.attrs["data-phx-teleported"], "view-1");
  assert.equal(focused, 1);
});

test("a part with no field (the suggestion list) is moved and focus is left alone", () => {
  const list = node();
  const d = dialog();
  adopt(list, { dialog: d, viewId: null });
  assert.equal(list.parentNode, d);
});

test("nothing happens without an open dialog, or for a part already inside it", () => {
  const n = node();
  adopt(n, null);
  assert.equal(n.parentNode, "body");
  const d = dialog();
  n.parentNode = d;
  adopt(n, { dialog: d, viewId: null });
  assert.equal(d.children.length, 0);
});
