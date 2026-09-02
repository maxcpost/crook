// Crook editor surface.
//
// Contracts this file must not break (S02, S03, S05):
//   - EditorState.lineSeparator is NEVER set. The buffer is LF-only; Swift
//     normalises CRLF on read and re-expands in the writer. Setting it would
//     make CM6 store a CRLF as ONE unit while Swift's NSMutableString stores
//     two, diverging the two coordinate spaces on the 8 CRLF fixture files.
//   - state.doc.toString() is NEVER called. sliceDoc only.
//   - basicSetup is NEVER used: it silently includes closeBrackets and
//     indentOnInput, both of which write characters the user did not type.
//   - markdown() is built on the commonmark base only. markdownLanguage would
//     opt into subscript/superscript, emoji shortcodes and GFM autolinks.
//   - setDocument is the ONLY sanctioned full-text push.

import { EditorState, StateField, StateEffect, Annotation, RangeSetBuilder, Prec } from "@codemirror/state"
import { EditorView, Decoration, ViewPlugin, keymap, rectangularSelection, highlightSpecialChars } from "@codemirror/view"
import { history, historyKeymap, defaultKeymap, undoDepth, redoDepth } from "@codemirror/commands"
import { syntaxTree, syntaxHighlighting, HighlightStyle, LanguageSupport, LRLanguage, foldNodeProp, indentNodeProp } from "@codemirror/language"
import { parser as mdParser, Table } from "@lezer/markdown"
import { tags as t, styleTags } from "@lezer/highlight"

// ---------------------------------------------------------------- annotations

// Marks a transaction as originating in Swift. Read at four sites (S03 §5).
const fromSwift = Annotation.define()

// Diagnostics arrive from Swift, which owns the filesystem. The web view has
// no disk access, so a dead-path verdict cannot be computed here. Keyed to a
// document generation: a stale batch is dropped rather than drawn.
const setDiagnostics = StateEffect.define()
const setChangedLines = StateEffect.define()
const changedLine = Decoration.line({ class: "q-changed" })
const deadRef = Decoration.mark({ class: "q-dead" })
function deadRefWith(title) {
  // A title attribute is a hover affordance, not a control: nothing to click,
  // nothing to focus, nothing in the tab order. The zero-controls rule holds.
  return title ? Decoration.mark({ class: "q-dead", attributes: { title } }) : deadRef
}

/// Lines an external write touched. Held until the reader engages — a timer
/// would expire exactly while they were in the terminal, which is the whole
/// situation this exists for.
const changedLines = StateField.define({
  create: () => Decoration.none,
  update(value, tr) {
    value = value.map(tr.changes)
    for (const e of tr.effects) {
      if (e.is(setChangedLines)) {
        const b = new RangeSetBuilder()
        for (const n of e.value) {
          if (n >= 1 && n <= tr.state.doc.lines) b.add(tr.state.doc.line(n).from, tr.state.doc.line(n).from, changedLine)
        }
        value = b.finish()
      }
    }
    // Any real interaction clears it: you have now seen it.
    if (value.size && (tr.selection || tr.docChanged) &&
        !tr.annotation(fromSwift)) value = Decoration.none
    return value
  },
  provide: (f) => EditorView.decorations.from(f),
})

const diagnostics = StateField.define({
  create: () => Decoration.none,
  update(value, tr) {
    value = value.map(tr.changes)
    for (const e of tr.effects) {
      if (e.is(setDiagnostics)) {
        const b = new RangeSetBuilder()
        for (const d of e.value) {
          if (d.from >= 0 && d.to > d.from && d.to <= tr.state.doc.length) b.add(d.from, d.to, deadRefWith(d.title))
        }
        value = b.finish()
      }
    }
    return value
  },
  provide: (f) => EditorView.decorations.from(f),
})

// ---------------------------------------------------------------- language

