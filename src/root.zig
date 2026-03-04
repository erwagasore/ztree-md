/// ztree-md — GFM (GitHub Flavoured Markdown) renderer for ztree.
///
/// Architecture:
///   render()        — public entry point
///   renderNode()    — single recursive walker (Zig requires self-recursion
///                     only for anytype; mutual recursion breaks error-set
///                     inference). Composes leaf writers + pure helpers.
///   Leaf writers    — write to writer, never call renderNode.
///   Table writers   — own recursion domain (cell content), no renderNode.
///   Pure helpers    — no writer, no side effects, data in → data out.
const std = @import("std");
const ztree = @import("ztree");
const Node = ztree.Node;
const Element = ztree.Element;
const Attr = ztree.Attr;

// ---------------------------------------------------------------------------
// Lookup tables
// ---------------------------------------------------------------------------

/// Block-level tags that get blank-line separation.
const block_tags = std.StaticStringMap(void).initComptime(.{
    .{ "h1", {} },  .{ "h2", {} },  .{ "h3", {} },
    .{ "h4", {} },  .{ "h5", {} },  .{ "h6", {} },
    .{ "p", {} },   .{ "blockquote", {} },
    .{ "ul", {} },  .{ "ol", {} },
    .{ "pre", {} },  .{ "hr", {} },  .{ "table", {} },
});

/// Heading tags → ATX prefix level.
const heading_levels = std.StaticStringMap(u8).initComptime(.{
    .{ "h1", 1 }, .{ "h2", 2 }, .{ "h3", 3 },
    .{ "h4", 4 }, .{ "h5", 5 }, .{ "h6", 6 },
});

// ---------------------------------------------------------------------------
// Context — mutable state threaded through the walk
// ---------------------------------------------------------------------------

const Context = struct {
    /// Line prefix for nesting (blockquote `> `, list indent).
    prefix: []const u8 = "",
    /// Whether a block element has been emitted (blank-line tracking).
    has_prev_block: bool = false,
};

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Write GFM Markdown for a ztree Node to any writer.
pub fn render(node: Node, writer: anytype) !void {
    var ctx = Context{};
    try renderNode(node, writer, &ctx);
}

// ---------------------------------------------------------------------------
// Walker — single recursive function
//
// Every branch that needs to recurse into children does so by calling
// renderNode directly (self-recursion). Tag-specific output is delegated
// to leaf writers and pure helpers defined below.
// ---------------------------------------------------------------------------

