/// ztree-md — GFM (GitHub Flavoured Markdown) renderer for ztree.
///
/// Architecture:
///   render()           — public entry point, delegates to ztree.renderWalk.
///   MdRenderer         — struct implementing the renderWalk protocol:
///                          elementOpen / elementClose / onText / onRaw.
///   elementOpen uses WalkAction:
///     .continue        — simple wrappers (strong, em, headings, p, blockquote, a, del).
///                          renderWalk recurses children and calls elementClose.
///     .skip_children   — complex elements (pre, table, code, ul/ol, hr, br, img).
///                          Handled entirely in elementOpen; no elementClose.
///                          List rendering uses ztree.Walker for re-entrant traversal.
///   Free functions     — pure helpers and leaf writers shared across contexts.
const std = @import("std");
const ztree = @import("ztree");
const Node = ztree.Node;
const Element = ztree.Element;
const WalkAction = ztree.WalkAction;
const Writer = std.Io.Writer;

// ---------------------------------------------------------------------------
// Lookup tables
// ---------------------------------------------------------------------------

/// Block-level tags that get blank-line separation.
const block_tags = std.StaticStringMap(void).initComptime(.{
    .{ "h1", {} },    .{ "h2", {} },         .{ "h3", {} },
    .{ "h4", {} },    .{ "h5", {} },         .{ "h6", {} },
    .{ "p", {} },     .{ "blockquote", {} }, .{ "ul", {} },
    .{ "ol", {} },    .{ "pre", {} },        .{ "hr", {} },
    .{ "table", {} },
});

/// Heading tags → ATX prefix level.
const heading_levels = std.StaticStringMap(u8).initComptime(.{
    .{ "h1", 1 }, .{ "h2", 2 }, .{ "h3", 3 },
    .{ "h4", 4 }, .{ "h5", 5 }, .{ "h6", 6 },
});

const heading_prefixes = [_][]const u8{ "# ", "## ", "### ", "#### ", "##### ", "###### " };

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Errors returned by `render`.
pub const RenderError = Writer.Error || error{
    /// Blockquote/list prefix exceeded the renderer's bounded stack buffer.
    PrefixOverflow,
    /// Blockquote nesting exceeded the renderer's bounded frame stack.
    NestingOverflow,
};

/// Write GFM Markdown for a ztree Node to a Zig 0.16 `std.Io.Writer`.
///
/// The renderer itself performs no heap allocation and does not flush. It may
/// return writer errors plus `error.PrefixOverflow` / `error.NestingOverflow`
/// for extremely deep nesting.
pub fn render(node: Node, writer: *Writer) RenderError!void {
    var r: MdRenderer = .{ .writer = writer };
    r.walker = ztree.typedWalker(RenderError, &r);
    try ztree.renderWalk(&r, node);
}

// ---------------------------------------------------------------------------
// Renderer — struct implementing the ztree renderWalk protocol
// ---------------------------------------------------------------------------

