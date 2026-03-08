/// ztree-md — GFM (GitHub Flavoured Markdown) renderer for ztree.
///
/// Architecture:
///   render()           — public entry point, delegates to ztree.renderWalk.
///   MdRenderer(Writer) — struct implementing the renderWalk protocol:
///                          elementOpen / elementClose / onText / onRaw.
///   elementOpen uses WalkAction:
///     .continue        — simple wrappers (strong, em, headings, p, blockquote, a, del).
///                          renderWalk recurses children and calls elementClose.
///     .skip_children   — complex elements (pre, table, code, ul/ol, hr, br, img).
///                          Handled entirely in elementOpen; no elementClose.
///                          List rendering re-enters renderWalk for nested content.
///   Free functions     — pure helpers and leaf writers shared across contexts.
const std = @import("std");
const ztree = @import("ztree");
const Node = ztree.Node;
const Element = ztree.Element;
const Attr = ztree.Attr;
const WalkAction = ztree.WalkAction;
const Walker = ztree.Walker;

// ---------------------------------------------------------------------------
// Lookup tables
// ---------------------------------------------------------------------------

/// Block-level tags that get blank-line separation.
const block_tags = std.StaticStringMap(void).initComptime(.{
    .{ "h1", {} },  .{ "h2", {} },  .{ "h3", {} },
    .{ "h4", {} },  .{ "h5", {} },  .{ "h6", {} },
    .{ "p", {} },   .{ "blockquote", {} },
    .{ "ul", {} },  .{ "ol", {} },
    .{ "pre", {} }, .{ "hr", {} },  .{ "table", {} },
});

/// Heading tags → ATX prefix level.
const heading_levels = std.StaticStringMap(u8).initComptime(.{
    .{ "h1", 1 }, .{ "h2", 2 }, .{ "h3", 3 },
    .{ "h4", 4 }, .{ "h5", 5 }, .{ "h6", 6 },
});

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Write GFM Markdown for a ztree Node to any writer.
pub fn render(node: Node, writer: anytype) !void {
    var r: MdRenderer(@TypeOf(writer)) = .{ .writer = writer };
    r.walker = ztree.walker(&r);
    try ztree.renderWalk(&r, node);
}

// ---------------------------------------------------------------------------
// Renderer — struct implementing the ztree renderWalk protocol
// ---------------------------------------------------------------------------