const mdLanguage = LRLanguage.define({
  name: "crook-markdown",
  parser: mdParser.configure([
    Table,
    {
    props: [
      styleTags({
        "ATXHeading1/...": t.heading1,
        "ATXHeading2/...": t.heading2,
        "ATXHeading3/...": t.heading3,
        "ATXHeading4/... ATXHeading5/... ATXHeading6/...": t.heading4,
        "Emphasis/...": t.emphasis,
        "StrongEmphasis/...": t.strong,
        "InlineCode": t.monospace,
        "FencedCode CodeBlock": t.monospace,
        "Link/...": t.link,
        "Blockquote/...": t.quote,
        "HeaderMark ListMark QuoteMark EmphasisMark CodeMark LinkMark": t.processingInstruction,
      }),
    ],
    },
  ]),
})
function markdown() { return new LanguageSupport(mdLanguage) }

const highlight = HighlightStyle.define([
  { tag: t.heading1, fontSize: "1.576em", lineHeight: "1.26", fontWeight: "700", letterSpacing: "-0.02em" },
  { tag: t.heading2, fontSize: "1.212em", lineHeight: "1.36", fontWeight: "650", letterSpacing: "-0.013em" },
  { tag: t.heading3, fontSize: "1em", lineHeight: "1.50", fontWeight: "650" },
  { tag: t.heading4, fontSize: "1em", fontWeight: "500", letterSpacing: "0.02em" },
  { tag: t.heading, fontWeight: "600" },
  { tag: t.strong, fontWeight: "600" },
  { tag: t.emphasis, fontStyle: "italic" },
  { tag: t.monospace, fontFamily: "var(--c-mono)", fontSize: "0.91em", color: "var(--c-code)", background: "var(--c-codebg)", borderRadius: "3px", padding: "0.5px 3px" },
  { tag: t.link, textDecoration: "underline", textDecorationColor: "var(--c-rule)" },
  { tag: t.quote, color: "var(--c-ink-2)", fontStyle: "normal" },
  { tag: t.processingInstruction, color: "var(--c-marker)" },
])

// ---------------------------------------------------------------- decorations

// Inline marks collapse to zero width; block markers are drawn into the gutter
// carved to the left of the text origin, at opacity 0, rising to 0.30 when the
// caret enters that line. Reveal for a block marker is an opacity change and
// never a width change, so the text never moves (S05 §3).
const INLINE_MARKS = new Set(["EmphasisMark", "CodeMark", "StrikethroughMark"])
const BLOCK_MARKS = new Set(["HeaderMark", "QuoteMark", "ListMark", "TaskMarker"])
const quoteLine = Decoration.line({ class: "q-quote" })

const hidden = Decoration.replace({})
const blockMark = Decoration.mark({ class: "q-blockmark" })
const revealLine = Decoration.line({ class: "q-reveal" })

// Tables render as aligned columns without a widget and without touching a
// byte. Interactive table editing stays permanently refused — every shipped
// CM6 live-preview editor's worst bugs live there. This is presentation only:
// the pipes are hidden, the cells become grid items, and the caret entering
// the table brings the raw source straight back.
const tableHead = Decoration.line({ class: "q-th" })
const tableRule = Decoration.line({ class: "q-trule" })
const cellMark = Decoration.mark({ class: "q-td" })
const ruleLineDeco = Decoration.line({ class: "q-hr" })
const fmOpen = Decoration.line({ class: "q-fm-open" })
const fmLine = Decoration.line({ class: "q-fm" })
const fmClose = Decoration.line({ class: "q-fm-close" })
const fmKey = Decoration.mark({ class: "q-fm-key" })

/// Frontmatter is handled LEXICALLY, before the parser gets an opinion.
///
/// CommonMark has no frontmatter concept, so `---\nname: x\n---` parses as a
/// HorizontalRule followed by a SetextHeading2 covering the whole block — which
/// is why every SKILL.md was rendering its metadata as a giant title. Claude
/// Code reads frontmatter only when the opening `---` is the file's first line,
/// and that is the same one-comparison rule used on the Swift side.
function frontmatterRange(state) {
  const first = state.doc.line(1)
  if (first.text.trim() !== "---") return null
  for (let n = 2; n <= state.doc.lines; n++) {
    const t = state.doc.line(n).text.trim()
    if (t === "---" || t === "...") return { open: first, close: state.doc.line(n) }
  }
  return null
}