const MdRenderer = struct {
    const Self = @This();

    const max_prefix_len = 256;
    const max_frame_depth = 64;

    writer: *Writer,
    walker: ztree.TypedWalker(RenderError) = undefined,
    prefix_buf: [max_prefix_len]u8 = undefined,
    prefix_len: usize = 0,
    has_prev_block: bool = false,

    // Frame stack for save/restore on nesting boundaries.
    frames: [max_frame_depth]Frame = undefined,
    depth: usize = 0,

    const Frame = struct {
        has_prev_block: bool,
        prefix_len: usize,
    };

    // ── State management ─────────────────────────────────────────

    fn prefix(self: *const Self) []const u8 {
        return self.prefix_buf[0..self.prefix_len];
    }

    fn pushPrefix(self: *Self, suffix: []const u8) RenderError!void {
        const new_len = std.math.add(usize, self.prefix_len, suffix.len) catch return error.PrefixOverflow;
        if (new_len > self.prefix_buf.len) return error.PrefixOverflow;
        @memcpy(self.prefix_buf[self.prefix_len..new_len], suffix);
        self.prefix_len = new_len;
    }

    fn pushFrame(self: *Self, prefix_suffix: []const u8) RenderError!void {
        if (self.depth == self.frames.len) return error.NestingOverflow;
        const new_prefix_len = std.math.add(usize, self.prefix_len, prefix_suffix.len) catch return error.PrefixOverflow;
        if (new_prefix_len > self.prefix_buf.len) return error.PrefixOverflow;

        self.frames[self.depth] = .{
            .has_prev_block = self.has_prev_block,
            .prefix_len = self.prefix_len,
        };
        self.depth += 1;
        self.has_prev_block = false;
        @memcpy(self.prefix_buf[self.prefix_len..new_prefix_len], prefix_suffix);
        self.prefix_len = new_prefix_len;
    }

    fn popFrame(self: *Self) void {
        std.debug.assert(self.depth > 0);
        self.depth -= 1;
        const f = self.frames[self.depth];
        self.has_prev_block = f.has_prev_block;
        self.prefix_len = f.prefix_len;
    }

    fn walk(self: *Self, node: Node) RenderError!void {
        try self.walker.walk(node);
    }

    // ── renderWalk protocol ──────────────────────────────────────

    pub fn onText(self: *Self, content: []const u8) RenderError!void {
        try self.writer.writeAll(content);
    }

    pub fn onRaw(self: *Self, content: []const u8) RenderError!void {
        try self.writer.writeAll(content);
    }

    pub fn elementOpen(self: *Self, el: Element) RenderError!WalkAction {
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
            try self.pushFrame("> ");
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
            try writeImage(self.writer, el);
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

    pub fn elementClose(self: *Self, el: Element) RenderError!void {
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
            try writeLinkTail(self.writer, el);
        }
    }

    // ── List rendering (skip_children, manual iteration) ─────────
    //
    // Lists use .skip_children because list-item children need custom
    // inline/block mixed handling that differs from standard block
    // separation. Nested content is walked through ztree.Walker, the
    // type-erased re-entrant traversal helper added by ztree v2.

    fn renderList(self: *Self, el: Element) RenderError!void {
        const ordered = std.mem.eql(u8, el.tag, "ol");
        const indent = if (ordered) "   " else "  ";
        var n: usize = if (ordered) orderedListStart(el) else 1;

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
                try writeListMarker(self.writer, self.prefix(), ordered, n, li);

                const saved_prev = self.has_prev_block;
                const saved_prefix_len = self.prefix_len;
                defer {
                    self.has_prev_block = saved_prev;
                    self.prefix_len = saved_prefix_len;
                }

                self.has_prev_block = false;
                try self.pushPrefix(indent);

                // Mixed inline + block children: inline flows on the
                // marker line, blocks start on new lines.
                var had_inline = false;
                var emitted_any = false;
                for (li.children) |li_child| {
                    if (isBlockNode(li_child)) {
                        if (!emitted_any or had_inline) try self.writer.writeByte('\n');
                        had_inline = false;
                        try self.walk(li_child);
                        emitted_any = true;
                    } else {
                        try self.walk(li_child);
                        had_inline = true;
                        emitted_any = true;
                    }
                }
                if (had_inline or !endsWithNewline(li.children)) {
                    try self.writer.writeByte('\n');
                }
                n += 1;
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Leaf writers — write output, never recurse into the tree
// ---------------------------------------------------------------------------

/// Write ATX heading prefix: `### `.
fn writeHeadingPrefix(writer: *Writer, pfx: []const u8, level: u8) !void {
    var parts = [_][]const u8{ pfx, heading_prefixes[level - 1] };
    try writer.writeVecAll(&parts);
}

/// Write list-item marker: `- `, `1. `, with optional task checkbox.
fn writeListMarker(writer: *Writer, pfx: []const u8, ordered: bool, index: usize, li: Element) !void {
    try writer.writeAll(pfx);
    if (ordered) {
        try writeOrderedNumber(writer, index);
    } else {
        try writer.writeAll("- ");
    }
    if (taskChecked(li)) |checked| {
        try writer.writeAll(if (checked) "[x] " else "[ ] ");
    }
}

/// Write `1. ` (with the actual number).
fn writeOrderedNumber(writer: *Writer, index: usize) !void {
    // usize max on 64-bit is 20 decimal digits; add ". ".
    var buf: [22]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}. ", .{index}) catch unreachable;
    try writer.writeAll(s);
}

/// Write a fenced code block with optional language.
fn writeCodeBlock(writer: *Writer, pfx: []const u8, language: []const u8, content: []const Node) !void {
    const fence = chooseFence(content);
    var open = [_][]const u8{ pfx, fence, language, "\n" };
    try writer.writeVecAll(&open);
    try writePrefixedText(content, writer, pfx);
    var close = [_][]const u8{ pfx, fence, "\n" };
    try writer.writeVecAll(&close);
}

/// Write `---\n`.
fn writeThematicBreak(writer: *Writer, pfx: []const u8) !void {
    try writer.writeAll(pfx);
    try writer.writeAll("---\n");
}

/// Write backtick-wrapped inline code, iterating all text/raw children.
fn writeInlineCode(writer: *Writer, children: []const Node) !void {
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
fn writeLinkTail(writer: *Writer, el: Element) !void {
    const href = el.getAttr("href") orelse "";
    const title = el.getAttr("title");
    if (title) |t| {
        var parts = [_][]const u8{ "](", href, " \"", t, "\")" };
        try writer.writeVecAll(&parts);
    } else {
        var parts = [_][]const u8{ "](", href, ")" };
        try writer.writeVecAll(&parts);
    }
}

/// Write `![alt](src "title")`.
fn writeImage(writer: *Writer, el: Element) !void {
    const src = el.getAttr("src") orelse "";
    const alt = el.getAttr("alt") orelse "";
    const title = el.getAttr("title");
    if (title) |t| {
        var parts = [_][]const u8{ "![", alt, "](", src, " \"", t, "\")" };
        try writer.writeVecAll(&parts);
    } else {
        var parts = [_][]const u8{ "![", alt, "](", src, ")" };
        try writer.writeVecAll(&parts);
    }
}

/// Write text/raw content line-by-line, prepending prefix to each line.
fn writePrefixedText(content: []const Node, writer: *Writer, pfx: []const u8) !void {
    var state = PrefixedTextWriter{ .writer = writer, .prefix = pfx };
    try state.writeNodes(content);
    try state.finish();
}

const PrefixedTextWriter = struct {
    const Self = @This();

    writer: *Writer,
    prefix: []const u8,
    at_line_start: bool = true,
    wrote_any: bool = false,
    ended_with_newline: bool = false,

    fn writeNodes(self: *Self, nodes: []const Node) !void {
        for (nodes) |node| {
            switch (node) {
                .text => |t| try self.writeSlice(t),
                .raw => |r| try self.writeSlice(r),
                .fragment => |frag| try self.writeNodes(frag),
                .element => {},
            }
        }
    }

    fn writeSlice(self: *Self, text: []const u8) !void {
        var start: usize = 0;
        for (text, 0..) |c, i| {
            if (c == '\n') {
                if (self.at_line_start) try self.writer.writeAll(self.prefix);
                try self.writer.writeAll(text[start .. i + 1]);
                self.at_line_start = true;
                self.wrote_any = true;
                self.ended_with_newline = true;
                start = i + 1;
            }
        }

        if (start < text.len) {
            if (self.at_line_start) try self.writer.writeAll(self.prefix);
            try self.writer.writeAll(text[start..]);
            self.at_line_start = false;
            self.wrote_any = true;
            self.ended_with_newline = false;
        }
    }

    fn finish(self: *Self) !void {
        if (self.wrote_any and !self.ended_with_newline) try self.writer.writeByte('\n');
    }
};

// ---------------------------------------------------------------------------
// Table writers — own recursion domain for cell content.
// Pipe escaping and limited inline formatting, no renderWalk re-entry.
// ---------------------------------------------------------------------------

/// Write a full GFM table from thead/tbody children.
fn writeTable(thead: []const Node, tbody: []const Node, writer: *Writer, pfx: []const u8) !void {
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

fn writeTableRow(cells: []const Node, writer: *Writer, pfx: []const u8) !void {
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
fn writeCellContent(children: []const Node, writer: *Writer) !void {
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
                    try writeLinkTail(writer, el);
                } else {
                    try writeCellContent(el.children, writer);
                }
            },
        }
    }
}

