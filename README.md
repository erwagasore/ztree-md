# ztree-md

GFM (GitHub Flavoured Markdown) renderer for [ztree](https://github.com/erwagasore/ztree). Walks a `Node` tree and writes Markdown to a Zig 0.16 `std.Io.Writer`.

Requires Zig 0.16.x and ztree v2.1.x. Uses the same HTML tag names as [ztree-html](https://github.com/erwagasore/ztree-html) — build one tree, render to multiple formats. Rendering streams directly to the caller's writer and does not flush. The renderer itself performs no heap allocation; allocation behavior is determined by the caller-provided writer.

The renderer accepts both native Markdown-oriented attrs and the HTML-shaped tree emitted by [ztree-parse-md](https://github.com/erwagasore/ztree-parse-md), including checkbox `input` task items, `ol start`, and table `style="text-align: ..."` alignment.

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

var out: std.Io.Writer.Allocating = .init(a);
defer out.deinit();

try md.render(doc, &out.writer);
const markdown = try out.toOwnedSlice();
defer a.free(markdown);
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