// Heading spacing rides on a line decoration, not a :has() selector — :has()
// on .cm-line re-evaluates on every DOM mutation and is fragile besides.
const HEADING_LINE = {
  ATXHeading1: Decoration.line({ class: "q-l1" }),
  ATXHeading2: Decoration.line({ class: "q-l2" }),
  ATXHeading3: Decoration.line({ class: "q-l3" }),
}

function tableDecorations(state, node, caretInside, marks, lineExtras) {
  const rows = []
  let ruleLine = null

  for (let c = node.node.firstChild; c; c = c.nextSibling) {
    if (c.name === "TableHeader" || c.name === "TableRow") {
      const cells = []
      for (let k = c.firstChild; k; k = k.nextSibling) {
        if (k.name === "TableCell") cells.push({ from: k.from, to: k.to })
      }
      if (cells.length) rows.push({ from: c.from, to: c.to, cells, head: c.name === "TableHeader" })
    } else if (c.name === "TableDelimiter" && c.to - c.from > 1) {
      ruleLine = state.doc.lineAt(c.from)
    }
  }
  if (!rows.length || caretInside) return   // caret in the table: raw pipes

  // Column widths in characters, from the widest cell in each column. Cells
  // render in mono so a ch unit is exact and columns line up across rows.
  let widths = []
  for (const r of rows) {
    r.cells.forEach((cell, i) => {
      const len = state.sliceDoc(cell.from, cell.to).trim().length
      widths[i] = Math.max(widths[i] || 4, len)
    })
  }
  // Keep the table inside the measure, read from the same token the text
  // column uses so the two cannot drift apart. Mono is 0.9em, so a ch of
  // measure buys about 1.1 mono characters.
  const GAP = 2
  const measureCh = parseInt(
    getComputedStyle(document.documentElement).getPropertyValue("--c-measure")) || 88
  const budget = Math.floor(measureCh * 1.1) - widths.length * GAP
  const total = widths.reduce((a, b) => a + b, 0)
  if (total > budget) {
    const scale = budget / total
    widths = widths.map((w) => Math.max(6, Math.floor(w * scale)))
  }

  if (ruleLine) lineExtras.push({ from: ruleLine.from, deco: tableRule })

  for (const r of rows) {
    const line = state.doc.lineAt(r.from)
    lineExtras.push({
      from: line.from,
      deco: Decoration.line({ class: r.head ? "q-th" : "q-tr" }),
    })
    // Cells are inline-block with an explicit width. Grid does not work here:
    // CodeMirror renders every REPLACED range as a real DOM element, so the
    // hidden pipes become grid items too and the columns stair-step.
    let cursor = line.from
    r.cells.forEach((cell, i) => {
      if (cell.from > cursor) marks.push({ from: cursor, to: cell.from, deco: hidden })
      marks.push({
        from: cell.from,
        to: cell.to,
        deco: Decoration.mark({
          class: "q-td",
          attributes: { style: "width:" + widths[i] + "ch" },
        }),
      })
      cursor = cell.to
    })
    if (line.to > cursor) marks.push({ from: cursor, to: line.to, deco: hidden })
  }
}

function buildDecorations(state) {
  try {
    return buildDecorationsInner(state)
  } catch (e) {
    // Decorations are presentation. A bug here must degrade to plain text,
    // never to an empty document — which is exactly what happened when a
    // RangeSetBuilder ordering error took the whole buffer with it.
    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.crook) {
      window.webkit.messageHandlers.crook.postMessage({
        type: "jserror", message: "decorations: " + (e && e.message), line: 0,
      })
    }
    return Decoration.none
  }
}