fn writePipeEscaped(text: []const u8, writer: *Writer) !void {
    var unescaped_start: usize = 0;

    for (text, 0..) |c, i| {
        if (c != '|') continue;

        if (unescaped_start < i) {
            var escaped = [_][]const u8{ text[unescaped_start..i], "\\|" };
            try writer.writeVecAll(&escaped);
        } else {
            try writer.writeAll("\\|");
        }
        unescaped_start = i + 1;
    }

    if (unescaped_start < text.len) {
        try writer.writeAll(text[unescaped_start..]);
    }
}

fn writeSeparatorRow(header_cells: []const Node, writer: *Writer, pfx: []const u8) !void {
    try writer.writeAll(pfx);
    try writer.writeByte('|');
    for (header_cells) |cell| {
        switch (cell) {
            .element => |el| {
                if (std.mem.eql(u8, el.tag, "th")) {
                    try writer.writeAll(separatorCell(el));
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
const CodeInfo = struct { language: []const u8, content: []const Node };

fn extractCodeInfo(e: Element) CodeInfo {
    for (e.children) |child| {
        switch (child) {
            .element => |code| {
                if (std.mem.eql(u8, code.tag, "code")) {
                    return .{
                        .language = languageFromClass(code),
                        .content = code.children,
                    };
                }
            },
            else => {},
        }
    }
    return .{ .language = "", .content = e.children };
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
fn chooseFence(content: []const Node) []const u8 {
    return if (textContainsTripleBackticks(content)) "````" else "```";
}

fn textContainsTripleBackticks(children: []const Node) bool {
    var consecutive: usize = 0;
    return textContainsTripleBackticksInner(children, &consecutive);
}

fn textContainsTripleBackticksInner(children: []const Node, consecutive: *usize) bool {
    for (children) |child| {
        switch (child) {
            .text => |t| if (sliceContainsTripleBackticks(t, consecutive)) return true,
            .raw => |r| if (sliceContainsTripleBackticks(r, consecutive)) return true,
            .fragment => |frag| if (textContainsTripleBackticksInner(frag, consecutive)) return true,
            .element => {},
        }
    }
    return false;
}

fn sliceContainsTripleBackticks(content: []const u8, consecutive: *usize) bool {
    for (content) |c| {
        if (c == '`') {
            consecutive.* += 1;
            if (consecutive.* == 3) return true;
        } else {
            consecutive.* = 0;
        }
    }
    return false;
}

fn orderedListStart(el: Element) usize {
    const value = el.getAttr("start") orelse return 1;
    return std.fmt.parseInt(usize, value, 10) catch 1;
}

fn taskChecked(li: Element) ?bool {
    if (li.hasAttr("checked")) return true;
    if (li.hasAttr("task")) return false;
    return leadingCheckboxChecked(li.children);
}

const LeadingCheckbox = union(enum) {
    found: bool,
    none,
    blocked,
};

fn leadingCheckboxChecked(children: []const Node) ?bool {
    return switch (findLeadingCheckbox(children)) {
        .found => |checked| checked,
        .none, .blocked => null,
    };
}

fn findLeadingCheckbox(children: []const Node) LeadingCheckbox {
    for (children) |child| {
        switch (child) {
            .element => |el| {
                if (std.mem.eql(u8, el.tag, "input")) {
                    const input_type = el.getAttr("type") orelse return .blocked;
                    if (std.ascii.eqlIgnoreCase(input_type, "checkbox")) return .{ .found = el.hasAttr("checked") };
                }
                return .blocked;
            },
            .fragment => |frag| switch (findLeadingCheckbox(frag)) {
                .found => |checked| return .{ .found = checked },
                .blocked => return .blocked,
                .none => continue,
            },
            .text => |t| if (!isBlank(t)) return .blocked,
            .raw => |r| if (!isBlank(r)) return .blocked,
        }
    }
    return .none;
}

fn isBlank(s: []const u8) bool {
    return std.mem.trim(u8, s, " \t\r\n").len == 0;
}

/// Return separator cell markup based on alignment attr or CSS text-align style.
fn separatorCell(el: Element) []const u8 {
    const a = el.getAttr("align") orelse alignmentFromStyle(el.getAttr("style")) orelse return " --- |";
    if (std.ascii.eqlIgnoreCase(a, "left")) return " :--- |";
    if (std.ascii.eqlIgnoreCase(a, "center")) return " :---: |";
    if (std.ascii.eqlIgnoreCase(a, "right")) return " ---: |";
    return " --- |";
}

fn alignmentFromStyle(style: ?[]const u8) ?[]const u8 {
    var rest = style orelse return null;
    while (rest.len > 0) {
        const sep = std.mem.indexOfScalar(u8, rest, ';') orelse rest.len;
        const declaration = rest[0..sep];
        defer rest = if (sep == rest.len) "" else rest[sep + 1 ..];

        const colon = std.mem.indexOfScalar(u8, declaration, ':') orelse continue;
        const property = std.mem.trim(u8, declaration[0..colon], " \t\r\n");
        if (!std.ascii.eqlIgnoreCase(property, "text-align")) continue;

        const value = std.mem.trim(u8, declaration[colon + 1 ..], " \t\r\n");
        if (std.ascii.eqlIgnoreCase(value, "left")) return "left";
        if (std.ascii.eqlIgnoreCase(value, "center")) return "center";
        if (std.ascii.eqlIgnoreCase(value, "right")) return "right";
    }
    return null;
}

/// Extract language from `class="language-xxx"`.
fn languageFromClass(el: Element) []const u8 {
    const class = el.getAttr("class") orelse return "";
    return if (std.mem.startsWith(u8, class, "language-")) class["language-".len..] else "";
}

/// Write all text/raw content from children to writer. Handles multiple
/// text nodes (e.g. from TreeBuilder producing separate text events).
fn writeAllText(children: []const Node, writer: *Writer) !void {
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
    var aw: Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try render(node, &aw.writer);
    return aw.toOwnedSlice();
}

// -- writer integration --

test "render — fixed writer streams without allocation" {
    var buffer: [64]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    try render(ztree.text("hello *world*"), &writer);

    try testing.expectEqualStrings("hello *world*", writer.buffered());
}

test "render — fixed writer reports WriteFailed when full" {
    var buffer: [4]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    try testing.expectError(error.WriteFailed, render(ztree.text("hello"), &writer));
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
    const md = try renderToString(try ztree.element(arena.allocator(), "div", .{}, .{ztree.text("inside")}));
    defer testing.allocator.free(md);
    try testing.expectEqualStrings("inside", md);
}

// -- block elements --

test "headings — h1 and h6 boundaries" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h1 = try renderToString(try ztree.element(a, "h1", .{}, .{ztree.text("Top")}));
    defer testing.allocator.free(h1);
    try testing.expectEqualStrings("# Top\n", h1);

    const h6 = try renderToString(try ztree.element(a, "h6", .{}, .{ztree.text("Deep")}));
    defer testing.allocator.free(h6);
    try testing.expectEqualStrings("###### Deep\n", h6);
}

test "paragraphs — blank line separation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const md = try renderToString(try ztree.fragment(a, .{
        try ztree.element(a, "p", .{}, .{ztree.text("First.")}),
        try ztree.element(a, "p", .{}, .{ztree.text("Second.")}),
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
            try ztree.element(a, "p", .{}, .{ztree.text("Deep.")}),
        }),
    }));
    defer testing.allocator.free(md);
    try testing.expectEqualStrings("> > Deep.\n", md);
}