fn renderNode(node: Node, writer: anytype, ctx: *Context) !void {
    switch (node) {
        .text => |t| try writer.writeAll(t),
        .raw => |r| try writer.writeAll(r),
        .fragment => |children| {
            for (children) |child| try renderNode(child, writer, ctx);
        },
        .element => |e| {
            try separateBlock(e.tag, writer, ctx);

            if (heading_levels.get(e.tag)) |level| {
                try writeHeadingPrefix(writer, ctx.prefix, level);
                for (e.children) |child| try renderNode(child, writer, ctx);
                try writer.writeByte('\n');
            } else if (std.mem.eql(u8, e.tag, "p")) {
                try writer.writeAll(ctx.prefix);
                for (e.children) |child| try renderNode(child, writer, ctx);
                try writer.writeByte('\n');
            } else if (std.mem.eql(u8, e.tag, "blockquote")) {
                var buf: [256]u8 = undefined;
                var inner = childContext(&buf, ctx.prefix, "> ");
                for (e.children) |child| try renderNode(child, writer, &inner);
            } else if (std.mem.eql(u8, e.tag, "ul") or std.mem.eql(u8, e.tag, "ol")) {
                const ordered = std.mem.eql(u8, e.tag, "ol");
                const indent = if (ordered) "   " else "  ";
                var n: usize = 1;

                for (e.children) |child| {
                    const items: []const Node = switch (child) {
                        .element => @as(*const [1]Node, &child),
                        .fragment => |f| f,
                        else => continue,
                    };
                    for (items) |item| {
                        const li = switch (item) {
                            .element => |el| if (std.mem.eql(u8, el.tag, "li")) el else continue,
                            else => continue,
                        };
                        try writeListMarker(writer, ctx.prefix, ordered, n, li.attrs);
                        var buf: [256]u8 = undefined;
                        var inner = childContext(&buf, ctx.prefix, indent);

                        // Mixed inline + block children: inline flows on the
                        // marker line, blocks start on new lines.
                        var had_inline = false;
                        var emitted_any = false;
                        for (li.children) |li_child| {
                            if (isBlockNode(li_child)) {
                                if (!emitted_any or had_inline) try writer.writeByte('\n');
                                had_inline = false;
                                try renderNode(li_child, writer, &inner);
                                emitted_any = true;
                            } else {
                                try renderNode(li_child, writer, &inner);
                                had_inline = true;
                                emitted_any = true;
                            }
                        }
                        if (had_inline or !endsWithNewline(li.children)) {
                            try writer.writeByte('\n');
                        }
                        n += 1;
                    }
                }
            } else if (std.mem.eql(u8, e.tag, "pre")) {
                const info = extractCodeInfo(e);
                try writeCodeBlock(writer, ctx.prefix, info.language, info.content);
            } else if (std.mem.eql(u8, e.tag, "hr")) {
                try writeThematicBreak(writer, ctx.prefix);
            } else if (std.mem.eql(u8, e.tag, "table")) {
                const t = extractTableSections(e.children);
                try writeTable(t.thead, t.tbody, writer, ctx);
            } else if (std.mem.eql(u8, e.tag, "strong")) {
                try writer.writeAll("**");
                for (e.children) |child| try renderNode(child, writer, ctx);
                try writer.writeAll("**");
            } else if (std.mem.eql(u8, e.tag, "em")) {
                try writer.writeAll("*");
                for (e.children) |child| try renderNode(child, writer, ctx);
                try writer.writeAll("*");
            } else if (std.mem.eql(u8, e.tag, "del")) {
                try writer.writeAll("~~");
                for (e.children) |child| try renderNode(child, writer, ctx);
                try writer.writeAll("~~");
            } else if (std.mem.eql(u8, e.tag, "code")) {
                try writeInlineCode(writer, e.children);
            } else if (std.mem.eql(u8, e.tag, "a")) {
                try writer.writeByte('[');
                for (e.children) |child| try renderNode(child, writer, ctx);
                try writeLinkTail(writer, e.attrs);
            } else if (std.mem.eql(u8, e.tag, "img")) {
                try writeImage(writer, e.attrs);
            } else if (std.mem.eql(u8, e.tag, "br")) {
                try writer.writeAll("  \n");
                try writer.writeAll(ctx.prefix);
            } else {
                for (e.children) |child| try renderNode(child, writer, ctx);
            }
        },
    }
}

// ---------------------------------------------------------------------------
// Leaf writers — write output, never call renderNode
// ---------------------------------------------------------------------------

/// Emit a blank line between consecutive block elements.
fn separateBlock(tag: []const u8, writer: anytype, ctx: *Context) !void {
    if (!block_tags.has(tag)) return;
    if (ctx.has_prev_block) {
        try writer.writeAll(ctx.prefix);
        try writer.writeByte('\n');
    }
    ctx.has_prev_block = true;
}

/// Write ATX heading prefix: `### `.
fn writeHeadingPrefix(writer: anytype, prefix: []const u8, level: u8) !void {
    try writer.writeAll(prefix);
    for (0..level) |_| try writer.writeByte('#');
    try writer.writeByte(' ');
}

/// Write list-item marker: `- `, `1. `, with optional task checkbox.
fn writeListMarker(writer: anytype, prefix: []const u8, ordered: bool, index: usize, attrs: []const Attr) !void {
    try writer.writeAll(prefix);
    if (ordered) {
        try writeOrderedNumber(writer, index);
    } else {
        try writer.writeAll("- ");
    }
    const is_task = hasAttr(attrs, "task") or hasAttr(attrs, "checked");
    if (is_task) {
        if (hasBooleanAttr(attrs, "checked")) {
            try writer.writeAll("[x] ");
        } else {
            try writer.writeAll("[ ] ");
        }
    }
}