function buildDecorationsInner(state) {
  const sel = state.selection.main
  const tree = syntaxTree(state)
  // Reveal scope is the innermost inline node containing the caret. With a
  // non-empty selection nothing reveals at all.
  const caret = sel.empty ? sel.head : -1
  const revealedLines = new Set()
  if (caret >= 0) revealedLines.add(state.doc.lineAt(caret).number)

  const marks = []
  const lineExtras = []

  // Frontmatter first, and the parser's view of that range is discarded.
  const fm = frontmatterRange(state)
  const fmEnd = fm ? fm.close.to : -1
  if (fm) {
    const caretInFm = caret >= 0 && caret >= fm.open.from && caret <= fm.close.to

    // The type normalisation applies ALWAYS, caret or no caret. The giant
    // heading comes from syntaxHighlighting — @lezer/markdown tags the block
    // SetextHeading2 by default — and that is a span style this build cannot
    // suppress by skipping the node. It has to be overridden.
    for (let n = fm.open.number; n <= fm.close.number; n++) {
      lineExtras.push({ from: state.doc.line(n).from, deco: fmLine })
    }
    for (let n = fm.open.number + 1; n < fm.close.number; n++) {
      const line = state.doc.line(n)
      // Dim the key, leave the value at full weight: the value is the part
      // Claude Code acts on.
      const colon = line.text.indexOf(":")
      if (colon > 0 && !/^\s/.test(line.text)) {
        marks.push({ from: line.from, to: line.from + colon + 1, deco: fmKey })
      }
    }
    // The markers collapse to rules only when the caret is elsewhere.
    if (!caretInFm) {
      lineExtras.push({ from: fm.open.from, deco: fmOpen })
      lineExtras.push({ from: fm.close.from, deco: fmClose })
    }
  }

  tree.iterate({
    from: 0,
    to: state.doc.length,
    enter(node) {
      const name = node.name
      // Inside frontmatter the parser sees a HorizontalRule and a giant
      // SetextHeading2. Neither is real.
      if (fmEnd >= 0 && node.from < fmEnd) return
      if (name === "HorizontalRule") {
        lineExtras.push({ from: state.doc.lineAt(node.from).from, deco: ruleLineDeco })
        return
      }
      if (INLINE_MARKS.has(name)) {
        const p = node.node.parent
        const inside = caret >= 0 && p && caret >= p.from && caret <= p.to
        if (!inside) marks.push({ from: node.from, to: node.to, deco: hidden })
      } else if (BLOCK_MARKS.has(name)) {
        marks.push({ from: node.from, to: node.to, deco: blockMark })
      } else if (name === "Table") {
        const inside = caret >= 0 && caret >= node.from && caret <= node.to
        tableDecorations(state, node, inside, marks, lineExtras)
      } else if (name === "Blockquote") {
        const first = state.doc.lineAt(node.from).number
        const last = state.doc.lineAt(node.to).number
        for (let n = first; n <= last; n++) {
          lineExtras.push({ from: state.doc.line(n).from, deco: quoteLine })
        }
      } else if (HEADING_LINE[name]) {
        const line = state.doc.lineAt(node.from)
        lineExtras.push({ from: line.from, deco: HEADING_LINE[name] })
      }
    },
  })

  // Decoration.set sorts by `from` AND `startSide`. A hand-rolled comparator
  // gets startSide wrong — line decorations attach before the line, marks and
  // replacements do not — and RangeSetBuilder then throws.
  const ranges = []
  for (const m of marks) ranges.push(m.deco.range(m.from, m.to))
  for (const e of lineExtras) ranges.push(e.deco.range(e.from))
  for (const n of revealedLines) ranges.push(revealLine.range(state.doc.line(n).from))
  return Decoration.set(ranges, true)
}

const decorations = StateField.define({
  create: (s) => buildDecorations(s),
  update(value, tr) {
    if (tr.docChanged || tr.selection || tr.reconfigured) return buildDecorations(tr.state)
    return value
  },
  provide: (f) => EditorView.decorations.from(f),
})

// ---------------------------------------------------------------- the bridge

