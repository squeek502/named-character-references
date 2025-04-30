const std = @import("std");
const Allocator = std.mem.Allocator;

// Note: Not very much effort was put into minimizing memory use here, since the
// number of named character references is small enough for the memory usage
// during construction not to be a huge concern.
//
// Much of this implemenation is based on http://stevehanov.ca/blog/?id=115

const DafsaBuilder = struct {
    root: *Node,
    arena: std.heap.ArenaAllocator.State,
    allocator: Allocator,
    unchecked_nodes: std.ArrayListUnmanaged(UncheckedNode),
    minimized_nodes: std.HashMapUnmanaged(*Node, *Node, Node.DuplicateContext, std.hash_map.default_max_load_percentage),
    previous_word_buf: [64]u8 = undefined,
    previous_word: []u8 = &[_]u8{},

    const UncheckedNode = struct {
        parent: *Node,
        char: u8,
        child: *Node,
    };

    pub fn init(allocator: Allocator) !DafsaBuilder {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        const root = try arena.allocator().create(Node);
        root.* = .{};
        return DafsaBuilder{
            .root = root,
            .allocator = allocator,
            .arena = arena.state,
            .unchecked_nodes = .{},
            .minimized_nodes = .{},
        };
    }

    pub fn deinit(self: *DafsaBuilder) void {
        self.arena.promote(self.allocator).deinit();
        self.unchecked_nodes.deinit(self.allocator);
        self.minimized_nodes.deinit(self.allocator);
        self.* = undefined;
    }

    const Node = struct {
        children: [256]?*Node = [_]?*Node{null} ** 256,
        is_terminal: bool = false,
        number: u12 = 0,

        const DuplicateContext = struct {
            pub fn hash(ctx: @This(), key: *Node) u64 {
                _ = ctx;
                var hasher = std.hash.Wyhash.init(0);
                std.hash.autoHash(&hasher, key.children);
                std.hash.autoHash(&hasher, key.is_terminal);
                return hasher.final();
            }

            pub fn eql(ctx: @This(), a: *Node, b: *Node) bool {
                _ = ctx;
                return a.is_terminal == b.is_terminal and std.mem.eql(?*Node, &a.children, &b.children);
            }
        };

        pub fn calcNumbers(self: *Node) void {
            self.number = @intFromBool(self.is_terminal);
            for (self.children) |maybe_child| {
                const child = maybe_child orelse continue;
                // A node's number is the sum of the
                // numbers of its immediate child nodes.
                child.calcNumbers();
                self.number += child.number;
            }
        }

        pub fn numDirectChildren(self: *const Node) u8 {
            var num: u8 = 0;
            for (self.children) |child| {
                if (child != null) num += 1;
            }
            return num;
        }
    };

    pub fn insert(self: *DafsaBuilder, str: []const u8) !void {
        if (std.mem.order(u8, str, self.previous_word) == .lt) {
            @panic("insertion order must be sorted");
        }

        var common_prefix_len: usize = 0;
        for (0..@min(str.len, self.previous_word.len)) |i| {
            if (str[i] != self.previous_word[i]) break;
            common_prefix_len += 1;
        }

        try self.minimize(common_prefix_len);

        var node = if (self.unchecked_nodes.items.len == 0)
            self.root
        else
            self.unchecked_nodes.getLast().child;

        for (str[common_prefix_len..]) |c| {
            std.debug.assert(node.children[c] == null);

            var arena = self.arena.promote(self.allocator);
            const child = try arena.allocator().create(Node);
            self.arena = arena.state;

            child.* = .{};
            node.children[c] = child;
            try self.unchecked_nodes.append(self.allocator, .{
                .parent = node,
                .char = c,
                .child = child,
            });
            node = node.children[c].?;
        }
        node.is_terminal = true;

        self.previous_word = self.previous_word_buf[0..str.len];
        @memcpy(self.previous_word, str);
    }

    pub fn minimize(self: *DafsaBuilder, down_to: usize) !void {
        if (self.unchecked_nodes.items.len == 0) return;
        while (self.unchecked_nodes.items.len > down_to) {
            const unchecked_node = self.unchecked_nodes.pop().?;
            if (self.minimized_nodes.getPtr(unchecked_node.child)) |child| {
                unchecked_node.parent.children[unchecked_node.char] = child.*;
            } else {
                try self.minimized_nodes.put(self.allocator, unchecked_node.child, unchecked_node.child);
            }
        }
    }

    pub fn finish(self: *DafsaBuilder) !void {
        try self.minimize(0);
    }

    fn nodeCount(self: *const DafsaBuilder) usize {
        return self.minimized_nodes.count();
    }

    fn edgeCount(self: *const DafsaBuilder) usize {
        var count: usize = 0;
        var it = self.minimized_nodes.iterator();
        while (it.next()) |entry| {
            for (entry.key_ptr.*.children) |child| {
                if (child != null) count += 1;
            }
        }
        return count;
    }

    fn dafsaNodeCount(self: *const DafsaBuilder) usize {
        return self.edgeCount() + 1 + self.root.numDirectChildren();
    }

    fn contains(self: *const DafsaBuilder, str: []const u8) bool {
        var node = self.root;
        for (str) |c| {
            node = node.children[c] orelse return false;
        }
        return node.is_terminal;
    }

    fn calcNumbers(self: *const DafsaBuilder) void {
        self.root.calcNumbers();
    }

    fn getUniqueIndex(self: *const DafsaBuilder, str: []const u8) ?usize {
        var index: usize = 0;
        var node = self.root;

        for (str) |c| {
            const child = node.children[c] orelse return null;
            for (node.children, 0..) |sibling, sibling_c| {
                if (sibling == null) continue;
                if (sibling_c < c) {
                    index += sibling.?.number;
                }
            }
            node = child;
            if (node.is_terminal) index += 1;
        }

        return index;
    }

    fn writeDafsa(self: *const DafsaBuilder, writer: anytype) !void {
        try writer.writeAll("pub const dafsa = [_]Node {\n");

        // write root
        try writer.writeAll("    .{ .char = 0, .end_of_word = false, .number = 0, .child_index = 0, .children_len = 0 },\n");

        var queue = std.fifo.LinearFifo(*Node, .Dynamic).init(self.allocator);
        defer queue.deinit();

        var child_indexes = std.AutoHashMap(*Node, u12).init(self.allocator);
        defer child_indexes.deinit();

        try child_indexes.ensureTotalCapacity(@intCast(self.edgeCount()));

        var first_available_index: u12 = 1;
        first_available_index = try queueDafsaChildren(self.root, &queue, &child_indexes, first_available_index);

        while (queue.readItem()) |node| {
            first_available_index = try writeDafsaChildren(node, writer, &queue, &child_indexes, first_available_index);
        }

        try writer.writeAll("};\n");
    }

    fn queueDafsaChildren(
        node: *Node,
        queue: *std.fifo.LinearFifo(*Node, .Dynamic),
        child_indexes: *std.AutoHashMap(*Node, u12),
        first_available_index: u12,
    ) !u12 {
        var cur_available_index = first_available_index;
        for (node.children) |maybe_child| {
            const child = maybe_child orelse continue;
            if (!child_indexes.contains(child)) {
                const child_num_children = child.numDirectChildren();
                if (child_num_children > 0) {
                    child_indexes.putAssumeCapacityNoClobber(child, cur_available_index);
                    cur_available_index += child_num_children;
                }
                try queue.writeItem(child);
            }
        }
        return cur_available_index;
    }

    fn writeDafsaChildren(
        node: *Node,
        writer: anytype,
        queue: *std.fifo.LinearFifo(*Node, .Dynamic),
        child_indexes: *std.AutoHashMap(*Node, u12),
        first_available_index: u12,
    ) !u12 {
        var cur_available_index = first_available_index;
        var child_i: u12 = 0;
        var unique_index_tally: u12 = 0;
        for (node.children, 0..) |maybe_child, c_usize| {
            const child = maybe_child orelse continue;
            const c: u8 = @intCast(c_usize);
            const child_num_children = child.numDirectChildren();

            if (!child_indexes.contains(child)) {
                if (child_num_children > 0) {
                    child_indexes.putAssumeCapacityNoClobber(child, cur_available_index);
                    cur_available_index += child_num_children;
                }
                try queue.writeItem(child);
            }

            const number = unique_index_tally;
            try writer.print(
                "    .{{ .char = '{c}', .end_of_word = {}, .number = {}, .child_index = {}, .children_len = {} }},\n",
                .{ c, child.is_terminal, number, child_indexes.get(child) orelse 0, child_num_children },
            );

            unique_index_tally += child.number;
            child_i += 1;
        }
        return cur_available_index;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const json_contents = try std.fs.cwd().readFileAlloc(allocator, "entities.json", std.math.maxInt(usize));
    defer allocator.free(json_contents);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_contents, .{});
    defer parsed.deinit();

    var builder = try DafsaBuilder.init(allocator);
    defer builder.deinit();
    for (parsed.value.object.keys()) |str| {
        std.debug.assert(str[0] == '&');
        try builder.insert(str[1..]);
    }
    try builder.finish();
    builder.calcNumbers();

    // As a sanity check, confirm that the minimal perfect hashing doesn't
    // have any collisions
    {
        var index_set = std.AutoHashMap(usize, void).init(allocator);
        defer index_set.deinit();

        for (parsed.value.object.keys()) |str| {
            const index = builder.getUniqueIndex(str[1..]).?;
            const result = try index_set.getOrPut(index);
            if (result.found_existing) {
                std.debug.print("clobbered {}\n", .{index});
                return error.MinimalPerfectHashCollision;
            }
        }
    }

    const out_writer = std.io.getStdOut().writer();
    var buffered_out = std.io.bufferedWriter(out_writer);
    const writer = buffered_out.writer();

    {
        const num_codepoints = parsed.value.object.count();
        const packed_bytes_len = try std.math.divCeil(usize, @bitSizeOf(Codepoints) * num_codepoints, 8);
        const packed_bytes = try allocator.alloc(u8, packed_bytes_len);
        defer allocator.free(packed_bytes);
        @memset(packed_bytes, 0);
        const backing_int = @typeInfo(Codepoints).@"struct".backing_integer.?;

        var it = parsed.value.object.iterator();
        while (it.next()) |entry| {
            const codepoints = entry.value_ptr.object.get("codepoints").?.array;
            const str = (entry.key_ptr.*)[1..];
            const index = builder.getUniqueIndex(str).?;

            const array_index = index - 1;
            std.mem.writePackedInt(backing_int, packed_bytes, array_index * @bitSizeOf(backing_int), @bitCast(Codepoints{
                .first = @intCast(codepoints.items[0].integer),
                .second = if (codepoints.items.len > 1) SecondCodepoint.fromCodepoint(@intCast(codepoints.items[1].integer)) else .none,
            }), .little);
        }

        try writer.writeAll("pub const codepoints_lookup = struct {\n");
        try writer.print("    const bytes = \"{}\";\n", .{std.zig.fmtEscapes(packed_bytes)});
        try writer.writeAll(
            \\
            \\    pub fn get(index: u16) Codepoints {
            \\        const backing_int = @typeInfo(Codepoints).@"struct".backing_integer.?;
            \\        return @bitCast(std.mem.readPackedInt(backing_int, bytes, index * @bitSizeOf(backing_int), .little));
            \\    }
            \\
        );
        try writer.writeAll("};\n\n");
    }

    // First layer accel table
    {
        const num_children = builder.root.numDirectChildren();
        std.debug.assert(num_children == 52);

        try writer.writeAll("pub const first_layer = [_]FirstLayerNode {\n");
        var unique_index_tally: u12 = 0;
        var first_child_index: u10 = 1;
        for (0..128) |c_usize| {
            const c: u8 = @intCast(c_usize);
            const child = builder.root.children[c] orelse continue;
            std.debug.assert(std.ascii.isAlphabetic(c));

            const child_num_children = child.numDirectChildren();
            try writer.print("    .{{ .number = {}, .child_index = {}, .children_len = {} }},\n", .{ unique_index_tally, first_child_index, child_num_children });
            unique_index_tally += child.number;
            first_child_index += child_num_children;
        }
        try writer.writeAll("};\n\n");
    }

    try builder.writeDafsa(writer);
    try buffered_out.flush();
}