/// Write `1. ` (with the actual number).
fn writeOrderedNumber(writer: anytype, index: usize) !void {
    var buf: [20]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}. ", .{index}) catch "1. ";
    try writer.writeAll(s);
}

/// Write a fenced code block with optional language.
fn writeCodeBlock(writer: anytype, prefix: []const u8, language: []const u8, content: []const u8) !void {
    const fence = chooseFence(content);
    try writer.writeAll(prefix);
    try writer.writeAll(fence);
    try writer.writeAll(language);
    try writer.writeByte('\n');
    try writePrefixedLines(content, writer, prefix);
    try writer.writeAll(prefix);
    try writer.writeAll(fence);
    try writer.writeByte('\n');
}

/// Write `---\n`.
fn writeThematicBreak(writer: anytype, prefix: []const u8) !void {
    try writer.writeAll(prefix);
    try writer.writeAll("---\n");
}

/// Write backtick-wrapped inline code.
fn writeInlineCode(writer: anytype, children: []const Node) !void {
    const content = collectText(children);
    if (std.mem.indexOfScalar(u8, content, '`') != null) {
        try writer.writeAll("`` ");
        try writer.writeAll(content);
        try writer.writeAll(" ``");
    } else {
        try writer.writeByte('`');
        try writer.writeAll(content);
        try writer.writeByte('`');
    }
}

/// Write `](href "title")`.
fn writeLinkTail(writer: anytype, attrs: []const Attr) !void {
    const href = getAttrValue(attrs, "href") orelse "";
    const title = getAttrValue(attrs, "title");
    try writer.writeAll("](");
    try writer.writeAll(href);
    if (title) |t| {
        try writer.writeAll(" \"");
        try writer.writeAll(t);
        try writer.writeByte('"');
    }
    try writer.writeByte(')');
}

/// Write `![alt](src "title")`.
fn writeImage(writer: anytype, attrs: []const Attr) !void {
    const src = getAttrValue(attrs, "src") orelse "";
    const alt = getAttrValue(attrs, "alt") orelse "";
    const title = getAttrValue(attrs, "title");
    try writer.writeAll("![");
    try writer.writeAll(alt);
    try writer.writeAll("](");
    try writer.writeAll(src);
    if (title) |t| {
        try writer.writeAll(" \"");
        try writer.writeAll(t);
        try writer.writeByte('"');
    }
    try writer.writeByte(')');
}

/// Write content line-by-line, prepending prefix to each line.
fn writePrefixedLines(content: []const u8, writer: anytype, prefix: []const u8) !void {
    if (content.len == 0) return;
    var start: usize = 0;
    for (content, 0..) |c, i| {
        if (c == '\n') {
            try writer.writeAll(prefix);
            try writer.writeAll(content[start .. i + 1]);
            start = i + 1;
        }
    }
    if (start < content.len) {
        try writer.writeAll(prefix);
        try writer.writeAll(content[start..]);
        try writer.writeByte('\n');
    }
}

// ---------------------------------------------------------------------------
// Table writers — own recursion domain, never call renderNode.
// Cell content is rendered with pipe escaping and limited inline formatting.
// ---------------------------------------------------------------------------

/// Write a full GFM table from thead/tbody children.
fn writeTable(thead: []const Node, tbody: []const Node, writer: anytype, ctx: *Context) !void {
    for (thead) |child| {
        switch (child) {
            .element => |tr| {
                if (std.mem.eql(u8, tr.tag, "tr")) {
                    try writeTableRow(tr.children, writer, ctx);
                    try writeSeparatorRow(tr.children, writer, ctx);
                }
            },
            else => {},
        }
    }
    for (tbody) |child| {
        switch (child) {
            .element => |tr| {
                if (std.mem.eql(u8, tr.tag, "tr")) {
                    try writeTableRow(tr.children, writer, ctx);
                }
            },
            else => {},
        }
    }
}