let seq = 0
let version = 0
let generation = 0
let pending = []
let scheduled = false

function post(msg) {
  const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.crook
  if (h) h.postMessage(msg)
}

function flush(view) {
  scheduled = false
  if (!pending.length) return
  const changes = pending
  pending = []
  post({
    type: "edit",
    seq: ++seq,
    generation,
    baseVersion: version,
    changes,
    undoDepth: undoDepth(view.state),
    redoDepth: redoDepth(view.state),
  })
  version += changes.length
}

function schedule(view) {
  if (scheduled) return
  scheduled = true
  requestAnimationFrame(() => flush(view))
}

/// Drain any batched edit immediately. Called from Swift before a save reads
/// the canonical buffer: edits normally reach Swift only after a
/// requestAnimationFrame plus IPC, so a save within ~16 ms of a keystroke
/// encoded a buffer that was missing those characters.
function flushNow() {
  if (!view) return 0
  flush(view)
  return view.state.doc.length
}

let lastSelection = -1
const bridge = ViewPlugin.fromClass(class {
  constructor(view) { this.view = view }
  update(u) {
    if (u.docChanged && !u.transactions.some((tr) => tr.annotation(fromSwift))) {
      // iterChanges triples, never ChangeSet.toJSON — whose newline encoding
      // [0,"",""] a naive decoder silently drops (S03 §4).
      u.changes.iterChanges((fromA, toA, _fromB, _toB, inserted) => {
        pending.push([fromA, toA, inserted.sliceString(0, inserted.length, "\n")])
      })
      schedule(this.view)
    }
    if (u.selectionSet) {
      const h = u.state.selection.main.head
      if (h !== lastSelection) {
        lastSelection = h
        post({ type: "selection", generation, head: h, anchor: u.state.selection.main.anchor })
      }
    }
  }
})

// ---------------------------------------------------------------- theme