test "deep blockquotes return explicit nesting error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var b = TreeBuilder.init(arena.allocator());
    for (0..65) |_| try b.open("blockquote", .{});
    try b.open("p", .{});
    try b.text("too deep");
    try b.close();
    for (0..65) |_| try b.close();

    try testing.expectError(error.NestingOverflow, renderToString(try b.finish()));
}

test "unordered list — nested" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const md = try renderToString(try ztree.element(a, "ul", .{}, .{
        try ztree.element(a, "li", .{}, .{
            ztree.text("parent"),
            try ztree.element(a, "ul", .{}, .{
                try ztree.element(a, "li", .{}, .{ztree.text("child")}),
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
                try ztree.element(a, "li", .{}, .{ztree.text("child")}),
            }),
        }),
    }));
    defer testing.allocator.free(md);
    try testing.expectEqualStrings("1. parent\n   1. child\n", md);
}

test "ordered list — start attr" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const md = try renderToString(try ztree.element(a, "ol", .{ .start = "3" }, .{
        try ztree.element(a, "li", .{}, .{ztree.text("foo")}),
        try ztree.element(a, "li", .{}, .{ztree.text("bar")}),
    }));
    defer testing.allocator.free(md);
    try testing.expectEqualStrings("3. foo\n4. bar\n", md);
}

