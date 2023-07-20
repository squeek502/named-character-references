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

        var root = try arena.allocator().create(Node);
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
            if (self.number != 0) return;
            for (self.children) |maybe_child| {
                const child = maybe_child orelse continue;
                // A node's number is the sum of the
                // numbers of its immediate child nodes.
                child.calcNumbers();
                if (child.is_terminal) self.number += 1;
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
            var child = try arena.allocator().create(Node);
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
            const unchecked_node = self.unchecked_nodes.pop();
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
                    if (sibling.?.is_terminal) index += 1;
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
        try writer.print("    .{{ .char = .none, .end_of_word = false, .end_of_list = true, .number = {}, .child_index = 1 }},\n", .{self.root.number});

        var queue = std.ArrayList(*Node).init(self.allocator);
        defer queue.deinit();

        var child_indexes = std.AutoHashMap(*Node, u12).init(self.allocator);
        defer child_indexes.deinit();

        try child_indexes.ensureTotalCapacity(@intCast(self.edgeCount()));

        var first_available_index: u12 = self.root.numDirectChildren() + 1;
        first_available_index = try writeDafsaChildren(self.root, writer, &queue, &child_indexes, first_available_index);

        while (queue.items.len > 0) {
            // TODO: something with better time complexity
            const node = queue.orderedRemove(0);

            first_available_index = try writeDafsaChildren(node, writer, &queue, &child_indexes, first_available_index);
        }

        try writer.writeAll("};\n");
    }

    fn writeDafsaChildren(
        node: *Node,
        writer: anytype,
        queue: *std.ArrayList(*Node),
        child_indexes: *std.AutoHashMap(*Node, u12),
        first_available_index: u12,
    ) !u12 {
        var cur_available_index = first_available_index;
        const num_children = node.numDirectChildren();
        var child_i: u12 = 0;
        for (node.children, 0..) |maybe_child, c_usize| {
            const child = maybe_child orelse continue;
            const c: u8 = @intCast(c_usize);
            const field_name = [1]u8{c};
            const is_last_child = child_i == num_children - 1;

            if (!child_indexes.contains(child)) {
                const child_num_children = child.numDirectChildren();
                if (child_num_children > 0) {
                    child_indexes.putAssumeCapacityNoClobber(child, cur_available_index);
                    cur_available_index += child_num_children;
                }
                try queue.append(child);
            }

            try writer.print(
                "    .{{ .char = .{}, .end_of_word = {}, .end_of_list = {}, .number = {}, .child_index = {} }},\n",
                .{ std.zig.fmtId(&field_name), child.is_terminal, is_last_child, child.number, child_indexes.get(child) orelse 0 },
            );

            child_i += 1;
        }
        return cur_available_index;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var json_contents = try std.fs.cwd().readFileAlloc(allocator, "entities.json", std.math.maxInt(usize));
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

    const writer = std.io.getStdOut().writer();
    try builder.writeDafsa(writer);

    {
        const Codepoints = struct {
            first: u21,
            second: ?u21,
        };

        var index_to_codepoints = try allocator.alloc(Codepoints, parsed.value.object.count());
        defer allocator.free(index_to_codepoints);

        var it = parsed.value.object.iterator();
        while (it.next()) |entry| {
            const codepoints = entry.value_ptr.object.get("codepoints").?.array;
            const str = (entry.key_ptr.*)[1..];
            const index = builder.getUniqueIndex(str).?;

            const array_index = index - 1;
            index_to_codepoints[array_index] = .{
                .first = @intCast(codepoints.items[0].integer),
                .second = if (codepoints.items.len > 1) @intCast(codepoints.items[1].integer) else null,
            };
        }

        try writer.writeAll("pub const codepoints_lookup = [_]Codepoints {\n");
        for (index_to_codepoints) |codepoints| {
            if (codepoints.second == null) {
                try writer.print("    .{{ .first = '\\u{{{X}}}' }},\n", .{codepoints.first});
            } else {
                const second_name = switch (codepoints.second.?) {
                    '\u{0338}' => "combining_long_solidus_overlay",
                    '\u{20D2}' => "combining_long_vertical_line_overlay",
                    '\u{200A}' => "hair_space",
                    '\u{0333}' => "combining_double_low_line",
                    '\u{20E5}' => "combining_reverse_solidus_overlay",
                    '\u{FE00}' => "variation_selector_1",
                    '\u{006A}' => "latin_small_letter_j",
                    '\u{0331}' => "combining_macron_below",
                    else => unreachable,
                };

                try writer.print("    .{{ .first = '\\u{{{X}}}', .second = .{s} }},\n", .{ codepoints.first, second_name });
            }
        }
        try writer.writeAll("};\n");
    }
}

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