fn writeTableRow(cells: []const Node, writer: anytype, ctx: *Context) !void {
    try writer.writeAll(ctx.prefix);
    try writer.writeByte('|');
    for (cells) |cell| {
        switch (cell) {
            .element => |el| {
                if (std.mem.eql(u8, el.tag, "th") or std.mem.eql(u8, el.tag, "td")) {
                    try writer.writeByte(' ');
                    try writeCellContent(el.children, writer);
                    try writer.writeAll(" |");
                }
            },
            else => {},
        }
    }
    try writer.writeByte('\n');
}

/// Write inline content for a table cell, escaping `|` in text.
fn writeCellContent(children: []const Node, writer: anytype) !void {
    for (children) |child| {
        switch (child) {
            .text => |t| try writePipeEscaped(t, writer),
            .raw => |r| try writer.writeAll(r),
            .fragment => |frag| try writeCellContent(frag, writer),
            .element => |el| {
                if (std.mem.eql(u8, el.tag, "strong")) {
                    try writer.writeAll("**");
                    try writeCellContent(el.children, writer);
                    try writer.writeAll("**");
                } else if (std.mem.eql(u8, el.tag, "em")) {
                    try writer.writeAll("*");
                    try writeCellContent(el.children, writer);
                    try writer.writeAll("*");
                } else if (std.mem.eql(u8, el.tag, "del")) {
                    try writer.writeAll("~~");
                    try writeCellContent(el.children, writer);
                    try writer.writeAll("~~");
                } else if (std.mem.eql(u8, el.tag, "code")) {
                    try writeInlineCode(writer, el.children);
                } else if (std.mem.eql(u8, el.tag, "a")) {
                    try writer.writeByte('[');
                    try writeCellContent(el.children, writer);
                    try writeLinkTail(writer, el.attrs);
                } else {
                    try writeCellContent(el.children, writer);
                }
            },
        }
    }
}

fn writePipeEscaped(text: []const u8, writer: anytype) !void {
    for (text) |c| {
        if (c == '|') {
            try writer.writeAll("\\|");
        } else {
            try writer.writeByte(c);
        }
    }
}

fn writeSeparatorRow(header_cells: []const Node, writer: anytype, ctx: *Context) !void {
    try writer.writeAll(ctx.prefix);
    try writer.writeByte('|');
    for (header_cells) |cell| {
        switch (cell) {
            .element => |el| {
                if (std.mem.eql(u8, el.tag, "th")) {
                    try writer.writeAll(separatorCell(el.attrs));
                }
            },
            else => {},
        }
    }
    try writer.writeByte('\n');
}

// ---------------------------------------------------------------------------
// Pure helpers — no writer, no side effects
// ---------------------------------------------------------------------------

/// Build a child context with an extended prefix.
fn childContext(buf: *[256]u8, current_prefix: []const u8, suffix: []const u8) Context {
    return .{
        .prefix = buildPrefix(buf, current_prefix, suffix),
        .has_prev_block = false,
    };
}

fn buildPrefix(buf: *[256]u8, current: []const u8, suffix: []const u8) []const u8 {
    if (current.len + suffix.len > buf.len) return current;
    @memcpy(buf[0..current.len], current);
    @memcpy(buf[current.len..][0..suffix.len], suffix);
    return buf[0 .. current.len + suffix.len];
}

/// Extract language and content from a `pre > code` element.
const CodeInfo = struct { language: []const u8, content: []const u8 };

fn extractCodeInfo(e: Element) CodeInfo {
    for (e.children) |child| {
        switch (child) {
            .element => |code| {
                if (std.mem.eql(u8, code.tag, "code")) {
                    return .{
                        .language = languageFromClass(code.attrs),
                        .content = collectText(code.children),
                    };
                }
            },
            else => {},
        }
    }
    return .{ .language = "", .content = collectText(e.children) };
}

/// Extract thead and tbody children from a table element.
const TableSections = struct { thead: []const Node, tbody: []const Node };

fn extractTableSections(children: []const Node) TableSections {
    var result = TableSections{ .thead = &.{}, .tbody = &.{} };
    for (children) |child| {
        switch (child) {
            .element => |el| {
                if (std.mem.eql(u8, el.tag, "thead")) {
                    result.thead = el.children;
                } else if (std.mem.eql(u8, el.tag, "tbody")) {
                    result.tbody = el.children;
                }
            },
            else => {},
        }
    }
    return result;
}