const Codepoints = packed struct(u21) {
    first: u17, // Largest value is U+1D56B
    second: SecondCodepoint = .none,
};

const SecondCodepoint = enum(u4) {
    none,
    combining_long_solidus_overlay, // U+0338
    combining_long_vertical_line_overlay, // U+20D2
    hair_space, // U+200A
    combining_double_low_line, // U+0333
    combining_reverse_solidus_overlay, // U+20E5
    variation_selector_1, // U+FE00
    latin_small_letter_j, // U+006A
    combining_macron_below, // U+0331

    pub fn fromCodepoint(codepoint: u21) SecondCodepoint {
        return switch (codepoint) {
            '\u{0338}' => .combining_long_solidus_overlay,
            '\u{20D2}' => .combining_long_vertical_line_overlay,
            '\u{200A}' => .hair_space,
            '\u{0333}' => .combining_double_low_line,
            '\u{20E5}' => .combining_reverse_solidus_overlay,
            '\u{FE00}' => .variation_selector_1,
            '\u{006A}' => .latin_small_letter_j,
            '\u{0331}' => .combining_macron_below,
            else => unreachable,
        };
    }
};

test {
    var builder = try DafsaBuilder.init(std.testing.allocator);
    defer builder.deinit();

    try builder.insert("hello");
    try builder.insert("jealous");
    try builder.insert("jello");

    try builder.finish();

    try std.testing.expect(builder.contains("hello"));
    try std.testing.expect(builder.contains("jello"));
    try std.testing.expect(builder.contains("jealous"));
    try std.testing.expect(!builder.contains("jeal"));
    try std.testing.expect(!builder.contains("jealousy"));
    try std.testing.expect(!builder.contains("jell"));
}
