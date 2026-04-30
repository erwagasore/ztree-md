# Changelog

## [1.0.0] — 2026-04-30

### Breaking Changes

- Require Zig 0.16.0 or newer.
- Update ztree dependency to v2.0.0.
- Adopt ztree v2's `Walker` for re-entrant list rendering.

### Features

- Stream fenced code block text from all text/raw children without heap allocation, matching `TreeBuilder` output.
- Return explicit `PrefixOverflow` / `NestingOverflow` errors instead of silently truncating deeply nested Markdown prefixes.

### Fixes

- Size the ordered-list number buffer for the full 64-bit `usize` range.

### Other

- Update README and project docs for the Zig 0.16 / ztree v2 API.
- Write heading prefixes with a static lookup table instead of repeated byte writes.

## [0.2.1] — 2026-03-08

### Other

- Use `Element.getAttr()` and `Element.hasAttr()` methods from ztree v1.2.0, replacing private attribute helpers.
- Leaf writers take `Element` instead of `[]const Attr` — simpler signatures, less indirection.
- Remove unused `Attr` import.
- Update ztree dependency v1.0.0 → v1.2.0.

## [0.2.0] — 2026-03-08

### Breaking Changes

- **ztree v1.0.0** — minimum dependency is now ztree 1.0.0 (`WalkAction`, `Element.closed`).

### Features

- **renderWalk architecture** — renderer is now a `MdRenderer(Writer)` struct implementing ztree's `renderWalk` protocol (`elementOpen`, `elementClose`, `onText`, `onRaw`). Replaces the monolithic recursive `renderNode` function.
- **WalkAction dispatch** — simple wrapper elements (`strong`, `em`, `del`, `a`, headings, `p`, `blockquote`) return `.continue` for free traversal. Complex elements (`pre`, `table`, `code`, `ul`/`ol`, `hr`, `br`, `img`) return `.skip_children` and handle subtrees directly in `elementOpen`.
- **Frame-based state** — nesting context (prefix, block separation) managed via a save/restore frame stack instead of per-call `Context` structs.
- **closedElement support** — `hr`, `br`, `img` now use `closedElement` (ztree v0.7.0+), correctly receiving only `elementOpen`.

### Fixes

- **Task list checked detection** — `checked` attribute with any value (boolean or string) now marks the item as checked. Previously only boolean attrs (`checked = {}`) were recognised; `checked = "true"` was rendered as unchecked.
- **Inline code with multiple text children** — `writeInlineCode` now iterates all text/raw children via `writeAllText` and `textContains`. Previously only the first text child was rendered, breaking trees built with `TreeBuilder` that produce multiple text events.

### Other

- New tests use `TreeBuilder` where needed (multi-child inline code), proving producer→consumer interop.
- Remove dead `hasBooleanAttr` function.
- Replace `@splat(0)` with `undefined` on prefix buffer (content below `prefix_len` is never read).
- Replace `catch "1. "` with `catch unreachable` in `writeOrderedNumber` (20-byte buffer is always sufficient).

## [0.1.0] — 2026-02-20

### Features

- GFM Markdown renderer for ztree — walks a Node tree and writes Markdown to any writer
- Block elements: headings, paragraphs, blockquotes, lists (ul/ol/task), fenced code blocks, thematic breaks, GFM tables
- Inline elements: strong, em, del, code, links, images, hard line breaks
- Nesting support: blockquote stacking, list indentation, cross-nesting
