# ztree-md — Design

GFM (GitHub Flavoured Markdown) renderer for ztree. Walks a `Node` tree and
writes Markdown.

Uses the same HTML tag names as ztree-html so one tree can render to both
formats.

---

## API

One function.

| Function | Signature | Description |
|----------|-----------|-------------|
| `render` | `(node: Node, writer: anytype) !void` | Write GFM to any writer. |

```zig
const ztree_md = @import("ztree-md");

// Write to any writer (file, buffer, socket):
try ztree_md.render(doc, writer);
```

---

## Tag → Markdown mapping

### Block elements

| Tag | Markdown | Notes |
|-----|----------|-------|
| `h1`–`h6` | `# `–`###### ` prefix + newline | ATX headings only. |
| `p` | content + blank line | Blank line before and after. |
| `blockquote` | `> ` prefix per line | Recursive — nested blockquotes stack `> > `. |
| `ul` | `- ` prefix per `li` child | Nested lists indent 2 spaces. |
| `ol` | `1. ` prefix per `li` child | Nested lists indent 3 spaces. Sequential numbering. |
| `li` | list marker + content | If `li` has boolean attr `checked` → `- [x] `. If `checked` is absent but attr `task` is set → `- [ ] `. |
| `pre` | fenced code block ` ``` ` | If child is `code` with `class="language-xxx"`, use `xxx` as fence info string. |
| `hr` | `---` + blank line | Thematic break. |
| `table` | GFM table | Children: `thead` and `tbody`. Cells from `th`/`td`. Alignment from `align` attr. |

### Inline elements

| Tag | Markdown | Notes |
|-----|----------|-------|
| `strong` | `**content**` | Bold. |
| `em` | `*content*` | Italic. |
| `del` | `~~content~~` | Strikethrough (GFM extension). |
| `code` | `` `content` `` | Inline code. If content contains backtick, use double backticks. |
| `a` | `[text](href "title")` | `href` attr required. `title` attr optional. |
| `img` | `![alt](src "title")` | `src` and `alt` attrs. `title` optional. |
| `br` | two trailing spaces + newline | Hard line break. |

### Passthrough

| Node type | Behaviour |
|-----------|-----------|
| `text` | Written as-is. Markdown special chars in text are **not escaped** — the caller controls content. |
| `raw` | Written as-is. No processing. |
| `fragment` | Transparent — children rendered directly. |
| `none` | Empty fragment — no output. |

### Unknown tags

Tags not listed above are **ignored** — their children are rendered inline
without any wrapping. This keeps the renderer lenient; ztree-md renders what
it understands and passes through what it doesn't.

---

## Rendering rules

### Blank lines

- Block elements (`p`, `blockquote`, `pre`, `hr`, `ul`, `ol`, `table`,
  `h1`–`h6`) are separated by blank lines.
- No leading blank line before the first block.
- No trailing blank line after the last block.

### Nesting

- Blockquotes prefix every line of nested content with `> `.
- Lists indent nested content by 2 spaces (unordered) or 3 spaces (ordered,
  to align past `1. `).
- Nesting stacks: a blockquote inside a list gets both indent and `> `.

### Text escaping

Markdown has many special characters (`*`, `_`, `` ` ``, `[`, `]`, `#`, etc.)
but this renderer does **not** auto-escape text content. Rationale:

- The tree is constructed by the caller, not parsed from user input.
- Auto-escaping would mangle intentional Markdown in raw nodes.
- If escaping is needed, the caller uses `text()` for safe content and
  `raw()` for pre-formatted Markdown.

### Tables (GFM)

- Header row from `thead > tr > th`.
- Separator row with alignment: `---` (left/default), `:---:` (center),
  `---:` (right). Alignment read from `align` attr on `th`.
- Body rows from `tbody > tr > td`.
- Cell content is rendered inline (no block elements inside cells).
- Pipes `|` in cell content are escaped to `\|`.

### Code blocks

- Fenced with triple backticks.
- Language from `class="language-xxx"` on the `code` element inside `pre`.
- Content is the raw text of the `code` element — no escaping.
- If content contains triple backticks, use quadruple backticks as fence.

---

## Design decisions

**`anytype` writer.** Same rationale as ztree-html. Matches idiomatic Zig.

