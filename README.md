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
const md = @import("ztree-md");

const doc = ztree.fragment(&.{
    ztree.element("h1", &.{}, &.{ztree.text("Hello")}),
    ztree.element("p", &.{}, &.{
        ztree.text("A paragraph with "),
        ztree.element("strong", &.{}, &.{ztree.text("bold")}),
        ztree.text(" and "),
        ztree.element("a", &.{
            ztree.attr("href", "https://ziglang.org"),
        }, &.{ztree.text("a link")}),
        ztree.text("."),
    }),
    ztree.element("pre", &.{}, &.{
        ztree.element("code", &.{
            ztree.attr("class", "language-zig"),
        }, &.{ztree.text("const x = 42;")}),
    }),
    ztree.element("ul", &.{}, &.{
        ztree.element("li", &.{ztree.attr("checked", null)}, &.{ztree.text("done")}),
        ztree.element("li", &.{ztree.attr("task", null)}, &.{ztree.text("todo")}),
    }),
});

try md.render(doc, writer);
```

Output:

~~~markdown
# Hello

A paragraph with **bold** and [a link](https://ziglang.org).

```zig
const x = 42;
```

- [x] done
- [ ] todo
~~~

## Structure

See [AGENTS.md](AGENTS.md#repo-map) for the full repo map.