/// Choose fence string: ```` ```` ```` if content has triple backticks.
fn chooseFence(content: []const u8) []const u8 {
    return if (containsTripleBackticks(content)) "````" else "```";
}

fn containsTripleBackticks(content: []const u8) bool {
    if (content.len < 3) return false;
    var i: usize = 0;
    while (i + 2 < content.len) : (i += 1) {
        if (content[i] == '`' and content[i + 1] == '`' and content[i + 2] == '`') return true;
    }
    return false;
}

/// Return separator cell markup based on alignment attr.
fn separatorCell(attrs: []const Attr) []const u8 {
    const a = getAttrValue(attrs, "align") orelse return " --- |";
    if (std.mem.eql(u8, a, "center")) return " :---: |";
    if (std.mem.eql(u8, a, "right")) return " ---: |";
    return " --- |";
}

/// Extract language from `class="language-xxx"`.
fn languageFromClass(attrs: []const Attr) []const u8 {
    const class = getAttrValue(attrs, "class") orelse return "";
    return if (std.mem.startsWith(u8, class, "language-")) class["language-".len..] else "";
}

fn getAttrValue(attrs: []const Attr, key: []const u8) ?[]const u8 {
    for (attrs) |a| {
        if (std.mem.eql(u8, a.key, key)) return a.value;
    }
    return null;
}

fn hasAttr(attrs: []const Attr, key: []const u8) bool {
    for (attrs) |a| {
        if (std.mem.eql(u8, a.key, key)) return true;
    }
    return false;
}

fn hasBooleanAttr(attrs: []const Attr, key: []const u8) bool {
    for (attrs) |a| {
        if (std.mem.eql(u8, a.key, key) and a.value == null) return true;
    }
    return false;
}

/// Collect text content from children (first text/raw node).
fn collectText(children: []const Node) []const u8 {
    for (children) |child| {
        switch (child) {
            .text => |t| return t,
            .raw => |r| return r,
            else => {},
        }
    }
    return "";
}

fn isBlockNode(node: Node) bool {
    return switch (node) {
        .element => |el| block_tags.has(el.tag),
        .fragment => |children| for (children) |child| {
            if (isBlockNode(child)) return true;
        } else false,
        else => false,
    };
}

fn endsWithNewline(children: []const Node) bool {
    if (children.len == 0) return false;
    return switch (children[children.len - 1]) {
        .element => |el| block_tags.has(el.tag),
        .text => |t| t.len > 0 and t[t.len - 1] == '\n',
        .raw => |r| r.len > 0 and r[r.len - 1] == '\n',
        .fragment => |frag| endsWithNewline(frag),
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn renderToString(node: Node) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    try render(node, &aw.writer);
    var al = aw.toArrayList();
    return al.toOwnedSlice(testing.allocator);
}

// -- node types --

test "text and raw — written as-is" {
    const t = try renderToString(ztree.text("hello *world*"));
    defer testing.allocator.free(t);
    try testing.expectEqualStrings("hello *world*", t);

    const r = try renderToString(ztree.raw("<!-- raw -->"));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("<!-- raw -->", r);
}

test "fragment transparent, none empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try renderToString(try ztree.fragment(a, .{ ztree.text("a"), ztree.text("b") }));
    defer testing.allocator.free(f);
    try testing.expectEqualStrings("ab", f);

    const n = try renderToString(ztree.none());
    defer testing.allocator.free(n);
    try testing.expectEqualStrings("", n);
}

test "unknown tag — children rendered without wrapper" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const md = try renderToString(try ztree.element(arena.allocator(), "div", .{}, .{ ztree.text("inside") }));
    defer testing.allocator.free(md);
    try testing.expectEqualStrings("inside", md);
}

// -- block elements --

test "headings — h1 and h6 boundaries" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h1 = try renderToString(try ztree.element(a, "h1", .{}, .{ ztree.text("Top") }));
    defer testing.allocator.free(h1);
    try testing.expectEqualStrings("# Top\n", h1);

    const h6 = try renderToString(try ztree.element(a, "h6", .{}, .{ ztree.text("Deep") }));
    defer testing.allocator.free(h6);
    try testing.expectEqualStrings("###### Deep\n", h6);
}