fn MdRenderer(Writer: type) type {
    return struct {
        const Self = @This();

        writer: Writer,
        walker: Walker = undefined,
        prefix_buf: [256]u8 = undefined,
        prefix_len: usize = 0,
        has_prev_block: bool = false,

        // Frame stack for save/restore on nesting boundaries.
        frames: [64]Frame = undefined,
        depth: usize = 0,

        const Frame = struct {
            has_prev_block: bool,
            prefix_len: usize,
        };

        // ── State management ─────────────────────────────────────────

        fn prefix(self: *const Self) []const u8 {
            return self.prefix_buf[0..self.prefix_len];
        }

        fn pushPrefix(self: *Self, suffix: []const u8) void {
            if (self.prefix_len + suffix.len <= self.prefix_buf.len) {
                @memcpy(self.prefix_buf[self.prefix_len..][0..suffix.len], suffix);
                self.prefix_len += suffix.len;
            }
        }

        fn pushFrame(self: *Self) void {
            self.frames[self.depth] = .{
                .has_prev_block = self.has_prev_block,
                .prefix_len = self.prefix_len,
            };
            self.depth += 1;
            self.has_prev_block = false;
        }

        fn popFrame(self: *Self) void {
            self.depth -= 1;
            const f = self.frames[self.depth];
            self.has_prev_block = f.has_prev_block;
            self.prefix_len = f.prefix_len;
        }

        // ── renderWalk protocol ──────────────────────────────────────

        pub fn onText(self: *Self, content: []const u8) !void {
            try self.writer.writeAll(content);
        }

        pub fn onRaw(self: *Self, content: []const u8) !void {
            try self.writer.writeAll(content);
        }

        pub fn elementOpen(self: *Self, el: Element) !WalkAction {
            // Block separation — blank line between consecutive block elements.
            if (block_tags.has(el.tag)) {
                if (self.has_prev_block) {
                    try self.writer.writeAll(self.prefix());
                    try self.writer.writeByte('\n');
                }
                self.has_prev_block = true;
            }

            // ── Block elements ──

            if (heading_levels.get(el.tag)) |level| {
                try writeHeadingPrefix(self.writer, self.prefix(), level);
                return .@"continue";
            }
            if (std.mem.eql(u8, el.tag, "p")) {
                try self.writer.writeAll(self.prefix());
                return .@"continue";
            }
            if (std.mem.eql(u8, el.tag, "blockquote")) {
                self.pushFrame();
                self.pushPrefix("> ");
                return .@"continue";
            }
            if (std.mem.eql(u8, el.tag, "ul") or std.mem.eql(u8, el.tag, "ol")) {
                try self.renderList(el);
                return .skip_children;
            }
            if (std.mem.eql(u8, el.tag, "pre")) {
                const info = extractCodeInfo(el);
                try writeCodeBlock(self.writer, self.prefix(), info.language, info.content);
                return .skip_children;
            }
            if (std.mem.eql(u8, el.tag, "table")) {
                const t = extractTableSections(el.children);
                try writeTable(t.thead, t.tbody, self.writer, self.prefix());
                return .skip_children;
            }
            if (std.mem.eql(u8, el.tag, "hr")) {
                try writeThematicBreak(self.writer, self.prefix());
                return .skip_children;
            }

            // ── Inline elements ──

            if (std.mem.eql(u8, el.tag, "strong")) {
                try self.writer.writeAll("**");
                return .@"continue";
            }
            if (std.mem.eql(u8, el.tag, "em")) {
                try self.writer.writeAll("*");
                return .@"continue";
            }
            if (std.mem.eql(u8, el.tag, "del")) {
                try self.writer.writeAll("~~");
                return .@"continue";
            }
            if (std.mem.eql(u8, el.tag, "code")) {
                try writeInlineCode(self.writer, el.children);
                return .skip_children;
            }
            if (std.mem.eql(u8, el.tag, "a")) {
                try self.writer.writeByte('[');
                return .@"continue";
            }
            if (std.mem.eql(u8, el.tag, "img")) {
                try writeImage(self.writer, el.attrs);
                return .skip_children;
            }
            if (std.mem.eql(u8, el.tag, "br")) {
                try self.writer.writeAll("  \n");
                try self.writer.writeAll(self.prefix());
                return .skip_children;
            }

            // Unknown tag — render children without wrapper.
            return .@"continue";
        }

        pub fn elementClose(self: *Self, el: Element) !void {
            if (heading_levels.has(el.tag)) {
                try self.writer.writeByte('\n');
            } else if (std.mem.eql(u8, el.tag, "p")) {
                try self.writer.writeByte('\n');
            } else if (std.mem.eql(u8, el.tag, "blockquote")) {
                self.popFrame();
            } else if (std.mem.eql(u8, el.tag, "strong")) {
                try self.writer.writeAll("**");
            } else if (std.mem.eql(u8, el.tag, "em")) {
                try self.writer.writeAll("*");
            } else if (std.mem.eql(u8, el.tag, "del")) {
                try self.writer.writeAll("~~");
            } else if (std.mem.eql(u8, el.tag, "a")) {
                try writeLinkTail(self.writer, el.attrs);
            }
        }

        // ── List rendering (skip_children, manual iteration) ─────────
        //
        // Lists use .skip_children because list-item children need custom
        // inline/block mixed handling that differs from standard block
        // separation. Nested content is walked via Walker re-entry.

        fn renderList(self: *Self, el: Element) !void {
            const ordered = std.mem.eql(u8, el.tag, "ol");
            const indent = if (ordered) "   " else "  ";
            var n: usize = 1;

            for (el.children) |child| {
                const items: []const Node = switch (child) {
                    .element => @as(*const [1]Node, &child),
                    .fragment => |f| f,
                    else => continue,
                };
                for (items) |item| {
                    const li = switch (item) {
                        .element => |li_el| if (std.mem.eql(u8, li_el.tag, "li")) li_el else continue,
                        else => continue,
                    };
                    try writeListMarker(self.writer, self.prefix(), ordered, n, li.attrs);

                    const saved_prev = self.has_prev_block;
                    self.has_prev_block = false;
                    self.pushPrefix(indent);

                    // Mixed inline + block children: inline flows on the
                    // marker line, blocks start on new lines.
                    var had_inline = false;
                    var emitted_any = false;
                    for (li.children) |li_child| {
                        if (isBlockNode(li_child)) {
                            if (!emitted_any or had_inline) try self.writer.writeByte('\n');
                            had_inline = false;
                            try self.walker.walk(li_child);
                            emitted_any = true;
                        } else {
                            try self.walker.walk(li_child);
                            had_inline = true;
                            emitted_any = true;
                        }
                    }
                    if (had_inline or !endsWithNewline(li.children)) {
                        try self.writer.writeByte('\n');
                    }

                    self.prefix_len -= indent.len;
                    self.has_prev_block = saved_prev;
                    n += 1;
                }
            }
        }
    };
}

