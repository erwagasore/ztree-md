# ztree-md

GFM (GitHub Flavoured Markdown) renderer for [ztree](https://github.com/erwagasore/ztree). Walks a `Node` tree and writes Markdown to any writer.

Requires Zig 0.16.x and ztree v2.x. Uses the same HTML tag names as [ztree-html](https://github.com/erwagasore/ztree-html) — build one tree, render to multiple formats.

## Quickstart

Add to `build.zig.zon`:

```zig
.ztree_md = .{
    .url = "git+https://github.com/erwagasore/ztree-md.git#main",
},
```

Then `zig build` to fetch. Import in your code:

```zig
const std = @import("std");
const ztree = @import("ztree");
const md = @import("ztree-md");

var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();
const a = arena.allocator();

const doc = try ztree.fragment(a, .{
    try ztree.element(a, "h1", .{}, .{ztree.text("Hello")}),
    try ztree.element(a, "p", .{}, .{
        ztree.text("A paragraph with "),
        try ztree.element(a, "strong", .{}, .{ztree.text("bold")}),
        ztree.text(" and "),
        try ztree.element(a, "a", .{ .href = "https://ziglang.org" }, .{ztree.text("a link")}),
        ztree.text("."),
    }),
    try ztree.element(a, "pre", .{}, .{
        try ztree.element(a, "code", .{ .class = "language-zig" }, .{ztree.text("const x = 42;")}),
    }),
    try ztree.element(a, "ul", .{}, .{
        try ztree.element(a, "li", .{ .checked = {} }, .{ztree.text("done")}),
        try ztree.element(a, "li", .{ .task = {} }, .{ztree.text("todo")}),
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