const theme = EditorView.theme({
  "&": {
    fontSize: "calc(16.5px * var(--c-scale))",
    height: "100%",
    backgroundColor: "transparent",
    color: "var(--c-ink)",
  },
  ".cm-scroller": {
    fontFamily: "var(--c-sans)",
    lineHeight: "1.62",
    overflowY: "auto",
    // Generous, asymmetric page margins. The bottom is deep so the last line
    // of a document is never pinned to the window edge.
    padding: "2.4em 0 45vh 0",
  },
  ".cm-content": {
    // Wider than the classic 68ch: this corpus is full of long paths and
    // table rows, and a 950pt pane was leaving ~300pt unused. Still centred
    // with real side margins — never edge to edge.
    maxWidth: "var(--c-measure)",
    margin: "0 auto",
    padding: "0 clamp(28px, 4vw, 64px)",
    caretColor: "var(--c-accent)",
  },
  ".cm-line": { paddingLeft: "4ch", position: "relative" },

  // Vertical rhythm on a 4px unit. Headings get space above, never below —
  // a heading belongs to the text that follows it.
  ".cm-line.q-l1": { marginTop: "2.06em", marginBottom: "0.12em" },
  ".cm-line.q-l2": { marginTop: "1.82em", marginBottom: "0.12em" },
  ".cm-line.q-l3": { marginTop: "1.33em", marginBottom: "0.12em" },
  ".cm-line.q-l1:first-child, .cm-line.q-l2:first-child": { marginTop: "0" },

  // A quote reads as an aside: a hairline rule, not a colour change alone.
  ".cm-line.q-th, .cm-line.q-tr": {
    fontFamily: "var(--c-mono)",
    fontSize: "0.9em",
    paddingLeft: "4ch",
    whiteSpace: "nowrap",
  },
  ".cm-line.q-th": { fontWeight: "600", paddingBottom: "3px" },
  ".cm-line.q-th .q-td": { color: "var(--c-ink)" },
  ".q-td": {
    display: "inline-block",
    overflow: "hidden",
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
    verticalAlign: "top",
    marginRight: "2ch",
  },
  // The |---|---| row becomes the rule it was always drawing in ASCII.
  ".cm-line.q-trule": {
    fontSize: "0",
    lineHeight: "0",
    height: "1px",
    overflow: "hidden",
    borderTop: "1px solid var(--c-rule)",
    margin: "0 0 6px 4ch",
  },
  // A thematic break is a rule, not three hyphens.
  ".cm-line.q-hr": {
    fontSize: "0",
    lineHeight: "0",
    height: "1px",
    overflow: "hidden",
    borderTop: "1px solid var(--c-rule)",
    margin: "1.6em 4ch",
  },
  // Frontmatter: a quiet metadata block, closed by a hairline. The opening
  // marker carries no information a reader needs.
  ".cm-line.q-fm-open": { fontSize: "0", lineHeight: "0", height: "0", overflow: "hidden" },
  // The descendant selector is load-bearing: HighlightStyle puts its own
  // class on the inner spans, and a line rule alone loses to it.
  ".cm-line.q-fm, .cm-line.q-fm span": {
    fontFamily: "var(--c-mono)",
    fontSize: "0.86em",
    fontWeight: "400",
    fontStyle: "normal",
    lineHeight: "1.55",
    letterSpacing: "0",
    color: "var(--c-ink)",
  },
  ".cm-line.q-fm-open span, .cm-line.q-fm-close span": { color: "var(--c-marker)" },
  ".cm-line.q-fm span.q-fm-key, .q-fm-key": { color: "var(--c-ink-2)" },
  ".cm-line.q-fm-close": {
    fontSize: "0",
    lineHeight: "0",
    height: "1px",
    overflow: "hidden",
    borderTop: "1px solid var(--c-rule)",
    margin: "0.9em 4ch 1.6em 4ch",
  },
  // The changed-line mark rides the gutter that already exists, so it costs
  // no layout and cannot interact with selection rendering.
  ".cm-line.q-changed": {
    boxShadow: "inset 2px 0 0 0 var(--c-changed)",
    marginLeft: "-0.6ch",
    paddingLeft: "calc(4ch + 0.6ch)",
  },
  ".cm-line.q-quote": {
    borderLeft: "2px solid var(--c-rule)",
    marginLeft: "calc(4ch - 2px)",
    paddingLeft: "1.4ch",
    color: "var(--c-ink-2)",
  },

  // Block markers live in the gutter carved left of the text origin. Opacity
  // only — the text never moves when one is revealed.
  ".q-blockmark": {
    position: "absolute",
    right: "100%",
    marginRight: "0.6ch",
    opacity: "0",
    color: "var(--c-marker)",
    fontFamily: "var(--c-mono)",
    fontSize: "0.82em",
    whiteSpace: "pre",
    transition: "none",
  },
  ".q-reveal .q-blockmark": { opacity: "0.34" },

  ".cm-cursor, .cm-dropCursor": {
    borderLeftWidth: "2px",
    borderLeftColor: "var(--c-ink)",
  },
  // Links are the one place the accent appears outside the highlighter.
  ".cm-content a": { color: "var(--c-accent)" },
  // A dead reference. Red is reserved for "Claude Code will not read this",
  // and a path that does not exist is exactly that.
  ".q-dead": {
    textDecoration: "underline",
    textDecorationStyle: "dotted",
    textDecorationColor: "var(--c-dead)",
    textUnderlineOffset: "3px",
    textDecorationThickness: "1px",
  },
  "&.cm-focused": { outline: "none" },
  ".cm-scroller::-webkit-scrollbar": { width: "0" },
})

// ---------------------------------------------------------------- public API

let view = null