test "paragraphs — blank line separation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const md = try renderToString(try ztree.fragment(a, .{
        try ztree.element(a, "p", .{}, .{ ztree.text("First.") }),
        try ztree.element(a, "p", .{}, .{ ztree.text("Second.") }),
    }));
    defer testing.allocator.free(md);
    try testing.expectEqualStrings("First.\n\nSecond.\n", md);
}

test "nested blockquotes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const md = try renderToString(try ztree.element(a, "blockquote", .{}, .{
        try ztree.element(a, "blockquote", .{}, .{
            try ztree.element(a, "p", .{}, .{ ztree.text("Deep.") }),
        }),
    }));
    defer testing.allocator.free(md);
    try testing.expectEqualStrings("> > Deep.\n", md);
}

test "unordered list — nested" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const md = try renderToString(try ztree.element(a, "ul", .{}, .{
        try ztree.element(a, "li", .{}, .{
            ztree.text("parent"),
            try ztree.element(a, "ul", .{}, .{
                try ztree.element(a, "li", .{}, .{ ztree.text("child") }),
            }),
        }),
    }));
    defer testing.allocator.free(md);
    try testing.expectEqualStrings("- parent\n  - child\n", md);
}

test "ordered list — nested, sequential numbering" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const md = try renderToString(try ztree.element(a, "ol", .{}, .{
        try ztree.element(a, "li", .{}, .{
            ztree.text("parent"),
            try ztree.element(a, "ol", .{}, .{
                try ztree.element(a, "li", .{}, .{ ztree.text("child") }),
            }),
        }),
    }));
    defer testing.allocator.free(md);
    try testing.expectEqualStrings("1. parent\n   1. child\n", md);
}

test "task list — checked and unchecked" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const md = try renderToString(try ztree.element(a, "ul", .{}, .{
        try ztree.element(a, "li", .{ .checked = {} }, .{ ztree.text("done") }),
        try ztree.element(a, "li", .{ .task = {} },    .{ ztree.text("todo") }),
    }));
    defer testing.allocator.free(md);
    try testing.expectEqualStrings("- [x] done\n- [ ] todo\n", md);
}

test "fenced code block with language" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const md = try renderToString(try ztree.element(a, "pre", .{}, .{
        try ztree.element(a, "code", .{ .class = "language-zig" }, .{
            ztree.text("const std = @import(\"std\");"),
        }),
    }));
    defer testing.allocator.free(md);
    try testing.expectEqualStrings("```zig\nconst std = @import(\"std\");\n```\n", md);
}

test "fenced code block — triple backtick escalation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const md = try renderToString(try ztree.element(a, "pre", .{}, .{
        try ztree.element(a, "code", .{}, .{ ztree.text("some ``` inside") }),
    }));
    defer testing.allocator.free(md);
    try testing.expectEqualStrings("````\nsome ``` inside\n````\n", md);
}

test "thematic break" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const md = try renderToString(try ztree.element(arena.allocator(), "hr", .{}, .{}));
    defer testing.allocator.free(md);
    try testing.expectEqualStrings("---\n", md);
}

test "GFM table — alignment and pipe escaping" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const md = try renderToString(try ztree.element(a, "table", .{}, .{
        try ztree.element(a, "thead", .{}, .{
            try ztree.element(a, "tr", .{}, .{
                try ztree.element(a, "th", .{},               .{ ztree.text("Name") }),
                try ztree.element(a, "th", .{ .@"align" = "center" }, .{ ztree.text("Age") }),
                try ztree.element(a, "th", .{ .@"align" = "right" },  .{ ztree.text("Score") }),
            }),
        }),
        try ztree.element(a, "tbody", .{}, .{
            try ztree.element(a, "tr", .{}, .{
                try ztree.element(a, "td", .{}, .{ ztree.text("Al|ice") }),
                try ztree.element(a, "td", .{}, .{ ztree.text("30") }),
                try ztree.element(a, "td", .{}, .{ ztree.text("95") }),
            }),
        }),
    }));
    defer testing.allocator.free(md);
    try testing.expectEqualStrings(
        "| Name | Age | Score |\n" ++
            "| --- | :---: | ---: |\n" ++
            "| Al\\|ice | 30 | 95 |\n",
        md,
    );
}