test "task list — checked and unchecked" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const md = try renderToString(try ztree.element(a, "ul", .{}, .{
        try ztree.element(a, "li", .{ .checked = {} }, .{ztree.text("done")}),
        try ztree.element(a, "li", .{ .task = {} }, .{ztree.text("todo")}),
    }));
    defer testing.allocator.free(md);
    try testing.expectEqualStrings("- [x] done\n- [ ] todo\n", md);
}

test "task list — checked with string value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const md = try renderToString(try ztree.element(a, "ul", .{}, .{
        try ztree.element(a, "li", .{ .checked = "true" }, .{ztree.text("also done")}),
    }));
    defer testing.allocator.free(md);
    try testing.expectEqualStrings("- [x] also done\n", md);
}

test "task list — leading checkbox input" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const md = try renderToString(try ztree.element(a, "ul", .{}, .{
        try ztree.element(a, "li", .{}, .{
            try ztree.closedElement(a, "input", .{ .type = "checkbox", .checked = {} }),
            ztree.text("done"),
        }),
        try ztree.element(a, "li", .{}, .{
            try ztree.closedElement(a, "input", .{ .type = "checkbox" }),
            ztree.text("todo"),
        }),
    }));
    defer testing.allocator.free(md);
    try testing.expectEqualStrings("- [x] done\n- [ ] todo\n", md);
}

