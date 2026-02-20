# ztree-md

GFM (GitHub Flavoured Markdown) renderer for [ztree](https://github.com/erwagasore/ztree). Walks a `Node` tree and writes Markdown to any writer.

Uses the same HTML tag names as [ztree-html](https://github.com/erwagasore/ztree-html) — build one tree, render to multiple formats.

## Quickstart

Add to `build.zig.zon`:

```zig
.ztree_md = .{
    .url = "git+https://github.com/erwagasore/ztree-md.git#main",
},
```

Then `zig build` to fetch. Import in your code:

```zig
const ztree = @import("ztree");
const ztree_md = @import("ztree-md");

const doc = ztree.element("h1", &.{}, &.{ztree.text("Hello")});
try ztree_md.render(doc, writer);
// Output: # Hello
```

## Structure

See [AGENTS.md](AGENTS.md#repo-map) for the full repo map.