// ---------------------------------------------------------------------------
// Leaf writers — write output, never recurse into the tree
// ---------------------------------------------------------------------------

/// Write ATX heading prefix: `### `.
fn writeHeadingPrefix(writer: anytype, pfx: []const u8, level: u8) !void {
    try writer.writeAll(pfx);
    for (0..level) |_| try writer.writeByte('#');
    try writer.writeByte(' ');
}

/// Write list-item marker: `- `, `1. `, with optional task checkbox.
fn writeListMarker(writer: anytype, pfx: []const u8, ordered: bool, index: usize, attrs: []const Attr) !void {
    try writer.writeAll(pfx);
    if (ordered) {
        try writeOrderedNumber(writer, index);
    } else {
        try writer.writeAll("- ");
    }
    const is_task = hasAttr(attrs, "task") or hasAttr(attrs, "checked");
    if (is_task) {
        if (hasAttr(attrs, "checked")) {
            try writer.writeAll("[x] ");
        } else {
            try writer.writeAll("[ ] ");
        }
    }
}

/// Write `1. ` (with the actual number).
fn writeOrderedNumber(writer: anytype, index: usize) !void {
    var buf: [20]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}. ", .{index}) catch unreachable;
    try writer.writeAll(s);
}

/// Write a fenced code block with optional language.
fn writeCodeBlock(writer: anytype, pfx: []const u8, language: []const u8, content: []const u8) !void {
    const fence = chooseFence(content);
    try writer.writeAll(pfx);
    try writer.writeAll(fence);
    try writer.writeAll(language);
    try writer.writeByte('\n');
    try writePrefixedLines(content, writer, pfx);
    try writer.writeAll(pfx);
    try writer.writeAll(fence);
    try writer.writeByte('\n');
}

/// Write `---\n`.
fn writeThematicBreak(writer: anytype, pfx: []const u8) !void {
    try writer.writeAll(pfx);
    try writer.writeAll("---\n");
}