test "task list — checkbox input must be leading" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const md = try renderToString(try ztree.element(a, "ul", .{}, .{
        try ztree.element(a, "li", .{}, .{
            ztree.text("not a task"),
            try ztree.closedElement(a, "input", .{ .type = "checkbox", .checked = {} }),
        }),
    }));
    defer testing.allocator.free(md);
    try testing.expectEqualStrings("- not a task\n", md);
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
        try ztree.element(a, "code", .{}, .{ztree.text("some ``` inside")}),
    }));
    defer testing.allocator.free(md);
    try testing.expectEqualStrings("````\nsome ``` inside\n````\n", md);
}

test "fenced code block — multiple text children from TreeBuilder" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = TreeBuilder.init(arena.allocator());
    try b.open("pre", .{});
    try b.open("code", .{ .class = "language-zig" });
    try b.text("const ");
    try b.text("x = 42;");
    try b.close();
    try b.close();

    const md = try renderToString(try b.finish());
    defer testing.allocator.free(md);
    try testing.expectEqualStrings("```zig\nconst x = 42;\n```\n", md);
}

test "fenced code block — triple backtick across text children" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = TreeBuilder.init(arena.allocator());
    try b.open("pre", .{});
    try b.open("code", .{});
    try b.text("some ``");
    try b.text("` inside");
    try b.close();
    try b.close();

    const md = try renderToString(try b.finish());
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
                try ztree.element(a, "th", .{}, .{ztree.text("Name")}),
                try ztree.element(a, "th", .{ .@"align" = "center" }, .{ztree.text("Age")}),
                try ztree.element(a, "th", .{ .@"align" = "right" }, .{ztree.text("Score")}),
            }),
        }),
        try ztree.element(a, "tbody", .{}, .{
            try ztree.element(a, "tr", .{}, .{
                try ztree.element(a, "td", .{}, .{ztree.text("Al|ice")}),
                try ztree.element(a, "td", .{}, .{ztree.text("30")}),
                try ztree.element(a, "td", .{}, .{ztree.text("95")}),
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

test "GFM table — style text-align from HTML-shaped tree" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const md = try renderToString(try ztree.element(a, "table", .{}, .{
        try ztree.element(a, "thead", .{}, .{
            try ztree.element(a, "tr", .{}, .{
                try ztree.element(a, "th", .{ .style = "text-align: left" }, .{ztree.text("Name")}),
                try ztree.element(a, "th", .{ .style = "text-align: center" }, .{ztree.text("Age")}),
                try ztree.element(a, "th", .{ .style = "text-align: right" }, .{ztree.text("Score")}),
            }),
        }),
        try ztree.element(a, "tbody", .{}, .{
            try ztree.element(a, "tr", .{}, .{
                try ztree.element(a, "td", .{}, .{ztree.text("Bob")}),
                try ztree.element(a, "td", .{}, .{ztree.text("30")}),
                try ztree.element(a, "td", .{}, .{ztree.text("95")}),
            }),
        }),
    }));
    defer testing.allocator.free(md);
    try testing.expectEqualStrings(
        "| Name | Age | Score |\n" ++
            "| :--- | :---: | ---: |\n" ++
            "| Bob | 30 | 95 |\n",
        md,
    );
}

test "GFM table — style text-align is case-insensitive" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const md = try renderToString(try ztree.element(a, "table", .{}, .{
        try ztree.element(a, "thead", .{}, .{
            try ztree.element(a, "tr", .{}, .{
                try ztree.element(a, "th", .{ .style = "color: red; TEXT-ALIGN : Center" }, .{ztree.text("Name")}),
            }),
        }),
    }));
    defer testing.allocator.free(md);
    try testing.expectEqualStrings(
        "| Name |\n" ++
            "| :---: |\n",
        md,
    );
}

// -- inline elements --

test "bold, italic, strikethrough" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const md = try renderToString(try ztree.element(a, "p", .{}, .{
        try ztree.element(a, "strong", .{}, .{ztree.text("b")}),
        ztree.text(" "),
        try ztree.element(a, "em", .{}, .{ztree.text("i")}),
        ztree.text(" "),
        try ztree.element(a, "del", .{}, .{ztree.text("d")}),
    }));
    defer testing.allocator.free(md);
    try testing.expectEqualStrings("**b** *i* ~~d~~\n", md);
}

test "inline code — backtick escalation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const md = try renderToString(try ztree.element(arena.allocator(), "code", .{}, .{ztree.text("a`b")}));
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
    const md = try renderToString(try ztree.element(a, "a", .{ .href = "https://example.com", .title = "Example" }, .{ztree.text("click")}));
    defer testing.allocator.free(md);
    try testing.expectEqualStrings("[click](https://example.com \"Example\")", md);
}

test "image with title" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const md = try renderToString(try ztree.closedElement(a, "img", .{ .src = "photo.jpg", .alt = "A photo", .title = "My photo" }));
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
            try ztree.element(a, "li", .{}, .{ztree.text("item")}),
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
                try ztree.element(a, "p", .{}, .{ztree.text("quoted")}),
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
        try ztree.element(a, "h1", .{}, .{ztree.text("Title")}),
        try ztree.element(a, "p", .{}, .{
            ztree.text("A paragraph with "),
            try ztree.element(a, "strong", .{}, .{ztree.text("bold")}),
            ztree.text(" text."),
        }),
        try ztree.element(a, "pre", .{}, .{
            try ztree.element(a, "code", .{ .class = "language-zig" }, .{
                ztree.text("const x = 42;"),
            }),
        }),
        try ztree.element(a, "ul", .{}, .{
            try ztree.element(a, "li", .{}, .{ztree.text("one")}),
            try ztree.element(a, "li", .{}, .{ztree.text("two")}),
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
