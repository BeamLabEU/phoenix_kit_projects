// Content-Security-Policy: the print button's delegated listener (what an
// inline `onclick="window.print()"` did) and the nonce stamp on every
// <style> the bundle creates. Run with `node --test test/js`.
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

// `kit`: what `window.PhoenixKitInternals` is; `pageStyle`: the page's own
// nonced <style>, if any.
function load({ kit, pageStyle } = {}) {
  const listeners = {};
  const created = [];
  const appended = [];
  const document = {
    addEventListener(type, fn) { (listeners[type] = listeners[type] || []).push(fn); },
    removeEventListener() {},
    createElement(tag) {
      const el = { tagName: String(tag).toUpperCase(), setAttribute() {}, style: {} };
      created.push(el);
      return el;
    },
    getElementById: () => null,
    querySelector: (selector) => (selector === "style[nonce]" ? pageStyle || null : null),
    querySelectorAll: () => [],
    head: { appendChild(el) { appended.push({ el, nonce: el.nonce }); } },
    body: stub(),
    documentElement: stub()
  };
  let prints = 0;
  const window = {
    document, addEventListener() {}, removeEventListener() {}, CSS: { escape: (s) => s },
    print() { prints++; }
  };
  if (kit) window.PhoenixKitInternals = kit;
  window.window = window;
  const ctx = vm.createContext({
    window, document, console, CSS: { escape: (s) => s },
    setTimeout, clearTimeout, MutationObserver: function () { return stub(); },
    getComputedStyle: () => stub(), navigator: stub(), location: stub(), history: stub()
  });
  const src = fs.readFileSync(path.join(__dirname, "../../priv/static/assets/phoenix_kit_projects.js"), "utf8");
  vm.runInContext(src, ctx);
  const click = (target) => (listeners.click || []).forEach((fn) => fn({ target, stopPropagation() {}, preventDefault() {} }));
  return { window, created, appended, click, prints: () => prints };
}

const button = (attr) => ({ closest: (selector) => (selector === "[" + attr + "]" ? {} : null) });

test("a click on [data-pkp-print] prints, any other click does not", () => {
  const page = load();
  page.click(button("data-other"));
  assert.equal(page.prints(), 0);
  page.click(button("data-pkp-print"));
  assert.equal(page.prints(), 1);
});

test("a <style> created at load is stamped by core before it joins the document", () => {
  const page = load({ kit: { adoptStyle(el) { el.nonce = "from-core"; } } });
  const styles = page.appended.filter((a) => a.el.tagName === "STYLE");
  assert.ok(styles.length >= 1);
  styles.forEach((a) => assert.equal(a.nonce, "from-core"));
});

test("a hook's <style> is stamped too", () => {
  const page = load({ kit: { adoptStyle(el) { el.nonce = "from-core"; } } });
  const before = page.appended.length;
  const hook = Object.create(page.window.PhoenixKitProjectsHooks.PkpBoard);
  hook.el = stub();
  hook.handleEvent = () => {};
  try { hook.mounted(); } catch (_) { /* the stub page is not a real board */ }
  const added = page.appended.slice(before).filter((a) => a.el.tagName === "STYLE");
  assert.equal(added.length, 1);
  assert.equal(added[0].nonce, "from-core");
});

test("without core's helper: the nonce of a <style> already on the page, or none", () => {
  const withStyle = load({ pageStyle: { nonce: "page" } });
  withStyle.appended.forEach((a) => assert.equal(a.nonce, "page"));

  const bare = load();
  assert.ok(bare.appended.length >= 1);
  bare.appended.forEach((a) => assert.equal(a.nonce, undefined));
});
