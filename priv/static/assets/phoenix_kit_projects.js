/*
 * phoenix_kit_projects — browser hooks.
 *
 * PkpOutline: a project's task list as ONE text field. One line is one
 * task, an indent is "sits under the line above", the box in the gutter is
 * the tick. The browser owns the text while it is being typed; the server
 * owns the tasks. After every pause the whole list goes to the server as
 * lines ({id, tmp, text, depth}) and the server reconciles: a line with no
 * id becomes a task, a changed line is renamed, a line that is gone is
 * removed (or held, when the task carries something), and the order and
 * nesting are rewritten (`PhoenixKitProjects.Outline.sync/4`).
 *
 * Identity never comes from the text: every line element carries the uuid
 * of its task (`data-id`), and every structural edit — Enter, a deletion
 * across lines, paste, cut, Tab — is done HERE on those elements rather
 * than left to the browser, so an id can only ever move with its line.
 *
 * PkpTitle: one task title edited in place on a card row.
 *
 * PkpBoard: one column of the board, its cards dragged between columns.
 */
(function () {
  "use strict";

  var STYLE_ID = "pkp-outline-style";
  var MIME = "application/x-pkp-outline";
  var SYNC_MS = 600;
  var INDENT_REM = 1.5;

  var CSS = [
    ".pkp-ol{outline:none;min-height:3rem;padding:.25rem 0;line-height:1.75rem;font-size:.95rem;white-space:pre-wrap;word-break:break-word;caret-color:currentColor}",
    ".pkp-ol-line{position:relative;min-height:1.75rem;padding-right:5.5rem;padding-left:calc(1.9rem + var(--d,0) * " + INDENT_REM + "rem);border-radius:.375rem}",
    ".pkp-ol-line:hover{background-color:color-mix(in oklab,currentColor 4%,transparent)}",
    ".pkp-ol-line::before{content:'';position:absolute;left:calc(.35rem + var(--d,0) * " + INDENT_REM + "rem);top:.4rem;width:.95rem;height:.95rem;border:1.5px solid color-mix(in oklab,currentColor 45%,transparent);border-radius:.25rem;cursor:pointer;box-sizing:border-box}",
    ".pkp-ol-line[data-done='1']::before{background:#16a34a;border-color:#16a34a;background-image:url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'%3E%3Cpath fill='none' stroke='white' stroke-width='2.2' stroke-linecap='round' stroke-linejoin='round' d='M3.5 8.5l3 3 6-7'/%3E%3C/svg%3E\");background-size:100% 100%}",
    ".pkp-ol-line[data-done='1']{text-decoration:line-through;color:color-mix(in oklab,currentColor 50%,transparent)}",
    ".pkp-ol-line[data-kind='project']::before{border-radius:50%;border-style:dashed;cursor:default}",
    ".pkp-ol-line[data-kind='project']{font-weight:600}",
    ".pkp-ol-line::after{content:attr(data-ref) '  \\203A';position:absolute;right:.5rem;top:0;font-size:.75rem;opacity:0;cursor:pointer;text-decoration:none;white-space:nowrap;color:color-mix(in oklab,currentColor 70%,transparent)}",
    ".pkp-ol-line[data-id]:hover::after,.pkp-ol-line[data-id].pkp-ol-cur::after{opacity:.75}",
    ".pkp-ol-line[data-count]:not([data-count=''])::after{content:attr(data-count) '   ' attr(data-ref) '  \\203A';opacity:.6}",
    // The ✕ at the end of a line (settings: "a delete button on each line").
    ".pkp-ol[data-del='1'] .pkp-ol-line[data-id]::after{content:attr(data-ref) '  \\203A     \\2715'}",
    ".pkp-ol[data-del='1'] .pkp-ol-line[data-count]:not([data-count=''])::after{content:attr(data-count) '   ' attr(data-ref) '  \\203A     \\2715'}",
    // Drag handles (settings: "drag handles"): a grip in front of the box.
    ".pkp-ol[data-handles='1'] .pkp-ol-line{padding-left:calc(3rem + var(--d,0) * " + INDENT_REM + "rem)}",
    ".pkp-ol[data-handles='1'] .pkp-ol-line::before{left:calc(1.45rem + var(--d,0) * " + INDENT_REM + "rem)}",
    ".pkp-ol[data-handles='1'] .pkp-ol-line[data-id]:hover{background-image:url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 10 16'%3E%3Cg fill='%23888'%3E%3Ccircle cx='3' cy='3' r='1.3'/%3E%3Ccircle cx='7' cy='3' r='1.3'/%3E%3Ccircle cx='3' cy='8' r='1.3'/%3E%3Ccircle cx='7' cy='8' r='1.3'/%3E%3Ccircle cx='3' cy='13' r='1.3'/%3E%3Ccircle cx='7' cy='13' r='1.3'/%3E%3C/g%3E%3C/svg%3E\");background-repeat:no-repeat;background-size:.6rem 1rem;background-position:calc(.4rem + var(--d,0) * " + INDENT_REM + "rem) .4rem}",
    ".pkp-ol-line.pkp-ol-dragging{opacity:.4}",
    ".pkp-ol-line[data-drop='before']{box-shadow:inset 0 2px 0 0 #3b82f6}",
    ".pkp-ol-line[data-drop='after']{box-shadow:inset 0 -2px 0 0 #3b82f6}",
    ".pkp-ol[data-empty='1'] .pkp-ol-line:first-child::after{content:attr(data-placeholder);left:1.9rem;right:auto;opacity:.45;font-size:.95rem;pointer-events:none}",
    ".pkp-ol[data-readonly='1'] .pkp-ol-line::before{cursor:default}",
    ".pkp-ol-bar{display:flex;gap:.75rem;align-items:center;min-height:1.5rem;font-size:.75rem;opacity:.7;padding:.25rem .35rem}",
    ".pkp-ol-bar button{text-decoration:underline;cursor:pointer}",
    ".pkp-ol-bar[data-tone='warn']{opacity:1;color:#b45309}"
  ].join("\n");

  function ensureStyle() {
    if (document.getElementById(STYLE_ID)) return;
    var style = document.createElement("style");
    style.id = STYLE_ID;
    style.textContent = CSS;
    document.head.appendChild(style);
  }

  function tmpId() {
    return "t" + Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
  }

  // "  - [x] Buy milk" → {text, depth, done}. Leading list markers are how
  // people write lists everywhere else; they are not part of the task.
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

  var Outline = {
    mounted: function () {
      ensureStyle();
      var self = this;
      this.known = {};
      this.dirty = false;
      this.inflight = false;
      this.composing = false;
      this.pendingRemote = null;
      this.undoStack = [];
      this.redoStack = [];
      this.timer = null;
      this.canEdit = this.el.dataset.canEdit === "1";
      this.canTick = this.el.dataset.canTick === "1";
      this.canNest = this.el.dataset.canNest !== "0";

      this.root = document.createElement("div");
      this.root.className = "pkp-ol";
      this.root.setAttribute("role", "textbox");
      this.root.setAttribute("aria-multiline", "true");
      this.root.setAttribute("aria-label", this.el.dataset.label || "Tasks");
      this.root.spellcheck = true;
      if (this.canEdit) this.root.contentEditable = "true";
      else this.root.dataset.readonly = "1";
      if (this.canEdit && this.el.dataset.delete === "1") this.root.dataset.del = "1";
      if (this.canEdit && this.el.dataset.handles === "1") this.root.dataset.handles = "1";
      this.bar = document.createElement("div");
      this.bar.className = "pkp-ol-bar";
      this.el.appendChild(this.root);
      this.el.appendChild(this.bar);

      var lines = [];
      try {
        lines = JSON.parse(this.el.dataset.lines || "[]");
      } catch (_e) {
        lines = [];
      }
      this.applyRemote(lines);
      this.say(this.el.dataset.hint || "");

      this.handleEvent("pkp_outline:lines", function (payload) {
        if (payload.id !== self.el.id) return;
        self.pendingRemote = payload.lines;
        self.maybeApplyRemote();
      });

      this.root.addEventListener("beforeinput", function (e) { self.onBeforeInput(e); });
      this.root.addEventListener("input", function () { self.onInput(); });
      this.root.addEventListener("keydown", function (e) { self.onKeyDown(e); });
      this.root.addEventListener("paste", function (e) { self.onPaste(e); });
      this.root.addEventListener("cut", function (e) { self.onCopy(e, true); });
      this.root.addEventListener("copy", function (e) { self.onCopy(e, false); });
      this.root.addEventListener("drop", function (e) { e.preventDefault(); });
      this.root.addEventListener("click", function (e) { self.onClick(e); });
      this.root.addEventListener("pointerdown", function (e) { self.onPointerDown(e); });
      this.root.addEventListener("compositionstart", function () { self.composing = true; });
      this.root.addEventListener("compositionend", function () {
        self.composing = false;
        self.onInput();
      });
      this.root.addEventListener("blur", function () { self.flush(); });
      this.onSelection = function () { self.markCurrent(); };
      document.addEventListener("selectionchange", this.onSelection);
      this.onHide = function () { if (document.visibilityState === "hidden") self.flush(); };
      document.addEventListener("visibilitychange", this.onHide);
    },

    destroyed: function () {
      document.removeEventListener("selectionchange", this.onSelection);
      document.removeEventListener("visibilitychange", this.onHide);
      clearTimeout(this.timer);
    },

    // ── lines ────────────────────────────────────────────────────────

    lines: function () {
      return Array.prototype.slice.call(this.root.querySelectorAll(":scope > .pkp-ol-line"));
    },

    makeLine: function (data) {
      var el = document.createElement("div");
      el.className = "pkp-ol-line";
      this.fill(el, data);
      return el;
    },

    fill: function (el, data) {
      if (data.id) el.dataset.id = data.id; else delete el.dataset.id;
      if (data.tmp) el.dataset.tmp = data.tmp; else if (!data.id) el.dataset.tmp = tmpId();
      this.setDepth(el, data.depth || 0);
      el.dataset.done = data.done ? "1" : "0";
      el.dataset.ref = data.ref || "";
      el.dataset.count = data.count || "";
      if (data.kind === "project") {
        el.dataset.kind = "project";
        el.contentEditable = "false";
      } else {
        delete el.dataset.kind;
        el.removeAttribute("contenteditable");
      }
      if (data.open) el.dataset.open = data.open; else delete el.dataset.open;
      if (data.href) el.dataset.href = data.href; else delete el.dataset.href;
      this.setText(el, data.text || "");
      el.dataset.orig = data.text || "";
    },

    text: function (el) { return el.textContent.replace(/ /g, " ").replace(/\n/g, " "); },

    setText: function (el, text) {
      el.textContent = text;
      if (text === "") el.appendChild(document.createElement("br"));
    },

    depth: function (el) { return parseInt(el.dataset.depth || "0", 10) || 0; },

    setDepth: function (el, depth) {
      depth = Math.max(0, depth);
      el.dataset.depth = String(depth);
      el.style.setProperty("--d", String(depth));
    },

    locked: function (el) { return el.dataset.kind === "project"; },

    lineOf: function (node) {
      while (node && node !== this.root) {
        if (node.nodeType === 1 && node.classList.contains("pkp-ol-line")) return node;
        node = node.parentNode;
      }
      return null;
    },

    // The lines under `el` (deeper, directly following).
    branch: function (el) {
      var all = this.lines();
      var i = all.indexOf(el);
      var d = this.depth(el);
      var out = [];
      for (var j = i + 1; j < all.length && this.depth(all[j]) > d; j++) out.push(all[j]);
      return out;
    },

    refreshEmpty: function () {
      var all = this.lines();
      if (all.length === 0) {
        this.root.appendChild(this.makeLine({ text: "", depth: 0 }));
        all = this.lines();
      }
      var empty = all.length === 1 && this.text(all[0]) === "" && !all[0].dataset.id;
      this.root.dataset.empty = empty ? "1" : "0";
      all[0].dataset.placeholder = this.el.dataset.placeholder || "";
    },

    // Whatever the browser did, the root holds line elements and nothing
    // else, and no line holds anything but text.
    normalize: function () {
      var self = this;
      Array.prototype.slice.call(this.root.childNodes).forEach(function (node) {
        if (node.nodeType === 1 && node.classList.contains("pkp-ol-line")) {
          if (node.querySelector("div,p,span,b,i,u,a,font")) self.setText(node, self.text(node));
          return;
        }
        var text = (node.textContent || "").trim();
        if (text === "") {
          self.root.removeChild(node);
        } else {
          var line = self.makeLine({ text: text, depth: 0 });
          self.root.replaceChild(line, node);
        }
      });
      // A browser that split a line itself copied the id onto both halves.
      var seen = {};
      this.lines().forEach(function (el) {
        var id = el.dataset.id;
        if (!id) return;
        if (seen[id]) {
          delete el.dataset.id;
          el.dataset.tmp = tmpId();
          el.dataset.ref = "";
          el.dataset.count = "";
        }
        seen[id] = true;
      });
      this.clampDepths();
      this.refreshEmpty();
    },

    clampDepths: function () {
      var prev = -1;
      var self = this;
      this.lines().forEach(function (el) {
        var d = Math.min(self.depth(el), prev + 1);
        if (d !== self.depth(el)) self.setDepth(el, d);
        prev = d;
      });
    },

    // ── caret ────────────────────────────────────────────────────────

    caret: function () {
      var sel = window.getSelection();
      if (!sel || sel.rangeCount === 0) return null;
      var range = sel.getRangeAt(0);
      if (!this.root.contains(range.startContainer)) return null;
      var start = this.point(range.startContainer, range.startOffset);
      var end = range.collapsed ? start : this.point(range.endContainer, range.endOffset);
      if (!start || !end) return null;
      return { start: start, end: end, collapsed: range.collapsed, multi: start.line !== end.line };
    },

    point: function (node, offset) {
      var line = this.lineOf(node);
      if (!line) {
        // On the root itself: between two lines.
        if (node === this.root) {
          var all = this.lines();
          var el = all[Math.min(offset, all.length - 1)];
          if (!el) return null;
          return { line: el, offset: offset >= all.length ? this.text(el).length : 0 };
        }
        return null;
      }
      var r = document.createRange();
      r.selectNodeContents(line);
      try { r.setEnd(node, offset); } catch (_e) { return { line: line, offset: 0 }; }
      return { line: line, offset: r.toString().length };
    },

    setCaret: function (line, offset) {
      if (!line || !line.isConnected) return;
      var sel = window.getSelection();
      var range = document.createRange();
      var node = line.firstChild;
      if (!node || node.nodeType !== 3) {
        range.setStart(line, 0);
      } else {
        range.setStart(node, Math.min(offset, node.length));
      }
      range.collapse(true);
      sel.removeAllRanges();
      sel.addRange(range);
      if (this.locked(line)) return;
      line.scrollIntoView({ block: "nearest" });
    },

    markCurrent: function () {
      var c = this.caret();
      var cur = c && c.collapsed ? c.start.line : null;
      this.lines().forEach(function (el) { el.classList.toggle("pkp-ol-cur", el === cur); });
    },

    // ── undo ─────────────────────────────────────────────────────────

    snapshot: function () {
      var self = this;
      var c = this.caret();
      var all = this.lines();
      return {
        lines: all.map(function (el) {
          return {
            id: el.dataset.id, tmp: el.dataset.tmp, text: self.text(el), depth: self.depth(el),
            done: el.dataset.done === "1", ref: el.dataset.ref, count: el.dataset.count,
            kind: el.dataset.kind, open: el.dataset.open, href: el.dataset.href
          };
        }),
        at: c ? { index: all.indexOf(c.start.line), offset: c.start.offset } : null
      };
    },

    remember: function () {
      this.undoStack.push(this.snapshot());
      if (this.undoStack.length > 200) this.undoStack.shift();
      this.redoStack = [];
    },

    restore: function (snap) {
      var self = this;
      this.root.textContent = "";
      snap.lines.forEach(function (data) { self.root.appendChild(self.makeLine(data)); });
      this.refreshEmpty();
      if (snap.at) {
        var el = this.lines()[snap.at.index];
        if (el) this.setCaret(el, snap.at.offset);
      }
      this.changed();
    },

    undo: function (redo) {
      var from = redo ? this.redoStack : this.undoStack;
      var to = redo ? this.undoStack : this.redoStack;
      if (from.length === 0) return;
      to.push(this.snapshot());
      this.restore(from.pop());
    },

    // ── editing ──────────────────────────────────────────────────────

    // Removes what a selection across lines covers: lines wholly inside go,
    // the first keeps what is before the selection, the last what is after
    // it. Two tasks are never fused into one by a keystroke. Returns the
    // point to type at.
    deleteRange: function (c) {
      var all = this.lines();
      var i = all.indexOf(c.start.line);
      var j = all.indexOf(c.end.line);
      var first = c.start.line;
      var last = c.end.line;
      var self = this;

      if (i === j) {
        var t = this.text(first);
        this.setText(first, t.slice(0, c.start.offset) + t.slice(c.end.offset));
        return { line: first, offset: c.start.offset };
      }

      for (var k = i + 1; k < j; k++) if (!this.locked(all[k])) this.root.removeChild(all[k]);

      var lastText = this.text(last);
      var tail = lastText.slice(c.end.offset);
      if (!this.locked(last)) {
        if (tail === "" || c.end.offset >= lastText.length) this.root.removeChild(last);
        else if (c.end.offset > 0) this.setText(last, tail);
      }

      if (this.locked(first)) return { line: first, offset: 0 };
      var head = this.text(first).slice(0, c.start.offset);
      if (head === "" && c.start.offset === 0 && first.isConnected && this.lines().length > 1 && self.text(first) !== "") {
        // The whole first line was selected too.
        var next = first.nextElementSibling || first.previousElementSibling;
        this.root.removeChild(first);
        this.refreshEmpty();
        var at = next && next.isConnected ? next : this.lines()[0];
        return { line: at, offset: 0, whole: true };
      }
      this.setText(first, head);
      return { line: first, offset: head.length };
    },

    insertText: function (at, text) {
      var t = this.text(at.line);
      this.setText(at.line, t.slice(0, at.offset) + text + t.slice(at.offset));
      this.setCaret(at.line, at.offset + text.length);
    },

    splitLine: function (at) {
      var line = at.line;
      if (this.locked(line)) return;
      var t = this.text(line);
      var head = t.slice(0, at.offset).replace(/\s+$/, "");
      var tail = t.slice(at.offset).replace(/^\s+/, "");

      // Enter on an empty indented line steps it out one level.
      if (t === "" && this.depth(line) > 0) {
        this.setDepth(line, this.depth(line) - 1);
        this.setCaret(line, 0);
        return;
      }

      // Enter at the very start pushes the task down: the new, empty line
      // goes above and the task keeps its line.
      if (at.offset === 0 && t !== "") {
        var above = this.makeLine({ text: "", depth: this.depth(line) });
        this.root.insertBefore(above, line);
        this.setCaret(line, 0);
        return;
      }

      this.setText(line, head);
      var d = this.depth(line);
      var kids = this.branch(line);
      // A new line after a task that has subtasks is its first subtask —
      // unless the text was split, when the second half stays a sibling
      // placed after the whole branch.
      var fresh;
      if (tail === "" && kids.length > 0) {
        fresh = this.makeLine({ text: "", depth: d + 1 });
        this.root.insertBefore(fresh, line.nextSibling);
      } else {
        fresh = this.makeLine({ text: tail, depth: d });
        var after = kids.length ? kids[kids.length - 1] : line;
        this.root.insertBefore(fresh, after.nextSibling);
      }
      this.setCaret(fresh, 0);
    },

    onBeforeInput: function (e) {
      if (!this.canEdit) { e.preventDefault(); return; }
      var type = e.inputType || "";
      var c = this.caret();
      if (!c) return;

      if (type === "historyUndo") { e.preventDefault(); this.undo(false); return; }
      if (type === "historyRedo") { e.preventDefault(); this.undo(true); return; }
      if (type === "insertFromPaste" || type === "insertFromDrop" || type === "deleteByCut") {
        // The paste and cut events do these.
        e.preventDefault();
        return;
      }
      if (/^format/.test(type)) { e.preventDefault(); return; }

      if (this.locked(c.start.line) && !c.multi) { e.preventDefault(); return; }

      if (c.multi) {
        if (this.composing || type === "insertCompositionText") return;
        e.preventDefault();
        this.remember();
        var at = this.deleteRange(c);
        if (type === "insertText" && e.data && at.line && !this.locked(at.line)) {
          if (at.whole) {
            var fresh = this.makeLine({ text: "", depth: this.depth(at.line) });
            this.root.insertBefore(fresh, at.line);
            at = { line: fresh, offset: 0 };
          }
          this.insertText(at, e.data);
        } else if (type === "insertParagraph" || type === "insertLineBreak") {
          this.setCaret(at.line, at.offset);
          this.splitLine(at);
        } else if (at.line) {
          this.setCaret(at.line, at.offset);
        }
        this.changed();
        return;
      }

      if (type === "insertParagraph" || type === "insertLineBreak") {
        e.preventDefault();
        this.remember();
        var point = c.collapsed ? c.start : this.deleteRange(c);
        this.splitLine(point);
        this.changed();
        return;
      }

      if (c.collapsed && (type === "deleteContentBackward" || type === "deleteWordBackward" || type === "deleteSoftLineBackward" || type === "deleteHardLineBackward") && c.start.offset === 0) {
        e.preventDefault();
        var line = c.start.line;
        if (this.depth(line) > 0) {
          this.remember();
          this.outdent([line]);
        } else if (this.text(line) === "") {
          var prev = line.previousElementSibling;
          if (prev || this.lines().length > 1) {
            this.remember();
            this.root.removeChild(line);
            this.refreshEmpty();
            var to = prev || this.lines()[0];
            this.setCaret(to, prev ? this.text(to).length : 0);
          }
        }
        this.changed();
        return;
      }

      if (c.collapsed && (type === "deleteContentForward" || type === "deleteWordForward" || type === "deleteSoftLineForward" || type === "deleteHardLineForward") && c.start.offset >= this.text(c.start.line).length) {
        // The end of a line: nothing to delete but the line break, and two
        // tasks are not joined by a keystroke.
        e.preventDefault();
        var cur = c.start.line;
        if (this.text(cur) === "" && this.lines().length > 1 && this.depth(cur) === 0) {
          this.remember();
          var nxt = cur.nextElementSibling || cur.previousElementSibling;
          this.root.removeChild(cur);
          this.refreshEmpty();
          this.setCaret(nxt, 0);
          this.changed();
        }
        return;
      }

      // Typing inside one line is the browser's own business; a pause in
      // it is one undo step.
      if (!this.typing) {
        this.remember();
        this.typing = true;
        var self = this;
        clearTimeout(this.typingTimer);
        this.typingTimer = setTimeout(function () { self.typing = false; }, 1500);
      }
    },

    onInput: function () {
      if (this.composing) return;
      var c = this.caret();
      this.normalize();
      if (c && c.start.line && c.start.line.isConnected && this.text(c.start.line) === "" && !c.start.line.firstChild) {
        this.setText(c.start.line, "");
        this.setCaret(c.start.line, 0);
      }
      this.changed();
    },

    indent: function (lines) {
      var self = this;
      var all = this.lines();
      var set = this.withBranches(lines);
      var first = set[0];
      var i = all.indexOf(first);
      if (i <= 0) return;
      if (this.depth(first) > this.depth(all[i - 1])) return;
      set.forEach(function (el) { self.setDepth(el, self.depth(el) + 1); });
    },

    outdent: function (lines) {
      var self = this;
      var set = this.withBranches(lines);
      if (this.depth(set[0]) === 0) return;
      set.forEach(function (el) { self.setDepth(el, self.depth(el) - 1); });
      this.clampDepths();
    },

    // The lines named, each with what sits under it, in list order.
    withBranches: function (lines) {
      var self = this;
      var all = this.lines();
      var pick = {};
      lines.forEach(function (el) {
        pick[all.indexOf(el)] = true;
        self.branch(el).forEach(function (kid) { pick[all.indexOf(kid)] = true; });
      });
      return all.filter(function (_el, i) { return pick[i]; });
    },

    selectedLines: function (c) {
      var all = this.lines();
      var i = all.indexOf(c.start.line);
      var j = all.indexOf(c.end.line);
      if (c.multi && c.end.offset === 0) j -= 1;
      return all.slice(i, Math.max(i, j) + 1);
    },

    move: function (line, dir) {
      var all = this.lines();
      var block = [line].concat(this.branch(line));
      var d = this.depth(line);
      var i = all.indexOf(line);
      var self = this;
      if (dir < 0) {
        // The sibling above (same depth, nothing shallower in between).
        var k = i - 1;
        while (k >= 0 && this.depth(all[k]) > d) k--;
        if (k < 0 || this.depth(all[k]) < d) return;
        block.forEach(function (el) { self.root.insertBefore(el, all[k]); });
      } else {
        var after = i + block.length;
        if (after >= all.length || this.depth(all[after]) < d) return;
        var next = all[after];
        var nextBlock = [next].concat(this.branch(next));
        var anchor = nextBlock[nextBlock.length - 1].nextSibling;
        block.forEach(function (el) { self.root.insertBefore(el, anchor); });
      }
    },

    onKeyDown: function (e) {
      var c = this.caret();
      if (!c) return;
      var mod = e.metaKey || e.ctrlKey;

      if (mod && !e.altKey && (e.key === "z" || e.key === "Z")) {
        e.preventDefault();
        this.undo(e.shiftKey);
        return;
      }
      if (mod && !e.altKey && (e.key === "y" || e.key === "Y")) {
        e.preventDefault();
        this.undo(true);
        return;
      }
      if (mod && e.key === "Enter") {
        e.preventDefault();
        this.open(c.start.line);
        return;
      }
      if (!this.canEdit) return;

      if (e.key === "Tab") {
        e.preventDefault();
        if (!this.canNest && !e.shiftKey) return;
        this.remember();
        var lines = this.selectedLines(c);
        var keep = { line: c.start.line, offset: c.start.offset };
        if (e.shiftKey) this.outdent(lines); else this.indent(lines);
        if (c.collapsed) this.setCaret(keep.line, keep.offset);
        this.changed();
        return;
      }
      if (e.altKey && (e.key === "ArrowUp" || e.key === "ArrowDown") && c.collapsed) {
        e.preventDefault();
        this.remember();
        var off = c.start.offset;
        this.move(c.start.line, e.key === "ArrowUp" ? -1 : 1);
        this.setCaret(c.start.line, off);
        this.changed();
        return;
      }
      if (e.key === "Escape" && c.collapsed && c.start.line.dataset.id) {
        var line = c.start.line;
        if (this.text(line) !== line.dataset.orig) {
          e.preventDefault();
          this.setText(line, line.dataset.orig || "");
          this.setCaret(line, (line.dataset.orig || "").length);
          this.changed();
        }
      }
    },

    // ── clipboard ────────────────────────────────────────────────────

    onCopy: function (e, cut) {
      var c = this.caret();
      if (!c || c.collapsed) return;
      var whole = !c.multi && c.start.offset === 0 && c.end.offset >= this.text(c.start.line).length && this.text(c.start.line) !== "";
      if (!c.multi && !whole) {
        // Part of one line: ordinary text.
        if (cut && this.canEdit) { this.remember(); var self = this; setTimeout(function () { self.onInput(); }, 0); }
        return;
      }
      e.preventDefault();
      var self2 = this;
      var lines = this.selectedLines(c).filter(function (el) { return !self2.locked(el); });
      if (lines.length === 0) return;
      var base = Math.min.apply(null, lines.map(function (el) { return self2.depth(el); }));
      var rows = lines.map(function (el) {
        return { id: el.dataset.id || null, text: self2.text(el), depth: self2.depth(el) - base, done: el.dataset.done === "1" };
      }).filter(function (row) { return row.text.trim() !== ""; });
      var plain = rows.map(function (row) {
        return new Array(row.depth + 1).join("\t") + (row.done ? "[x] " : "") + row.text;
      }).join("\n");
      e.clipboardData.setData("text/plain", plain);
      e.clipboardData.setData(MIME, JSON.stringify({ plain: plain, rows: rows }));
      if (cut && this.canEdit) {
        this.remember();
        lines.forEach(function (el) { self2.root.removeChild(el); });
        this.refreshEmpty();
        this.clampDepths();
        var all = this.lines();
        var at = all[Math.min(all.length - 1, Math.max(0, all.indexOf(c.start.line)))] || all[0];
        if (!at.isConnected) at = all[0];
        this.setCaret(at, 0);
        this.changed();
      }
    },

    onPaste: function (e) {
      e.preventDefault();
      if (!this.canEdit) return;
      var c = this.caret();
      if (!c) return;
      var plain = (e.clipboardData && e.clipboardData.getData("text/plain")) || "";
      if (plain === "") return;
      var rows = null;
      try {
        var raw = e.clipboardData.getData(MIME);
        var payload = raw ? JSON.parse(raw) : null;
        // Only when the text is still what was cut: a clipboard edited on
        // the way here is new text, not those tasks.
        if (payload && payload.plain === plain) rows = payload.rows;
      } catch (_e) { rows = null; }

      // Nothing is pasted onto (or across from) a sub-project line: refuse
      // before touching the lines, not after.
      if (this.locked(c.start.line)) return;
      this.remember();
      var at = c.collapsed ? c.start : this.deleteRange(c);
      if (!at.line || this.locked(at.line)) { this.changed(); return; }

      if (!rows && plain.indexOf("\n") === -1) {
        this.insertText(at, plain.replace(/\s+/g, " "));
        this.changed();
        return;
      }

      if (!rows) rows = parsePasted(plain);
      if (rows.length === 0) return;

      var self = this;
      var present = {};
      this.lines().forEach(function (el) { if (el.dataset.id) present[el.dataset.id] = true; });
      var base = this.depth(at.line);
      var target = at.line;
      var anchor;
      var made = [];
      var replace = this.text(target) === "" && !target.dataset.id;

      if (replace) {
        anchor = target;
      } else {
        var kids = this.branch(target);
        anchor = (kids.length ? kids[kids.length - 1] : target).nextSibling;
      }
      rows.forEach(function (row) {
        // A cut task that is no longer in the list comes back as itself;
        // one that is still here (copied) is a new task with the same text.
        var id = row.id && !present[row.id] ? row.id : null;
        if (id) present[id] = true;
        var el = self.makeLine({ id: id, text: row.text, depth: base + (row.depth || 0), done: row.done });
        self.root.insertBefore(el, anchor);
        made.push(el);
      });
      if (replace) this.root.removeChild(target);
      this.clampDepths();
      this.refreshEmpty();
      var last = made[made.length - 1];
      this.setCaret(last, this.text(last).length);
      this.changed();
    },

    // ── the gutter and the row's end ─────────────────────────────────

    onClick: function (e) {
      var line = this.lineOf(e.target);
      if (!line || e.target !== line) {
        if (!line) return;
      }
      var rect = line.getBoundingClientRect();
      var rem = parseFloat(getComputedStyle(document.documentElement).fontSize) || 16;
      var x = e.clientX - rect.left;
      var handles = this.root.dataset.handles === "1" ? 1.1 : 0;
      var gutter = (0.1 + handles + this.depth(line) * INDENT_REM) * rem;
      // The ✕ is the line's last 1.6rem.
      if (this.root.dataset.del === "1" && line.dataset.id && !this.locked(line) &&
          rect.right - e.clientX <= 1.6 * rem && e.clientY - rect.top < 1.9 * rem) {
        e.preventDefault();
        this.removeLine(line);
        return;
      }
      if (x >= gutter && x <= gutter + 1.6 * rem && e.clientY - rect.top < 1.9 * rem) {
        e.preventDefault();
        this.tick(line);
        return;
      }
      if (rect.right - e.clientX <= 4.5 * rem && line.dataset.id && e.clientY - rect.top < 1.9 * rem) {
        var textRange = document.createRange();
        textRange.selectNodeContents(line);
        var tr = textRange.getBoundingClientRect();
        if (e.clientX > tr.right + 4 || this.locked(line)) {
          e.preventDefault();
          this.open(line);
        }
      } else if (this.locked(line)) {
        this.open(line);
      }
    },

    // The ✕: the line goes, as if its text had been cut — the server deletes
    // the task, or holds it when it carries work. Its subtasks stay, one
    // level up. Undo brings it back.
    removeLine: function (line) {
      if (!this.canEdit || this.locked(line)) return;
      this.remember();
      var next = line.nextElementSibling || line.previousElementSibling;
      this.root.removeChild(line);
      this.clampDepths();
      this.refreshEmpty();
      if (next && next.isConnected) this.setCaret(next, 0);
      this.changed();
    },

    // Drag handles: press on the grip, drop above or below another line. The
    // line moves with everything under it and takes the depth of the line it
    // lands beside.
    onPointerDown: function (e) {
      if (this.root.dataset.handles !== "1" || e.button !== 0) return;
      var line = this.lineOf(e.target);
      if (!line || this.locked(line)) return;
      var rem = parseFloat(getComputedStyle(document.documentElement).fontSize) || 16;
      var x = e.clientX - line.getBoundingClientRect().left;
      var grip = this.depth(line) * INDENT_REM * rem;
      if (x < grip || x > grip + 1.2 * rem) return;
      e.preventDefault();
      var self = this;
      var block = [line].concat(this.branch(line));
      block.forEach(function (el) { el.classList.add("pkp-ol-dragging"); });
      var target = null;
      var where = null;
      var clear = function () {
        self.lines().forEach(function (el) { delete el.dataset.drop; });
      };
      var move = function (ev) {
        clear();
        target = null;
        var lines = self.lines().filter(function (el) { return block.indexOf(el) === -1; });
        for (var i = 0; i < lines.length; i++) {
          var r = lines[i].getBoundingClientRect();
          if (ev.clientY < r.top + r.height / 2) { target = lines[i]; where = "before"; break; }
          target = lines[i];
          where = "after";
        }
        if (target) target.dataset.drop = where;
      };
      var up = function () {
        document.removeEventListener("pointermove", move);
        document.removeEventListener("pointerup", up);
        block.forEach(function (el) { el.classList.remove("pkp-ol-dragging"); });
        clear();
        if (!target) return;
        self.remember();
        var shift = self.depth(target) - self.depth(line);
        var anchor = where === "before" ? target : (self.branch(target).slice(-1)[0] || target).nextSibling;
        block.forEach(function (el) {
          self.root.insertBefore(el, anchor);
          self.setDepth(el, self.depth(el) + shift);
        });
        self.clampDepths();
        self.changed();
      };
      document.addEventListener("pointermove", move);
      document.addEventListener("pointerup", up);
    },

    tick: function (line, force) {
      if (!this.canTick || this.locked(line)) return;
      var done = line.dataset.done !== "1";
      var self = this;
      if (!line.dataset.id) {
        line.dataset.done = done ? "1" : "0";
        this.changed();
        return;
      }
      line.dataset.done = done ? "1" : "0";
      this.pushEvent("outline_tick", { id: line.dataset.id, done: done, force: !!force }, function (reply) {
        if (reply && reply.asked) {
          // The page asked first (someone else's subtasks); its answer
          // refreshes the list.
          line.dataset.done = done ? "0" : "1";
        } else if (reply && reply.error) {
          line.dataset.done = done ? "0" : "1";
          self.say(reply.error, "warn");
        }
      });
    },

    open: function (line) {
      if (!line || !line.dataset.id) return;
      var self = this;
      var go = function () {
        if (line.dataset.open) {
          var o = JSON.parse(line.dataset.open);
          self.pushEvent("open_embed", { lv: o.lv, session: o.session });
        } else if (line.dataset.href) {
          var a = document.createElement("a");
          a.href = line.dataset.href;
          a.setAttribute("data-phx-link", "redirect");
          a.setAttribute("data-phx-link-state", "push");
          a.style.display = "none";
          self.el.appendChild(a);
          a.click();
          self.el.removeChild(a);
        }
      };
      if (this.dirty || this.inflight) this.flush(go); else go();
    },

    // ── the bar under the list ───────────────────────────────────────

    say: function (text, tone) {
      this.bar.textContent = text || "";
      if (tone) this.bar.dataset.tone = tone; else delete this.bar.dataset.tone;
    },

    // ── talking to the server ────────────────────────────────────────

    changed: function () {
      var self = this;
      this.dirty = true;
      this.refreshEmpty();
      clearTimeout(this.timer);
      this.timer = setTimeout(function () { self.sync(); }, SYNC_MS);
    },

    flush: function (then) {
      clearTimeout(this.timer);
      if (this.dirty && !this.inflight) this.sync(then);
      else if (this.inflight && then) this.afterSync = then;
      else if (then) then();
    },

    sync: function (then) {
      var self = this;
      if (!this.canEdit) return;
      if (this.inflight || this.composing) {
        if (then) this.afterSync = then;
        return;
      }
      this.normalize();
      this.inflight = true;
      this.dirty = false;
      var sent = this.lines();
      var lines = sent.map(function (el) {
        return {
          id: el.dataset.id || null,
          tmp: el.dataset.tmp || null,
          text: self.text(el),
          depth: self.depth(el),
          done: el.dataset.done === "1"
        };
      });
      this.say(this.el.dataset.saving || "");
      this.pushEvent("outline_sync", { lines: lines, known: Object.keys(this.known) }, function (reply) {
        self.inflight = false;
        if (!reply || reply.error) {
          self.dirty = true;
          self.say((reply && reply.error) || self.el.dataset.failed || "", "warn");
          return;
        }
        var created = reply.created || {};
        self.lines().forEach(function (el) {
          var made = el.dataset.tmp && created[el.dataset.tmp];
          if (made && !el.dataset.id) {
            el.dataset.id = made.uuid;
            el.dataset.ref = made.ref || "";
            if (made.open) el.dataset.open = made.open;
            if (made.href) el.dataset.href = made.href;
            el.dataset.orig = self.text(el);
            self.known[made.uuid] = true;
          }
        });
        (reply.gone || []).forEach(function (id) {
          delete self.known[id];
          self.lines().forEach(function (el) {
            if (el.dataset.id === id) { delete el.dataset.id; el.dataset.ref = ""; el.dataset.tmp = tmpId(); }
          });
        });
        self.say(reply.note || self.el.dataset.saved || "", reply.note ? "warn" : null);
        var next = self.afterSync;
        self.afterSync = null;
        if (self.dirty) self.changed();
        else self.maybeApplyRemote();
        if (next) next();
      });
      if (then) this.afterSync = then;
    },

    maybeApplyRemote: function () {
      if (!this.pendingRemote || this.dirty || this.inflight || this.composing) return;
      var lines = this.pendingRemote;
      this.pendingRemote = null;
      this.applyRemote(lines);
    },

    // The server's list, laid over what is on screen without disturbing
    // the caret: a line that already exists is reused (and moved), new
    // ones are made, lines the server no longer has go — except the blank
    // or not-yet-saved ones, which stay where they are.
    applyRemote: function (lines) {
      var self = this;
      var c = this.caret();
      var keep = c && c.collapsed ? { line: c.start.line, offset: c.start.offset } : null;
      var byId = {};
      var locals = [];
      this.lines().forEach(function (el) {
        if (el.dataset.id) byId[el.dataset.id] = el;
        else locals.push({ el: el, after: el.previousElementSibling, before: el.nextElementSibling });
      });

      var frag = document.createDocumentFragment();
      // What the browser has been shown is what the server last sent:
      // a task gone from there is no longer this list's to remove.
      this.known = {};
      lines.forEach(function (data) {
        self.known[data.id] = true;
        var el = byId[data.id];
        if (el) {
          delete byId[data.id];
          var typed = self.text(el);
          var mine = keep && keep.line === el && typed !== el.dataset.orig;
          var text = mine ? typed : data.text;
          self.fill(el, Object.assign({}, data, { text: text }));
          el.dataset.orig = data.text;
        } else {
          el = self.makeLine(data);
        }
        frag.appendChild(el);
      });
      Object.keys(byId).forEach(function (id) {
        var el = byId[id];
        if (el.parentNode === self.root) self.root.removeChild(el);
      });
      this.root.appendChild(frag);
      locals.forEach(function (local) {
        if (self.text(local.el) === "" && local.el !== (keep && keep.line) && lines.length > 0) {
          if (local.el.parentNode === self.root) self.root.removeChild(local.el);
          return;
        }
        // Beside the line it followed; failing that, before the one it
        // preceded; only then at the end — never jumped to the top.
        var after = local.after && local.after.isConnected ? local.after : null;
        var before = local.before && local.before.isConnected ? local.before : null;
        if (after) self.root.insertBefore(local.el, after.nextSibling);
        else if (before) self.root.insertBefore(local.el, before);
        else self.root.appendChild(local.el);
      });
      this.refreshEmpty();
      if (keep && keep.line.isConnected && document.activeElement === this.root) this.setCaret(keep.line, keep.offset);
    }
  };

  /*
   * PkpTitle: a task's title on a card row, edited in place. Enter saves
   * and adds a task below; Tab / Shift+Tab nest and un-nest; Backspace on
   * an emptied title of a new task removes it; Ctrl+Enter opens the form.
   * Pasting several lines adds a task per line below.
   */
  var Title = {
    mounted: function () {
      var self = this;
      var el = this.el;
      this.saved = el.value;
      el.addEventListener("keydown", function (e) {
        var mod = e.metaKey || e.ctrlKey;
        if (e.key === "Enter" && mod) {
          e.preventDefault();
          self.save(function () { self.pushEvent("outline_open", { id: el.dataset.id }); });
        } else if (e.key === "Enter") {
          e.preventDefault();
          var at = el.selectionStart;
          var head = el.value.slice(0, at);
          var tail = el.selectionEnd >= el.value.length ? "" : el.value.slice(el.selectionEnd);
          if (tail !== "") el.value = head;
          self.save(function () { self.pushEvent("outline_add", { after: el.dataset.id, text: tail }); });
        } else if (e.key === "Tab") {
          e.preventDefault();
          self.save(function () { self.pushEvent("outline_nest", { id: el.dataset.id, dir: e.shiftKey ? "out" : "in" }); });
        } else if (e.key === "Escape") {
          el.value = self.saved;
          el.blur();
        } else if (e.key === "Backspace" && el.value === "" && el.dataset.fresh === "1") {
          e.preventDefault();
          self.pushEvent("outline_drop", { id: el.dataset.id });
        } else if (e.key === "ArrowUp" || e.key === "ArrowDown") {
          var all = Array.prototype.slice.call(document.querySelectorAll("[phx-hook='PkpTitle']"));
          var i = all.indexOf(el);
          var to = all[i + (e.key === "ArrowUp" ? -1 : 1)];
          if (to && !e.altKey && !e.shiftKey) { e.preventDefault(); to.focus(); }
        }
      });
      el.addEventListener("paste", function (e) {
        var plain = (e.clipboardData && e.clipboardData.getData("text/plain")) || "";
        if (plain.indexOf("\n") === -1) return;
        e.preventDefault();
        var rows = parsePasted(plain);
        if (rows.length === 0) return;
        self.save(function () { self.pushEvent("outline_paste", { after: el.dataset.id, lines: rows }); });
      });
      el.addEventListener("blur", function () { self.save(); });
      this.wanted = el.dataset.focus === "1";
      if (this.wanted) { el.focus(); el.setSelectionRange(0, 0); }
    },
    updated: function () {
      if (document.activeElement !== this.el) this.saved = this.el.value;
      // Only on the change to "take the cursor", not on every refresh.
      var wants = this.el.dataset.focus === "1";
      if (wants && !this.wanted && document.activeElement !== this.el) {
        this.el.focus();
        this.el.setSelectionRange(0, 0);
      }
      this.wanted = wants;
    },
    save: function (then) {
      var el = this.el;
      var self = this;
      var value = el.value.replace(/\s+/g, " ").trim();
      if (value === this.saved || value === "") { if (then) then(); return; }
      this.pushEvent("outline_rename", { id: el.dataset.id, text: value }, function () {
        self.saved = value;
        if (then) then();
      });
    }
  };

  /*
   * PkpLinks: a task list's connections, shown without writing them on the
   * cards. Hovering a connected task (a fine pointer only) marks the tasks
   * it waits on and the ones it unlocks, draws arrows between them in the
   * list's left gutter (into the hovered task from what it waits on, out of
   * it to what it unlocks) and fades every other task to half; its trace
   * button does the same for the whole chain, before and after, until the
   * button is pressed again, Escape, or a click outside the list. All here
   * in the browser from `data-links` ([[before, after], …]); the server is
   * never asked.
   *
   * Nothing on a card is touched: the marks are this hook's own <style>
   * rules, keyed by task uuid (the labels are their `content`), so a
   * LiveView patch of a card — a status changing while it is traced —
   * cannot strip them. Only the button's aria-pressed is set on the DOM,
   * and `updated` sets it again. The arrows live in the list's own
   * `<svg data-pkp-arrows phx-update="ignore">`, which a patch leaves alone.
   */
  var LINKS_STYLE_ID = "pkp-links-style";
  var LINKS_CSS = [
    "[data-pkp-card]{transition:opacity .12s,background-color .12s}",
    // The label is a tab on the card's top-left edge, out of the row's flow:
    // it comes and goes without moving anything (the view icon stays put).
    "[data-pkp-rel]{position:absolute;left:.75rem;top:-.6rem;z-index:1;pointer-events:none;display:inline-flex;align-items:center;gap:.3rem;font-size:.7rem;font-weight:600;line-height:1.15rem;white-space:nowrap;border-radius:999px}",
    "@media (prefers-reduced-motion:reduce){[data-pkp-card]{transition:none}}"
  ].join("\n");
  var LK_BEFORE = "#7c5cd6", LK_AFTER = "#e0682b", LK_AFTER_TEXT = "#d0571d";
  var LK_PRIMARY = "var(--color-primary,#4f46e5)";

  function cssString(text) {
    return '"' + String(text || "").replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/[\r\n]+/g, " ") + '"';
  }

  var Links = {
    mounted: function () {
      if (!document.getElementById(LINKS_STYLE_ID)) {
        var style = document.createElement("style");
        style.id = LINKS_STYLE_ID;
        style.textContent = LINKS_CSS;
        document.head.appendChild(style);
      }
      var self = this;
      this.marks = document.createElement("style");
      this.marks.setAttribute("data-pkp-links-for", this.el.id);
      document.head.appendChild(this.marks);
      this.pin = null;
      this.hover = null;
      this.arrows = this.el.querySelector("[data-pkp-arrows]");
      this.onResize = function () { if (self.pin !== null || self.hover !== null) self.apply(); };
      window.addEventListener("resize", this.onResize);
      this.fine = window.matchMedia("(hover: hover) and (pointer: fine)");
      this.read();

      // Hover after a short pause; between two cards the highlight moves
      // straight over, and leaving clears after a grace period — moving
      // down the list does not flicker.
      this.onOver = function (e) {
        if (!self.fine.matches) return;
        var card = e.target.closest("[data-pkp-card]");
        if (!card || !self.el.contains(card)) return;
        var id = card.getAttribute("data-pkp-card");
        clearTimeout(self.leaveT);
        clearTimeout(self.enterT);
        if (!self.linked(id)) { self.leaveT = setTimeout(function () { self.setHover(null); }, 90); return; }
        if (self.hover === id) return;
        self.enterT = setTimeout(function () { self.setHover(id); }, self.hover === null ? 140 : 60);
      };
      this.onOut = function (e) {
        if (!self.fine.matches) return;
        var card = e.target.closest("[data-pkp-card]");
        if (!card || card.contains(e.relatedTarget)) return;
        clearTimeout(self.enterT);
        clearTimeout(self.leaveT);
        self.leaveT = setTimeout(function () { self.setHover(null); }, 120);
      };
      this.onClick = function (e) {
        var button = e.target.closest("[data-pkp-trace]");
        if (!button || !self.el.contains(button)) return;
        e.preventDefault();
        var id = button.getAttribute("data-pkp-trace");
        self.pin = self.pin === id ? null : id;
        self.hover = null;
        self.apply();
      };
      this.onFocus = function (e) {
        var button = e.target.closest && e.target.closest("[data-pkp-trace]");
        if (button && self.pin === null) self.setHover(button.getAttribute("data-pkp-trace"));
      };
      this.onBlur = function (e) {
        if (e.target.closest && e.target.closest("[data-pkp-trace]") && self.pin === null) self.setHover(null);
      };
      this.onKey = function (e) {
        if (e.key === "Escape" && (self.pin !== null || self.hover !== null)) {
          self.pin = null;
          self.hover = null;
          self.apply();
        }
      };
      this.onDoc = function (e) {
        if (self.pin !== null && !self.el.contains(e.target)) {
          self.pin = null;
          self.apply();
        }
      };
      // Dragging a card: no highlight while it moves.
      this.onDrag = function () {
        self.hover = null;
        self.pin = null;
        self.apply();
      };

      this.el.addEventListener("pointerover", this.onOver);
      this.el.addEventListener("pointerout", this.onOut);
      this.el.addEventListener("click", this.onClick);
      this.el.addEventListener("focusin", this.onFocus);
      this.el.addEventListener("focusout", this.onBlur);
      this.el.addEventListener("dragstart", this.onDrag);
      document.addEventListener("keydown", this.onKey);
      document.addEventListener("click", this.onDoc, true);
      this.apply();
    },
    updated: function () {
      this.read();
      if (this.pin !== null && !this.card(this.pin)) this.pin = null;
      if (this.hover !== null && !this.card(this.hover)) this.hover = null;
      this.apply();
    },
    destroyed: function () {
      clearTimeout(this.enterT);
      clearTimeout(this.leaveT);
      document.removeEventListener("keydown", this.onKey);
      document.removeEventListener("click", this.onDoc, true);
      window.removeEventListener("resize", this.onResize);
      if (this.marks) this.marks.remove();
    },
    read: function () {
      var pairs = [];
      this.arrows = this.el.querySelector("[data-pkp-arrows]");
      try { pairs = JSON.parse(this.el.dataset.links || "[]"); } catch (_) { pairs = []; }
      try { this.labels = JSON.parse(this.el.dataset.labels || "{}"); } catch (_) { this.labels = {}; }
      var up = {}, down = {};
      // The ids end up in CSS selectors: only uuids pass.
      var uuid = /^[0-9a-f-]{36}$/i;
      pairs = pairs.filter(function (p) {
        return Array.isArray(p) && uuid.test(p[0]) && uuid.test(p[1]);
      });
      this.pairs = pairs;
      pairs.forEach(function (p) {
        (up[p[1]] = up[p[1]] || []).push(p[0]);
        (down[p[0]] = down[p[0]] || []).push(p[1]);
      });
      this.up = up;
      this.down = down;
    },
    linked: function (id) { return !!(this.up[id] || this.down[id]); },
    card: function (id) {
      return this.el.querySelector('[data-pkp-card="' + (window.CSS && CSS.escape ? CSS.escape(id) : id) + '"]');
    },
    // Everything reachable from `id` one way, guarded against a cycle.
    reach: function (id, map) {
      var seen = {}, stack = (map[id] || []).slice();
      while (stack.length) {
        var x = stack.pop();
        if (seen[x] || x === id) continue;
        seen[x] = true;
        (map[x] || []).forEach(function (y) { stack.push(y); });
      }
      return seen;
    },
    setHover: function (id) {
      if (this.hover === id) return;
      this.hover = id;
      if (this.pin === null) this.apply();
    },
    apply: function () {
      var self = this;
      var labels = this.labels || {};
      var src = this.pin !== null ? this.pin : this.hover;
      var traced = this.pin !== null;

      this.el.querySelectorAll("[data-pkp-trace]").forEach(function (b) {
        var on = b.getAttribute("data-pkp-trace") === self.pin;
        b.setAttribute("aria-pressed", on ? "true" : "false");
        if (labels.trace) b.title = on ? labels.stop : labels.trace;
      });
      if (src === null) { this.marks.textContent = ""; this.draw([]); return; }

      // Hover: direct neighbours only, nothing fades. Trace: the whole
      // chain, and what is not part of it fades a little.
      var b1 = {}, a1 = {};
      (this.up[src] || []).forEach(function (x) { b1[x] = true; });
      (this.down[src] || []).forEach(function (x) { a1[x] = true; });
      var bAll = traced ? this.reach(src, this.up) : b1;
      var aAll = traced ? this.reach(src, this.down) : a1;

      var scope = "#" + (window.CSS && CSS.escape ? CSS.escape(this.el.id) : this.el.id) + " ";
      var card = function (id) { return scope + '[data-pkp-card="' + id + '"]'; };
      var rel = function (id) { return scope + '[data-pkp-rel="' + id + '"]'; };
      var rules = [];
      var mark = function (id, colour, direct, label, textColour) {
        rules.push(card(id) + (direct
          ? "{opacity:1;background-color:color-mix(in oklab," + colour + " 6%,transparent);box-shadow:inset 3px 0 0 " + colour + "}"
          : "{opacity:1;background-image:repeating-linear-gradient(to bottom," + colour + " 0 3px,transparent 3px 6px);background-size:2px 100%;background-repeat:no-repeat;background-position:left top}"));
        rules.push(rel(id) + "{color:" + textColour + ";background-color:var(--color-base-100,#fff);padding:0 .45rem;box-shadow:0 0 0 1px " +
          (direct ? "currentColor" : "color-mix(in oklab,currentColor 45%,transparent)") + "}");
        rules.push(rel(id) + "::before{content:'';width:.4rem;height:.4rem;border-radius:50%;" +
          (direct ? "background:currentColor" : "box-shadow:inset 0 0 0 1.5px currentColor") + "}");
        rules.push(rel(id) + "::after{content:" + cssString(label) + "}");
      };

      // Everything outside what is shown fades to half, hover and trace.
      rules.push(scope + "[data-pkp-card]{opacity:.4}");
      rules.push(card(src) + "{opacity:1;box-shadow:inset 0 0 0 1px color-mix(in oklab,currentColor 28%,transparent)}");
      Object.keys(b1).forEach(function (id) { mark(id, LK_BEFORE, true, labels.before, LK_BEFORE); });
      Object.keys(a1).forEach(function (id) { if (!b1[id]) mark(id, LK_AFTER, true, labels.after, LK_AFTER_TEXT); });
      Object.keys(bAll).forEach(function (id) { if (!b1[id] && !a1[id] && id !== src) mark(id, LK_BEFORE, false, labels.earlier, LK_BEFORE); });
      Object.keys(aAll).forEach(function (id) { if (!b1[id] && !a1[id] && !bAll[id] && id !== src) mark(id, LK_AFTER, false, labels.later, LK_AFTER_TEXT); });
      if (traced) rules.push(scope + '[data-pkp-trace="' + src + '"]{color:' + LK_PRIMARY + ";background-color:color-mix(in oklab," + LK_PRIMARY + " 12%,transparent)}");

      this.marks.textContent = rules.join("\n");

      // Arrows run in the flow's direction, from what comes first to what
      // it frees. Hover: the hovered task's own. Trace: every connection
      // inside the chain, the ones not touching it dashed.
      var inChain = {};
      inChain[src] = true;
      Object.keys(bAll).forEach(function (id) { inChain[id] = true; });
      Object.keys(aAll).forEach(function (id) { inChain[id] = true; });
      var edges = (this.pairs || []).filter(function (p) {
        return traced ? inChain[p[0]] && inChain[p[1]] : p[0] === src || p[1] === src;
      }).map(function (p) {
        return { from: p[0], to: p[1], after: !!aAll[p[1]] && !bAll[p[1]], direct: p[0] === src || p[1] === src };
      });
      this.draw(edges);
    },
    // Draws `edges` into the list's arrow layer: a curve from the left edge
    // of the earlier task, out into the gutter and back into the later
    // one, with a head. Cards out of view (folded) are skipped.
    draw: function (edges) {
      var svg = this.arrows;
      if (!svg) return;
      var NS = "http://www.w3.org/2000/svg";
      while (svg.firstChild) svg.removeChild(svg.firstChild);
      if (!edges.length) return;
      var self = this, base = this.el.getBoundingClientRect();
      var mid = this.el.id.replace(/[^\w-]/g, "");
      var defs = document.createElementNS(NS, "defs");
      [["b", LK_BEFORE], ["a", LK_AFTER]].forEach(function (m) {
        var marker = document.createElementNS(NS, "marker");
        marker.setAttribute("id", mid + "-head-" + m[0]);
        marker.setAttribute("viewBox", "0 0 10 10");
        marker.setAttribute("refX", "9");
        marker.setAttribute("refY", "5");
        marker.setAttribute("markerWidth", "7");
        marker.setAttribute("markerHeight", "7");
        marker.setAttribute("orient", "auto-start-reverse");
        var head = document.createElementNS(NS, "path");
        head.setAttribute("d", "M0,0 L10,5 L0,10 z");
        head.setAttribute("fill", m[1]);
        marker.appendChild(head);
        defs.appendChild(marker);
      });
      svg.appendChild(defs);
      // An arrow leaves a task low on its edge and arrives high on the
      // next one's, so on the hovered task what comes in and what goes out
      // do not meet at one point.
      var point = function (id, leaving) {
        var c = self.card(id);
        if (!c) return null;
        var r = c.getBoundingClientRect();
        if (!r.height) return null;
        var inset = Math.min(14, r.height / 4);
        return { x: r.left - base.left, y: (leaving ? r.bottom - inset : r.top + inset) - base.top };
      };
      edges.forEach(function (e) {
        var p0 = point(e.from, true), p1 = point(e.to, false);
        if (!p0 || !p1) return;
        // Farther apart, wider out — stacked arrows do not sit on each other.
        var bow = Math.max(12, Math.min(28, 12 + Math.abs(p1.y - p0.y) / 25));
        var bx = Math.min(p0.x, p1.x) - bow;
        var path = document.createElementNS(NS, "path");
        path.setAttribute("d", "M" + (p0.x - 1) + "," + p0.y + " C" + bx + "," + p0.y + " " + bx + "," + p1.y + " " + (p1.x - 1) + "," + p1.y);
        path.setAttribute("fill", "none");
        path.setAttribute("stroke", e.after ? LK_AFTER : LK_BEFORE);
        path.setAttribute("stroke-width", e.direct ? "2" : "1.5");
        path.setAttribute("stroke-linecap", "round");
        if (!e.direct) path.setAttribute("stroke-dasharray", "4 3");
        path.setAttribute("marker-end", "url(#" + mid + "-head-" + (e.after ? "a" : "b") + ")");
        svg.appendChild(path);
        var dot = document.createElementNS(NS, "circle");
        dot.setAttribute("cx", p0.x);
        dot.setAttribute("cy", p0.y);
        dot.setAttribute("r", "2.5");
        dot.setAttribute("fill", e.after ? LK_AFTER : LK_BEFORE);
        svg.appendChild(dot);
      });
    }
  };

  // ── PkpBoard: one column of the board ────────────────────────────────
  //
  // Core's SortableGrid serves sortable lists; the board needs three things
  // it does not take as options (the boss, 2026-10-29: a card dropped only
  // when let go over one particular spot):
  //   * the whole card picks up, not a small handle — its links and buttons
  //     still click (a press that does not move is a click; a drag that
  //     started on a link swallows the click after it, SortableJS's own);
  //   * on a touch screen only after a short hold, so a swipe still scrolls
  //     the board instead of grabbing whatever card is under the finger;
  //   * while a card is held, every column shows it takes drops and the one
  //     under the card lights up, with a dashed gap where it will land.
  // The column's whole body is the list (the template makes it fill the
  // column, empty or not), so anywhere in a column is a drop.
  //
  // Sends what SortableGrid sends — `{ordered_ids, moved_id, status,
  // fromStatus}` under the column's `data-board-event` — and answers the
  // page's `sortable:flash`. SortableJS is the host's vendored copy, loaded
  // through core's loader (`PhoenixKitLibraries`, in core since 2.60).
  var BOARD_STYLE_ID = "pkp-board-style";
  var BOARD_CSS = [
    ".pkp-board-card{-webkit-touch-callout:none;-webkit-user-select:none;user-select:none}",
    ".pkp-board-list{transition:background-color .12s,box-shadow .12s}",
    // Held: every column is a place to drop; the one holding the gap lights up.
    ".pkp-board-dragging .pkp-board-list{box-shadow:inset 0 0 0 2px color-mix(in oklab,currentColor 10%,transparent)}",
    ".pkp-board-dragging .pkp-board-list:has(.pkp-board-ghost){background-color:color-mix(in oklab,var(--color-primary,#4f46e5) 10%,transparent);box-shadow:inset 0 0 0 2px var(--color-primary,#4f46e5)}",
    // The gap: where the card lands, as a dashed outline of its size.
    ".pkp-board-ghost{opacity:1!important;background:transparent!important;border:2px dashed var(--color-primary,#4f46e5)!important;box-shadow:none!important}",
    ".pkp-board-ghost>*{visibility:hidden}",
    ".pkp-board-drag{cursor:grabbing!important;transform:rotate(1.5deg);box-shadow:0 10px 15px -3px rgba(0,0,0,.15)}",
    ".pkp-board-list:has(.sortable-item) .pkp-board-empty{display:none}",
    ".pkp-board-ok,.pkp-board-err{position:relative}",
    ".pkp-board-ok::after,.pkp-board-err::after{content:'';position:absolute;inset:0;pointer-events:none;border-radius:inherit;animation:pkp-board-flash 1.1s ease-out}",
    ".pkp-board-ok::after{--pkp-flash:rgba(34,197,94,.35)}",
    ".pkp-board-err::after{--pkp-flash:rgba(239,68,68,.35)}",
    "@keyframes pkp-board-flash{15%{background-color:var(--pkp-flash)}100%{background-color:transparent}}",
    "@media (prefers-reduced-motion:reduce){.pkp-board-drag{transform:none}.pkp-board-ok::after,.pkp-board-err::after{animation:none}}"
  ].join("\n");

  function loadSortable() {
    if (typeof window.Sortable === "function") return Promise.resolve();
    var libs = window.PhoenixKitLibraries;
    if (!libs || typeof libs.loadVendored !== "function") {
      return Promise.reject(new Error("SortableJS is not available"));
    }
    return libs.loadVendored("SortableJS", "sortable", {
      check: function () { return typeof window.Sortable === "function"; }
    });
  }

  var Board = {
    mounted: function () {
      var self = this;
      this.gone = false;
      if (!document.getElementById(BOARD_STYLE_ID)) {
        var style = document.createElement("style");
        style.id = BOARD_STYLE_ID;
        style.textContent = BOARD_CSS;
        document.head.appendChild(style);
      }
      // Every column hears it; one card answers, so it flashes once.
      this.handleEvent("sortable:flash", function (payload) {
        if (!payload || !payload.uuid || !self.el.isConnected) return;
        var cls = payload.status === "ok" ? "pkp-board-ok" : payload.status === "error" ? "pkp-board-err" : null;
        if (!cls) return;
        var card = self.el.querySelector('.sortable-item[data-id="' + CSS.escape(payload.uuid) + '"]');
        if (!card) return;
        card.classList.remove("pkp-board-ok", "pkp-board-err");
        void card.offsetWidth;
        card.classList.add(cls);
        setTimeout(function () { card.classList.remove(cls); }, 1200);
      });
      loadSortable().then(function () {
        if (!self.gone) self.init();
      }, function () {
        // Reported by core's loader; the step buttons still move cards.
      });
    },

    init: function () {
      var self = this;
      var el = this.el;
      var board = function () { return el.parentElement && el.parentElement.parentElement; };
      this.sortable = window.Sortable.create(el, {
        group: el.dataset.boardGroup,
        draggable: ".sortable-item",
        // Form controls never start a drag; links and buttons may (a press
        // that does not move is still their click), and nothing filtered is
        // prevented, so no click is lost to the filter.
        filter: "input, textarea, select, .sortable-ignore",
        preventOnFilter: false,
        forceFallback: true,
        fallbackOnBody: true,
        fallbackTolerance: 4,
        delay: 180,
        delayOnTouchOnly: true,
        touchStartThreshold: 6,
        animation: 150,
        emptyInsertThreshold: 24,
        ghostClass: "pkp-board-ghost",
        chosenClass: "pkp-board-chosen",
        dragClass: "pkp-board-drag",
        onStart: function () {
          var b = board();
          if (b) b.classList.add("pkp-board-dragging");
        },
        onEnd: function (evt) {
          var b = board();
          if (b) b.classList.remove("pkp-board-dragging");
          if (evt.from === evt.to && evt.oldIndex === evt.newIndex) return;
          try {
            var to = evt.to;
            var ids = Array.prototype.map.call(
              to.querySelectorAll(".sortable-item[data-id]"),
              function (n) { return n.dataset.id; }
            );
            self.pushEvent(to.dataset.boardEvent || el.dataset.boardEvent, {
              ordered_ids: ids,
              moved_id: evt.item.dataset.id,
              status: to.dataset.boardStatus,
              fromStatus: evt.from.dataset.boardStatus
            });
          } catch (err) {
            console.error("PkpBoard.onEnd failed:", err);
          }
        }
      });
    },

    destroyed: function () {
      this.gone = true;
      if (this.sortable) {
        this.sortable.destroy();
        this.sortable = null;
      }
    }
  };

  window.PhoenixKitProjectsHooks = { PkpOutline: Outline, PkpTitle: Title, PkpLinks: Links, PkpBoard: Board };
})();
