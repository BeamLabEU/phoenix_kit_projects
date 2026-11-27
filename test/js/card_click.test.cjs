// A task's card opens on a click, except on its own controls, after a drag
// or after a text selection (Max, 2026-11-26). `cardClickOpens` in
// phoenix_kit_projects.js; run with `node --test test/js`.
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

let selection = "";
function load() {
  const listeners = {};
  const document = new Proxy({ addEventListener: (t, fn) => { (listeners[t] = listeners[t] || []).push(fn); } }, {
    get: (t, k) => (k in t ? t[k] : stub())
  });
  const window = { document, addEventListener() {}, removeEventListener() {}, CSS: { escape: (s) => s }, getSelection: () => ({ toString: () => selection }) };
  window.window = window;
  const ctx = vm.createContext({
    window, document, console, CSS: { escape: (s) => s },
    setTimeout, clearTimeout, MutationObserver: function () { return stub(); },
    getComputedStyle: () => stub(), navigator: stub(), location: stub(), history: stub()
  });
  vm.runInContext(fs.readFileSync(path.join(__dirname, "../../priv/static/assets/phoenix_kit_projects.js"), "utf8"), ctx);
  return { I: window.PhoenixKitProjectsInternals, listeners };
}

const { I, listeners } = load();
const card = { contains: (n) => n.inCard === true };
const plain = { inCard: true, closest: () => null };
const button = { inCard: true, closest: () => ({ inCard: true }) };
const press = (x, y) => listeners.pointerdown.forEach((fn) => fn({ clientX: x, clientY: y }));

test("a click on the card's empty space opens it", () => {
  selection = "";
  press(100, 100);
  assert.equal(I.cardClickOpens({ target: plain, clientX: 101, clientY: 100 }, card), true);
});

test("a click on one of the card's controls does not", () => {
  selection = "";
  press(100, 100);
  assert.equal(I.cardClickOpens({ target: button, clientX: 100, clientY: 100 }, card), false);
});

test("a press that moved (a drag) does not", () => {
  selection = "";
  press(100, 100);
  assert.equal(I.cardClickOpens({ target: plain, clientX: 130, clientY: 100 }, card), false);
});

test("a click that ends a text selection does not", () => {
  selection = "Seal the";
  press(100, 100);
  assert.equal(I.cardClickOpens({ target: plain, clientX: 100, clientY: 100 }, card), false);
  selection = "";
});