**HTML tag names.** Reuses the same tag vocabulary as ztree-html (`h1`, `p`,
`strong`, `a`, etc.) so one tree can render to multiple formats. No
Markdown-specific tag names.

**No escaping.** Unlike HTML, Markdown special characters in text are not
escaped. The renderer trusts the caller. This is intentional — escaping `*`
and `_` in all text would break intentional inline formatting in raw nodes.

**No pretty-printing options.** One output style. ATX headings, `-` for
unordered lists, `1.` for ordered lists, `---` for thematic breaks, triple
backticks for code. One way to do a thing.

**No validation.** The renderer does not check whether the tree makes
semantic sense (e.g. a `strong` inside a `pre`). It renders what it's given.

**GFM superset.** Tables, task lists, and strikethrough are always available.
If you don't use them, the output is valid CommonMark.

---

## File structure

```
ztree-md/
├── build.zig
├── build.zig.zon
├── src/
│   └── root.zig     # render, block/inline helpers — single file
├── DESIGN.md
├── README.md
├── AGENTS.md
├── LICENSE
└── .gitignore
```

Single source file. Same structure as ztree-html.

---

## Checklist

### Setup

- [ ] Set up `build.zig` and `build.zig.zon` with ztree dependency
- [ ] Scaffold `render()` entry point with recursive tree walk

### Block elements

- [ ] Headings (`h1`–`h6`) — ATX `# ` prefix
- [ ] Paragraph (`p`) — content with blank line separation
- [ ] Blockquote (`blockquote`) — `> ` prefix, recursive nesting
- [ ] Unordered list (`ul` + `li`) — `- ` prefix, 2-space indent for nesting
- [ ] Ordered list (`ol` + `li`) — `1. ` prefix, 3-space indent for nesting
- [ ] Task list (`li` with `checked`/`task` attr) — `- [x] ` / `- [ ] `
- [ ] Fenced code block (`pre` + `code`) — triple backticks, language info string
- [ ] Thematic break (`hr`) — `---`
- [ ] Table (`table` + `thead`/`tbody` + `tr`/`th`/`td`) — GFM table syntax
- [ ] Table alignment — `align` attr on `th` → separator row

### Inline elements

- [ ] Bold (`strong`) — `**content**`
- [ ] Italic (`em`) — `*content*`
- [ ] Strikethrough (`del`) — `~~content~~`
- [ ] Inline code (`code`) — backtick wrapping, double backtick when needed
- [ ] Link (`a`) — `[text](href "title")`
- [ ] Image (`img`) — `![alt](src "title")`
- [ ] Hard line break (`br`) — two trailing spaces + newline

### Node types

- [ ] Text — written as-is
- [ ] Raw — written as-is
- [ ] Fragment — transparent, children rendered directly
- [ ] None (empty fragment) — no output
- [ ] Unknown tags — children rendered, no wrapping

### Blank line management

- [ ] Blank line between consecutive block elements
- [ ] No leading blank line
- [ ] No trailing blank line

### Nesting

- [ ] Blockquote inside blockquote — stacked `> > `
- [ ] List inside list — indented correctly
- [ ] Blockquote inside list — combined indent + prefix
- [ ] List inside blockquote — combined prefix + indent

### Tests

- [ ] Test: `h1`–`h6` headings
- [ ] Test: paragraph with blank line separation
- [ ] Test: nested blockquotes
- [ ] Test: unordered list with nested items
- [ ] Test: ordered list with nested items
- [ ] Test: task list — checked and unchecked
- [ ] Test: fenced code block with language
- [ ] Test: fenced code block containing triple backticks
- [ ] Test: thematic break
- [ ] Test: GFM table with alignment
- [ ] Test: table with pipe in cell content
- [ ] Test: bold, italic, strikethrough
- [ ] Test: inline code with backtick in content
- [ ] Test: link with title
- [ ] Test: link without title
- [ ] Test: image with title
- [ ] Test: hard line break
- [ ] Test: text passthrough
- [ ] Test: raw passthrough
- [ ] Test: fragment — transparent
- [ ] Test: none — no output
- [ ] Test: unknown tag — children rendered without wrapper
- [ ] Test: list inside blockquote
- [ ] Test: blockquote inside list
- [ ] Test: full document — headings, paragraphs, code, list, table