/// Write backtick-wrapped inline code, iterating all text/raw children.
fn writeInlineCode(writer: anytype, children: []const Node) !void {
    const has_backtick = textContains(children, '`');
    if (has_backtick) {
        try writer.writeAll("`` ");
        try writeAllText(children, writer);
        try writer.writeAll(" ``");
    } else {
        try writer.writeByte('`');
        try writeAllText(children, writer);
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
fn writePrefixedLines(content: []const u8, writer: anytype, pfx: []const u8) !void {
    if (content.len == 0) return;
    var start: usize = 0;
    for (content, 0..) |c, i| {
        if (c == '\n') {
            try writer.writeAll(pfx);
            try writer.writeAll(content[start .. i + 1]);
            start = i + 1;
        }
    }
    if (start < content.len) {
        try writer.writeAll(pfx);
        try writer.writeAll(content[start..]);
        try writer.writeByte('\n');
    }
}

// ---------------------------------------------------------------------------
// Table writers — own recursion domain for cell content.
// Pipe escaping and limited inline formatting, no renderWalk re-entry.
// ---------------------------------------------------------------------------

/// Write a full GFM table from thead/tbody children.
fn writeTable(thead: []const Node, tbody: []const Node, writer: anytype, pfx: []const u8) !void {
    for (thead) |child| {
        switch (child) {
            .element => |tr| {
                if (std.mem.eql(u8, tr.tag, "tr")) {
                    try writeTableRow(tr.children, writer, pfx);
                    try writeSeparatorRow(tr.children, writer, pfx);
                }
            },
            else => {},
        }
    }
    for (tbody) |child| {
        switch (child) {
            .element => |tr| {
                if (std.mem.eql(u8, tr.tag, "tr")) {
                    try writeTableRow(tr.children, writer, pfx);
                }
            },
            else => {},
        }
    }
}

fn writeTableRow(cells: []const Node, writer: anytype, pfx: []const u8) !void {
    try writer.writeAll(pfx);
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

fn writeSeparatorRow(header_cells: []const Node, writer: anytype, pfx: []const u8) !void {
    try writer.writeAll(pfx);
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

/// Return the first text or raw content from a flat children list.
/// Used by extractCodeInfo for `pre > code` content (single text child).
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

/// Write all text/raw content from children to writer. Handles multiple
/// text nodes (e.g. from TreeBuilder producing separate text events).
fn writeAllText(children: []const Node, writer: anytype) !void {
    for (children) |child| {
        switch (child) {
            .text => |t| try writer.writeAll(t),
            .raw => |r| try writer.writeAll(r),
            .fragment => |frag| try writeAllText(frag, writer),
            else => {},
        }
    }
}

/// Check whether any text/raw child contains a specific byte.
fn textContains(children: []const Node, needle: u8) bool {
    for (children) |child| {
        switch (child) {
            .text => |t| if (std.mem.indexOfScalar(u8, t, needle) != null) return true,
            .raw => |r| if (std.mem.indexOfScalar(u8, r, needle) != null) return true,
            .fragment => |frag| if (textContains(frag, needle)) return true,
            else => {},
        }
    }
    return false;
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
const TreeBuilder = ztree.TreeBuilder;

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
        try ztree.element(a, "li", .{ .task = {} }, .{ ztree.text("todo") }),
    }));
    defer testing.allocator.free(md);
    try testing.expectEqualStrings("- [x] done\n- [ ] todo\n", md);
}

test "task list — checked with string value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const md = try renderToString(try ztree.element(a, "ul", .{}, .{
        try ztree.element(a, "li", .{ .checked = "true" }, .{ ztree.text("also done") }),
    }));
    defer testing.allocator.free(md);
    try testing.expectEqualStrings("- [x] also done\n", md);
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
    const md = try renderToString(try ztree.closedElement(arena.allocator(), "hr", .{}));
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
                try ztree.element(a, "th", .{}, .{ ztree.text("Name") }),
                try ztree.element(a, "th", .{ .@"align" = "center" }, .{ ztree.text("Age") }),
                try ztree.element(a, "th", .{ .@"align" = "right" }, .{ ztree.text("Score") }),
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
        try ztree.element(a, "em", .{}, .{ ztree.text("i") }),
        ztree.text(" "),
        try ztree.element(a, "del", .{}, .{ ztree.text("d") }),
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

test "inline code — multiple text children from TreeBuilder" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = TreeBuilder.init(arena.allocator());
    try b.open("code", .{});
    try b.text("hello ");
    try b.text("world");
    try b.close();
    const md = try renderToString(try b.finish());
    defer testing.allocator.free(md);
    try testing.expectEqualStrings("`hello world`", md);
}

test "inline code — backtick in multi-child" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = TreeBuilder.init(arena.allocator());
    try b.open("code", .{});
    try b.text("a");
    try b.text("`");
    try b.text("b");
    try b.close();
    const md = try renderToString(try b.finish());
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
    const md = try renderToString(try ztree.closedElement(a, "img",
        .{ .src = "photo.jpg", .alt = "A photo", .title = "My photo" }));
    defer testing.allocator.free(md);
    try testing.expectEqualStrings("![A photo](photo.jpg \"My photo\")", md);
}

test "hard line break" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const md = try renderToString(try ztree.element(a, "p", .{}, .{
        ztree.text("line one"),
        try ztree.closedElement(a, "br", .{}),
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
