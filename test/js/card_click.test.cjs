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
function load(open = () => {}) {
  const listeners = {};
  const document = new Proxy({ addEventListener: (t, fn) => { (listeners[t] = listeners[t] || []).push(fn); } }, {
    get: (t, k) => (k in t ? t[k] : stub())
  });
  const window = { document, open, addEventListener() {}, removeEventListener() {}, CSS: { escape: (s) => s }, getSelection: () => ({ toString: () => selection }) };
  window.window = window;
  const ctx = vm.createContext({
    window, document, console, CSS: { escape: (s) => s },
    setTimeout, clearTimeout, MutationObserver: function () { return stub(); },
    getComputedStyle: () => stub(), navigator: stub(), location: stub(), history: stub()
  });
  vm.runInContext(fs.readFileSync(path.join(__dirname, "../../priv/static/assets/phoenix_kit_projects.js"), "utf8"), ctx);
  return { I: window.PhoenixKitProjectsInternals, listeners, hooks: window.PhoenixKitProjectsHooks };
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

test("tracing updates only this embed's controls, including its detached menu", () => {
  const hook = load().hooks.PkpLinks;
  const button = () => ({
    isConnected: true, getAttribute: () => "same-task", hasAttribute: () => false,
    setAttribute(_key, value) { this.pressed = value; }
  });
  const first = button(), second = button();
  function list(control) {
    const el = {dataset: {}, querySelector: () => null, querySelectorAll: () => [control]};
    return Object.assign(Object.create(hook), {el, marks: {}, draw() {}, pin: null, hover: null});
  }
  const a = list(first), b = list(second);
  a.read();
  b.read();
  a.el.querySelectorAll = () => [];
  a.read();
  a.apply();
  assert.equal(first.pressed, "false");
  assert.equal(second.pressed, undefined);
});

test("a modified popup title click opens the task URL and consumes the drawer event", () => {
  const opened = [];
  const { listeners } = load((...args) => opened.push(args));
  let stopped = false, prevented = false;
  const title = { getAttribute: () => "/tasks/42" };
  const event = {
    button: 0, metaKey: true,
    target: { closest: selector => selector === "button[data-pkp-open-url]" ? title : null },
    preventDefault() { prevented = true; }, stopPropagation() { stopped = true; }
  };
  for (const click of listeners.click) {
    click(event);
    if (stopped) break;
  }
  assert.deepEqual(opened, [["/tasks/42", "_blank", "noopener"]]);
  assert.ok(prevented && stopped);
});
