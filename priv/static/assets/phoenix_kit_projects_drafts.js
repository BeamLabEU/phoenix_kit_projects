/*
 * phoenix_kit_projects — the task list's draft row.
 *
 * PkpDraft: the row Enter opens on a card list (`OutlineList.draft_row/1`).
 * What is typed here is no task until it is written: Enter writes it and
 * opens the next draft below; Tab / Shift+Tab move the draft in and out a
 * level; Esc, Enter on an empty draft, or leaving it empty drop it; leaving
 * it with text writes it. A pasted list goes in where the draft stands.
 *
 * As the title is typed, the library's matching tasks are offered in a small
 * list under the row (`outline_draft_suggest`, never another project's
 * tasks): ↓/↑ and Enter, or a click, take one (`outline_draft_pick`); typing
 * on and pressing Enter makes a new task as before.
 *
 * Every draft is a new input with a key of its own (`data-key`); the server
 * acts on an event only while that key is the open draft's, so a blur that
 * fires as the row is replaced cannot write a task twice.
 */
(function () {
  "use strict";

  // "  - [x] Buy milk" → {text, depth, done} — the same reading of a pasted
  // list as the typed list's (phoenix_kit_projects.js).
  function parsePasted(text) {
    var raw = text.replace(/\r\n?/g, "\n").split("\n");
    var rows = [];
    raw.forEach(function (line) {
      if (line.trim() === "") return;
      var lead = line.match(/^[\t ]*/)[0];
      var tabs = (lead.match(/\t/g) || []).length;
      var spaces = lead.length - tabs;
      var rest = line.slice(lead.length);
      var done = false;
      var m = rest.match(/^(?:[-*+•◦‣]|\d{1,3}[.)])\s+/);
      if (m) rest = rest.slice(m[0].length);
      m = rest.match(/^\[( |x|X)?\]\s*/);
      if (m) {
        done = /x/i.test(m[1] || "");
        rest = rest.slice(m[0].length);
      }
      rest = rest.trim();
      if (rest === "") return;
      rows.push({ text: rest, indent: tabs * 4 + spaces, done: done });
    });
    // Indent widths → levels: each distinct width seen is one level deeper
    // than the nearest smaller one above it.
    var stack = [];
    rows.forEach(function (row) {
      while (stack.length && stack[stack.length - 1] >= row.indent) stack.pop();
      row.depth = stack.length;
      stack.push(row.indent);
    });
    return rows;
  }

  var Draft = {
    mounted: function () {
      var self = this;
      var el = this.el;
      this.key = el.dataset.key;
      // Set once this draft has been handed to the server: nothing after
      // that (the blur as the row goes) may hand it over again.
      this.done = false;
      this.menu = document.getElementById(el.dataset.menu);
      this.items = [];
      this.active = -1;
      this.seq = 0;

      el.addEventListener("keydown", function (e) {
        if (self.done) return;
        var open = self.items.length > 0;
        if (open && (e.key === "ArrowDown" || e.key === "ArrowUp")) {
          e.preventDefault();
          var n = self.items.length;
          self.active = e.key === "ArrowDown" ? (self.active + 1) % n : (self.active - 1 + n) % n;
          self.paint();
        } else if (e.key === "Enter") {
          e.preventDefault();
          if (open && self.active >= 0) self.pick(self.items[self.active], true);
          else self.finish(true);
        } else if (e.key === "Escape") {
          e.preventDefault();
          // The list first; Esc again drops the draft.
          if (open) self.close();
          else self.drop(true);
        } else if (e.key === "Tab") {
          e.preventDefault();
          self.done = true;
          self.pushEvent("outline_draft_nest", { key: self.key, dir: e.shiftKey ? "out" : "in", text: el.value });
          // A draft that cannot move (nothing above to go under) stays open.
          setTimeout(function () { if (!self.gone) self.done = false; }, 400);
        }
      });

      el.addEventListener("paste", function (e) {
        var plain = (e.clipboardData && e.clipboardData.getData("text/plain")) || "";
        if (plain.indexOf("\n") === -1 || self.done) return;
        e.preventDefault();
        var rows = parsePasted(plain);
        if (rows.length === 0) return;
        self.done = true;
        self.pushEvent("outline_draft_paste", { key: self.key, text: el.value, lines: rows });
      });

      el.addEventListener("input", function () {
        clearTimeout(self.timer);
        self.timer = setTimeout(function () { self.suggest(); }, 160);
      });

      if (this.menu) {
        // A click on the list must not blur the title first (the blur would
        // write the typed text as a task of its own).
        this.menu.addEventListener("mousedown", function (e) { e.preventDefault(); });
        this.menu.addEventListener("click", function (e) {
          var li = e.target.closest("[data-index]");
          if (!li || self.done) return;
          self.pick(self.items[Number(li.dataset.index)], true);
        });
      }

      el.addEventListener("blur", function () {
        self.close();
        if (self.done || self.gone) return;
        self.finish(false);
      });

      el.focus();
      var end = el.value.length;
      el.setSelectionRange(end, end);
    },

    suggest: function () {
      var self = this;
      if (this.done || this.gone || !this.menu) return;
      var q = this.el.value.trim();
      var seq = ++this.seq;
      if (q.length < 2) { this.close(); return; }
      this.pushEvent("outline_draft_suggest", { key: this.key, q: q }, function (reply) {
        // Only the answer to the latest keystroke counts.
        if (seq !== self.seq || self.done || self.gone) return;
        self.items = (reply && reply.items) || [];
        self.active = -1;
        self.render();
      });
    },

    render: function () {
      var menu = this.menu;
      if (!menu) return;
      menu.textContent = "";
      if (this.items.length === 0) { menu.classList.add("hidden"); return; }
      var head = document.createElement("li");
      head.className = "menu-title text-xs";
      head.textContent = menu.dataset.label || "";
      menu.appendChild(head);
      this.items.forEach(function (item, i) {
        var li = document.createElement("li");
        li.setAttribute("role", "option");
        li.dataset.index = String(i);
        var a = document.createElement("a");
        a.className = "flex flex-col items-start gap-0";
        var title = document.createElement("span");
        title.className = "font-medium";
        title.textContent = item.title;
        a.appendChild(title);
        if (item.hint) {
          var hint = document.createElement("span");
          hint.className = "text-xs text-base-content/60 truncate max-w-full";
          hint.textContent = item.hint;
          a.appendChild(hint);
        }
        li.appendChild(a);
        menu.appendChild(li);
      });
      menu.classList.remove("hidden");
      this.paint();
    },

    paint: function () {
      var self = this;
      if (!this.menu) return;
      this.menu.querySelectorAll("[data-index]").forEach(function (li) {
        var on = Number(li.dataset.index) === self.active;
        li.setAttribute("aria-selected", on ? "true" : "false");
        li.firstChild.classList.toggle("menu-active", on);
      });
    },

    close: function () {
      this.seq++;
      this.items = [];
      this.active = -1;
      if (this.menu) { this.menu.textContent = ""; this.menu.classList.add("hidden"); }
    },

    pick: function (item, next) {
      if (!item) return;
      this.done = true;
      this.close();
      this.pushEvent("outline_draft_pick", { key: this.key, task: item.uuid, next: next });
    },

    // Enter (next = true: the next draft opens below) or leaving the row.
    finish: function (next) {
      var text = this.el.value.replace(/\s+/g, " ").trim();
      if (text === "") { this.drop(next); return; }
      this.done = true;
      this.pushEvent("outline_draft_save", { key: this.key, text: text, next: next, refocus: false });
    },

    // refocus: the cursor goes back to the row above (Esc, Enter on empty);
    // not when the person clicked somewhere else.
    drop: function (refocus) {
      this.done = true;
      this.pushEvent("outline_draft_cancel", { key: this.key, refocus: !!refocus });
    },

    destroyed: function () {
      this.gone = true;
      clearTimeout(this.timer);
    }
  };

  window.PhoenixKitProjectsDraftHooks = { PkpDraft: Draft };
})();