// -- inline elements --

test "bold, italic, strikethrough" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const md = try renderToString(try ztree.element(a, "p", .{}, .{
        try ztree.element(a, "strong", .{}, .{ ztree.text("b") }),
        ztree.text(" "),
        try ztree.element(a, "em",     .{}, .{ ztree.text("i") }),
        ztree.text(" "),
        try ztree.element(a, "del",    .{}, .{ ztree.text("d") }),
    }));
    defer testing.allocator.free(md);
    try testing.expectEqualStrings("**b** *i* ~~d~~\n", md);
}

test "inline code — backtick escalation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const md = try renderToString(try ztree.element(arena.allocator(), "code", .{}, .{ ztree.text("a`b") }));
    defer testing.allocator.free(md);
    try testing.expectEqualStrings("`` a`b ``", md);
}

test "link with title" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const md = try renderToString(try ztree.element(a, "a",
        .{ .href = "https://example.com", .title = "Example" },
        .{ ztree.text("click") }));
    defer testing.allocator.free(md);
    try testing.expectEqualStrings("[click](https://example.com \"Example\")", md);
}

test "image with title" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const md = try renderToString(try ztree.element(a, "img",
        .{ .src = "photo.jpg", .alt = "A photo", .title = "My photo" },
        .{}));
    defer testing.allocator.free(md);
    try testing.expectEqualStrings("![A photo](photo.jpg \"My photo\")", md);
}

test "hard line break" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const md = try renderToString(try ztree.element(a, "p", .{}, .{
        ztree.text("line one"),
        try ztree.element(a, "br", .{}, .{}),
        ztree.text("line two"),
    }));
    defer testing.allocator.free(md);
    try testing.expectEqualStrings("line one  \nline two\n", md);
}

// -- nesting --

test "list inside blockquote" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const md = try renderToString(try ztree.element(a, "blockquote", .{}, .{
        try ztree.element(a, "ul", .{}, .{
            try ztree.element(a, "li", .{}, .{ ztree.text("item") }),
        }),
    }));
    defer testing.allocator.free(md);
    try testing.expectEqualStrings("> - item\n", md);
}

test "blockquote inside list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const md = try renderToString(try ztree.element(a, "ul", .{}, .{
        try ztree.element(a, "li", .{}, .{
            try ztree.element(a, "blockquote", .{}, .{
                try ztree.element(a, "p", .{}, .{ ztree.text("quoted") }),
            }),
        }),
    }));
    defer testing.allocator.free(md);
    try testing.expectEqualStrings("- \n  > quoted\n", md);
}

// -- integration --

test "full document" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const md = try renderToString(try ztree.fragment(a, .{
        try ztree.element(a, "h1", .{}, .{ ztree.text("Title") }),
        try ztree.element(a, "p", .{}, .{
            ztree.text("A paragraph with "),
            try ztree.element(a, "strong", .{}, .{ ztree.text("bold") }),
            ztree.text(" text."),
        }),
        try ztree.element(a, "pre", .{}, .{
            try ztree.element(a, "code", .{ .class = "language-zig" }, .{
                ztree.text("const x = 42;"),
            }),
        }),
        try ztree.element(a, "ul", .{}, .{
            try ztree.element(a, "li", .{}, .{ ztree.text("one") }),
            try ztree.element(a, "li", .{}, .{ ztree.text("two") }),
        }),
    }));
    defer testing.allocator.free(md);
    try testing.expectEqualStrings(
        "# Title\n" ++
            "\n" ++
            "A paragraph with **bold** text.\n" ++
            "\n" ++
            "```zig\n" ++
            "const x = 42;\n" ++
            "```\n" ++
            "\n" ++
            "- one\n" ++
            "- two\n",
        md,
    );
}