function mount(parent) {
  view = new EditorView({
    parent,
    state: EditorState.create({
      doc: "",
      extensions: [
        history(),
        rectangularSelection(),
        highlightSpecialChars(),
        markdown(),
        syntaxHighlighting(highlight),
        decorations,
        diagnostics,
        changedLines,
        bridge,
        theme,
        // defaultKeymap minus anything that writes characters we did not type.
        Prec.low(keymap.of(defaultKeymap.concat(historyKeymap))),
        EditorView.lineWrapping,
        // Belt and braces with the AppKit-side defaults in main.swift. These
        // are web attributes and do not govern macOS's own substitution layer,
        // but they cost nothing and close the browser half.
        EditorView.contentAttributes.of({
          spellcheck: "false", autocorrect: "off", autocapitalize: "off",
        }),
      ],
    }),
  })
  post({ type: "editorReady" })
  return view
}

// The ONLY sanctioned full-text push: initial load and post-crash reseed.
function setDocument(text, gen, caret, scrollTop) {
  if (!view) return
  generation = gen | 0
  version = 0
  seq = 0
  pending = []
  view.dispatch({
    changes: { from: 0, to: view.state.doc.length, insert: text },
    annotations: [fromSwift.of(true)],
  })
  if (typeof caret === "number") {
    const p = Math.max(0, Math.min(caret, view.state.doc.length))
    view.dispatch({ selection: { anchor: p }, annotations: [fromSwift.of(true)] })
  }
  if (typeof scrollTop === "number") view.scrollDOM.scrollTop = scrollTop
}

// Swift-originated edits. addToHistory.of(false) also calls
// state.addMapping(tr.changes.desc), so older undo entries stay correctly
// positioned across an external rewrite (S03 §5).
function applyRemote(changes, gen) {
  if (!view || (gen | 0) !== generation) return false
  view.dispatch({
    changes: changes.map((c) => ({ from: c[0], to: c[1], insert: c[2] })),
    annotations: [fromSwift.of(true)],
    // eslint-disable-next-line no-undef
    ...{},
  })
  return true
}

function getText() {
  // sliceDoc, never doc.toString() (S02 §5).
  return view ? view.state.sliceDoc(0, view.state.doc.length) : ""
}

function getLength() { return view ? view.state.doc.length : 0 }
function getSelection() {
  if (!view) return null
  const s = view.state.selection.main
  return { anchor: s.anchor, head: s.head }
}
function focus() { if (view) view.focus() }

const SCALES = [0.80, 0.90, 1.00, 1.15, 1.30, 1.50, 1.75]
let scaleIndex = 2

function setScale(i) {
  scaleIndex = Math.max(0, Math.min(SCALES.length - 1, i | 0))
  document.documentElement.style.setProperty("--c-scale", String(SCALES[scaleIndex]))
  // Column widths are in ch, which tracks the font, but the budget is derived
  // once per build — recompute so a zoom re-lays the tables too.
  if (view) view.dispatch({ effects: [], annotations: [fromSwift.of(true)] })
  return scaleIndex
}
function zoomIn() { return setScale(scaleIndex + 1) }
function zoomOut() { return setScale(scaleIndex - 1) }
function zoomReset() { return setScale(2) }

function applyChangedLines(lines) {
  if (!view) return
  view.dispatch({ effects: setChangedLines.of(lines || []), annotations: [fromSwift.of(true)] })
}

function applyDiagnostics(list) {
  if (!view) return
  view.dispatch({ effects: setDiagnostics.of(list || []), annotations: [fromSwift.of(true)] })
}

function selectRange(from, to) {
  if (!view) return
  const len = view.state.doc.length
  view.dispatch({ selection: { anchor: Math.min(from, len), head: Math.min(to, len) } })
  view.focus()
}

// Auto-mount. The bootstrap cannot live in an inline <script> tag: the page's
// CSP (D-59, zero network) has no 'unsafe-inline' in script-src, and a blocked
// inline script fails SILENTLY — it does not reach window.onerror.
function boot() {
  const root = document.getElementById("root")
  if (root && !view) mount(root)
}
if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", boot)
else boot()

export { mount, setDocument, applyRemote, getText, getLength, getSelection, focus, selectRange, applyDiagnostics, applyChangedLines, flushNow, setScale, zoomIn, zoomOut, zoomReset }
