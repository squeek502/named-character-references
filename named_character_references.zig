const std = @import("std");

pub const Matcher = struct {
    children_to_check: ChildrenToCheck = .init,
    last_matched_unique_index: u12 = 0,
    pending_unique_index: u12 = 0,
    /// This will be true if the last match ends with a semicolon
    ends_with_semicolon: bool = false,

    const ChildrenToCheck = union(enum) {
        init: void,
        second_layer: []const SecondLayerNode,
        dafsa: []const Node,
    };

    /// If `c` is the codepoint of a child of the current `node_index`, the `node_index`
    /// is updated to that child and the function returns `true`.
    /// Otherwise, the `node_index` is unchanged and the function returns false.
    pub fn codepoint(self: *Matcher, c: u21) bool {
        if (c > std.math.maxInt(u7)) return false;
        return self.ascii_char(@intCast(c));
    }

    /// If `c` is the character of a child of the current `node_index`, the `node_index`
    /// is updated to that child and the function returns `true`.
    /// Otherwise, the `node_index` is unchanged and the function returns false.
    pub fn char(self: *Matcher, c: u8) bool {
        if (c > std.math.maxInt(u7)) return false;
        return self.ascii_char(@intCast(c));
    }

    /// If `c` is the character of a child of the current `node_index`, the `node_index`
    /// is updated to that child and the function returns `true`.
    /// Otherwise, the `node_index` is unchanged and the function returns false.
    pub fn ascii_char(self: *Matcher, c: u7) bool {
        switch (self.children_to_check) {
            .init => {
                if (std.ascii.isAlphabetic(c)) {
                    const index: usize = if (c <= 'Z') c - 'A' else c - 'a' + 26;
                    const node = first_layer[index];
                    self.children_to_check = .{ .second_layer = second_layer[index * 52 ..][0..52] };
                    //self.overconsumed_code_points += 1;
                    self.pending_unique_index = @intCast(node.number);
                    return true;
                }
                return false;
            },
            .second_layer => |children| {
                if (std.ascii.isAlphabetic(c)) {
                    const index = if (c <= 'Z') c - 'A' else c - 'a' + 26;
                    const node = children[index];
                    if (node == SecondLayerNode.invalid) return false;
                    //self.overconsumed_code_points += 1;
                    self.pending_unique_index += node.number;
                    if (node.end_of_word) {
                        self.pending_unique_index += 1;
                        self.last_matched_unique_index = self.pending_unique_index;
                        self.ends_with_semicolon = c == ';';
                    }
                    self.children_to_check = .{ .dafsa = dafsa[node.child_index..][0..node.children_len] };
                    return true;
                }
                return false;
            },
            .dafsa => |children| {
                const matching_child_index = std.sort.binarySearch(
                    Node,
                    children,
                    c,
                    Node.searchOrder,
                ) orelse return false;
                const node = children[matching_child_index];
                self.pending_unique_index += node.number;
                if (node.end_of_word) {
                    self.pending_unique_index += 1;
                    self.last_matched_unique_index = self.pending_unique_index;
                    self.ends_with_semicolon = c == ';';
                }
                self.children_to_check.dafsa = dafsa[node.child_index..][0..node.children_len];
                return true;
            },
        }
    }

    /// Returns the `Codepoints` associated with the last match, if any.
    pub fn getCodepoints(self: Matcher) ?Codepoints {
        if (self.last_matched_unique_index == 0) return null;
        return codepoints_lookup.get(self.last_matched_unique_index - 1);
    }
};

test Matcher {
    var matcher = Matcher{};

    // 'n' can still match something
    try std.testing.expect(matcher.char('n'));
    //try std.testing.expect(!matcher.matched());

    // 'no' can still match something
    try std.testing.expect(matcher.char('o'));
    //try std.testing.expect(!matcher.matched());

    // 'not' matches fully
    try std.testing.expect(matcher.char('t'));
    //try std.testing.expect(matcher.matched());

    // 'not' still matches fully, since the node_index is not modified here
    try std.testing.expect(!matcher.char('!'));
    //try std.testing.expect(matcher.matched());
}

pub const Node = packed struct(u32) {
    /// The actual alphabet of characters used in the list of named character references only
    /// includes 61 unique characters ('1'...'8', ';', 'a'...'z', 'A'...'Z'), but we have
    /// bits to spare and encoding this as a `u8` allows us to avoid the need for converting
    /// between an `enum(u6)` containing only the alphabet and the actual `u8` character value.
    char: u7,
    /// Nodes are numbered with "an integer which gives the number of words that
    /// would be accepted by the automaton starting from that state." This numbering
    /// allows calculating "a one-to-one correspondence between the integers 1 to L
    /// (L is the number of words accepted by the automaton) and the words themselves."
    ///
    /// Essentially, this allows us to have a minimal perfect hashing scheme such that
    /// it's possible to store & lookup the codepoint transformations of each named character
    /// reference using a separate array.
    ///
    /// Empirically, the largest number in our DAFSA is 168, so all number values fit in a u8.
    number: u8,
    /// If true, this node is the end of a valid named character reference.
    /// Note: This does not necessarily mean that this node does not have child nodes.
    end_of_word: bool,
    /// Number of children
    children_len: u4,
    /// Index of the first child of this node.
    /// There are 3872 nodes in our DAFSA, so all indexes can fit in a u12.
    child_index: u12,

    pub fn searchOrder(context: u7, node: Node) std.math.Order {
        return std.math.order(context, node.char);
    }
};

const FirstLayerNode = packed struct {
    number: u16, // could be u12
};

const SecondLayerNode = packed struct {
    number: u8,
    child_index: u10,
    children_len: u4,
    end_of_word: bool,

    // This is techinically a possible real node, but we know this particular combination
    // of values doesn't exist in the second layer.
    const invalid = SecondLayerNode{
        .number = 0,
        .child_index = 0,
        .children_len = 0,
        .end_of_word = false,
    };
};

/// There are only 8 possible codepoints that appear as the second codepoint of a
/// named character reference (plus the most common option of no second codepoint).
/// The 8 possible codepoints can be encoded as a u3, but we use u4 to encode the
/// 'no second codepoint' option in this enum as well.
pub const SecondCodepoint = enum(u4) {
    none,
    combining_long_solidus_overlay, // U+0338
    combining_long_vertical_line_overlay, // U+20D2
    hair_space, // U+200A
    combining_double_low_line, // U+0333
    combining_reverse_solidus_overlay, // U+20E5
    variation_selector_1, // U+FE00
    latin_small_letter_j, // U+006A
    combining_macron_below, // U+0331

    pub fn asInt(self: SecondCodepoint) ?u16 {
        return switch (self) {
            .none => null,
            .combining_long_solidus_overlay => '\u{0338}',
            .combining_long_vertical_line_overlay => '\u{20D2}',
            .hair_space => '\u{200A}',
            .combining_double_low_line => '\u{0333}',
            .combining_reverse_solidus_overlay => '\u{20E5}',
            .variation_selector_1 => '\u{FE00}',
            .latin_small_letter_j => '\u{006A}',
            .combining_macron_below => '\u{0331}',
        };
    }
};

pub const Codepoints = packed struct(u21) {
    first: u17, // Largest value is U+1D56B
    second: SecondCodepoint = .none,
};

/// Without using a packed array, [2231]Codepoints would take up 8,924 bytes since @alignOf(Codepoints) is 4,
/// so by using a packed array we save 3,067 bytes. The increased runtime cost of accessing elements in the packed
/// array should not cause any issues since it is only used after we *know* we have a match, so exactly one element
/// in the `codepoints_lookup` will be accessed per named character reference.
///
/// To avoid the comptime cost of packing 2231 `u21`s into [5857]u8, we have done that packing once
/// and then dumped out the [5857]u8 as a string literal, which is what's provided to the bytes
/// field here.
///
/// Because we are providing the [5857]u8 directly, its endianness is fixed (and happens to be little-endian).
/// So, we need explicitly read with little endianness to make this work properly regardless of native endianness.
pub const codepoints_lookup = struct {
    const bytes = "\xc6\x00\xc0\x18\x00\x98\x00\x00\x13\x00\x10\x0c\x00\x82\x01\x80@\x00\x10\x06\x00\xc2\x00\x00\x82\x00\x10T\x07`\x00\x00\x0c\x00\"\x07\x00@\x00\x98R\x01\x04\x01\x00\xa7:\x84\x81\x80b\x00P\x0c\x008\xa9\x03\x95\x08\x18\x06\x00\xc3\x00\x80\x18\x00\x10\x03\x00\x0b\x11p\xae\x02\x0cF@\x04\x01\xa8\x11\x01,!@r\x00\x14T\x87\x9c\xea\x80-\x00XB\x80\x93\x088!\x00\xa9\x00 \x15\x00\x18\x04\x00i\x11P\x14\x02ZB\x00C\x008\x06\x00\xc7\x00\x00!\x00\xc0\x88\x00\x85\x00\x80\x0b\x00n\x01@K\x088\x1d\x00\x99\"\xc0R\x04T\x8a\x80K\x11 #\x02:@@\x06\x08\xb8\x11\x01t* L\x04\xbc\x88\x00\x17\x11 \x10\x02 D\xc0\x8c\x08xQ\x01\x9e\xd4aZ\x044\x89\x80\xa2\x10\x10\x91\x02\x04\x08@\x01\x01x \x00!  4\x04\x90\xab\x00\x87\x00@A\x00\x0eD\x00\xe5\x008\xa8\x0e\xb4\x00 [\x00t\x0b\x000\x00\xc0-\x00\x88E\x80Q\x08\xd8\xa9\x0e\xa8\x00\x80\x1b\x04@\x89\x80\x17\x11\x80\n\x00\xa6C\x00t\x08\xa0\x0e\x01\xe4*\x00\xff\x04\xe8\x9f\x80\xfc\x13 \x1d\x02PE@t\x08\xa8\x0e\x01%\"`2\x04L\xa4\x80\xfa\x10\x101\x00\xa0R\x80W\n\xe8\r\x01V)\xe0+\x05\x04\x87\x80\xab\x14@*\x02NC\xc0t\x08\xf8\xa4\x0e\x10\x01@)\x00@\x03\x00h\x00\x90\x0c\x00\x92\x01\x80F\x00P\x06\x00\xca\x00\xa0\x85\x00X\x04\x00\x84\xea\x80\x0c\x00\x90\x01\x00\x82\x08\x90\x08\x00\xfb%`\xb5\x04`\x04\x00\x9e\xeaP9\x00\xeaT\x80\x90\x08`\x0e\x010!`N\x05\\\x0e\x80e\x00\xb0\x0c\x00\x06D\xc0Q\x08 !\x00\t\xd5\x81\xbf\x04\xa8\x96\x80\x9e\xea\x00 \x02bB@L\x08\x18 \x00>\x00\xc0\x07\x00L\x0e\x00\xee\x01\xe0\x11\x00D\x02\x00G\x00\x98 \x00 \x01@\xa1:d\x8b\x00\x9f\xeaP&\x02\xb6E\xc0\x99\x08\x10U\x01w\"\xc0O\x05\xcc\x89\x00Q\xea\xb0&\x02T\x08\xc0\xb1\x00\xf0\x02\x00$\x01\x80!\x04,\x84\x80\x86\x10\x00P\x02\x16B\x80I\x00p\x12\x01O\"\xa0\x82\x00\xc8\x04\x80\x00\x02\xd0\x0c\x00\x9a\x01\x803\x00p\x06\x00\x18\x04\x00&\x00D\x84\x00f\x00\xc0\x0c\x00\"B\x80J\x00@\n\x01\xd2!\x80E\x04\xac\x88\x00a\x110\x06\x02\xc4@\x80K\x00\x00\xaa\x0e\x99\x03\x00\"\x04\xa0\x04\x00\x03\x02\xf0\x0c\x00\x9e\x01\x00M\x00\xc8 \x00\r\xd5!\xa8:\x94R\x07\x04\x02@@\x00J\x08\x00\x03\x01\xd0\x1c\x006\x01@\x83\x008T\x07\xa1\xea`J\x1d\x12\x08\x00\x0f\x00\xe0\x01\x009\x01`s\x00\xa8\x9f\x00\x89\x10\xe0\x19\x02z\x02\xc0N\x00\xd8 \x00\xe8'\x002\x04\x90\x87\x00\xe3\x10\x800\x02\xccO@X\n\x18\x0e\x01Y)@a\x04P\x86\x00\xa7\x140*\x02HC\x80V\n\x90\x15\x01\xcf)\x80V\x04D\xa5\x00\xb0\x14\xf0\x1b\x02\xb0R\x00o\x08\x90J\x01\xd0!\x80:\x04h\x8b\x003\x11`'\x02BU@\x9f\n\x90\x13\x01\x0f\xd5\x01[\x04h\x87\x80\x9f\x00P\x7f\x02\xeeO\x80\xfd\t\xc0?\x01\xfa' \xff\x04\x0cU\x87\xcc\x10\x80\x19\x02$B\x00l\x08\x08\n\x00j\"\xa0 \x05p\x10\x80/\x100\x13\x02 \xaa\xc3\x84\x08 \xaa\x0e3!\x80s\x00(\x10\x80\xa1\x00p\x14\x00\x8a\x02@\x07\x01X\x00\x01\x0b `\x01\x04,\x80\x805\x11\xa0&\x02\x14\x00@Du\x00\x03\x01\xa0\x00\xa0\"\x04\xb0\xab\x001\x11\xd0&\x02LD@\x82\x08\x00\x13\x01B\"\x82@\x04\xbc\x89\x808\x11p&\"\xd6DD\x9e\x08\xf0S\x11u\"\xc0ID<\x89\x08u\x11\xf0\x9c\"\xd8E\x80\x9b\x08\x80\x13\x01x\"@MD\xf4\xa9\x08:\x11 \xaa\"BU\x04\xa0\x08xU\x11\xe0\"\x80A\x04\xac\x8b\x00\xe8\x14\xd1.\x02\x1eE\x84\xb8\x08\x80\x14\x11\xe3\"@P\x84 \x8a\x80@\x11\x00\xab\"\xc2E\xc0\x9f\x88\x18\x14!\x89\" H\x04\x10\x89\x80#\x11\x90$\x02HD@*u\x88\x06\x00\xd1\x00\xa0s\x00H\x05\x80i\x000\r\x00\xa8\x01\x005\x00\xf0 \x00P\x01@\xa2:H\x03\x00i\x00\xc0\x14\x00R\x07\xc0\xe7\x000\xaa\x0e\x1c \x00\x03\x04P\xa9\x00U\xea\x80\r\x00\xb0\x01@5\x00\xa8\x06\x007*\xc0\x1a\x00X\x03\x00\x1f\x10\xe0=\x02hG\x00\xf7\x08\x10\x10\x01\x1f\x04`\xa2:\x98\x0e\x00\xd0\x01\x10\x0b\x00\x18B@F\x08\xd8U\x01z\"\xe0U\x05\xf0\x89\x00?\x110\x03\x02\x1eD\xc0\x8d\x08\xe8\x10\x01\xab\xd4\x01u\x00\x88\x00\x00\x11\x00@Q\x1d4B\x00+u\x80H\x01\xae\x00\xc0\x15\x00P\x05\x80\xf5\x13\x00\x1a\x02,R\x00V\x00\xb0\n\x00 \x04\x80#\x04,\x88\x80\xe5\x10\xf0\x96\x028B@\xe8\x00H?\x01\x92!\xa0<\x04\x10\x87\x80\x84\x11p~\x02\xbaR\x80p\x08\xa8J\x01\x0b#@T\x04\x98\x86\x80\xad\x140+\x02\xa0S@\xad\x08xJ\x01\\)\xc07\x04P\xa5\x00\xe0\x100\x95\x02\xa4C@G\x08\x80K\x01\xdb!`#\x04\xc4\x86\x00\xfa\x14\x90B\x00P\x08\x00\x0b\x01\xd0\n\x00\xbc*\x00,\x00x\x05\x00\xae\x00\x10B\x00,\xaa\xc3d\x08\x80\x0c\x01\x92! 2\x04\x8c\x0e\x00\x0c\x11\xa0T\x1d4D@h\t\x98\x14\x01\x8f\" R\x04@\x8a\x00I\x11@)\x02\\\xa9\x83\xb1\x08\x80\x16\x01\xd0\"\xc0P\x04\xec\x89\x00X\x15\xd0'\x02\xfeD\xc0\x82\x08\x88\x10\x01\xd1\"`P\x04\x1c\x8a\x80h\x11\xe0\r\x00\xbc\x01\x80H\x08X \x00&\x04 \x01\x00\x90\x0e\x00\xb2\x00 \x16\x00D\x08\xc0Eu\xa0\x11\x01\x98\x03\xe0\x0b\xc4$\x80\x00\x1e\x110$\x02\x8aD\x00\x92\x08X\xaa\x0e\xdb \xe0\x95:\x98\x05\x00m\x00\xa0\r\x00>C@R\np \x00l\x01`\x1b\x00l\x03\x80\x11\x02\x00\x17\x000\xaaC6\x00\xc8\x06\x00j\x01\xe0\x0b\x00|\x8f\x80\xda\x11\xd0=\x02\x86E\x80\xa3\x08\x90\x0b\x00L\xd5!2\x04H\xa4\x80\xe2\x10P\x19\x02\xdcR@\xa9\x08(\r\x01\xd1!\xa0:\x04X\x86\x80\xcb\x10 =\x00J\x07\x80[\x00\x80\xa5\x0eh\x01\x80\x1b\x00p\x03\x80U\x11\xb0\xae\x02$\x08@\xaa\x080W\x01\xc1\"\xc0\x02\x04X\x80\x80\x11\x11\xc0\x07\x00\xb0N\x00\x90\x08P\x00\x01\x19\xd5\xa1\xa9:\xc4R\x07U\x11@\x17\x00\x80E\x80Fup\xaa\x0e\xb2\xd4a\xa3:x\x0e\x80\xa7\xea0K\x1d^\x08\xc0\x01\x01p!\x00\xdd\x00\xa0\x1b\x00\xd8\x05\x80\x15\x02\xc0Q\x1d\xa0\xaa\x03-u\xc0\x0b\x00\x16\x04 /\x00\xf4\x05\x80\x0b\x02\xb0\x17\x00\x16@\x80\xe5\x00@\t\x01$!\xa0\x96:\x84\x03\x80p\x000\x10\x00|D\x80\x8f\x08\xfa\x11\x01\xe2\x00@\x1c\x00\xd0\x02\x00Z\x00\x00C\x00\xcc\x01\x809\x00\x08\x03\x01\x1e\xd5\x01\x1c\x00\x80\x03\x80\x9a\x10P\x13\x02b\x07@@\x00\xf8Q\x01&\x00\xc0\x04\x00\x9c\x88\x80*\x15\xc0\xa5\x02\xb0T\x80\x96\n\x00\x11\x01\xa4)\x00D\x04\x84\x88\x00\xd4\x14\x90\x9a\x02TS\xc0j\n`M\x01\xad)\xc05\x05\xbc\xa6\x80\x0f\x11\xe0+\x02:S\x80\x88\x08(\x06\x00|#\xa0 \x00HU\x07$\x11\x00\xa7\x02\xdeT\x80\x92\x08X\x12\x01'\x00\x00I\x04(\x89\x80r\x00P\x0e\x00l\xa9\x83\n\x00@\x12\x01M\"`\x1c\x00\x8c\x03\x00r\x00@\x0e\x00fD@\x84\nhW\x01L\"\xc0~\x00\xd4\x80\x80\x1e\x11\xd0,\x02zE@\xc1\x08(\x18\x01\xb5#\xc0v\x040\x89\x80\x18\x02\xe0\x01\x02jD@\x8d\x08\x80M\x01\xf6\x03\x80%\x04\xc8\x0e\x00\x9b\x10\xc0&\x02>\xaa\x83\xb0\x08x/\x01\xc3\"\x00@\x05\x04\xa8\x00\x01\x15`\xa0\x02\nL@o\t\x98-\x01\x04* X\x04\x00\x8b\x80\x86\x14\xb0\x9e\x02TK\x00m\t\xf0-\x01\xc2%\x00\xb7\x04\x8c\x90\x00\xc9\x12\x10Y\x02&K\x00b\t\xe8\x01Pa\"\nb\x04LU\x87R\x11P*\x02\x90E\xc0U\t\xa0*\x01V%`\xaa\x04@\x95\x00\xb3\x12\x90V\x02\xc8J\xc0Y\t\xe8*\x01Z%\x80\xab\x04d\x95\x80\xa8\x12\xc0V\x02\xc6J\x00X\tX+\x01b%\xe0\xab\x04$\xa7\x80\xaa\x12 U\x02 J\x00C\t\x00(\x01e%\x00\xad\x04\xb0\x94\x00\x9a\x12\xf0)\x02<E\x00\xa8\x08\xd8*\x01X%\x00\xa3\x04P\x94\x00\x81\x12\xa0V\x02\xc2J\x80W\t\xe0)\x01$%\x80\xa3\x04\xd4\x80\x00l\x01`\n\x00L\x01\xc0-ux\x02\x01=\"\xa0Y\x04p\x01\x80\xe2\x14\x80|\x02D@\x80\x08\x08p\x12\x01\xae*\xe0I\x04<\x89\x80\x83\x00\x90\"\x02\x88T@\x92\nXR\x01G*\x00H\x05\xa4\x88\xb0 \x10p,\x00\x9aT@C\x008\x07\x00\xe7\x00 !\x000\xa9\x00(\x15\xb0\x10\x00p\x01\x00.\x00\x90M\x01\xa2\x00@\x14\x00\xdc\x02\x00\x90\xeapD\x00&N\xc0\xc4\t8\x1e\x00\xcb%`8\x05\x18\x0b\x80+\x11\xa0\x1b\x02vC\x80+\x00@&\x01\x9b\"@S\x04t\x8a\x80+\x11\x00\xa1\x02\xdeU\x80p\n\x183\x01c&@\x07\x00P\x89\x00*\x11\xc0\x02\x00\x80\x00@\x80\x08\xc0\x10\x01\x01\"@ \x04\x14\x89\x806\x15\xe0\"\x02\xa8\xaa\x03\x84\x08H\x05\x00\xa9\x00\xe0\"\x04\xd4\x86\x80\x8b\x13\x80K\x1d\x9eU@\xb4\n\x80V\x01\xd2*\xe0]\x04\xe0\xa4\x80\x9a\x14\xe0-\x02\xbeE\x80m\x08\xe8I\x01*\"\x00I\x05\x18\xa9\x00%\x15\xd0(\x02\x8aT\x80\x8a\x08\xbb\r\x01<)\xc0[\x04|\x8b\x00g\x11\xf0,\x02H\x01\x00)\x00\xb0\r\x01\xb7!\xc0Y\x04<\x8b\x00\x19\x11\x10#\x02ZF\xc0t\x08(K\x01  \x00'\x04L\x86\x00\x08\x100*\x02\x1eR@\xb7\x00x\x08\x004\x04\xc0(\x04\x84\x80\x00\xe5\x10p\xa7\x02`\x01\x00,\x00\xa0\x1d\x00\xb1)\xe0/\x05\x84T\x87\xe1\x10 \x1c\x02\x88E\x00\xb1\x0803\x01f&\x00\x15\x00t\x0f\x00y\x11p\x0f\x00\xee\x01\xc0=\x008\x16\x01\xc7\"@\x8a\x00x\x8c\x80\x86\x11@\x02\x00\xaa\xaaC\xb6\x00\x80\x12\x01Q\"\x00G\x04P\x88\x80P\x11`0\x02&C\x80r\x08\x18\x0e\x01\xc2!\x00\"\x05|\x8c\x00\x86\x11\x90K\x1d\xaa\x08\x80}\n\x88\x08\x00\xf1\"\xe0\xb7\x04\xf8\x96\x80\xfa\x10\xf0\x96\x02LS\xc0\x17\x01\xf8?\x01w* J\x04\xa4\x03\x80t\x00\xe0\xa6\x026\x02\x80\x95\x08P\x07\x00\xea\x00\xa0J\x044\x11\x80\x8b\x00p\x14\x02\xa4D\x80Hu\xd0T\x01\xe8\x00\x00\x1d\x00X\xaa\x00L\x15\x90\xa9\x02\xceG\xc0D\x08\xa8T\x01\x97*`\"\x00\x14\x88\x80\x02\x11P \x02\x08@@\x01\x08\x18\x00\x01K\x01@\x00\x04d\x04\x00\xab\xeaP-\x02\xc6S@\x9c\n\xa8\x1d\x00\xb5\x03\xa0~\x00X\x89\x80*\x11 $\x02,U@\xa5\n\xe8\x01\x00_\" L\x04\xe0\xa9\x80\xf2\x140%\x02\xe2R\xc0K\x08\x80\x12\x01B\"\xe0v\x00\xc0\x03\x00x\x00\xb0\x0e\x00\xd6\x01\x00+\x08\x08\x01\x00\x03\"\x00&\x04\x1c\x85\x00)\x11@D\x00\x80L\xc0\xc0>\x00\xd8\x07\x04\xfb`\xa4:\x04\xec\x033\x00\xd7f\x02\x04\xf6Al\t\x90\x0c\x00W\xd5\x01@\x04P\x8b\x80l\x15\xd0\xa0\x02z\x01@/\x00\x98\n\x01\xbc\x00\x80\x17\x00T\x85\x80\xac\x10\xb0\x15\x02\xa8B\x80U\x08\xf0\x05\x00\xbe\x00\xe0*\x04p\x85\x00\xac\x10\xa0\x15\x02\xbaB\x80W\x08 \x02\x01\"#`\x97:\x9c\x89\x00F\x15P\x1f\x00f\x07@\xf7\x000T\x01\x1f\x01\xa0#\x00\xcc\x10\x80\x90\x00P&\x02\xb6E@\x99\x088\x13\x01~*\xc0O\x05\xa4\xaa\x00@\x15 \xa8\x02\x08U\xc0\xb6\x08\xa3T\x01$\xd5aM\x04d\x8b\x80\x9b\x100E\x00\xeeD\x80\xa4\n(U\x01\xa4* M\x04(\xaa\x00E\x15\x80\xa8\x02\x10U@\x9a\x088\x17\x01X\xd5\x01\x0c\x00(\x84\x809\x11\xe0\xa8\x02 U\x80\x0f\x00\xf0\x01\x00\xa7*@O\x05\\\x8b\x80\xca\x14\xc0\xa7\x02\x0cU\x00^\n\xb8\x16\x01\xdb\"\x80Q\x05\xdc\x89\x809\x11\x90&\xc2\xd2D\x18u\x08P\x00\x01\xbd\x00`!\x04(\x11\x00\xca\x10\x80\x94\x02ZC\xc0C\x08(\t\x00e&\xa0\xcc\x04\x98\x80\x80\\\x11PR\x1dJR\x80I\n\xf8\x0f\x01;\" 5\x04\xa8\x86\x80\xac\xeaP\x01\x02z\xa9\xc3C\x088\t\x00C \x00\x02\x04\xb4\x03\x80v\x000\x06\x02\xdc\x01\x80;\x00\xc0!\x005\x04 \x14\x00\x84\x02\x00\xea\x10`R\x1d\xd8\x01\x00;\x00@\n\x01\x0c*\xa0E\x04p\xa7\x80\x94\x100\x13\x00V\x02@D\x08\x80\x08\x01\x11! &\x00\xdc\x8a\x80\xda\x00\x80 \x02\nB\x80\x87\x08\xe8N\x011\x01`E\x04\xe8\x8a\x00\x92\x10\xa0+\x02.T\x00\x8f\n\x88\"\x00/\x01@\xab:\xe4\x0e\x00\x1e\x15\xf0\x0b\x00~\x01\x80/u@\x10\x01\xf9\"\xa0^\x04\xd0\x8b\x80y\x11\x80 \x02\xc4@@J\x00\xb0\"\x00\xef\x00\xe0\x1d\x00\xd4\x04\x80\x1c\x02pR\x1dn\x04\xc0Vu\xf8\xa5\x0eX\x04\x80\x8a\x00\xe8\x0e\x00\xf8\x01p\x13\x00t\x08\x00Ju\xc0\t\x00E\x04\x80\x8b\x00pU\x07`\xea\xa0\x1d\x02\xa0C\xc0F\npH\x01f\"`Q\x05\x88\xa5\x00\x9d\x00@\x9b\x02$B\xc0\xee\x00@?\x01\x91)\x00\xfd\x04\x14\xaa\x80U\x00\xb0\n\x00 C\x00y\x08\xf8H\x01\x1d) 5\x04\xac\x86\x80\x9c\x140\x97\x02DC\xc0\xaa\n\xc8H\x01\xad*\xa0U\x851\xa4\x00\xb9\x13\xb0\x07\x00\xb6\x00\xc0b\nxL\x01\x8d)\xc0'\x00\xf0\x04\x00\x84\x11\xb0\x07\x00v\x08\x80M\n\xe0\x00\x01\x1e \xe0,\x05,\xa5\x00\xd9\x10@&\x02 C\x80h\x08\xe8\r\x01\xbc!\xe08\x04P\x86\x00\xe3\x10\xb0\x1c\x02ZC\xc0\xb2\x08\xd0\x16\x01d\"\xc0L\x04\xf4\xa9\x80>\x15\x80\xaa\x02\xfeT@\xa0\n\x18T\x01\xda\"lR\x05\x14\xaa\x00k\x11\xa0-\x02\x16U\x80\x9d\x08\x90\x13\x01|)@a\x04\xa4T\x07;\x11\x10\xa9\x02zC\x00o\x08PK\x01\x84% \x8b\x00\xa8\x89\x80\xe3\x10\xe01\x02\xd6R\x80~\t\x00\n\x00\xb0#\x00v\x04\xa0\x89\x80D\x15\x90\xa8\x02\x0eU\xc0\xa1\n@\x13\x01\xe6\"\x80\xfd\x04\xf4\x87\x00\xf3\x13P\x7f\x02\xeeO\x00\xff\t\xb0?\x01\xab!\x805\x04\x14\xa6\x80\xae\xea\xd0\xa2\x02hT\xc0\x85\x08\xf8\x02\x00\xca%@\xb9\x04\xac\xa7\x00\x14\x000\x99\x02\x8cC\xc0\xc7\x08X\x0e\x01m)\xc0\x01\x04\xfc\x8a\x80\x1c\x10\x10L\x1d`C\x80\x9c\x08hT\x01\x8f*`\x0b\x00`\x80\x00\r\x10 \x14\x00x\x00\x00\x0f\x000U\x01y*\xc0Z\x04,\x8b\x80d\x11`\x97\x02\xf6T\x80e\n\x18.\x01\xb4\"@\xb8\x04(\xa5\x00\xb3\x14\x80&\xc2\xd0D\x98\x8e\x08x\x05\x00\xaf\x00@\xc8\x04\x80\x9c\x00\x90\x13`\x1a\x02LC\xc0i\x08 \r\x01\xa5!\xc0\xb5\x04\xa4\xa8\x00\x1e\x02@\x01\x02BD\x80Ju8\t\x01\xb5\x00\xa0\x16\x00\x8c\x88\x00\x15\x00\x00\xaf\x02n\x01\xc0-\x00\x90\x10\x01\x9f\"\x00G\x04\xa8\xa8\x80m\x15`\x02\x02&D\xc0\xa9\x08\xf0\xaa\x0e\x13\"@\x98:\xf8\x88\x00\xde\x01\x80+\x02pE@\xb6\x88X\x13!k\"\xa29\x048\x87\x00l\x11\xa1&B\xd4D\xc4s\x08x\x15\x01\xae\"\xe0@\x04\x10\x05\x00\x10\x11\x92$\x02\xe0T\xc4\x92\x88H\n\x00I\"\xc0\xcd\x04\xb8\x99\x80\x8a\x10\x00\n\x00@\x01\x80\x93\x88x\x12\x11C*\x00)\x00\x18\x05\x80#\x11\xd0\xa6\"\x84T@\x0f\x01\x98\x00\x01`\"\xe0:\x04\x90\xa4\x80\xcb\x10p\x19\x02\xa0D\x84\x98\x08@I\x01B\"\x82@\x04\x10\x88\x80\x95\xeap&\"\xe2D@\x9c\x088\x13\x11~*\xc2OE\xd4\x89\x807\x11\xf0&\x02\x9cC\x80k\x08\x90W\x01\x0b\"\x80_\x04\xe8\x8b\x80\x05\x11\xa0E\x00\x9aC\x80\x99\x88\xd0\x0c\x01% \x00N\x04h\x86\x00\xd7\x10\x00'\x02\xccDD\x9f\x8a\xe8S\x11n\"\x80N\x04\xb8\x89\x00u\x11\xc0.\x02HD\xc0Wu`\x05\x00\xac\x00 A\x04\xe4\x8b\x88z\x11\x91 \x02\xeeE\x80\xbd\x08`\x10\x01\x0c\"\xc0_\x04\xf4\x8b\x00\x13\x11`\"\x02\xfaU\x94\x80\x88\xa0P\x01\x80\"\x00\\\x04\xbc\xaa\x08@\x11\xf0\xaa\"\x9eC\xc0f\x08\x98I\x11\x9d!b3\x04\xac\x8b\x80v\x11\x10(\x02\xc2E\x00\xac\x8a\x18\xa6\x0e$\"\xc0D\x04\x04\x89\x00\"\x11@$\x02HD\x80\x89\x08\x10\x17\x01\xe3\"\x80P\x04\x14\xab\x08D\x11 (B\x10E@\xb1\x8a\x08\x14\x01\xb0*\xa2P\x04\x18\xab\x88D\x110(B\x12E\x80\xb1\x8a\xc8\x13\x01\xf1\x00 \x1e\x00\xe0\x89\x00u\x11\xc0.\x02\xd6E@\xbb\x08\xe8\x1d\x00#\x00\xc0\"\x04\x1c\x80\x80V\x11@\x90\x02\x9aD\x08\xab\x08(\x13!>\x00\xc4;\x05\x08\xa4\x002\x11\xc2\x03@hE\xc8@\n\xa8\x15!<\"\xc4:\x04\x8c\xa4\x00\xcb\x10`\x19\x02NR\x002\t\x98\x07\x00\xf3\x00`S\x04h\x8a\x00z\x00@\x0f\x00|\x08@\xa7\x08\x88\n\x008* S\x04\xf0\xa6\x80\xa9\x00\xf0\x9b\x02X\xaa\xc3\xb6\x00\x90\x07\x00\xf2\x00 8\x05\xd4\xa6\x80\xd4\x01\xe0\"\x02tC\x80o\n\xd8M\x01> \x008\x054\x05\x80\xe4\x01\xf0;\x00lS\x80\xa5\x08\x00\xab\x0e\xb7) 7\x05T\x8a\x00\x14\x11\xb0\x1b\x02\xbaT\x00M\x08\xa0\t\x01\xaa\x00@\x15\x00\xe8\x02\x00]\x00`+\x02\xacT\xc0\x95\n\xd8R\x014!\x00\x1f\x00\xe0\x03\x00L\x11P\x0f\x00\xea\x01\xc0\xa5\x08\xb0Q\x01\xf6\x00\xc0\x1e\x00\xf4\x8c\x80\x12\x11`\x0b\x00l\x01@\x89\x08\x98W\x01\xfd*@@\x04\xfc\x10\x80\x12\x00\xe0\x02\x00`@@\xa9\x08\x88\x01\x01-\xd5\xc1x\x00T\x0f\x80\x99\x10\xe0`\x02\x80\x07\x00\xb5\x08\xb0\x1e\x00\x0f!\xc0!\x04<\x84\x80\x15\x000\xa2\x02<E\x80\x88\n\xa0\x10\x01%*@N\x05\xc4\x02\x80X\x00`\xa2\x02NT@,\x00\xa8P\x01a\xd5a\x14\x00\x8c\x02\x00=\x110\xab\x02nU\x00\x9f\x08xU\x01z\"\xe0V\x05\xf0\x89\x80W\x15\x90\xab\x02jU\x00\xba\x08\xf0\x13\x012  #\x04\xd4\xaa\x80\\\x15\x80.\x02\x1eD\x80\xcb\x08\x90\x18\x01\x13#\xa0C\x04t\x88\x00?\x11\x00+\x02\x8a\xa9\x03\xf2\x00@\x00\x01.\xd5\x81A\x05\x88U\x87+\x10`L\x1d\x1aB\x80\x85\n\xf8\x01\x00_\"@\x04\x00\x88\x00\x80\xed\x10 \x1d\x028R\xc0C\n K\x01=\"\xb0*\x00h\x88\x80\xd9\x14\x90~\x02$S@i\nH?\x01\xbb\x00`\x17\x00H\x86\x80\xba\x14P\x1e\x02@R\xc0L\n\xf0H\x01\xaa!\x805\x04\x14\xa5\x00\xba\x140\x1a\x02:C\x80F\n\xb0\x11\x01\x1a!\xa0!\x05\xcc\x9d\x80>\x00\xd0\x05\x00\x18S\x80c\n\x80L\x01Y\x01\xe0*\x00$\x8c\x80>\x00\x00D\x00nR@Z\n\xe8\x00\x01\x1d `6\x04p\x84\x80\x8d\x10\xc0\x11\x02:B@k\tp\x05\x00\xae\x00\xa0/\x05,\x8c\x80\x97\xea\x10\x1c\x02\x80C\x00[\n\x08\x1e\x00\xf1\x03@2\x04\x8c\x86\x80\xe0\x10\x00\x1c\x02\x88C\x00s\x08H\x0e\x01\x9d!\x80Y\x04h\x0b\x80)\x11@\x1c\x02\x98C\xc0\x03\x08\x88\x1d\x01\xb1#\xc0]\x05\xb4\x9f\x00\xff\x10p~\x02\x0cS\xc0XupQ\x015* \x05\x00P\xa6\x00\t\x15\x90\x1c\x02t@\xc01u\x88\r\x01]\x00 \x03\x04d\x80\x00f\x11\xa0,\x02rK@\xad\x08\xc0-\x01\xce)\x00-\x05x\x84\x80\xad\x00\xa0\x01\x02\xf6D\x00\xad\n\xc0U\x01a\x01\xa0O\x04\xc0\xaa\x80\xaf\x00\xd0\x15\x00lU\x80\xae\nH\x17\x01\x13*\xe0O\x04\x04\x11\x80b\x11\x10*\x02\xccT\x00v\x08(I\x01\x98!\x003\x04\x9c\x02\x80S\x00\xb0\x03\x00RR\x80\x85\x08\xb0\x10\x016'\x00\xa6:\x88\x8c\x807\x13\x90D\x00\x90\x08\xc0\x88\x08(\x11\x01\xad\x00\xa0\x15\x00\x0c\x0f\x00\xe1\x01 <\x00xD\x80\x9a\n\x18\x12\x01C\"\xc0S\x05\x80\xaa\x80N\x15\xf0\xa9\x02\x8cD\x00\x89\n\x90K\x01\x90!\xc0B\x04\xcc\xa8\x00\xf2\x140\"\x02FF\x80\xaa\n`U\x01\xac*\x8c\x89\x00\xbc\x00\x00\xe2\x14\xf03\x02\xc8\xaa\x03\x98\t\x003\x01%\"`R\x04L\x8a0J\x11@)\xc2\x1eE@\xa4\x08x\x14\x01\x91\"\x00R\x04H\x8a\x00H\x11 )\x02BK@h\tP-\x01\xaa%@2\x04 S\x07\x0b\x1102\x02\x8cE\x80\x81\t(0\x01\xf5\x03\xa0z\x00\xbc\x02\x00A\x11P\xac\x02zU\x80\xa1\x08\x18V\x01\xc1*`Y\x05(\x8a\x80_\x15\x90\x97\x02\x04E\x80\xa1\x08(V\x01\x8a\"`Y\x05\x1c\xab\x80j\x150\xad\x02\xf6D\x00\xae\n\xe8\x13\x01\xb0*@W\x05\xd8\xaa\x80t\x11\xf0'\x02\"D\x80\x9a\t\xc8\x05\x00\xb9\x00@\x16\x00\xc8\x02\x80Y\x000\x0b\x00\x06E\x80\xb1\n\xf0U\x01\xd8*\xe0P\x04\x10\xab\x80\xe4\x13p\xad\x02\xf6R\x80\xb0\n`V\x01\x8b\"\x00X\x05\x0c\x8a\x80C\x11`\xac\x02\x16E\x00\xb3\n@V\x01\xd4*\xc0Z\x05d\x87\x00\x93\x14\x90\x19\x022C\x80J\n\xf8\x06\x00\xdf\x00\xc0b\x04\x10\x0f\x00\xda\x11P\x16\x00\xc6\x02\x80\x10\x01\xd8\x06\x01\x15# \xa6:\xd0\x88\x00\x1a\x11\x80;\x00\xa2\x07@\xf4\x00@\x12\x01<\" \x01\x04 \x89\x00\x1e\x11\xe0\x0f\x00\xfc\x01\x00\xb7\x00\xb8\x06\x00\xd7\x00\x00T\x04\xc4\xa8\x00\x18\x15\xd0\"\x02PR\x00\xa9\x08\xb0\x19\x01\xf1*\xa0\xac:h\xab\x80\x94\x14@\x03\x02DB@m\t\xf8-\x01\xc3%\x80V\x04p\x89\x80\xdc\x12P+\x02\xd8K\x00\x97\x08\xd0Q\x019*\xa09\x05\xec\xa8\x00\xf1\x11\x90L\x1d\x8c\x08\xc0\x16\x018\x0b\x00l\"\xc03\x04\x80\x86\x80\xe8\x100\x96\x02\xf4\x01\x80>\x00\x88\x0c\x01^\x04\xa0-\x00\xec\x03\x80}\x000D\x00\x8aC@\\\x00pK\x01~)@\xa6:\xe4\x03\x80|\x00\xf0\x1b\x02|C\x00`\t\xe0\x18\x01\x1c#\xe0a\x04\xe0\x97\x80\xb5\x00\x80\n\x00P\x01\xc0\\\x000\xab\x0e\x91!\xa02\x04\xfc\x86\x00\xdf\x10\xe0(\x02\x8a\x07\x80\xf4\x00(\x1e\x00\xc8!\xa0c\x04t\x8c\x00\x87\x11\xf0\x16\x00\xf2K\x802u\x80\x17\x01i\x01\xa0\xb6\x04\xd0\x96\x00\xe4\x10\xc0\x0f\x00\xf8\x01\xc0i\n\xa8\x0e\x01\xe8* ]\x05\xa0\x8a\x00\xce\x14P?\x00\xe0\x07@\x81\x08\xa8\x1e\x00\xd6\x03\xa0C\x04T\x86\x80\xf8\x01 <\x00\x14E\xd8\xb2\n[\x14a\xcc*,z\x00\xc8\x8a\x80Y\x11 C\x00DE\x00\x8a\x08\xd8\x15\x01Z\"\xc0]\x04\xf0\x01\x00>\x000S\x1ddE\x80\xa0\x08\x19\x14!g\xd5\xa1C\x04\xcc\x8a\x80e\xea\xb0\xac\xc2\x14E\x18\xb3\n[\x14a\x9a)\xa0.\x00|\xa9\x80\x13\x11\x90%\x020B\x00Mu@\xab\x0e\x18!\x00H\x04\x00\x89\x00f\xea ,\x02\xdeK\xc0\xb0\x08\xe8-\x015\xd5A\xff\x04\xdc\x9f\x00\xdf\x01\x80\x7f\x02\xeaO\x00\xff\t\xd8\x17\x01\x00* \xad:\x04\xa8\x00\x01\x15\x90\x7f\x02\xecO@3u0P\x01\x04*`\xb6\x04\x04\x8b\x00`\x11\xd0\x0f\x00\xfa\x01\xc0\x13\x01\xb8\x0b\x00K\x04\xa0\x14\x00\x94\x02\x00\x9b\xeapE\x00\xd4\xaa\x833up\"\x00\xff\x00\xe0\x1f\x00\xe8\x05\x00\xbf\x00pC\x00\xf8\x02\x00J\x08\xb0\x1d\x007\xd5\xc1\x86\x00t\x87\x80\xb5\xea\xf0L\x1d\x1a@\x00\x03\x08\x00";

    pub fn get(index: u16) Codepoints {
        const backing_int = @typeInfo(Codepoints).@"struct".backing_integer.?;
        return @bitCast(std.mem.readPackedInt(backing_int, bytes, index * @bitSizeOf(backing_int), .little));
    }
};

pub const first_layer = [_]FirstLayerNode{
    .{ .number = 0 },
    .{ .number = 27 },
    .{ .number = 39 },
    .{ .number = 75 },
    .{ .number = 129 },
    .{ .number = 159 },
    .{ .number = 167 },
    .{ .number = 189 },
    .{ .number = 201 },
    .{ .number = 230 },
    .{ .number = 237 },
    .{ .number = 245 },
    .{ .number = 305 },
    .{ .number = 314 },
    .{ .number = 386 },
    .{ .number = 415 },
    .{ .number = 434 },
    .{ .number = 439 },
    .{ .number = 484 },
    .{ .number = 524 },
    .{ .number = 547 },
    .{ .number = 587 },
    .{ .number = 604 },
    .{ .number = 609 },
    .{ .number = 613 },
    .{ .number = 624 },
    .{ .number = 634 },
    .{ .number = 703 },
    .{ .number = 819 },
    .{ .number = 918 },
    .{ .number = 984 },
    .{ .number = 1051 },
    .{ .number = 1090 },
    .{ .number = 1150 },
    .{ .number = 1178 },
    .{ .number = 1234 },
    .{ .number = 1242 },
    .{ .number = 1252 },
    .{ .number = 1406 },
    .{ .number = 1446 },
    .{ .number = 1614 },
    .{ .number = 1675 },
    .{ .number = 1744 },
    .{ .number = 1755 },
    .{ .number = 1859 },
    .{ .number = 2017 },
    .{ .number = 2075 },
    .{ .number = 2127 },
    .{ .number = 2169 },
    .{ .number = 2180 },
    .{ .number = 2204 },
    .{ .number = 2218 },
};

pub const second_layer = [_]SecondLayerNode{
    .invalid, // AA
    .invalid, // AB
    .invalid, // AC
    .invalid, // AD
    .{ .number = 0, .child_index = 1, .children_len = 1, .end_of_word = false }, // AE
    .invalid, // AF
    .invalid, // AG
    .invalid, // AH
    .invalid, // AI
    .invalid, // AJ
    .invalid, // AK
    .invalid, // AL
    .{ .number = 2, .child_index = 2, .children_len = 1, .end_of_word = false }, // AM
    .invalid, // AN
    .invalid, // AO
    .invalid, // AP
    .invalid, // AQ
    .invalid, // AR
    .invalid, // AS
    .invalid, // AT
    .invalid, // AU
    .invalid, // AV
    .invalid, // AW
    .invalid, // AX
    .invalid, // AY
    .invalid, // AZ
    .{ .number = 4, .child_index = 3, .children_len = 1, .end_of_word = false }, // Aa
    .{ .number = 6, .child_index = 4, .children_len = 1, .end_of_word = false }, // Ab
    .{ .number = 7, .child_index = 5, .children_len = 2, .end_of_word = false }, // Ac
    .invalid, // Ad
    .invalid, // Ae
    .{ .number = 10, .child_index = 7, .children_len = 1, .end_of_word = false }, // Af
    .{ .number = 11, .child_index = 8, .children_len = 1, .end_of_word = false }, // Ag
    .invalid, // Ah
    .invalid, // Ai
    .invalid, // Aj
    .invalid, // Ak
    .{ .number = 13, .child_index = 9, .children_len = 1, .end_of_word = false }, // Al
    .{ .number = 14, .child_index = 10, .children_len = 1, .end_of_word = false }, // Am
    .{ .number = 15, .child_index = 11, .children_len = 1, .end_of_word = false }, // An
    .{ .number = 16, .child_index = 12, .children_len = 2, .end_of_word = false }, // Ao
    .{ .number = 18, .child_index = 14, .children_len = 1, .end_of_word = false }, // Ap
    .invalid, // Aq
    .{ .number = 19, .child_index = 15, .children_len = 1, .end_of_word = false }, // Ar
    .{ .number = 21, .child_index = 16, .children_len = 2, .end_of_word = false }, // As
    .{ .number = 23, .child_index = 18, .children_len = 1, .end_of_word = false }, // At
    .{ .number = 25, .child_index = 19, .children_len = 1, .end_of_word = false }, // Au
    .invalid, // Av
    .invalid, // Aw
    .invalid, // Ax
    .invalid, // Ay
    .invalid, // Az
    .invalid, // BA
    .invalid, // BB
    .invalid, // BC
    .invalid, // BD
    .invalid, // BE
    .invalid, // BF
    .invalid, // BG
    .invalid, // BH
    .invalid, // BI
    .invalid, // BJ
    .invalid, // BK
    .invalid, // BL
    .invalid, // BM
    .invalid, // BN
    .invalid, // BO
    .invalid, // BP
    .invalid, // BQ
    .invalid, // BR
    .invalid, // BS
    .invalid, // BT
    .invalid, // BU
    .invalid, // BV
    .invalid, // BW
    .invalid, // BX
    .invalid, // BY
    .invalid, // BZ
    .{ .number = 0, .child_index = 20, .children_len = 2, .end_of_word = false }, // Ba
    .invalid, // Bb
    .{ .number = 3, .child_index = 22, .children_len = 1, .end_of_word = false }, // Bc
    .invalid, // Bd
    .{ .number = 4, .child_index = 23, .children_len = 3, .end_of_word = false }, // Be
    .{ .number = 7, .child_index = 7, .children_len = 1, .end_of_word = false }, // Bf
    .invalid, // Bg
    .invalid, // Bh
    .invalid, // Bi
    .invalid, // Bj
    .invalid, // Bk
    .invalid, // Bl
    .invalid, // Bm
    .invalid, // Bn
    .{ .number = 8, .child_index = 26, .children_len = 1, .end_of_word = false }, // Bo
    .invalid, // Bp
    .invalid, // Bq
    .{ .number = 9, .child_index = 27, .children_len = 1, .end_of_word = false }, // Br
    .{ .number = 10, .child_index = 28, .children_len = 1, .end_of_word = false }, // Bs
    .invalid, // Bt
    .{ .number = 11, .child_index = 29, .children_len = 1, .end_of_word = false }, // Bu
    .invalid, // Bv
    .invalid, // Bw
    .invalid, // Bx
    .invalid, // By
    .invalid, // Bz
    .invalid, // CA
    .invalid, // CB
    .invalid, // CC
    .invalid, // CD
    .invalid, // CE
    .invalid, // CF
    .invalid, // CG
    .{ .number = 0, .child_index = 30, .children_len = 1, .end_of_word = false }, // CH
    .invalid, // CI
    .invalid, // CJ
    .invalid, // CK
    .invalid, // CL
    .invalid, // CM
    .invalid, // CN
    .{ .number = 1, .child_index = 31, .children_len = 1, .end_of_word = false }, // CO
    .invalid, // CP
    .invalid, // CQ
    .invalid, // CR
    .invalid, // CS
    .invalid, // CT
    .invalid, // CU
    .invalid, // CV
    .invalid, // CW
    .invalid, // CX
    .invalid, // CY
    .invalid, // CZ
    .{ .number = 3, .child_index = 32, .children_len = 3, .end_of_word = false }, // Ca
    .invalid, // Cb
    .{ .number = 7, .child_index = 35, .children_len = 4, .end_of_word = false }, // Cc
    .{ .number = 12, .child_index = 39, .children_len = 1, .end_of_word = false }, // Cd
    .{ .number = 13, .child_index = 40, .children_len = 2, .end_of_word = false }, // Ce
    .{ .number = 15, .child_index = 7, .children_len = 1, .end_of_word = false }, // Cf
    .invalid, // Cg
    .{ .number = 16, .child_index = 42, .children_len = 1, .end_of_word = false }, // Ch
    .{ .number = 17, .child_index = 43, .children_len = 1, .end_of_word = false }, // Ci
    .invalid, // Cj
    .invalid, // Ck
    .{ .number = 21, .child_index = 44, .children_len = 1, .end_of_word = false }, // Cl
    .invalid, // Cm
    .invalid, // Cn
    .{ .number = 24, .child_index = 45, .children_len = 4, .end_of_word = false }, // Co
    .invalid, // Cp
    .invalid, // Cq
    .{ .number = 32, .child_index = 49, .children_len = 1, .end_of_word = false }, // Cr
    .{ .number = 33, .child_index = 28, .children_len = 1, .end_of_word = false }, // Cs
    .invalid, // Ct
    .{ .number = 34, .child_index = 50, .children_len = 1, .end_of_word = false }, // Cu
    .invalid, // Cv
    .invalid, // Cw
    .invalid, // Cx
    .invalid, // Cy
    .invalid, // Cz
    .invalid, // DA
    .invalid, // DB
    .invalid, // DC
    .{ .number = 0, .child_index = 51, .children_len = 2, .end_of_word = false }, // DD
    .invalid, // DE
    .invalid, // DF
    .invalid, // DG
    .invalid, // DH
    .invalid, // DI
    .{ .number = 2, .child_index = 30, .children_len = 1, .end_of_word = false }, // DJ
    .invalid, // DK
    .invalid, // DL
    .invalid, // DM
    .invalid, // DN
    .invalid, // DO
    .invalid, // DP
    .invalid, // DQ
    .invalid, // DR
    .{ .number = 3, .child_index = 30, .children_len = 1, .end_of_word = false }, // DS
    .invalid, // DT
    .invalid, // DU
    .invalid, // DV
    .invalid, // DW
    .invalid, // DX
    .invalid, // DY
    .{ .number = 4, .child_index = 30, .children_len = 1, .end_of_word = false }, // DZ
    .{ .number = 5, .child_index = 53, .children_len = 3, .end_of_word = false }, // Da
    .invalid, // Db
    .{ .number = 8, .child_index = 56, .children_len = 2, .end_of_word = false }, // Dc
    .invalid, // Dd
    .{ .number = 10, .child_index = 58, .children_len = 1, .end_of_word = false }, // De
    .{ .number = 12, .child_index = 7, .children_len = 1, .end_of_word = false }, // Df
    .invalid, // Dg
    .invalid, // Dh
    .{ .number = 13, .child_index = 59, .children_len = 2, .end_of_word = false }, // Di
    .invalid, // Dj
    .invalid, // Dk
    .invalid, // Dl
    .invalid, // Dm
    .invalid, // Dn
    .{ .number = 20, .child_index = 61, .children_len = 4, .end_of_word = false }, // Do
    .invalid, // Dp
    .invalid, // Dq
    .invalid, // Dr
    .{ .number = 52, .child_index = 65, .children_len = 2, .end_of_word = false }, // Ds
    .invalid, // Dt
    .invalid, // Du
    .invalid, // Dv
    .invalid, // Dw
    .invalid, // Dx
    .invalid, // Dy
    .invalid, // Dz
    .invalid, // EA
    .invalid, // EB
    .invalid, // EC
    .invalid, // ED
    .invalid, // EE
    .invalid, // EF
    .invalid, // EG
    .invalid, // EH
    .invalid, // EI
    .invalid, // EJ
    .invalid, // EK
    .invalid, // EL
    .invalid, // EM
    .{ .number = 0, .child_index = 67, .children_len = 1, .end_of_word = false }, // EN
    .invalid, // EO
    .invalid, // EP
    .invalid, // EQ
    .invalid, // ER
    .invalid, // ES
    .{ .number = 1, .child_index = 68, .children_len = 1, .end_of_word = false }, // ET
    .invalid, // EU
    .invalid, // EV
    .invalid, // EW
    .invalid, // EX
    .invalid, // EY
    .invalid, // EZ
    .{ .number = 3, .child_index = 3, .children_len = 1, .end_of_word = false }, // Ea
    .invalid, // Eb
    .{ .number = 5, .child_index = 69, .children_len = 3, .end_of_word = false }, // Ec
    .{ .number = 9, .child_index = 39, .children_len = 1, .end_of_word = false }, // Ed
    .invalid, // Ee
    .{ .number = 10, .child_index = 7, .children_len = 1, .end_of_word = false }, // Ef
    .{ .number = 11, .child_index = 8, .children_len = 1, .end_of_word = false }, // Eg
    .invalid, // Eh
    .invalid, // Ei
    .invalid, // Ej
    .invalid, // Ek
    .{ .number = 13, .child_index = 72, .children_len = 1, .end_of_word = false }, // El
    .{ .number = 14, .child_index = 73, .children_len = 2, .end_of_word = false }, // Em
    .invalid, // En
    .{ .number = 17, .child_index = 12, .children_len = 2, .end_of_word = false }, // Eo
    .{ .number = 19, .child_index = 75, .children_len = 1, .end_of_word = false }, // Ep
    .{ .number = 20, .child_index = 76, .children_len = 1, .end_of_word = false }, // Eq
    .invalid, // Er
    .{ .number = 23, .child_index = 77, .children_len = 2, .end_of_word = false }, // Es
    .{ .number = 25, .child_index = 79, .children_len = 1, .end_of_word = false }, // Et
    .{ .number = 26, .child_index = 19, .children_len = 1, .end_of_word = false }, // Eu
    .invalid, // Ev
    .invalid, // Ew
    .{ .number = 28, .child_index = 80, .children_len = 2, .end_of_word = false }, // Ex
    .invalid, // Ey
    .invalid, // Ez
    .invalid, // FA
    .invalid, // FB
    .invalid, // FC
    .invalid, // FD
    .invalid, // FE
    .invalid, // FF
    .invalid, // FG
    .invalid, // FH
    .invalid, // FI
    .invalid, // FJ
    .invalid, // FK
    .invalid, // FL
    .invalid, // FM
    .invalid, // FN
    .invalid, // FO
    .invalid, // FP
    .invalid, // FQ
    .invalid, // FR
    .invalid, // FS
    .invalid, // FT
    .invalid, // FU
    .invalid, // FV
    .invalid, // FW
    .invalid, // FX
    .invalid, // FY
    .invalid, // FZ
    .invalid, // Fa
    .invalid, // Fb
    .{ .number = 0, .child_index = 22, .children_len = 1, .end_of_word = false }, // Fc
    .invalid, // Fd
    .invalid, // Fe
    .{ .number = 1, .child_index = 7, .children_len = 1, .end_of_word = false }, // Ff
    .invalid, // Fg
    .invalid, // Fh
    .{ .number = 2, .child_index = 82, .children_len = 1, .end_of_word = false }, // Fi
    .invalid, // Fj
    .invalid, // Fk
    .invalid, // Fl
    .invalid, // Fm
    .invalid, // Fn
    .{ .number = 4, .child_index = 83, .children_len = 3, .end_of_word = false }, // Fo
    .invalid, // Fp
    .invalid, // Fq
    .invalid, // Fr
    .{ .number = 7, .child_index = 28, .children_len = 1, .end_of_word = false }, // Fs
    .invalid, // Ft
    .invalid, // Fu
    .invalid, // Fv
    .invalid, // Fw
    .invalid, // Fx
    .invalid, // Fy
    .invalid, // Fz
    .invalid, // GA
    .invalid, // GB
    .invalid, // GC
    .invalid, // GD
    .invalid, // GE
    .invalid, // GF
    .invalid, // GG
    .invalid, // GH
    .invalid, // GI
    .{ .number = 0, .child_index = 30, .children_len = 1, .end_of_word = false }, // GJ
    .invalid, // GK
    .invalid, // GL
    .invalid, // GM
    .invalid, // GN
    .invalid, // GO
    .invalid, // GP
    .invalid, // GQ
    .invalid, // GR
    .invalid, // GS
    .{ .number = 1, .child_index = 86, .children_len = 1, .end_of_word = true }, // GT
    .invalid, // GU
    .invalid, // GV
    .invalid, // GW
    .invalid, // GX
    .invalid, // GY
    .invalid, // GZ
    .{ .number = 3, .child_index = 87, .children_len = 1, .end_of_word = false }, // Ga
    .{ .number = 5, .child_index = 4, .children_len = 1, .end_of_word = false }, // Gb
    .{ .number = 6, .child_index = 88, .children_len = 3, .end_of_word = false }, // Gc
    .{ .number = 9, .child_index = 39, .children_len = 1, .end_of_word = false }, // Gd
    .invalid, // Ge
    .{ .number = 10, .child_index = 7, .children_len = 1, .end_of_word = false }, // Gf
    .{ .number = 11, .child_index = 91, .children_len = 1, .end_of_word = false }, // Gg
    .invalid, // Gh
    .invalid, // Gi
    .invalid, // Gj
    .invalid, // Gk
    .invalid, // Gl
    .invalid, // Gm
    .invalid, // Gn
    .{ .number = 12, .child_index = 26, .children_len = 1, .end_of_word = false }, // Go
    .invalid, // Gp
    .invalid, // Gq
    .{ .number = 13, .child_index = 92, .children_len = 1, .end_of_word = false }, // Gr
    .{ .number = 20, .child_index = 28, .children_len = 1, .end_of_word = false }, // Gs
    .{ .number = 21, .child_index = 91, .children_len = 1, .end_of_word = false }, // Gt
    .invalid, // Gu
    .invalid, // Gv
    .invalid, // Gw
    .invalid, // Gx
    .invalid, // Gy
    .invalid, // Gz
    .{ .number = 0, .child_index = 93, .children_len = 1, .end_of_word = false }, // HA
    .invalid, // HB
    .invalid, // HC
    .invalid, // HD
    .invalid, // HE
    .invalid, // HF
    .invalid, // HG
    .invalid, // HH
    .invalid, // HI
    .invalid, // HJ
    .invalid, // HK
    .invalid, // HL
    .invalid, // HM
    .invalid, // HN
    .invalid, // HO
    .invalid, // HP
    .invalid, // HQ
    .invalid, // HR
    .invalid, // HS
    .invalid, // HT
    .invalid, // HU
    .invalid, // HV
    .invalid, // HW
    .invalid, // HX
    .invalid, // HY
    .invalid, // HZ
    .{ .number = 1, .child_index = 94, .children_len = 2, .end_of_word = false }, // Ha
    .invalid, // Hb
    .{ .number = 3, .child_index = 96, .children_len = 1, .end_of_word = false }, // Hc
    .invalid, // Hd
    .invalid, // He
    .{ .number = 4, .child_index = 7, .children_len = 1, .end_of_word = false }, // Hf
    .invalid, // Hg
    .invalid, // Hh
    .{ .number = 5, .child_index = 97, .children_len = 1, .end_of_word = false }, // Hi
    .invalid, // Hj
    .invalid, // Hk
    .invalid, // Hl
    .invalid, // Hm
    .invalid, // Hn
    .{ .number = 6, .child_index = 98, .children_len = 2, .end_of_word = false }, // Ho
    .invalid, // Hp
    .invalid, // Hq
    .invalid, // Hr
    .{ .number = 8, .child_index = 65, .children_len = 2, .end_of_word = false }, // Hs
    .invalid, // Ht
    .{ .number = 10, .child_index = 100, .children_len = 1, .end_of_word = false }, // Hu
    .invalid, // Hv
    .invalid, // Hw
    .invalid, // Hx
    .invalid, // Hy
    .invalid, // Hz
    .invalid, // IA
    .invalid, // IB
    .invalid, // IC
    .invalid, // ID
    .{ .number = 0, .child_index = 30, .children_len = 1, .end_of_word = false }, // IE
    .invalid, // IF
    .invalid, // IG
    .invalid, // IH
    .invalid, // II
    .{ .number = 1, .child_index = 101, .children_len = 1, .end_of_word = false }, // IJ
    .invalid, // IK
    .invalid, // IL
    .invalid, // IM
    .invalid, // IN
    .{ .number = 2, .child_index = 30, .children_len = 1, .end_of_word = false }, // IO
    .invalid, // IP
    .invalid, // IQ
    .invalid, // IR
    .invalid, // IS
    .invalid, // IT
    .invalid, // IU
    .invalid, // IV
    .invalid, // IW
    .invalid, // IX
    .invalid, // IY
    .invalid, // IZ
    .{ .number = 3, .child_index = 3, .children_len = 1, .end_of_word = false }, // Ia
    .invalid, // Ib
    .{ .number = 5, .child_index = 5, .children_len = 2, .end_of_word = false }, // Ic
    .{ .number = 8, .child_index = 39, .children_len = 1, .end_of_word = false }, // Id
    .invalid, // Ie
    .{ .number = 9, .child_index = 7, .children_len = 1, .end_of_word = false }, // If
    .{ .number = 10, .child_index = 8, .children_len = 1, .end_of_word = false }, // Ig
    .invalid, // Ih
    .invalid, // Ii
    .invalid, // Ij
    .invalid, // Ik
    .invalid, // Il
    .{ .number = 12, .child_index = 102, .children_len = 3, .end_of_word = false }, // Im
    .{ .number = 16, .child_index = 105, .children_len = 2, .end_of_word = false }, // In
    .{ .number = 21, .child_index = 107, .children_len = 3, .end_of_word = false }, // Io
    .invalid, // Ip
    .invalid, // Iq
    .invalid, // Ir
    .{ .number = 24, .child_index = 28, .children_len = 1, .end_of_word = false }, // Is
    .{ .number = 25, .child_index = 110, .children_len = 1, .end_of_word = false }, // It
    .{ .number = 26, .child_index = 111, .children_len = 2, .end_of_word = false }, // Iu
    .invalid, // Iv
    .invalid, // Iw
    .invalid, // Ix
    .invalid, // Iy
    .invalid, // Iz
    .invalid, // JA
    .invalid, // JB
    .invalid, // JC
    .invalid, // JD
    .invalid, // JE
    .invalid, // JF
    .invalid, // JG
    .invalid, // JH
    .invalid, // JI
    .invalid, // JJ
    .invalid, // JK
    .invalid, // JL
    .invalid, // JM
    .invalid, // JN
    .invalid, // JO
    .invalid, // JP
    .invalid, // JQ
    .invalid, // JR
    .invalid, // JS
    .invalid, // JT
    .invalid, // JU
    .invalid, // JV
    .invalid, // JW
    .invalid, // JX
    .invalid, // JY
    .invalid, // JZ
    .invalid, // Ja
    .invalid, // Jb
    .{ .number = 0, .child_index = 113, .children_len = 2, .end_of_word = false }, // Jc
    .invalid, // Jd
    .invalid, // Je
    .{ .number = 2, .child_index = 7, .children_len = 1, .end_of_word = false }, // Jf
    .invalid, // Jg
    .invalid, // Jh
    .invalid, // Ji
    .invalid, // Jj
    .invalid, // Jk
    .invalid, // Jl
    .invalid, // Jm
    .invalid, // Jn
    .{ .number = 3, .child_index = 26, .children_len = 1, .end_of_word = false }, // Jo
    .invalid, // Jp
    .invalid, // Jq
    .invalid, // Jr
    .{ .number = 4, .child_index = 115, .children_len = 2, .end_of_word = false }, // Js
    .invalid, // Jt
    .{ .number = 6, .child_index = 117, .children_len = 1, .end_of_word = false }, // Ju
    .invalid, // Jv
    .invalid, // Jw
    .invalid, // Jx
    .invalid, // Jy
    .invalid, // Jz
    .invalid, // KA
    .invalid, // KB
    .invalid, // KC
    .invalid, // KD
    .invalid, // KE
    .invalid, // KF
    .invalid, // KG
    .{ .number = 0, .child_index = 30, .children_len = 1, .end_of_word = false }, // KH
    .invalid, // KI
    .{ .number = 1, .child_index = 30, .children_len = 1, .end_of_word = false }, // KJ
    .invalid, // KK
    .invalid, // KL
    .invalid, // KM
    .invalid, // KN
    .invalid, // KO
    .invalid, // KP
    .invalid, // KQ
    .invalid, // KR
    .invalid, // KS
    .invalid, // KT
    .invalid, // KU
    .invalid, // KV
    .invalid, // KW
    .invalid, // KX
    .invalid, // KY
    .invalid, // KZ
    .{ .number = 2, .child_index = 118, .children_len = 1, .end_of_word = false }, // Ka
    .invalid, // Kb
    .{ .number = 3, .child_index = 119, .children_len = 2, .end_of_word = false }, // Kc
    .invalid, // Kd
    .invalid, // Ke
    .{ .number = 5, .child_index = 7, .children_len = 1, .end_of_word = false }, // Kf
    .invalid, // Kg
    .invalid, // Kh
    .invalid, // Ki
    .invalid, // Kj
    .invalid, // Kk
    .invalid, // Kl
    .invalid, // Km
    .invalid, // Kn
    .{ .number = 6, .child_index = 26, .children_len = 1, .end_of_word = false }, // Ko
    .invalid, // Kp
    .invalid, // Kq
    .invalid, // Kr
    .{ .number = 7, .child_index = 28, .children_len = 1, .end_of_word = false }, // Ks
    .invalid, // Kt
    .invalid, // Ku
    .invalid, // Kv
    .invalid, // Kw
    .invalid, // Kx
    .invalid, // Ky
    .invalid, // Kz
    .invalid, // LA
    .invalid, // LB
    .invalid, // LC
    .invalid, // LD
    .invalid, // LE
    .invalid, // LF
    .invalid, // LG
    .invalid, // LH
    .invalid, // LI
    .{ .number = 0, .child_index = 30, .children_len = 1, .end_of_word = false }, // LJ
    .invalid, // LK
    .invalid, // LL
    .invalid, // LM
    .invalid, // LN
    .invalid, // LO
    .invalid, // LP
    .invalid, // LQ
    .invalid, // LR
    .invalid, // LS
    .{ .number = 1, .child_index = 86, .children_len = 1, .end_of_word = true }, // LT
    .invalid, // LU
    .invalid, // LV
    .invalid, // LW
    .invalid, // LX
    .invalid, // LY
    .invalid, // LZ
    .{ .number = 3, .child_index = 121, .children_len = 5, .end_of_word = false }, // La
    .invalid, // Lb
    .{ .number = 8, .child_index = 126, .children_len = 3, .end_of_word = false }, // Lc
    .invalid, // Ld
    .{ .number = 11, .child_index = 129, .children_len = 2, .end_of_word = false }, // Le
    .{ .number = 43, .child_index = 7, .children_len = 1, .end_of_word = false }, // Lf
    .invalid, // Lg
    .invalid, // Lh
    .invalid, // Li
    .invalid, // Lj
    .invalid, // Lk
    .{ .number = 44, .child_index = 131, .children_len = 2, .end_of_word = false }, // Ll
    .{ .number = 46, .child_index = 133, .children_len = 1, .end_of_word = false }, // Lm
    .invalid, // Ln
    .{ .number = 47, .child_index = 134, .children_len = 3, .end_of_word = false }, // Lo
    .invalid, // Lp
    .invalid, // Lq
    .invalid, // Lr
    .{ .number = 56, .child_index = 137, .children_len = 3, .end_of_word = false }, // Ls
    .{ .number = 59, .child_index = 91, .children_len = 1, .end_of_word = false }, // Lt
    .invalid, // Lu
    .invalid, // Lv
    .invalid, // Lw
    .invalid, // Lx
    .invalid, // Ly
    .invalid, // Lz
    .invalid, // MA
    .invalid, // MB
    .invalid, // MC
    .invalid, // MD
    .invalid, // ME
    .invalid, // MF
    .invalid, // MG
    .invalid, // MH
    .invalid, // MI
    .invalid, // MJ
    .invalid, // MK
    .invalid, // ML
    .invalid, // MM
    .invalid, // MN
    .invalid, // MO
    .invalid, // MP
    .invalid, // MQ
    .invalid, // MR
    .invalid, // MS
    .invalid, // MT
    .invalid, // MU
    .invalid, // MV
    .invalid, // MW
    .invalid, // MX
    .invalid, // MY
    .invalid, // MZ
    .{ .number = 0, .child_index = 140, .children_len = 1, .end_of_word = false }, // Ma
    .invalid, // Mb
    .{ .number = 1, .child_index = 22, .children_len = 1, .end_of_word = false }, // Mc
    .invalid, // Md
    .{ .number = 2, .child_index = 141, .children_len = 2, .end_of_word = false }, // Me
    .{ .number = 4, .child_index = 7, .children_len = 1, .end_of_word = false }, // Mf
    .invalid, // Mg
    .invalid, // Mh
    .{ .number = 5, .child_index = 143, .children_len = 1, .end_of_word = false }, // Mi
    .invalid, // Mj
    .invalid, // Mk
    .invalid, // Ml
    .invalid, // Mm
    .invalid, // Mn
    .{ .number = 6, .child_index = 26, .children_len = 1, .end_of_word = false }, // Mo
    .invalid, // Mp
    .invalid, // Mq
    .invalid, // Mr
    .{ .number = 7, .child_index = 28, .children_len = 1, .end_of_word = false }, // Ms
    .invalid, // Mt
    .{ .number = 8, .child_index = 91, .children_len = 1, .end_of_word = false }, // Mu
    .invalid, // Mv
    .invalid, // Mw
    .invalid, // Mx
    .invalid, // My
    .invalid, // Mz
    .invalid, // NA
    .invalid, // NB
    .invalid, // NC
    .invalid, // ND
    .invalid, // NE
    .invalid, // NF
    .invalid, // NG
    .invalid, // NH
    .invalid, // NI
    .{ .number = 0, .child_index = 30, .children_len = 1, .end_of_word = false }, // NJ
    .invalid, // NK
    .invalid, // NL
    .invalid, // NM
    .invalid, // NN
    .invalid, // NO
    .invalid, // NP
    .invalid, // NQ
    .invalid, // NR
    .invalid, // NS
    .invalid, // NT
    .invalid, // NU
    .invalid, // NV
    .invalid, // NW
    .invalid, // NX
    .invalid, // NY
    .invalid, // NZ
    .{ .number = 1, .child_index = 144, .children_len = 1, .end_of_word = false }, // Na
    .invalid, // Nb
    .{ .number = 2, .child_index = 126, .children_len = 3, .end_of_word = false }, // Nc
    .invalid, // Nd
    .{ .number = 5, .child_index = 145, .children_len = 3, .end_of_word = false }, // Ne
    .{ .number = 12, .child_index = 7, .children_len = 1, .end_of_word = false }, // Nf
    .invalid, // Ng
    .invalid, // Nh
    .invalid, // Ni
    .invalid, // Nj
    .invalid, // Nk
    .invalid, // Nl
    .invalid, // Nm
    .invalid, // Nn
    .{ .number = 13, .child_index = 148, .children_len = 4, .end_of_word = false }, // No
    .invalid, // Np
    .invalid, // Nq
    .invalid, // Nr
    .{ .number = 68, .child_index = 28, .children_len = 1, .end_of_word = false }, // Ns
    .{ .number = 69, .child_index = 18, .children_len = 1, .end_of_word = false }, // Nt
    .{ .number = 71, .child_index = 91, .children_len = 1, .end_of_word = false }, // Nu
    .invalid, // Nv
    .invalid, // Nw
    .invalid, // Nx
    .invalid, // Ny
    .invalid, // Nz
    .invalid, // OA
    .invalid, // OB
    .invalid, // OC
    .invalid, // OD
    .{ .number = 0, .child_index = 101, .children_len = 1, .end_of_word = false }, // OE
    .invalid, // OF
    .invalid, // OG
    .invalid, // OH
    .invalid, // OI
    .invalid, // OJ
    .invalid, // OK
    .invalid, // OL
    .invalid, // OM
    .invalid, // ON
    .invalid, // OO
    .invalid, // OP
    .invalid, // OQ
    .invalid, // OR
    .invalid, // OS
    .invalid, // OT
    .invalid, // OU
    .invalid, // OV
    .invalid, // OW
    .invalid, // OX
    .invalid, // OY
    .invalid, // OZ
    .{ .number = 1, .child_index = 3, .children_len = 1, .end_of_word = false }, // Oa
    .invalid, // Ob
    .{ .number = 3, .child_index = 5, .children_len = 2, .end_of_word = false }, // Oc
    .{ .number = 6, .child_index = 152, .children_len = 1, .end_of_word = false }, // Od
    .invalid, // Oe
    .{ .number = 7, .child_index = 7, .children_len = 1, .end_of_word = false }, // Of
    .{ .number = 8, .child_index = 8, .children_len = 1, .end_of_word = false }, // Og
    .invalid, // Oh
    .invalid, // Oi
    .invalid, // Oj
    .invalid, // Ok
    .invalid, // Ol
    .{ .number = 10, .child_index = 153, .children_len = 3, .end_of_word = false }, // Om
    .invalid, // On
    .{ .number = 13, .child_index = 26, .children_len = 1, .end_of_word = false }, // Oo
    .{ .number = 14, .child_index = 156, .children_len = 1, .end_of_word = false }, // Op
    .invalid, // Oq
    .{ .number = 16, .child_index = 91, .children_len = 1, .end_of_word = false }, // Or
    .{ .number = 17, .child_index = 157, .children_len = 2, .end_of_word = false }, // Os
    .{ .number = 20, .child_index = 159, .children_len = 1, .end_of_word = false }, // Ot
    .{ .number = 23, .child_index = 19, .children_len = 1, .end_of_word = false }, // Ou
    .{ .number = 25, .child_index = 160, .children_len = 1, .end_of_word = false }, // Ov
    .invalid, // Ow
    .invalid, // Ox
    .invalid, // Oy
    .invalid, // Oz
    .invalid, // PA
    .invalid, // PB
    .invalid, // PC
    .invalid, // PD
    .invalid, // PE
    .invalid, // PF
    .invalid, // PG
    .invalid, // PH
    .invalid, // PI
    .invalid, // PJ
    .invalid, // PK
    .invalid, // PL
    .invalid, // PM
    .invalid, // PN
    .invalid, // PO
    .invalid, // PP
    .invalid, // PQ
    .invalid, // PR
    .invalid, // PS
    .invalid, // PT
    .invalid, // PU
    .invalid, // PV
    .invalid, // PW
    .invalid, // PX
    .invalid, // PY
    .invalid, // PZ
    .{ .number = 0, .child_index = 161, .children_len = 1, .end_of_word = false }, // Pa
    .invalid, // Pb
    .{ .number = 1, .child_index = 22, .children_len = 1, .end_of_word = false }, // Pc
    .invalid, // Pd
    .invalid, // Pe
    .{ .number = 2, .child_index = 7, .children_len = 1, .end_of_word = false }, // Pf
    .invalid, // Pg
    .{ .number = 3, .child_index = 42, .children_len = 1, .end_of_word = false }, // Ph
    .{ .number = 4, .child_index = 91, .children_len = 1, .end_of_word = false }, // Pi
    .invalid, // Pj
    .invalid, // Pk
    .{ .number = 5, .child_index = 162, .children_len = 1, .end_of_word = false }, // Pl
    .invalid, // Pm
    .invalid, // Pn
    .{ .number = 6, .child_index = 163, .children_len = 2, .end_of_word = false }, // Po
    .invalid, // Pp
    .invalid, // Pq
    .{ .number = 8, .child_index = 165, .children_len = 4, .end_of_word = false }, // Pr
    .{ .number = 17, .child_index = 169, .children_len = 2, .end_of_word = false }, // Ps
    .invalid, // Pt
    .invalid, // Pu
    .invalid, // Pv
    .invalid, // Pw
    .invalid, // Px
    .invalid, // Py
    .invalid, // Pz
    .invalid, // QA
    .invalid, // QB
    .invalid, // QC
    .invalid, // QD
    .invalid, // QE
    .invalid, // QF
    .invalid, // QG
    .invalid, // QH
    .invalid, // QI
    .invalid, // QJ
    .invalid, // QK
    .invalid, // QL
    .invalid, // QM
    .invalid, // QN
    .invalid, // QO
    .invalid, // QP
    .invalid, // QQ
    .invalid, // QR
    .invalid, // QS
    .invalid, // QT
    .{ .number = 0, .child_index = 171, .children_len = 1, .end_of_word = false }, // QU
    .invalid, // QV
    .invalid, // QW
    .invalid, // QX
    .invalid, // QY
    .invalid, // QZ
    .invalid, // Qa
    .invalid, // Qb
    .invalid, // Qc
    .invalid, // Qd
    .invalid, // Qe
    .{ .number = 2, .child_index = 7, .children_len = 1, .end_of_word = false }, // Qf
    .invalid, // Qg
    .invalid, // Qh
    .invalid, // Qi
    .invalid, // Qj
    .invalid, // Qk
    .invalid, // Ql
    .invalid, // Qm
    .invalid, // Qn
    .{ .number = 3, .child_index = 26, .children_len = 1, .end_of_word = false }, // Qo
    .invalid, // Qp
    .invalid, // Qq
    .invalid, // Qr
    .{ .number = 4, .child_index = 28, .children_len = 1, .end_of_word = false }, // Qs
    .invalid, // Qt
    .invalid, // Qu
    .invalid, // Qv
    .invalid, // Qw
    .invalid, // Qx
    .invalid, // Qy
    .invalid, // Qz
    .invalid, // RA
    .{ .number = 0, .child_index = 172, .children_len = 1, .end_of_word = false }, // RB
    .invalid, // RC
    .invalid, // RD
    .{ .number = 1, .child_index = 173, .children_len = 1, .end_of_word = false }, // RE
    .invalid, // RF
    .invalid, // RG
    .invalid, // RH
    .invalid, // RI
    .invalid, // RJ
    .invalid, // RK
    .invalid, // RL
    .invalid, // RM
    .invalid, // RN
    .invalid, // RO
    .invalid, // RP
    .invalid, // RQ
    .invalid, // RR
    .invalid, // RS
    .invalid, // RT
    .invalid, // RU
    .invalid, // RV
    .invalid, // RW
    .invalid, // RX
    .invalid, // RY
    .invalid, // RZ
    .{ .number = 3, .child_index = 174, .children_len = 3, .end_of_word = false }, // Ra
    .invalid, // Rb
    .{ .number = 7, .child_index = 126, .children_len = 3, .end_of_word = false }, // Rc
    .invalid, // Rd
    .{ .number = 10, .child_index = 177, .children_len = 2, .end_of_word = false }, // Re
    .{ .number = 14, .child_index = 7, .children_len = 1, .end_of_word = false }, // Rf
    .invalid, // Rg
    .{ .number = 15, .child_index = 179, .children_len = 1, .end_of_word = false }, // Rh
    .{ .number = 16, .child_index = 180, .children_len = 1, .end_of_word = false }, // Ri
    .invalid, // Rj
    .invalid, // Rk
    .invalid, // Rl
    .invalid, // Rm
    .invalid, // Rn
    .{ .number = 39, .child_index = 181, .children_len = 2, .end_of_word = false }, // Ro
    .invalid, // Rp
    .invalid, // Rq
    .{ .number = 41, .child_index = 183, .children_len = 1, .end_of_word = false }, // Rr
    .{ .number = 42, .child_index = 184, .children_len = 2, .end_of_word = false }, // Rs
    .invalid, // Rt
    .{ .number = 44, .child_index = 186, .children_len = 1, .end_of_word = false }, // Ru
    .invalid, // Rv
    .invalid, // Rw
    .invalid, // Rx
    .invalid, // Ry
    .invalid, // Rz
    .invalid, // SA
    .invalid, // SB
    .invalid, // SC
    .invalid, // SD
    .invalid, // SE
    .invalid, // SF
    .invalid, // SG
    .{ .number = 0, .child_index = 187, .children_len = 2, .end_of_word = false }, // SH
    .invalid, // SI
    .invalid, // SJ
    .invalid, // SK
    .invalid, // SL
    .invalid, // SM
    .invalid, // SN
    .{ .number = 2, .child_index = 189, .children_len = 1, .end_of_word = false }, // SO
    .invalid, // SP
    .invalid, // SQ
    .invalid, // SR
    .invalid, // SS
    .invalid, // ST
    .invalid, // SU
    .invalid, // SV
    .invalid, // SW
    .invalid, // SX
    .invalid, // SY
    .invalid, // SZ
    .{ .number = 3, .child_index = 144, .children_len = 1, .end_of_word = false }, // Sa
    .invalid, // Sb
    .{ .number = 4, .child_index = 190, .children_len = 5, .end_of_word = false }, // Sc
    .invalid, // Sd
    .invalid, // Se
    .{ .number = 9, .child_index = 7, .children_len = 1, .end_of_word = false }, // Sf
    .invalid, // Sg
    .{ .number = 10, .child_index = 195, .children_len = 1, .end_of_word = false }, // Sh
    .{ .number = 14, .child_index = 196, .children_len = 1, .end_of_word = false }, // Si
    .invalid, // Sj
    .invalid, // Sk
    .invalid, // Sl
    .{ .number = 15, .child_index = 197, .children_len = 1, .end_of_word = false }, // Sm
    .invalid, // Sn
    .{ .number = 16, .child_index = 26, .children_len = 1, .end_of_word = false }, // So
    .invalid, // Sp
    .{ .number = 17, .child_index = 198, .children_len = 2, .end_of_word = false }, // Sq
    .invalid, // Sr
    .{ .number = 25, .child_index = 28, .children_len = 1, .end_of_word = false }, // Ss
    .{ .number = 26, .child_index = 200, .children_len = 1, .end_of_word = false }, // St
    .{ .number = 27, .child_index = 201, .children_len = 4, .end_of_word = false }, // Su
    .invalid, // Sv
    .invalid, // Sw
    .invalid, // Sx
    .invalid, // Sy
    .invalid, // Sz
    .invalid, // TA
    .invalid, // TB
    .invalid, // TC
    .invalid, // TD
    .invalid, // TE
    .invalid, // TF
    .invalid, // TG
    .{ .number = 0, .child_index = 205, .children_len = 1, .end_of_word = false }, // TH
    .invalid, // TI
    .invalid, // TJ
    .invalid, // TK
    .invalid, // TL
    .invalid, // TM
    .invalid, // TN
    .invalid, // TO
    .invalid, // TP
    .invalid, // TQ
    .{ .number = 2, .child_index = 206, .children_len = 1, .end_of_word = false }, // TR
    .{ .number = 3, .child_index = 207, .children_len = 2, .end_of_word = false }, // TS
    .invalid, // TT
    .invalid, // TU
    .invalid, // TV
    .invalid, // TW
    .invalid, // TX
    .invalid, // TY
    .invalid, // TZ
    .{ .number = 5, .child_index = 209, .children_len = 2, .end_of_word = false }, // Ta
    .invalid, // Tb
    .{ .number = 7, .child_index = 126, .children_len = 3, .end_of_word = false }, // Tc
    .invalid, // Td
    .invalid, // Te
    .{ .number = 10, .child_index = 7, .children_len = 1, .end_of_word = false }, // Tf
    .invalid, // Tg
    .{ .number = 11, .child_index = 211, .children_len = 2, .end_of_word = false }, // Th
    .{ .number = 15, .child_index = 213, .children_len = 1, .end_of_word = false }, // Ti
    .invalid, // Tj
    .invalid, // Tk
    .invalid, // Tl
    .invalid, // Tm
    .invalid, // Tn
    .{ .number = 19, .child_index = 26, .children_len = 1, .end_of_word = false }, // To
    .invalid, // Tp
    .invalid, // Tq
    .{ .number = 20, .child_index = 214, .children_len = 1, .end_of_word = false }, // Tr
    .{ .number = 21, .child_index = 65, .children_len = 2, .end_of_word = false }, // Ts
    .invalid, // Tt
    .invalid, // Tu
    .invalid, // Tv
    .invalid, // Tw
    .invalid, // Tx
    .invalid, // Ty
    .invalid, // Tz
    .invalid, // UA
    .invalid, // UB
    .invalid, // UC
    .invalid, // UD
    .invalid, // UE
    .invalid, // UF
    .invalid, // UG
    .invalid, // UH
    .invalid, // UI
    .invalid, // UJ
    .invalid, // UK
    .invalid, // UL
    .invalid, // UM
    .invalid, // UN
    .invalid, // UO
    .invalid, // UP
    .invalid, // UQ
    .invalid, // UR
    .invalid, // US
    .invalid, // UT
    .invalid, // UU
    .invalid, // UV
    .invalid, // UW
    .invalid, // UX
    .invalid, // UY
    .invalid, // UZ
    .{ .number = 0, .child_index = 215, .children_len = 2, .end_of_word = false }, // Ua
    .{ .number = 4, .child_index = 217, .children_len = 1, .end_of_word = false }, // Ub
    .{ .number = 6, .child_index = 5, .children_len = 2, .end_of_word = false }, // Uc
    .{ .number = 9, .child_index = 152, .children_len = 1, .end_of_word = false }, // Ud
    .invalid, // Ue
    .{ .number = 10, .child_index = 7, .children_len = 1, .end_of_word = false }, // Uf
    .{ .number = 11, .child_index = 8, .children_len = 1, .end_of_word = false }, // Ug
    .invalid, // Uh
    .invalid, // Ui
    .invalid, // Uj
    .invalid, // Uk
    .invalid, // Ul
    .{ .number = 13, .child_index = 10, .children_len = 1, .end_of_word = false }, // Um
    .{ .number = 14, .child_index = 218, .children_len = 2, .end_of_word = false }, // Un
    .{ .number = 20, .child_index = 12, .children_len = 2, .end_of_word = false }, // Uo
    .{ .number = 22, .child_index = 220, .children_len = 8, .end_of_word = false }, // Up
    .invalid, // Uq
    .{ .number = 35, .child_index = 228, .children_len = 1, .end_of_word = false }, // Ur
    .{ .number = 36, .child_index = 28, .children_len = 1, .end_of_word = false }, // Us
    .{ .number = 37, .child_index = 110, .children_len = 1, .end_of_word = false }, // Ut
    .{ .number = 38, .child_index = 19, .children_len = 1, .end_of_word = false }, // Uu
    .invalid, // Uv
    .invalid, // Uw
    .invalid, // Ux
    .invalid, // Uy
    .invalid, // Uz
    .invalid, // VA
    .invalid, // VB
    .invalid, // VC
    .{ .number = 0, .child_index = 229, .children_len = 1, .end_of_word = false }, // VD
    .invalid, // VE
    .invalid, // VF
    .invalid, // VG
    .invalid, // VH
    .invalid, // VI
    .invalid, // VJ
    .invalid, // VK
    .invalid, // VL
    .invalid, // VM
    .invalid, // VN
    .invalid, // VO
    .invalid, // VP
    .invalid, // VQ
    .invalid, // VR
    .invalid, // VS
    .invalid, // VT
    .invalid, // VU
    .invalid, // VV
    .invalid, // VW
    .invalid, // VX
    .invalid, // VY
    .invalid, // VZ
    .invalid, // Va
    .{ .number = 1, .child_index = 200, .children_len = 1, .end_of_word = false }, // Vb
    .{ .number = 2, .child_index = 22, .children_len = 1, .end_of_word = false }, // Vc
    .{ .number = 3, .child_index = 230, .children_len = 1, .end_of_word = false }, // Vd
    .{ .number = 5, .child_index = 231, .children_len = 2, .end_of_word = false }, // Ve
    .{ .number = 13, .child_index = 7, .children_len = 1, .end_of_word = false }, // Vf
    .invalid, // Vg
    .invalid, // Vh
    .invalid, // Vi
    .invalid, // Vj
    .invalid, // Vk
    .invalid, // Vl
    .invalid, // Vm
    .invalid, // Vn
    .{ .number = 14, .child_index = 26, .children_len = 1, .end_of_word = false }, // Vo
    .invalid, // Vp
    .invalid, // Vq
    .invalid, // Vr
    .{ .number = 15, .child_index = 28, .children_len = 1, .end_of_word = false }, // Vs
    .invalid, // Vt
    .invalid, // Vu
    .{ .number = 16, .child_index = 233, .children_len = 1, .end_of_word = false }, // Vv
    .invalid, // Vw
    .invalid, // Vx
    .invalid, // Vy
    .invalid, // Vz
    .invalid, // WA
    .invalid, // WB
    .invalid, // WC
    .invalid, // WD
    .invalid, // WE
    .invalid, // WF
    .invalid, // WG
    .invalid, // WH
    .invalid, // WI
    .invalid, // WJ
    .invalid, // WK
    .invalid, // WL
    .invalid, // WM
    .invalid, // WN
    .invalid, // WO
    .invalid, // WP
    .invalid, // WQ
    .invalid, // WR
    .invalid, // WS
    .invalid, // WT
    .invalid, // WU
    .invalid, // WV
    .invalid, // WW
    .invalid, // WX
    .invalid, // WY
    .invalid, // WZ
    .invalid, // Wa
    .invalid, // Wb
    .{ .number = 0, .child_index = 96, .children_len = 1, .end_of_word = false }, // Wc
    .invalid, // Wd
    .{ .number = 1, .child_index = 234, .children_len = 1, .end_of_word = false }, // We
    .{ .number = 2, .child_index = 7, .children_len = 1, .end_of_word = false }, // Wf
    .invalid, // Wg
    .invalid, // Wh
    .invalid, // Wi
    .invalid, // Wj
    .invalid, // Wk
    .invalid, // Wl
    .invalid, // Wm
    .invalid, // Wn
    .{ .number = 3, .child_index = 26, .children_len = 1, .end_of_word = false }, // Wo
    .invalid, // Wp
    .invalid, // Wq
    .invalid, // Wr
    .{ .number = 4, .child_index = 28, .children_len = 1, .end_of_word = false }, // Ws
    .invalid, // Wt
    .invalid, // Wu
    .invalid, // Wv
    .invalid, // Ww
    .invalid, // Wx
    .invalid, // Wy
    .invalid, // Wz
    .invalid, // XA
    .invalid, // XB
    .invalid, // XC
    .invalid, // XD
    .invalid, // XE
    .invalid, // XF
    .invalid, // XG
    .invalid, // XH
    .invalid, // XI
    .invalid, // XJ
    .invalid, // XK
    .invalid, // XL
    .invalid, // XM
    .invalid, // XN
    .invalid, // XO
    .invalid, // XP
    .invalid, // XQ
    .invalid, // XR
    .invalid, // XS
    .invalid, // XT
    .invalid, // XU
    .invalid, // XV
    .invalid, // XW
    .invalid, // XX
    .invalid, // XY
    .invalid, // XZ
    .invalid, // Xa
    .invalid, // Xb
    .invalid, // Xc
    .invalid, // Xd
    .invalid, // Xe
    .{ .number = 0, .child_index = 7, .children_len = 1, .end_of_word = false }, // Xf
    .invalid, // Xg
    .invalid, // Xh
    .{ .number = 1, .child_index = 91, .children_len = 1, .end_of_word = false }, // Xi
    .invalid, // Xj
    .invalid, // Xk
    .invalid, // Xl
    .invalid, // Xm
    .invalid, // Xn
    .{ .number = 2, .child_index = 26, .children_len = 1, .end_of_word = false }, // Xo
    .invalid, // Xp
    .invalid, // Xq
    .invalid, // Xr
    .{ .number = 3, .child_index = 28, .children_len = 1, .end_of_word = false }, // Xs
    .invalid, // Xt
    .invalid, // Xu
    .invalid, // Xv
    .invalid, // Xw
    .invalid, // Xx
    .invalid, // Xy
    .invalid, // Xz
    .{ .number = 0, .child_index = 30, .children_len = 1, .end_of_word = false }, // YA
    .invalid, // YB
    .invalid, // YC
    .invalid, // YD
    .invalid, // YE
    .invalid, // YF
    .invalid, // YG
    .invalid, // YH
    .{ .number = 1, .child_index = 30, .children_len = 1, .end_of_word = false }, // YI
    .invalid, // YJ
    .invalid, // YK
    .invalid, // YL
    .invalid, // YM
    .invalid, // YN
    .invalid, // YO
    .invalid, // YP
    .invalid, // YQ
    .invalid, // YR
    .invalid, // YS
    .invalid, // YT
    .{ .number = 2, .child_index = 30, .children_len = 1, .end_of_word = false }, // YU
    .invalid, // YV
    .invalid, // YW
    .invalid, // YX
    .invalid, // YY
    .invalid, // YZ
    .{ .number = 3, .child_index = 3, .children_len = 1, .end_of_word = false }, // Ya
    .invalid, // Yb
    .{ .number = 5, .child_index = 113, .children_len = 2, .end_of_word = false }, // Yc
    .invalid, // Yd
    .invalid, // Ye
    .{ .number = 7, .child_index = 7, .children_len = 1, .end_of_word = false }, // Yf
    .invalid, // Yg
    .invalid, // Yh
    .invalid, // Yi
    .invalid, // Yj
    .invalid, // Yk
    .invalid, // Yl
    .invalid, // Ym
    .invalid, // Yn
    .{ .number = 8, .child_index = 26, .children_len = 1, .end_of_word = false }, // Yo
    .invalid, // Yp
    .invalid, // Yq
    .invalid, // Yr
    .{ .number = 9, .child_index = 28, .children_len = 1, .end_of_word = false }, // Ys
    .invalid, // Yt
    .{ .number = 10, .child_index = 235, .children_len = 1, .end_of_word = false }, // Yu
    .invalid, // Yv
    .invalid, // Yw
    .invalid, // Yx
    .invalid, // Yy
    .invalid, // Yz
    .invalid, // ZA
    .invalid, // ZB
    .invalid, // ZC
    .invalid, // ZD
    .invalid, // ZE
    .invalid, // ZF
    .invalid, // ZG
    .{ .number = 0, .child_index = 30, .children_len = 1, .end_of_word = false }, // ZH
    .invalid, // ZI
    .invalid, // ZJ
    .invalid, // ZK
    .invalid, // ZL
    .invalid, // ZM
    .invalid, // ZN
    .invalid, // ZO
    .invalid, // ZP
    .invalid, // ZQ
    .invalid, // ZR
    .invalid, // ZS
    .invalid, // ZT
    .invalid, // ZU
    .invalid, // ZV
    .invalid, // ZW
    .invalid, // ZX
    .invalid, // ZY
    .invalid, // ZZ
    .{ .number = 1, .child_index = 144, .children_len = 1, .end_of_word = false }, // Za
    .invalid, // Zb
    .{ .number = 2, .child_index = 56, .children_len = 2, .end_of_word = false }, // Zc
    .{ .number = 4, .child_index = 39, .children_len = 1, .end_of_word = false }, // Zd
    .{ .number = 5, .child_index = 236, .children_len = 2, .end_of_word = false }, // Ze
    .{ .number = 7, .child_index = 7, .children_len = 1, .end_of_word = false }, // Zf
    .invalid, // Zg
    .invalid, // Zh
    .invalid, // Zi
    .invalid, // Zj
    .invalid, // Zk
    .invalid, // Zl
    .invalid, // Zm
    .invalid, // Zn
    .{ .number = 8, .child_index = 26, .children_len = 1, .end_of_word = false }, // Zo
    .invalid, // Zp
    .invalid, // Zq
    .invalid, // Zr
    .{ .number = 9, .child_index = 28, .children_len = 1, .end_of_word = false }, // Zs
    .invalid, // Zt
    .invalid, // Zu
    .invalid, // Zv
    .invalid, // Zw
    .invalid, // Zx
    .invalid, // Zy
    .invalid, // Zz
    .invalid, // aA
    .invalid, // aB
    .invalid, // aC
    .invalid, // aD
    .invalid, // aE
    .invalid, // aF
    .invalid, // aG
    .invalid, // aH
    .invalid, // aI
    .invalid, // aJ
    .invalid, // aK
    .invalid, // aL
    .invalid, // aM
    .invalid, // aN
    .invalid, // aO
    .invalid, // aP
    .invalid, // aQ
    .invalid, // aR
    .invalid, // aS
    .invalid, // aT
    .invalid, // aU
    .invalid, // aV
    .invalid, // aW
    .invalid, // aX
    .invalid, // aY
    .invalid, // aZ
    .{ .number = 0, .child_index = 3, .children_len = 1, .end_of_word = false }, // aa
    .{ .number = 2, .child_index = 4, .children_len = 1, .end_of_word = false }, // ab
    .{ .number = 3, .child_index = 238, .children_len = 6, .end_of_word = false }, // ac
    .invalid, // ad
    .{ .number = 11, .child_index = 1, .children_len = 1, .end_of_word = false }, // ae
    .{ .number = 13, .child_index = 244, .children_len = 2, .end_of_word = false }, // af
    .{ .number = 15, .child_index = 8, .children_len = 1, .end_of_word = false }, // ag
    .invalid, // ah
    .invalid, // ai
    .invalid, // aj
    .invalid, // ak
    .{ .number = 17, .child_index = 246, .children_len = 2, .end_of_word = false }, // al
    .{ .number = 20, .child_index = 248, .children_len = 2, .end_of_word = false }, // am
    .{ .number = 24, .child_index = 250, .children_len = 2, .end_of_word = false }, // an
    .{ .number = 47, .child_index = 12, .children_len = 2, .end_of_word = false }, // ao
    .{ .number = 49, .child_index = 252, .children_len = 7, .end_of_word = false }, // ap
    .invalid, // aq
    .{ .number = 57, .child_index = 15, .children_len = 1, .end_of_word = false }, // ar
    .{ .number = 59, .child_index = 259, .children_len = 3, .end_of_word = false }, // as
    .{ .number = 63, .child_index = 18, .children_len = 1, .end_of_word = false }, // at
    .{ .number = 65, .child_index = 19, .children_len = 1, .end_of_word = false }, // au
    .invalid, // av
    .{ .number = 67, .child_index = 262, .children_len = 2, .end_of_word = false }, // aw
    .invalid, // ax
    .invalid, // ay
    .invalid, // az
    .invalid, // bA
    .invalid, // bB
    .invalid, // bC
    .invalid, // bD
    .invalid, // bE
    .invalid, // bF
    .invalid, // bG
    .invalid, // bH
    .invalid, // bI
    .invalid, // bJ
    .invalid, // bK
    .invalid, // bL
    .invalid, // bM
    .{ .number = 0, .child_index = 39, .children_len = 1, .end_of_word = false }, // bN
    .invalid, // bO
    .invalid, // bP
    .invalid, // bQ
    .invalid, // bR
    .invalid, // bS
    .invalid, // bT
    .invalid, // bU
    .invalid, // bV
    .invalid, // bW
    .invalid, // bX
    .invalid, // bY
    .invalid, // bZ
    .{ .number = 1, .child_index = 264, .children_len = 2, .end_of_word = false }, // ba
    .{ .number = 9, .child_index = 266, .children_len = 1, .end_of_word = false }, // bb
    .{ .number = 11, .child_index = 267, .children_len = 2, .end_of_word = false }, // bc
    .{ .number = 13, .child_index = 269, .children_len = 1, .end_of_word = false }, // bd
    .{ .number = 14, .child_index = 270, .children_len = 5, .end_of_word = false }, // be
    .{ .number = 22, .child_index = 7, .children_len = 1, .end_of_word = false }, // bf
    .invalid, // bg
    .invalid, // bh
    .{ .number = 23, .child_index = 275, .children_len = 1, .end_of_word = false }, // bi
    .invalid, // bj
    .{ .number = 36, .child_index = 276, .children_len = 1, .end_of_word = false }, // bk
    .{ .number = 37, .child_index = 277, .children_len = 3, .end_of_word = false }, // bl
    .invalid, // bm
    .{ .number = 48, .child_index = 280, .children_len = 2, .end_of_word = false }, // bn
    .{ .number = 51, .child_index = 282, .children_len = 4, .end_of_word = false }, // bo
    .{ .number = 99, .child_index = 286, .children_len = 1, .end_of_word = false }, // bp
    .invalid, // bq
    .{ .number = 100, .child_index = 287, .children_len = 2, .end_of_word = false }, // br
    .{ .number = 103, .child_index = 289, .children_len = 4, .end_of_word = false }, // bs
    .invalid, // bt
    .{ .number = 110, .child_index = 293, .children_len = 2, .end_of_word = false }, // bu
    .invalid, // bv
    .invalid, // bw
    .invalid, // bx
    .invalid, // by
    .invalid, // bz
    .invalid, // cA
    .invalid, // cB
    .invalid, // cC
    .invalid, // cD
    .invalid, // cE
    .invalid, // cF
    .invalid, // cG
    .invalid, // cH
    .invalid, // cI
    .invalid, // cJ
    .invalid, // cK
    .invalid, // cL
    .invalid, // cM
    .invalid, // cN
    .invalid, // cO
    .invalid, // cP
    .invalid, // cQ
    .invalid, // cR
    .invalid, // cS
    .invalid, // cT
    .invalid, // cU
    .invalid, // cV
    .invalid, // cW
    .invalid, // cX
    .invalid, // cY
    .invalid, // cZ
    .{ .number = 0, .child_index = 295, .children_len = 3, .end_of_word = false }, // ca
    .invalid, // cb
    .{ .number = 10, .child_index = 298, .children_len = 4, .end_of_word = false }, // cc
    .{ .number = 17, .child_index = 39, .children_len = 1, .end_of_word = false }, // cd
    .{ .number = 18, .child_index = 302, .children_len = 3, .end_of_word = false }, // ce
    .{ .number = 24, .child_index = 7, .children_len = 1, .end_of_word = false }, // cf
    .invalid, // cg
    .{ .number = 25, .child_index = 305, .children_len = 3, .end_of_word = false }, // ch
    .{ .number = 29, .child_index = 308, .children_len = 1, .end_of_word = false }, // ci
    .invalid, // cj
    .invalid, // ck
    .{ .number = 44, .child_index = 309, .children_len = 1, .end_of_word = false }, // cl
    .invalid, // cm
    .invalid, // cn
    .{ .number = 46, .child_index = 310, .children_len = 4, .end_of_word = false }, // co
    .invalid, // cp
    .invalid, // cq
    .{ .number = 63, .child_index = 314, .children_len = 2, .end_of_word = false }, // cr
    .{ .number = 65, .child_index = 316, .children_len = 2, .end_of_word = false }, // cs
    .{ .number = 70, .child_index = 318, .children_len = 1, .end_of_word = false }, // ct
    .{ .number = 71, .child_index = 319, .children_len = 7, .end_of_word = false }, // cu
    .invalid, // cv
    .{ .number = 96, .child_index = 262, .children_len = 2, .end_of_word = false }, // cw
    .invalid, // cx
    .{ .number = 98, .child_index = 326, .children_len = 1, .end_of_word = false }, // cy
    .invalid, // cz
    .{ .number = 0, .child_index = 327, .children_len = 1, .end_of_word = false }, // dA
    .invalid, // dB
    .invalid, // dC
    .invalid, // dD
    .invalid, // dE
    .invalid, // dF
    .invalid, // dG
    .{ .number = 1, .child_index = 200, .children_len = 1, .end_of_word = false }, // dH
    .invalid, // dI
    .invalid, // dJ
    .invalid, // dK
    .invalid, // dL
    .invalid, // dM
    .invalid, // dN
    .invalid, // dO
    .invalid, // dP
    .invalid, // dQ
    .invalid, // dR
    .invalid, // dS
    .invalid, // dT
    .invalid, // dU
    .invalid, // dV
    .invalid, // dW
    .invalid, // dX
    .invalid, // dY
    .invalid, // dZ
    .{ .number = 2, .child_index = 328, .children_len = 4, .end_of_word = false }, // da
    .{ .number = 7, .child_index = 332, .children_len = 2, .end_of_word = false }, // db
    .{ .number = 9, .child_index = 56, .children_len = 2, .end_of_word = false }, // dc
    .{ .number = 11, .child_index = 334, .children_len = 3, .end_of_word = false }, // dd
    .{ .number = 15, .child_index = 337, .children_len = 3, .end_of_word = false }, // de
    .{ .number = 19, .child_index = 340, .children_len = 2, .end_of_word = false }, // df
    .invalid, // dg
    .{ .number = 21, .child_index = 342, .children_len = 1, .end_of_word = false }, // dh
    .{ .number = 23, .child_index = 343, .children_len = 5, .end_of_word = false }, // di
    .{ .number = 35, .child_index = 30, .children_len = 1, .end_of_word = false }, // dj
    .invalid, // dk
    .{ .number = 36, .child_index = 348, .children_len = 1, .end_of_word = false }, // dl
    .invalid, // dm
    .invalid, // dn
    .{ .number = 38, .child_index = 349, .children_len = 5, .end_of_word = false }, // do
    .invalid, // dp
    .invalid, // dq
    .{ .number = 51, .child_index = 354, .children_len = 2, .end_of_word = false }, // dr
    .{ .number = 54, .child_index = 356, .children_len = 3, .end_of_word = false }, // ds
    .{ .number = 58, .child_index = 359, .children_len = 2, .end_of_word = false }, // dt
    .{ .number = 61, .child_index = 361, .children_len = 2, .end_of_word = false }, // du
    .invalid, // dv
    .{ .number = 63, .child_index = 363, .children_len = 1, .end_of_word = false }, // dw
    .invalid, // dx
    .invalid, // dy
    .{ .number = 64, .child_index = 364, .children_len = 2, .end_of_word = false }, // dz
    .invalid, // eA
    .invalid, // eB
    .invalid, // eC
    .{ .number = 0, .child_index = 366, .children_len = 2, .end_of_word = false }, // eD
    .invalid, // eE
    .invalid, // eF
    .invalid, // eG
    .invalid, // eH
    .invalid, // eI
    .invalid, // eJ
    .invalid, // eK
    .invalid, // eL
    .invalid, // eM
    .invalid, // eN
    .invalid, // eO
    .invalid, // eP
    .invalid, // eQ
    .invalid, // eR
    .invalid, // eS
    .invalid, // eT
    .invalid, // eU
    .invalid, // eV
    .invalid, // eW
    .invalid, // eX
    .invalid, // eY
    .invalid, // eZ
    .{ .number = 2, .child_index = 368, .children_len = 2, .end_of_word = false }, // ea
    .invalid, // eb
    .{ .number = 5, .child_index = 370, .children_len = 4, .end_of_word = false }, // ec
    .{ .number = 11, .child_index = 39, .children_len = 1, .end_of_word = false }, // ed
    .{ .number = 12, .child_index = 91, .children_len = 1, .end_of_word = false }, // ee
    .{ .number = 13, .child_index = 374, .children_len = 2, .end_of_word = false }, // ef
    .{ .number = 15, .child_index = 376, .children_len = 3, .end_of_word = false }, // eg
    .invalid, // eh
    .invalid, // ei
    .invalid, // ej
    .invalid, // ek
    .{ .number = 20, .child_index = 379, .children_len = 4, .end_of_word = false }, // el
    .{ .number = 25, .child_index = 383, .children_len = 3, .end_of_word = false }, // em
    .{ .number = 32, .child_index = 386, .children_len = 2, .end_of_word = false }, // en
    .{ .number = 34, .child_index = 12, .children_len = 2, .end_of_word = false }, // eo
    .{ .number = 36, .child_index = 388, .children_len = 3, .end_of_word = false }, // ep
    .{ .number = 42, .child_index = 391, .children_len = 4, .end_of_word = false }, // eq
    .{ .number = 52, .child_index = 395, .children_len = 2, .end_of_word = false }, // er
    .{ .number = 54, .child_index = 397, .children_len = 3, .end_of_word = false }, // es
    .{ .number = 57, .child_index = 400, .children_len = 2, .end_of_word = false }, // et
    .{ .number = 60, .child_index = 402, .children_len = 2, .end_of_word = false }, // eu
    .invalid, // ev
    .invalid, // ew
    .{ .number = 63, .child_index = 404, .children_len = 3, .end_of_word = false }, // ex
    .invalid, // ey
    .invalid, // ez
    .invalid, // fA
    .invalid, // fB
    .invalid, // fC
    .invalid, // fD
    .invalid, // fE
    .invalid, // fF
    .invalid, // fG
    .invalid, // fH
    .invalid, // fI
    .invalid, // fJ
    .invalid, // fK
    .invalid, // fL
    .invalid, // fM
    .invalid, // fN
    .invalid, // fO
    .invalid, // fP
    .invalid, // fQ
    .invalid, // fR
    .invalid, // fS
    .invalid, // fT
    .invalid, // fU
    .invalid, // fV
    .invalid, // fW
    .invalid, // fX
    .invalid, // fY
    .invalid, // fZ
    .{ .number = 0, .child_index = 407, .children_len = 1, .end_of_word = false }, // fa
    .invalid, // fb
    .{ .number = 1, .child_index = 22, .children_len = 1, .end_of_word = false }, // fc
    .invalid, // fd
    .{ .number = 2, .child_index = 408, .children_len = 1, .end_of_word = false }, // fe
    .{ .number = 3, .child_index = 409, .children_len = 3, .end_of_word = false }, // ff
    .invalid, // fg
    .invalid, // fh
    .{ .number = 7, .child_index = 101, .children_len = 1, .end_of_word = false }, // fi
    .{ .number = 8, .child_index = 101, .children_len = 1, .end_of_word = false }, // fj
    .invalid, // fk
    .{ .number = 9, .child_index = 412, .children_len = 3, .end_of_word = false }, // fl
    .invalid, // fm
    .{ .number = 12, .child_index = 415, .children_len = 1, .end_of_word = false }, // fn
    .{ .number = 13, .child_index = 416, .children_len = 2, .end_of_word = false }, // fo
    .{ .number = 17, .child_index = 418, .children_len = 1, .end_of_word = false }, // fp
    .invalid, // fq
    .{ .number = 18, .child_index = 419, .children_len = 2, .end_of_word = false }, // fr
    .{ .number = 38, .child_index = 28, .children_len = 1, .end_of_word = false }, // fs
    .invalid, // ft
    .invalid, // fu
    .invalid, // fv
    .invalid, // fw
    .invalid, // fx
    .invalid, // fy
    .invalid, // fz
    .invalid, // gA
    .invalid, // gB
    .invalid, // gC
    .invalid, // gD
    .{ .number = 0, .child_index = 421, .children_len = 2, .end_of_word = false }, // gE
    .invalid, // gF
    .invalid, // gG
    .invalid, // gH
    .invalid, // gI
    .invalid, // gJ
    .invalid, // gK
    .invalid, // gL
    .invalid, // gM
    .invalid, // gN
    .invalid, // gO
    .invalid, // gP
    .invalid, // gQ
    .invalid, // gR
    .invalid, // gS
    .invalid, // gT
    .invalid, // gU
    .invalid, // gV
    .invalid, // gW
    .invalid, // gX
    .invalid, // gY
    .invalid, // gZ
    .{ .number = 2, .child_index = 423, .children_len = 3, .end_of_word = false }, // ga
    .{ .number = 6, .child_index = 4, .children_len = 1, .end_of_word = false }, // gb
    .{ .number = 7, .child_index = 113, .children_len = 2, .end_of_word = false }, // gc
    .{ .number = 9, .child_index = 39, .children_len = 1, .end_of_word = false }, // gd
    .{ .number = 10, .child_index = 426, .children_len = 4, .end_of_word = false }, // ge
    .{ .number = 22, .child_index = 7, .children_len = 1, .end_of_word = false }, // gf
    .{ .number = 23, .child_index = 430, .children_len = 2, .end_of_word = false }, // gg
    .invalid, // gh
    .{ .number = 25, .child_index = 432, .children_len = 1, .end_of_word = false }, // gi
    .{ .number = 26, .child_index = 30, .children_len = 1, .end_of_word = false }, // gj
    .invalid, // gk
    .{ .number = 27, .child_index = 433, .children_len = 4, .end_of_word = false }, // gl
    .invalid, // gm
    .{ .number = 31, .child_index = 437, .children_len = 4, .end_of_word = false }, // gn
    .{ .number = 38, .child_index = 26, .children_len = 1, .end_of_word = false }, // go
    .invalid, // gp
    .invalid, // gq
    .{ .number = 39, .child_index = 441, .children_len = 1, .end_of_word = false }, // gr
    .{ .number = 40, .child_index = 442, .children_len = 2, .end_of_word = false }, // gs
    .{ .number = 44, .child_index = 444, .children_len = 6, .end_of_word = true }, // gt
    .invalid, // gu
    .{ .number = 58, .child_index = 450, .children_len = 2, .end_of_word = false }, // gv
    .invalid, // gw
    .invalid, // gx
    .invalid, // gy
    .invalid, // gz
    .{ .number = 0, .child_index = 327, .children_len = 1, .end_of_word = false }, // hA
    .invalid, // hB
    .invalid, // hC
    .invalid, // hD
    .invalid, // hE
    .invalid, // hF
    .invalid, // hG
    .invalid, // hH
    .invalid, // hI
    .invalid, // hJ
    .invalid, // hK
    .invalid, // hL
    .invalid, // hM
    .invalid, // hN
    .invalid, // hO
    .invalid, // hP
    .invalid, // hQ
    .invalid, // hR
    .invalid, // hS
    .invalid, // hT
    .invalid, // hU
    .invalid, // hV
    .invalid, // hW
    .invalid, // hX
    .invalid, // hY
    .invalid, // hZ
    .{ .number = 1, .child_index = 452, .children_len = 4, .end_of_word = false }, // ha
    .{ .number = 8, .child_index = 200, .children_len = 1, .end_of_word = false }, // hb
    .{ .number = 9, .child_index = 96, .children_len = 1, .end_of_word = false }, // hc
    .invalid, // hd
    .{ .number = 10, .child_index = 456, .children_len = 3, .end_of_word = false }, // he
    .{ .number = 14, .child_index = 7, .children_len = 1, .end_of_word = false }, // hf
    .invalid, // hg
    .invalid, // hh
    .invalid, // hi
    .invalid, // hj
    .{ .number = 15, .child_index = 459, .children_len = 1, .end_of_word = false }, // hk
    .invalid, // hl
    .invalid, // hm
    .invalid, // hn
    .{ .number = 17, .child_index = 460, .children_len = 5, .end_of_word = false }, // ho
    .invalid, // hp
    .invalid, // hq
    .invalid, // hr
    .{ .number = 23, .child_index = 465, .children_len = 3, .end_of_word = false }, // hs
    .invalid, // ht
    .invalid, // hu
    .invalid, // hv
    .invalid, // hw
    .invalid, // hx
    .{ .number = 26, .child_index = 468, .children_len = 2, .end_of_word = false }, // hy
    .invalid, // hz
    .invalid, // iA
    .invalid, // iB
    .invalid, // iC
    .invalid, // iD
    .invalid, // iE
    .invalid, // iF
    .invalid, // iG
    .invalid, // iH
    .invalid, // iI
    .invalid, // iJ
    .invalid, // iK
    .invalid, // iL
    .invalid, // iM
    .invalid, // iN
    .invalid, // iO
    .invalid, // iP
    .invalid, // iQ
    .invalid, // iR
    .invalid, // iS
    .invalid, // iT
    .invalid, // iU
    .invalid, // iV
    .invalid, // iW
    .invalid, // iX
    .invalid, // iY
    .invalid, // iZ
    .{ .number = 0, .child_index = 3, .children_len = 1, .end_of_word = false }, // ia
    .invalid, // ib
    .{ .number = 2, .child_index = 470, .children_len = 3, .end_of_word = false }, // ic
    .invalid, // id
    .{ .number = 6, .child_index = 473, .children_len = 2, .end_of_word = false }, // ie
    .{ .number = 9, .child_index = 475, .children_len = 2, .end_of_word = false }, // if
    .{ .number = 11, .child_index = 8, .children_len = 1, .end_of_word = false }, // ig
    .invalid, // ih
    .{ .number = 13, .child_index = 477, .children_len = 4, .end_of_word = false }, // ii
    .{ .number = 18, .child_index = 101, .children_len = 1, .end_of_word = false }, // ij
    .invalid, // ik
    .invalid, // il
    .{ .number = 19, .child_index = 481, .children_len = 3, .end_of_word = false }, // im
    .{ .number = 26, .child_index = 484, .children_len = 5, .end_of_word = false }, // in
    .{ .number = 37, .child_index = 489, .children_len = 4, .end_of_word = false }, // io
    .{ .number = 41, .child_index = 493, .children_len = 1, .end_of_word = false }, // ip
    .{ .number = 42, .child_index = 494, .children_len = 1, .end_of_word = false }, // iq
    .invalid, // ir
    .{ .number = 44, .child_index = 495, .children_len = 2, .end_of_word = false }, // is
    .{ .number = 51, .child_index = 497, .children_len = 2, .end_of_word = false }, // it
    .{ .number = 53, .child_index = 111, .children_len = 2, .end_of_word = false }, // iu
    .invalid, // iv
    .invalid, // iw
    .invalid, // ix
    .invalid, // iy
    .invalid, // iz
    .invalid, // jA
    .invalid, // jB
    .invalid, // jC
    .invalid, // jD
    .invalid, // jE
    .invalid, // jF
    .invalid, // jG
    .invalid, // jH
    .invalid, // jI
    .invalid, // jJ
    .invalid, // jK
    .invalid, // jL
    .invalid, // jM
    .invalid, // jN
    .invalid, // jO
    .invalid, // jP
    .invalid, // jQ
    .invalid, // jR
    .invalid, // jS
    .invalid, // jT
    .invalid, // jU
    .invalid, // jV
    .invalid, // jW
    .invalid, // jX
    .invalid, // jY
    .invalid, // jZ
    .invalid, // ja
    .invalid, // jb
    .{ .number = 0, .child_index = 113, .children_len = 2, .end_of_word = false }, // jc
    .invalid, // jd
    .invalid, // je
    .{ .number = 2, .child_index = 7, .children_len = 1, .end_of_word = false }, // jf
    .invalid, // jg
    .invalid, // jh
    .invalid, // ji
    .invalid, // jj
    .invalid, // jk
    .invalid, // jl
    .{ .number = 3, .child_index = 499, .children_len = 1, .end_of_word = false }, // jm
    .invalid, // jn
    .{ .number = 4, .child_index = 26, .children_len = 1, .end_of_word = false }, // jo
    .invalid, // jp
    .invalid, // jq
    .invalid, // jr
    .{ .number = 5, .child_index = 115, .children_len = 2, .end_of_word = false }, // js
    .invalid, // jt
    .{ .number = 7, .child_index = 117, .children_len = 1, .end_of_word = false }, // ju
    .invalid, // jv
    .invalid, // jw
    .invalid, // jx
    .invalid, // jy
    .invalid, // jz
    .invalid, // kA
    .invalid, // kB
    .invalid, // kC
    .invalid, // kD
    .invalid, // kE
    .invalid, // kF
    .invalid, // kG
    .invalid, // kH
    .invalid, // kI
    .invalid, // kJ
    .invalid, // kK
    .invalid, // kL
    .invalid, // kM
    .invalid, // kN
    .invalid, // kO
    .invalid, // kP
    .invalid, // kQ
    .invalid, // kR
    .invalid, // kS
    .invalid, // kT
    .invalid, // kU
    .invalid, // kV
    .invalid, // kW
    .invalid, // kX
    .invalid, // kY
    .invalid, // kZ
    .{ .number = 0, .child_index = 500, .children_len = 1, .end_of_word = false }, // ka
    .invalid, // kb
    .{ .number = 2, .child_index = 119, .children_len = 2, .end_of_word = false }, // kc
    .invalid, // kd
    .invalid, // ke
    .{ .number = 4, .child_index = 7, .children_len = 1, .end_of_word = false }, // kf
    .{ .number = 5, .child_index = 501, .children_len = 1, .end_of_word = false }, // kg
    .{ .number = 6, .child_index = 30, .children_len = 1, .end_of_word = false }, // kh
    .invalid, // ki
    .{ .number = 7, .child_index = 30, .children_len = 1, .end_of_word = false }, // kj
    .invalid, // kk
    .invalid, // kl
    .invalid, // km
    .invalid, // kn
    .{ .number = 8, .child_index = 26, .children_len = 1, .end_of_word = false }, // ko
    .invalid, // kp
    .invalid, // kq
    .invalid, // kr
    .{ .number = 9, .child_index = 28, .children_len = 1, .end_of_word = false }, // ks
    .invalid, // kt
    .invalid, // ku
    .invalid, // kv
    .invalid, // kw
    .invalid, // kx
    .invalid, // ky
    .invalid, // kz
    .{ .number = 0, .child_index = 502, .children_len = 3, .end_of_word = false }, // lA
    .{ .number = 3, .child_index = 172, .children_len = 1, .end_of_word = false }, // lB
    .invalid, // lC
    .invalid, // lD
    .{ .number = 4, .child_index = 430, .children_len = 2, .end_of_word = false }, // lE
    .invalid, // lF
    .invalid, // lG
    .{ .number = 6, .child_index = 200, .children_len = 1, .end_of_word = false }, // lH
    .invalid, // lI
    .invalid, // lJ
    .invalid, // lK
    .invalid, // lL
    .invalid, // lM
    .invalid, // lN
    .invalid, // lO
    .invalid, // lP
    .invalid, // lQ
    .invalid, // lR
    .invalid, // lS
    .invalid, // lT
    .invalid, // lU
    .invalid, // lV
    .invalid, // lW
    .invalid, // lX
    .invalid, // lY
    .invalid, // lZ
    .{ .number = 7, .child_index = 505, .children_len = 9, .end_of_word = false }, // la
    .{ .number = 30, .child_index = 514, .children_len = 3, .end_of_word = false }, // lb
    .{ .number = 37, .child_index = 517, .children_len = 4, .end_of_word = false }, // lc
    .{ .number = 42, .child_index = 521, .children_len = 4, .end_of_word = false }, // ld
    .{ .number = 48, .child_index = 525, .children_len = 5, .end_of_word = false }, // le
    .{ .number = 76, .child_index = 530, .children_len = 3, .end_of_word = false }, // lf
    .{ .number = 79, .child_index = 533, .children_len = 2, .end_of_word = false }, // lg
    .{ .number = 81, .child_index = 535, .children_len = 2, .end_of_word = false }, // lh
    .invalid, // li
    .{ .number = 85, .child_index = 30, .children_len = 1, .end_of_word = false }, // lj
    .invalid, // lk
    .{ .number = 86, .child_index = 537, .children_len = 5, .end_of_word = false }, // ll
    .{ .number = 91, .child_index = 542, .children_len = 2, .end_of_word = false }, // lm
    .{ .number = 94, .child_index = 437, .children_len = 4, .end_of_word = false }, // ln
    .{ .number = 101, .child_index = 544, .children_len = 8, .end_of_word = false }, // lo
    .{ .number = 119, .child_index = 552, .children_len = 1, .end_of_word = false }, // lp
    .invalid, // lq
    .{ .number = 121, .child_index = 553, .children_len = 5, .end_of_word = false }, // lr
    .{ .number = 127, .child_index = 558, .children_len = 6, .end_of_word = false }, // ls
    .{ .number = 137, .child_index = 564, .children_len = 8, .end_of_word = true }, // lt
    .{ .number = 150, .child_index = 572, .children_len = 1, .end_of_word = false }, // lu
    .{ .number = 152, .child_index = 450, .children_len = 2, .end_of_word = false }, // lv
    .invalid, // lw
    .invalid, // lx
    .invalid, // ly
    .invalid, // lz
    .invalid, // mA
    .invalid, // mB
    .invalid, // mC
    .{ .number = 0, .child_index = 573, .children_len = 1, .end_of_word = false }, // mD
    .invalid, // mE
    .invalid, // mF
    .invalid, // mG
    .invalid, // mH
    .invalid, // mI
    .invalid, // mJ
    .invalid, // mK
    .invalid, // mL
    .invalid, // mM
    .invalid, // mN
    .invalid, // mO
    .invalid, // mP
    .invalid, // mQ
    .invalid, // mR
    .invalid, // mS
    .invalid, // mT
    .invalid, // mU
    .invalid, // mV
    .invalid, // mW
    .invalid, // mX
    .invalid, // mY
    .invalid, // mZ
    .{ .number = 1, .child_index = 574, .children_len = 4, .end_of_word = false }, // ma
    .invalid, // mb
    .{ .number = 12, .child_index = 578, .children_len = 2, .end_of_word = false }, // mc
    .{ .number = 14, .child_index = 229, .children_len = 1, .end_of_word = false }, // md
    .{ .number = 15, .child_index = 580, .children_len = 1, .end_of_word = false }, // me
    .{ .number = 16, .child_index = 7, .children_len = 1, .end_of_word = false }, // mf
    .invalid, // mg
    .{ .number = 17, .child_index = 179, .children_len = 1, .end_of_word = false }, // mh
    .{ .number = 18, .child_index = 581, .children_len = 3, .end_of_word = false }, // mi
    .invalid, // mj
    .invalid, // mk
    .{ .number = 29, .child_index = 584, .children_len = 2, .end_of_word = false }, // ml
    .invalid, // mm
    .{ .number = 31, .child_index = 586, .children_len = 1, .end_of_word = false }, // mn
    .{ .number = 32, .child_index = 587, .children_len = 2, .end_of_word = false }, // mo
    .{ .number = 34, .child_index = 91, .children_len = 1, .end_of_word = false }, // mp
    .invalid, // mq
    .invalid, // mr
    .{ .number = 35, .child_index = 589, .children_len = 2, .end_of_word = false }, // ms
    .invalid, // mt
    .{ .number = 37, .child_index = 591, .children_len = 3, .end_of_word = false }, // mu
    .invalid, // mv
    .invalid, // mw
    .invalid, // mx
    .invalid, // my
    .invalid, // mz
    .invalid, // nA
    .invalid, // nB
    .invalid, // nC
    .invalid, // nD
    .invalid, // nE
    .invalid, // nF
    .{ .number = 0, .child_index = 594, .children_len = 2, .end_of_word = false }, // nG
    .invalid, // nH
    .invalid, // nI
    .invalid, // nJ
    .invalid, // nK
    .{ .number = 3, .child_index = 596, .children_len = 3, .end_of_word = false }, // nL
    .invalid, // nM
    .invalid, // nN
    .invalid, // nO
    .invalid, // nP
    .invalid, // nQ
    .{ .number = 8, .child_index = 183, .children_len = 1, .end_of_word = false }, // nR
    .invalid, // nS
    .invalid, // nT
    .invalid, // nU
    .{ .number = 9, .child_index = 599, .children_len = 2, .end_of_word = false }, // nV
    .invalid, // nW
    .invalid, // nX
    .invalid, // nY
    .invalid, // nZ
    .{ .number = 11, .child_index = 601, .children_len = 5, .end_of_word = false }, // na
    .{ .number = 22, .child_index = 606, .children_len = 2, .end_of_word = false }, // nb
    .{ .number = 26, .child_index = 608, .children_len = 5, .end_of_word = false }, // nc
    .{ .number = 33, .child_index = 229, .children_len = 1, .end_of_word = false }, // nd
    .{ .number = 34, .child_index = 613, .children_len = 7, .end_of_word = false }, // ne
    .{ .number = 45, .child_index = 7, .children_len = 1, .end_of_word = false }, // nf
    .{ .number = 46, .child_index = 620, .children_len = 4, .end_of_word = false }, // ng
    .{ .number = 55, .child_index = 624, .children_len = 3, .end_of_word = false }, // nh
    .{ .number = 58, .child_index = 627, .children_len = 3, .end_of_word = false }, // ni
    .{ .number = 62, .child_index = 30, .children_len = 1, .end_of_word = false }, // nj
    .invalid, // nk
    .{ .number = 63, .child_index = 630, .children_len = 7, .end_of_word = false }, // nl
    .{ .number = 79, .child_index = 637, .children_len = 1, .end_of_word = false }, // nm
    .invalid, // nn
    .{ .number = 80, .child_index = 638, .children_len = 2, .end_of_word = false }, // no
    .{ .number = 93, .child_index = 640, .children_len = 3, .end_of_word = false }, // np
    .invalid, // nq
    .{ .number = 103, .child_index = 643, .children_len = 4, .end_of_word = false }, // nr
    .{ .number = 110, .child_index = 647, .children_len = 7, .end_of_word = false }, // ns
    .{ .number = 137, .child_index = 654, .children_len = 4, .end_of_word = false }, // nt
    .{ .number = 145, .child_index = 658, .children_len = 2, .end_of_word = false }, // nu
    .{ .number = 149, .child_index = 660, .children_len = 9, .end_of_word = false }, // nv
    .{ .number = 163, .child_index = 669, .children_len = 3, .end_of_word = false }, // nw
    .invalid, // nx
    .invalid, // ny
    .invalid, // nz
    .invalid, // oA
    .invalid, // oB
    .invalid, // oC
    .invalid, // oD
    .invalid, // oE
    .invalid, // oF
    .invalid, // oG
    .invalid, // oH
    .invalid, // oI
    .invalid, // oJ
    .invalid, // oK
    .invalid, // oL
    .invalid, // oM
    .invalid, // oN
    .invalid, // oO
    .invalid, // oP
    .invalid, // oQ
    .invalid, // oR
    .{ .number = 0, .child_index = 91, .children_len = 1, .end_of_word = false }, // oS
    .invalid, // oT
    .invalid, // oU
    .invalid, // oV
    .invalid, // oW
    .invalid, // oX
    .invalid, // oY
    .invalid, // oZ
    .{ .number = 1, .child_index = 672, .children_len = 2, .end_of_word = false }, // oa
    .invalid, // ob
    .{ .number = 4, .child_index = 674, .children_len = 2, .end_of_word = false }, // oc
    .{ .number = 8, .child_index = 676, .children_len = 5, .end_of_word = false }, // od
    .{ .number = 13, .child_index = 101, .children_len = 1, .end_of_word = false }, // oe
    .{ .number = 14, .child_index = 681, .children_len = 2, .end_of_word = false }, // of
    .{ .number = 16, .child_index = 683, .children_len = 3, .end_of_word = false }, // og
    .{ .number = 20, .child_index = 686, .children_len = 2, .end_of_word = false }, // oh
    .{ .number = 22, .child_index = 688, .children_len = 1, .end_of_word = false }, // oi
    .invalid, // oj
    .invalid, // ok
    .{ .number = 23, .child_index = 689, .children_len = 4, .end_of_word = false }, // ol
    .{ .number = 28, .child_index = 693, .children_len = 3, .end_of_word = false }, // om
    .invalid, // on
    .{ .number = 33, .child_index = 26, .children_len = 1, .end_of_word = false }, // oo
    .{ .number = 34, .child_index = 696, .children_len = 3, .end_of_word = false }, // op
    .invalid, // oq
    .{ .number = 37, .child_index = 699, .children_len = 7, .end_of_word = false }, // or
    .{ .number = 50, .child_index = 706, .children_len = 3, .end_of_word = false }, // os
    .{ .number = 54, .child_index = 709, .children_len = 1, .end_of_word = false }, // ot
    .{ .number = 58, .child_index = 19, .children_len = 1, .end_of_word = false }, // ou
    .{ .number = 60, .child_index = 710, .children_len = 1, .end_of_word = false }, // ov
    .invalid, // ow
    .invalid, // ox
    .invalid, // oy
    .invalid, // oz
    .invalid, // pA
    .invalid, // pB
    .invalid, // pC
    .invalid, // pD
    .invalid, // pE
    .invalid, // pF
    .invalid, // pG
    .invalid, // pH
    .invalid, // pI
    .invalid, // pJ
    .invalid, // pK
    .invalid, // pL
    .invalid, // pM
    .invalid, // pN
    .invalid, // pO
    .invalid, // pP
    .invalid, // pQ
    .invalid, // pR
    .invalid, // pS
    .invalid, // pT
    .invalid, // pU
    .invalid, // pV
    .invalid, // pW
    .invalid, // pX
    .invalid, // pY
    .invalid, // pZ
    .{ .number = 0, .child_index = 711, .children_len = 1, .end_of_word = false }, // pa
    .invalid, // pb
    .{ .number = 7, .child_index = 22, .children_len = 1, .end_of_word = false }, // pc
    .invalid, // pd
    .{ .number = 8, .child_index = 712, .children_len = 1, .end_of_word = false }, // pe
    .{ .number = 13, .child_index = 7, .children_len = 1, .end_of_word = false }, // pf
    .invalid, // pg
    .{ .number = 14, .child_index = 713, .children_len = 3, .end_of_word = false }, // ph
    .{ .number = 18, .child_index = 716, .children_len = 3, .end_of_word = false }, // pi
    .invalid, // pj
    .invalid, // pk
    .{ .number = 21, .child_index = 719, .children_len = 2, .end_of_word = false }, // pl
    .{ .number = 35, .child_index = 91, .children_len = 1, .end_of_word = false }, // pm
    .invalid, // pn
    .{ .number = 36, .child_index = 721, .children_len = 3, .end_of_word = false }, // po
    .invalid, // pp
    .invalid, // pq
    .{ .number = 40, .child_index = 724, .children_len = 10, .end_of_word = false }, // pr
    .{ .number = 66, .child_index = 169, .children_len = 2, .end_of_word = false }, // ps
    .invalid, // pt
    .{ .number = 68, .child_index = 734, .children_len = 1, .end_of_word = false }, // pu
    .invalid, // pv
    .invalid, // pw
    .invalid, // px
    .invalid, // py
    .invalid, // pz
    .invalid, // qA
    .invalid, // qB
    .invalid, // qC
    .invalid, // qD
    .invalid, // qE
    .invalid, // qF
    .invalid, // qG
    .invalid, // qH
    .invalid, // qI
    .invalid, // qJ
    .invalid, // qK
    .invalid, // qL
    .invalid, // qM
    .invalid, // qN
    .invalid, // qO
    .invalid, // qP
    .invalid, // qQ
    .invalid, // qR
    .invalid, // qS
    .invalid, // qT
    .invalid, // qU
    .invalid, // qV
    .invalid, // qW
    .invalid, // qX
    .invalid, // qY
    .invalid, // qZ
    .invalid, // qa
    .invalid, // qb
    .invalid, // qc
    .invalid, // qd
    .invalid, // qe
    .{ .number = 0, .child_index = 7, .children_len = 1, .end_of_word = false }, // qf
    .invalid, // qg
    .invalid, // qh
    .{ .number = 1, .child_index = 688, .children_len = 1, .end_of_word = false }, // qi
    .invalid, // qj
    .invalid, // qk
    .invalid, // ql
    .invalid, // qm
    .invalid, // qn
    .{ .number = 2, .child_index = 26, .children_len = 1, .end_of_word = false }, // qo
    .{ .number = 3, .child_index = 286, .children_len = 1, .end_of_word = false }, // qp
    .invalid, // qq
    .invalid, // qr
    .{ .number = 4, .child_index = 28, .children_len = 1, .end_of_word = false }, // qs
    .invalid, // qt
    .{ .number = 5, .child_index = 735, .children_len = 3, .end_of_word = false }, // qu
    .invalid, // qv
    .invalid, // qw
    .invalid, // qx
    .invalid, // qy
    .invalid, // qz
    .{ .number = 0, .child_index = 502, .children_len = 3, .end_of_word = false }, // rA
    .{ .number = 3, .child_index = 172, .children_len = 1, .end_of_word = false }, // rB
    .invalid, // rC
    .invalid, // rD
    .invalid, // rE
    .invalid, // rF
    .invalid, // rG
    .{ .number = 4, .child_index = 200, .children_len = 1, .end_of_word = false }, // rH
    .invalid, // rI
    .invalid, // rJ
    .invalid, // rK
    .invalid, // rL
    .invalid, // rM
    .invalid, // rN
    .invalid, // rO
    .invalid, // rP
    .invalid, // rQ
    .invalid, // rR
    .invalid, // rS
    .invalid, // rT
    .invalid, // rU
    .invalid, // rV
    .invalid, // rW
    .invalid, // rX
    .invalid, // rY
    .invalid, // rZ
    .{ .number = 5, .child_index = 738, .children_len = 7, .end_of_word = false }, // ra
    .{ .number = 30, .child_index = 514, .children_len = 3, .end_of_word = false }, // rb
    .{ .number = 37, .child_index = 517, .children_len = 4, .end_of_word = false }, // rc
    .{ .number = 42, .child_index = 745, .children_len = 4, .end_of_word = false }, // rd
    .{ .number = 47, .child_index = 749, .children_len = 3, .end_of_word = false }, // re
    .{ .number = 54, .child_index = 530, .children_len = 3, .end_of_word = false }, // rf
    .invalid, // rg
    .{ .number = 57, .child_index = 752, .children_len = 2, .end_of_word = false }, // rh
    .{ .number = 62, .child_index = 754, .children_len = 3, .end_of_word = false }, // ri
    .invalid, // rj
    .invalid, // rk
    .{ .number = 73, .child_index = 757, .children_len = 3, .end_of_word = false }, // rl
    .{ .number = 76, .child_index = 760, .children_len = 1, .end_of_word = false }, // rm
    .{ .number = 78, .child_index = 761, .children_len = 1, .end_of_word = false }, // rn
    .{ .number = 79, .child_index = 762, .children_len = 4, .end_of_word = false }, // ro
    .{ .number = 86, .child_index = 766, .children_len = 2, .end_of_word = false }, // rp
    .invalid, // rq
    .{ .number = 89, .child_index = 172, .children_len = 1, .end_of_word = false }, // rr
    .{ .number = 90, .child_index = 768, .children_len = 4, .end_of_word = false }, // rs
    .{ .number = 96, .child_index = 772, .children_len = 3, .end_of_word = false }, // rt
    .{ .number = 102, .child_index = 775, .children_len = 1, .end_of_word = false }, // ru
    .invalid, // rv
    .invalid, // rw
    .{ .number = 103, .child_index = 91, .children_len = 1, .end_of_word = false }, // rx
    .invalid, // ry
    .invalid, // rz
    .invalid, // sA
    .invalid, // sB
    .invalid, // sC
    .invalid, // sD
    .invalid, // sE
    .invalid, // sF
    .invalid, // sG
    .invalid, // sH
    .invalid, // sI
    .invalid, // sJ
    .invalid, // sK
    .invalid, // sL
    .invalid, // sM
    .invalid, // sN
    .invalid, // sO
    .invalid, // sP
    .invalid, // sQ
    .invalid, // sR
    .invalid, // sS
    .invalid, // sT
    .invalid, // sU
    .invalid, // sV
    .invalid, // sW
    .invalid, // sX
    .invalid, // sY
    .invalid, // sZ
    .{ .number = 0, .child_index = 144, .children_len = 1, .end_of_word = false }, // sa
    .{ .number = 1, .child_index = 269, .children_len = 1, .end_of_word = false }, // sb
    .{ .number = 2, .child_index = 776, .children_len = 10, .end_of_word = false }, // sc
    .{ .number = 16, .child_index = 786, .children_len = 1, .end_of_word = false }, // sd
    .{ .number = 19, .child_index = 787, .children_len = 7, .end_of_word = false }, // se
    .{ .number = 30, .child_index = 794, .children_len = 1, .end_of_word = false }, // sf
    .invalid, // sg
    .{ .number = 32, .child_index = 795, .children_len = 4, .end_of_word = false }, // sh
    .{ .number = 39, .child_index = 799, .children_len = 2, .end_of_word = false }, // si
    .invalid, // sj
    .invalid, // sk
    .{ .number = 53, .child_index = 172, .children_len = 1, .end_of_word = false }, // sl
    .{ .number = 54, .child_index = 801, .children_len = 4, .end_of_word = false }, // sm
    .invalid, // sn
    .{ .number = 62, .child_index = 805, .children_len = 3, .end_of_word = false }, // so
    .{ .number = 67, .child_index = 808, .children_len = 1, .end_of_word = false }, // sp
    .{ .number = 70, .child_index = 809, .children_len = 3, .end_of_word = false }, // sq
    .{ .number = 86, .child_index = 172, .children_len = 1, .end_of_word = false }, // sr
    .{ .number = 87, .child_index = 812, .children_len = 4, .end_of_word = false }, // ss
    .{ .number = 91, .child_index = 816, .children_len = 2, .end_of_word = false }, // st
    .{ .number = 96, .child_index = 818, .children_len = 5, .end_of_word = false }, // su
    .invalid, // sv
    .{ .number = 151, .child_index = 823, .children_len = 3, .end_of_word = false }, // sw
    .invalid, // sx
    .invalid, // sy
    .{ .number = 156, .child_index = 1, .children_len = 1, .end_of_word = false }, // sz
    .invalid, // tA
    .invalid, // tB
    .invalid, // tC
    .invalid, // tD
    .invalid, // tE
    .invalid, // tF
    .invalid, // tG
    .invalid, // tH
    .invalid, // tI
    .invalid, // tJ
    .invalid, // tK
    .invalid, // tL
    .invalid, // tM
    .invalid, // tN
    .invalid, // tO
    .invalid, // tP
    .invalid, // tQ
    .invalid, // tR
    .invalid, // tS
    .invalid, // tT
    .invalid, // tU
    .invalid, // tV
    .invalid, // tW
    .invalid, // tX
    .invalid, // tY
    .invalid, // tZ
    .{ .number = 0, .child_index = 826, .children_len = 2, .end_of_word = false }, // ta
    .{ .number = 2, .child_index = 828, .children_len = 1, .end_of_word = false }, // tb
    .{ .number = 3, .child_index = 126, .children_len = 3, .end_of_word = false }, // tc
    .{ .number = 6, .child_index = 39, .children_len = 1, .end_of_word = false }, // td
    .{ .number = 7, .child_index = 829, .children_len = 1, .end_of_word = false }, // te
    .{ .number = 8, .child_index = 7, .children_len = 1, .end_of_word = false }, // tf
    .invalid, // tg
    .{ .number = 9, .child_index = 830, .children_len = 4, .end_of_word = false }, // th
    .{ .number = 21, .child_index = 834, .children_len = 3, .end_of_word = false }, // ti
    .invalid, // tj
    .invalid, // tk
    .invalid, // tl
    .invalid, // tm
    .invalid, // tn
    .{ .number = 28, .child_index = 837, .children_len = 3, .end_of_word = false }, // to
    .{ .number = 35, .child_index = 286, .children_len = 1, .end_of_word = false }, // tp
    .invalid, // tq
    .{ .number = 36, .child_index = 840, .children_len = 3, .end_of_word = false }, // tr
    .{ .number = 51, .child_index = 843, .children_len = 3, .end_of_word = false }, // ts
    .invalid, // tt
    .invalid, // tu
    .invalid, // tv
    .{ .number = 55, .child_index = 846, .children_len = 2, .end_of_word = false }, // tw
    .invalid, // tx
    .invalid, // ty
    .invalid, // tz
    .{ .number = 0, .child_index = 327, .children_len = 1, .end_of_word = false }, // uA
    .invalid, // uB
    .invalid, // uC
    .invalid, // uD
    .invalid, // uE
    .invalid, // uF
    .invalid, // uG
    .{ .number = 1, .child_index = 200, .children_len = 1, .end_of_word = false }, // uH
    .invalid, // uI
    .invalid, // uJ
    .invalid, // uK
    .invalid, // uL
    .invalid, // uM
    .invalid, // uN
    .invalid, // uO
    .invalid, // uP
    .invalid, // uQ
    .invalid, // uR
    .invalid, // uS
    .invalid, // uT
    .invalid, // uU
    .invalid, // uV
    .invalid, // uW
    .invalid, // uX
    .invalid, // uY
    .invalid, // uZ
    .{ .number = 2, .child_index = 848, .children_len = 2, .end_of_word = false }, // ua
    .{ .number = 5, .child_index = 217, .children_len = 1, .end_of_word = false }, // ub
    .{ .number = 7, .child_index = 5, .children_len = 2, .end_of_word = false }, // uc
    .{ .number = 10, .child_index = 850, .children_len = 3, .end_of_word = false }, // ud
    .invalid, // ue
    .{ .number = 13, .child_index = 340, .children_len = 2, .end_of_word = false }, // uf
    .{ .number = 15, .child_index = 8, .children_len = 1, .end_of_word = false }, // ug
    .{ .number = 17, .child_index = 853, .children_len = 2, .end_of_word = false }, // uh
    .invalid, // ui
    .invalid, // uj
    .invalid, // uk
    .{ .number = 20, .child_index = 855, .children_len = 2, .end_of_word = false }, // ul
    .{ .number = 24, .child_index = 857, .children_len = 2, .end_of_word = false }, // um
    .invalid, // un
    .{ .number = 27, .child_index = 12, .children_len = 2, .end_of_word = false }, // uo
    .{ .number = 29, .child_index = 859, .children_len = 6, .end_of_word = false }, // up
    .invalid, // uq
    .{ .number = 38, .child_index = 865, .children_len = 3, .end_of_word = false }, // ur
    .{ .number = 43, .child_index = 28, .children_len = 1, .end_of_word = false }, // us
    .{ .number = 44, .child_index = 868, .children_len = 3, .end_of_word = false }, // ut
    .{ .number = 48, .child_index = 871, .children_len = 2, .end_of_word = false }, // uu
    .invalid, // uv
    .{ .number = 51, .child_index = 363, .children_len = 1, .end_of_word = false }, // uw
    .invalid, // ux
    .invalid, // uy
    .invalid, // uz
    .{ .number = 0, .child_index = 327, .children_len = 1, .end_of_word = false }, // vA
    .{ .number = 1, .child_index = 873, .children_len = 1, .end_of_word = false }, // vB
    .invalid, // vC
    .{ .number = 3, .child_index = 229, .children_len = 1, .end_of_word = false }, // vD
    .invalid, // vE
    .invalid, // vF
    .invalid, // vG
    .invalid, // vH
    .invalid, // vI
    .invalid, // vJ
    .invalid, // vK
    .invalid, // vL
    .invalid, // vM
    .invalid, // vN
    .invalid, // vO
    .invalid, // vP
    .invalid, // vQ
    .invalid, // vR
    .invalid, // vS
    .invalid, // vT
    .invalid, // vU
    .invalid, // vV
    .invalid, // vW
    .invalid, // vX
    .invalid, // vY
    .invalid, // vZ
    .{ .number = 4, .child_index = 874, .children_len = 2, .end_of_word = false }, // va
    .invalid, // vb
    .{ .number = 21, .child_index = 22, .children_len = 1, .end_of_word = false }, // vc
    .{ .number = 22, .child_index = 229, .children_len = 1, .end_of_word = false }, // vd
    .{ .number = 23, .child_index = 876, .children_len = 3, .end_of_word = false }, // ve
    .{ .number = 29, .child_index = 7, .children_len = 1, .end_of_word = false }, // vf
    .invalid, // vg
    .invalid, // vh
    .invalid, // vi
    .invalid, // vj
    .invalid, // vk
    .{ .number = 30, .child_index = 879, .children_len = 1, .end_of_word = false }, // vl
    .invalid, // vm
    .{ .number = 31, .child_index = 880, .children_len = 1, .end_of_word = false }, // vn
    .{ .number = 33, .child_index = 26, .children_len = 1, .end_of_word = false }, // vo
    .{ .number = 34, .child_index = 881, .children_len = 1, .end_of_word = false }, // vp
    .invalid, // vq
    .{ .number = 35, .child_index = 879, .children_len = 1, .end_of_word = false }, // vr
    .{ .number = 36, .child_index = 882, .children_len = 2, .end_of_word = false }, // vs
    .invalid, // vt
    .invalid, // vu
    .invalid, // vv
    .invalid, // vw
    .invalid, // vx
    .invalid, // vy
    .{ .number = 41, .child_index = 884, .children_len = 1, .end_of_word = false }, // vz
    .invalid, // wA
    .invalid, // wB
    .invalid, // wC
    .invalid, // wD
    .invalid, // wE
    .invalid, // wF
    .invalid, // wG
    .invalid, // wH
    .invalid, // wI
    .invalid, // wJ
    .invalid, // wK
    .invalid, // wL
    .invalid, // wM
    .invalid, // wN
    .invalid, // wO
    .invalid, // wP
    .invalid, // wQ
    .invalid, // wR
    .invalid, // wS
    .invalid, // wT
    .invalid, // wU
    .invalid, // wV
    .invalid, // wW
    .invalid, // wX
    .invalid, // wY
    .invalid, // wZ
    .invalid, // wa
    .invalid, // wb
    .{ .number = 0, .child_index = 96, .children_len = 1, .end_of_word = false }, // wc
    .invalid, // wd
    .{ .number = 1, .child_index = 885, .children_len = 2, .end_of_word = false }, // we
    .{ .number = 5, .child_index = 7, .children_len = 1, .end_of_word = false }, // wf
    .invalid, // wg
    .invalid, // wh
    .invalid, // wi
    .invalid, // wj
    .invalid, // wk
    .invalid, // wl
    .invalid, // wm
    .invalid, // wn
    .{ .number = 6, .child_index = 26, .children_len = 1, .end_of_word = false }, // wo
    .{ .number = 7, .child_index = 91, .children_len = 1, .end_of_word = false }, // wp
    .invalid, // wq
    .{ .number = 8, .child_index = 887, .children_len = 2, .end_of_word = false }, // wr
    .{ .number = 10, .child_index = 28, .children_len = 1, .end_of_word = false }, // ws
    .invalid, // wt
    .invalid, // wu
    .invalid, // wv
    .invalid, // ww
    .invalid, // wx
    .invalid, // wy
    .invalid, // wz
    .invalid, // xA
    .invalid, // xB
    .invalid, // xC
    .invalid, // xD
    .invalid, // xE
    .invalid, // xF
    .invalid, // xG
    .invalid, // xH
    .invalid, // xI
    .invalid, // xJ
    .invalid, // xK
    .invalid, // xL
    .invalid, // xM
    .invalid, // xN
    .invalid, // xO
    .invalid, // xP
    .invalid, // xQ
    .invalid, // xR
    .invalid, // xS
    .invalid, // xT
    .invalid, // xU
    .invalid, // xV
    .invalid, // xW
    .invalid, // xX
    .invalid, // xY
    .invalid, // xZ
    .invalid, // xa
    .invalid, // xb
    .{ .number = 0, .child_index = 889, .children_len = 3, .end_of_word = false }, // xc
    .{ .number = 3, .child_index = 879, .children_len = 1, .end_of_word = false }, // xd
    .invalid, // xe
    .{ .number = 4, .child_index = 7, .children_len = 1, .end_of_word = false }, // xf
    .invalid, // xg
    .{ .number = 5, .child_index = 892, .children_len = 2, .end_of_word = false }, // xh
    .{ .number = 7, .child_index = 91, .children_len = 1, .end_of_word = false }, // xi
    .invalid, // xj
    .invalid, // xk
    .{ .number = 8, .child_index = 892, .children_len = 2, .end_of_word = false }, // xl
    .{ .number = 10, .child_index = 894, .children_len = 1, .end_of_word = false }, // xm
    .{ .number = 11, .child_index = 895, .children_len = 1, .end_of_word = false }, // xn
    .{ .number = 12, .child_index = 896, .children_len = 3, .end_of_word = false }, // xo
    .invalid, // xp
    .invalid, // xq
    .{ .number = 16, .child_index = 892, .children_len = 2, .end_of_word = false }, // xr
    .{ .number = 18, .child_index = 899, .children_len = 2, .end_of_word = false }, // xs
    .invalid, // xt
    .{ .number = 20, .child_index = 901, .children_len = 2, .end_of_word = false }, // xu
    .{ .number = 22, .child_index = 903, .children_len = 1, .end_of_word = false }, // xv
    .{ .number = 23, .child_index = 904, .children_len = 1, .end_of_word = false }, // xw
    .invalid, // xx
    .invalid, // xy
    .invalid, // xz
    .invalid, // yA
    .invalid, // yB
    .invalid, // yC
    .invalid, // yD
    .invalid, // yE
    .invalid, // yF
    .invalid, // yG
    .invalid, // yH
    .invalid, // yI
    .invalid, // yJ
    .invalid, // yK
    .invalid, // yL
    .invalid, // yM
    .invalid, // yN
    .invalid, // yO
    .invalid, // yP
    .invalid, // yQ
    .invalid, // yR
    .invalid, // yS
    .invalid, // yT
    .invalid, // yU
    .invalid, // yV
    .invalid, // yW
    .invalid, // yX
    .invalid, // yY
    .invalid, // yZ
    .{ .number = 0, .child_index = 905, .children_len = 1, .end_of_word = false }, // ya
    .invalid, // yb
    .{ .number = 3, .child_index = 113, .children_len = 2, .end_of_word = false }, // yc
    .invalid, // yd
    .{ .number = 5, .child_index = 906, .children_len = 1, .end_of_word = false }, // ye
    .{ .number = 7, .child_index = 7, .children_len = 1, .end_of_word = false }, // yf
    .invalid, // yg
    .invalid, // yh
    .{ .number = 8, .child_index = 30, .children_len = 1, .end_of_word = false }, // yi
    .invalid, // yj
    .invalid, // yk
    .invalid, // yl
    .invalid, // ym
    .invalid, // yn
    .{ .number = 9, .child_index = 26, .children_len = 1, .end_of_word = false }, // yo
    .invalid, // yp
    .invalid, // yq
    .invalid, // yr
    .{ .number = 10, .child_index = 28, .children_len = 1, .end_of_word = false }, // ys
    .invalid, // yt
    .{ .number = 11, .child_index = 907, .children_len = 2, .end_of_word = false }, // yu
    .invalid, // yv
    .invalid, // yw
    .invalid, // yx
    .invalid, // yy
    .invalid, // yz
    .invalid, // zA
    .invalid, // zB
    .invalid, // zC
    .invalid, // zD
    .invalid, // zE
    .invalid, // zF
    .invalid, // zG
    .invalid, // zH
    .invalid, // zI
    .invalid, // zJ
    .invalid, // zK
    .invalid, // zL
    .invalid, // zM
    .invalid, // zN
    .invalid, // zO
    .invalid, // zP
    .invalid, // zQ
    .invalid, // zR
    .invalid, // zS
    .invalid, // zT
    .invalid, // zU
    .invalid, // zV
    .invalid, // zW
    .invalid, // zX
    .invalid, // zY
    .invalid, // zZ
    .{ .number = 0, .child_index = 144, .children_len = 1, .end_of_word = false }, // za
    .invalid, // zb
    .{ .number = 1, .child_index = 56, .children_len = 2, .end_of_word = false }, // zc
    .{ .number = 3, .child_index = 39, .children_len = 1, .end_of_word = false }, // zd
    .{ .number = 4, .child_index = 909, .children_len = 2, .end_of_word = false }, // ze
    .{ .number = 6, .child_index = 7, .children_len = 1, .end_of_word = false }, // zf
    .invalid, // zg
    .{ .number = 7, .child_index = 30, .children_len = 1, .end_of_word = false }, // zh
    .{ .number = 8, .child_index = 911, .children_len = 1, .end_of_word = false }, // zi
    .invalid, // zj
    .invalid, // zk
    .invalid, // zl
    .invalid, // zm
    .invalid, // zn
    .{ .number = 9, .child_index = 26, .children_len = 1, .end_of_word = false }, // zo
    .invalid, // zp
    .invalid, // zq
    .invalid, // zr
    .{ .number = 10, .child_index = 28, .children_len = 1, .end_of_word = false }, // zs
    .invalid, // zt
    .invalid, // zu
    .invalid, // zv
    .{ .number = 11, .child_index = 912, .children_len = 2, .end_of_word = false }, // zw
    .invalid, // zx
    .invalid, // zy
    .invalid, // zz
};

pub const dafsa = [_]Node{
    .{ .char = 0, .end_of_word = false, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 914, .children_len = 1 },
    .{ .char = 'P', .end_of_word = true, .number = 0, .child_index = 86, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 915, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 27, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 916, .children_len = 1 },
    .{ .char = 'y', .end_of_word = false, .number = 2, .child_index = 91, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 917, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 918, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 28, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 919, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 1, .child_index = 920, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 921, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 922, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 7, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 1, .child_index = 923, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 924, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 925, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 926, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 927, .children_len = 2 },
    .{ .char = 'y', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 929, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 930, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 2, .child_index = 79, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 920, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 931, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 7, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 932, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 22, .children_len = 1 },
    .{ .char = 'P', .end_of_word = false, .number = 0, .child_index = 933, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 934, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 1, .child_index = 935, .children_len = 2 },
    .{ .char = 'y', .end_of_word = false, .number = 3, .child_index = 937, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 938, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 939, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 3, .child_index = 940, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 4, .child_index = 941, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 942, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 943, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 1, .child_index = 944, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 945, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 946, .children_len = 2 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 948, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 2, .child_index = 949, .children_len = 3 },
    .{ .char = 'p', .end_of_word = false, .number = 5, .child_index = 952, .children_len = 2 },
    .{ .char = 'u', .end_of_word = false, .number = 7, .child_index = 954, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 955, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 956, .children_len = 2 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'o', .end_of_word = false, .number = 1, .child_index = 958, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 959, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 7, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 2, .child_index = 960, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 938, .children_len = 1 },
    .{ .char = 'y', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 961, .children_len = 2 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 963, .children_len = 2 },
    .{ .char = 'f', .end_of_word = false, .number = 6, .child_index = 965, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 920, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 1, .child_index = 966, .children_len = 3 },
    .{ .char = 'u', .end_of_word = false, .number = 4, .child_index = 969, .children_len = 1 },
    .{ .char = 'w', .end_of_word = false, .number = 18, .child_index = 970, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 7, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 1, .child_index = 971, .children_len = 1 },
    .{ .char = 'G', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'H', .end_of_word = true, .number = 0, .child_index = 86, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 938, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 916, .children_len = 1 },
    .{ .char = 'y', .end_of_word = false, .number = 3, .child_index = 91, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 972, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 28, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 1, .child_index = 973, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 974, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 975, .children_len = 2 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 7, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 977, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 978, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 1, .child_index = 979, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 980, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 920, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 981, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 2, .child_index = 982, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 983, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 984, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 940, .children_len = 1 },
    .{ .char = 'y', .end_of_word = false, .number = 2, .child_index = 91, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 985, .children_len = 1 },
    .{ .char = 'R', .end_of_word = false, .number = 0, .child_index = 986, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 987, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 940, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 988, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 920, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 989, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 990, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 991, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 992, .children_len = 2 },
    .{ .char = 'p', .end_of_word = false, .number = 3, .child_index = 994, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 995, .children_len = 2 },
    .{ .char = 'v', .end_of_word = false, .number = 3, .child_index = 997, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 919, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 1, .child_index = 920, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 2, .child_index = 79, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 998, .children_len = 1 },
    .{ .char = 'k', .end_of_word = false, .number = 0, .child_index = 30, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 1, .child_index = 925, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 940, .children_len = 1 },
    .{ .char = 'y', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 7, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 999, .children_len = 1 },
    .{ .char = 'k', .end_of_word = false, .number = 0, .child_index = 30, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 1000, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 984, .children_len = 1 },
    .{ .char = 'y', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 934, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 1, .child_index = 1001, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 2, .child_index = 1002, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 3, .child_index = 1003, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 4, .child_index = 7, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 938, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 984, .children_len = 1 },
    .{ .char = 'y', .end_of_word = false, .number = 2, .child_index = 91, .children_len = 1 },
    .{ .char = 'f', .end_of_word = false, .number = 0, .child_index = 1004, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 26, .child_index = 1005, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 1006, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 318, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1007, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 6, .child_index = 920, .children_len = 1 },
    .{ .char = 'w', .end_of_word = false, .number = 7, .child_index = 1008, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 7, .children_len = 1 },
    .{ .char = 'h', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 2, .child_index = 971, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 1009, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 1, .child_index = 1010, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1011, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 934, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 1012, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 4, .child_index = 1013, .children_len = 1 },
    .{ .char = 'w', .end_of_word = false, .number = 6, .child_index = 1014, .children_len = 1 },
    .{ .char = 'B', .end_of_word = false, .number = 0, .child_index = 1015, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 1, .child_index = 1016, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 2, .child_index = 920, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 3, .child_index = 1017, .children_len = 13 },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 1030, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 28, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 1031, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 2, .child_index = 1032, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1033, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 7, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 1, .child_index = 1034, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1035, .children_len = 2 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1037, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1038, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 1039, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1040, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 1, .child_index = 920, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 1041, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 5, .child_index = 1042, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 6, .child_index = 1043, .children_len = 2 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 7, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'O', .end_of_word = false, .number = 0, .child_index = 1045, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 327, .children_len = 1 },
    .{ .char = 'G', .end_of_word = true, .number = 0, .child_index = 86, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 934, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 1, .child_index = 1002, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 2, .child_index = 1046, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'v', .end_of_word = false, .number = 1, .child_index = 1047, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 1048, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 920, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 1, .child_index = 1049, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1050, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 7, .children_len = 1 },
    .{ .char = 'h', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1051, .children_len = 1 },
    .{ .char = 'C', .end_of_word = false, .number = 0, .child_index = 1052, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 1, .child_index = 22, .children_len = 1 },
    .{ .char = 'F', .end_of_word = false, .number = 0, .child_index = 1053, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 938, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 2, .child_index = 984, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 3, .child_index = 940, .children_len = 1 },
    .{ .char = 'y', .end_of_word = false, .number = 4, .child_index = 91, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1054, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 1055, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1056, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 942, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 1, .child_index = 1057, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 7, .children_len = 1 },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 1058, .children_len = 2 },
    .{ .char = 'c', .end_of_word = false, .number = 3, .child_index = 1060, .children_len = 2 },
    .{ .char = 'm', .end_of_word = false, .number = 8, .child_index = 91, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 9, .child_index = 1062, .children_len = 3 },
    .{ .char = 'O', .end_of_word = false, .number = 0, .child_index = 1065, .children_len = 1 },
    .{ .char = 'A', .end_of_word = false, .number = 0, .child_index = 1066, .children_len = 1 },
    .{ .char = 'H', .end_of_word = false, .number = 0, .child_index = 30, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 1, .child_index = 22, .children_len = 1 },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1067, .children_len = 2 },
    .{ .char = 'i', .end_of_word = false, .number = 2, .child_index = 1069, .children_len = 2 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1071, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1072, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 915, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 2, .child_index = 1073, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1074, .children_len = 2 },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 160, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 4, .child_index = 1076, .children_len = 1 },
    .{ .char = 'A', .end_of_word = false, .number = 0, .child_index = 1077, .children_len = 1 },
    .{ .char = 'D', .end_of_word = false, .number = 3, .child_index = 1078, .children_len = 1 },
    .{ .char = 'E', .end_of_word = false, .number = 4, .child_index = 1079, .children_len = 1 },
    .{ .char = 'T', .end_of_word = false, .number = 5, .child_index = 1080, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 7, .child_index = 1081, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 8, .child_index = 1082, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 9, .child_index = 1008, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 11, .child_index = 1083, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1084, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1085, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1086, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 1087, .children_len = 3 },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 229, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 1090, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 1091, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1092, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 1, .child_index = 79, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'E', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 2, .child_index = 91, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 3, .child_index = 916, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 5, .child_index = 1093, .children_len = 1 },
    .{ .char = 'y', .end_of_word = false, .number = 7, .child_index = 91, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1094, .children_len = 2 },
    .{ .char = 'p', .end_of_word = false, .number = 2, .child_index = 918, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1096, .children_len = 2 },
    .{ .char = 'p', .end_of_word = true, .number = 2, .child_index = 86, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 1098, .children_len = 5 },
    .{ .char = 'g', .end_of_word = false, .number = 5, .child_index = 1103, .children_len = 7 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'E', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 2, .child_index = 1110, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 3, .child_index = 91, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 4, .child_index = 11, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 5, .child_index = 1111, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 6, .child_index = 1112, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 7, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'y', .end_of_word = false, .number = 2, .child_index = 1113, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1114, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 688, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1115, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 5, .child_index = 1116, .children_len = 2 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1118, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1084, .children_len = 1 },
    .{ .char = 'y', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'q', .end_of_word = false, .number = 0, .child_index = 1119, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1120, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 2, .child_index = 1121, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 3, .child_index = 1122, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 4, .child_index = 1123, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 5, .child_index = 1124, .children_len = 3 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 1127, .children_len = 7 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1134, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1135, .children_len = 2 },
    .{ .char = 'k', .end_of_word = false, .number = 7, .child_index = 1137, .children_len = 2 },
    .{ .char = 'o', .end_of_word = false, .number = 10, .child_index = 1139, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1140, .children_len = 2 },
    .{ .char = 'o', .end_of_word = false, .number = 2, .child_index = 942, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 920, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 1, .child_index = 1142, .children_len = 2 },
    .{ .char = 'w', .end_of_word = false, .number = 3, .child_index = 1144, .children_len = 1 },
    .{ .char = 'x', .end_of_word = false, .number = 4, .child_index = 1145, .children_len = 12 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1157, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 931, .children_len = 1 },
    .{ .char = 'v', .end_of_word = false, .number = 1, .child_index = 1158, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 7, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 1159, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 2, .child_index = 1160, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 4, .child_index = 1161, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1162, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 2, .child_index = 1163, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 934, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 1, .child_index = 1164, .children_len = 6 },
    .{ .char = 'r', .end_of_word = false, .number = 8, .child_index = 1170, .children_len = 2 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1172, .children_len = 2 },
    .{ .char = 'e', .end_of_word = false, .number = 2, .child_index = 939, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 4, .child_index = 940, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 5, .child_index = 1174, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 1175, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 2, .child_index = 1121, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 3, .child_index = 1176, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 22, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 1177, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 3, .child_index = 91, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1178, .children_len = 7 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 1185, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1186, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 3, .child_index = 1187, .children_len = 2 },
    .{ .char = 'n', .end_of_word = false, .number = 9, .child_index = 1189, .children_len = 2 },
    .{ .char = 'p', .end_of_word = false, .number = 12, .child_index = 1191, .children_len = 3 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 327, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 1, .child_index = 955, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 7, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 1, .child_index = 1194, .children_len = 2 },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 39, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 1196, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 2, .child_index = 1197, .children_len = 2 },
    .{ .char = 'l', .end_of_word = false, .number = 4, .child_index = 1199, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 6, .child_index = 1200, .children_len = 6 },
    .{ .char = 'r', .end_of_word = false, .number = 13, .child_index = 1206, .children_len = 4 },
    .{ .char = 'v', .end_of_word = false, .number = 23, .child_index = 903, .children_len = 1 },
    .{ .char = 'w', .end_of_word = false, .number = 24, .child_index = 1210, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1211, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 7, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 959, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 1, .child_index = 1212, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 2, .child_index = 7, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 3, .child_index = 1213, .children_len = 1 },
    .{ .char = 'k', .end_of_word = false, .number = 0, .child_index = 276, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 1, .child_index = 1214, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 1215, .children_len = 2 },
    .{ .char = 'o', .end_of_word = false, .number = 3, .child_index = 1217, .children_len = 1 },
    .{ .char = 'g', .end_of_word = true, .number = 0, .child_index = 86, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 2, .child_index = 1218, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 3, .child_index = 1121, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1219, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1220, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1221, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 4, .child_index = 91, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 5, .child_index = 1222, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 6, .child_index = 1223, .children_len = 1 },
    .{ .char = 'v', .end_of_word = false, .number = 7, .child_index = 1224, .children_len = 3 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1227, .children_len = 2 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1229, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 1, .child_index = 920, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 2, .child_index = 1230, .children_len = 5 },
    .{ .char = 'u', .end_of_word = false, .number = 8, .child_index = 1235, .children_len = 1 },
    .{ .char = 'w', .end_of_word = false, .number = 9, .child_index = 1236, .children_len = 1 },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 1237, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 1, .child_index = 1227, .children_len = 2 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1238, .children_len = 2 },
    .{ .char = 'o', .end_of_word = false, .number = 2, .child_index = 1091, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 3, .child_index = 971, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 39, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 1240, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 327, .children_len = 1 },
    .{ .char = 'h', .end_of_word = false, .number = 1, .child_index = 200, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1241, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 22, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 911, .children_len = 1 },
    .{ .char = 'D', .end_of_word = false, .number = 0, .child_index = 39, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 1, .child_index = 942, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 915, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 2, .child_index = 1242, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 938, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 1243, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 4, .child_index = 1244, .children_len = 1 },
    .{ .char = 'y', .end_of_word = false, .number = 5, .child_index = 91, .children_len = 1 },
    .{ .char = 'D', .end_of_word = false, .number = 0, .child_index = 39, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 917, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 3, .child_index = 1245, .children_len = 2 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 1247, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 2, .child_index = 91, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 3, .child_index = 1245, .children_len = 2 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 28, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 1, .child_index = 1248, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 4, .child_index = 1249, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 1, .child_index = 140, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1250, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 2, .child_index = 1251, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 3, .child_index = 1252, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1253, .children_len = 2 },
    .{ .char = 's', .end_of_word = false, .number = 2, .child_index = 1255, .children_len = 2 },
    .{ .char = 'u', .end_of_word = false, .number = 5, .child_index = 1257, .children_len = 3 },
    .{ .char = 'v', .end_of_word = false, .number = 9, .child_index = 1260, .children_len = 1 },
    .{ .char = 'D', .end_of_word = false, .number = 0, .child_index = 39, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 327, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 7, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 1, .child_index = 39, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 2, .child_index = 977, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'h', .end_of_word = true, .number = 1, .child_index = 86, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 925, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 2, .child_index = 179, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1091, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 1261, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 2, .child_index = 1262, .children_len = 2 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1264, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 1265, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 101, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 1, .child_index = 1266, .children_len = 2 },
    .{ .char = 'r', .end_of_word = false, .number = 3, .child_index = 91, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 942, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 1, .child_index = 991, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 2, .child_index = 1268, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 920, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 920, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 1269, .children_len = 2 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1271, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1272, .children_len = 2 },
    .{ .char = 'o', .end_of_word = false, .number = 19, .child_index = 1274, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'l', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 934, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 1, .child_index = 983, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 3, .child_index = 91, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'l', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'q', .end_of_word = false, .number = 2, .child_index = 1275, .children_len = 3 },
    .{ .char = 's', .end_of_word = false, .number = 5, .child_index = 1278, .children_len = 4 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'g', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 1282, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'E', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 2, .child_index = 91, .children_len = 1 },
    .{ .char = 'j', .end_of_word = false, .number = 3, .child_index = 91, .children_len = 1 },
    .{ .char = 'E', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 1283, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 3, .child_index = 1284, .children_len = 2 },
    .{ .char = 's', .end_of_word = false, .number = 6, .child_index = 1286, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 931, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 7, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 1287, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'c', .end_of_word = false, .number = 1, .child_index = 1288, .children_len = 2 },
    .{ .char = 'd', .end_of_word = false, .number = 3, .child_index = 39, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 4, .child_index = 1290, .children_len = 1 },
    .{ .char = 'q', .end_of_word = false, .number = 5, .child_index = 1291, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 6, .child_index = 1292, .children_len = 5 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1297, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 1, .child_index = 1298, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1299, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 1, .child_index = 920, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 2, .child_index = 1300, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 3, .child_index = 1301, .children_len = 2 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1303, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 2, .child_index = 1304, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 3, .child_index = 1305, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 1306, .children_len = 2 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 327, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 1, .child_index = 1308, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 2, .child_index = 1309, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 4, .child_index = 920, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 5, .child_index = 710, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 7, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 1, .child_index = 229, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 2, .child_index = 971, .children_len = 1 },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 1310, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 1, .child_index = 1311, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 916, .children_len = 1 },
    .{ .char = 'y', .end_of_word = false, .number = 3, .child_index = 91, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 22, .children_len = 1 },
    .{ .char = 'x', .end_of_word = false, .number = 1, .child_index = 1312, .children_len = 1 },
    .{ .char = 'f', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 1313, .children_len = 2 },
    .{ .char = 'n', .end_of_word = false, .number = 3, .child_index = 1315, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 4, .child_index = 1218, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1316, .children_len = 3 },
    .{ .char = 'o', .end_of_word = false, .number = 5, .child_index = 920, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 6, .child_index = 1210, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'c', .end_of_word = false, .number = 1, .child_index = 1319, .children_len = 1 },
    .{ .char = 'f', .end_of_word = false, .number = 2, .child_index = 1320, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 4, .child_index = 318, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 5, .child_index = 1321, .children_len = 5 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 22, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 1, .child_index = 919, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 2, .child_index = 920, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 3, .child_index = 79, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1326, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 1327, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 7, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 1328, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 998, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1329, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 1330, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1331, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 327, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 7, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 2, .child_index = 1332, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 934, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 1333, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 2, .child_index = 1334, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 3, .child_index = 1001, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 4, .child_index = 1335, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 7, .child_index = 91, .children_len = 1 },
    .{ .char = 'q', .end_of_word = false, .number = 8, .child_index = 1336, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 10, .child_index = 1337, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 19, .child_index = 1338, .children_len = 3 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 327, .children_len = 1 },
    .{ .char = 'b', .end_of_word = false, .number = 1, .child_index = 828, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 2, .child_index = 1341, .children_len = 2 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 938, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 1343, .children_len = 2 },
    .{ .char = 'u', .end_of_word = false, .number = 3, .child_index = 1345, .children_len = 1 },
    .{ .char = 'y', .end_of_word = false, .number = 4, .child_index = 91, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 79, .children_len = 1 },
    .{ .char = 'q', .end_of_word = false, .number = 1, .child_index = 1346, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 3, .child_index = 1347, .children_len = 2 },
    .{ .char = 's', .end_of_word = false, .number = 5, .child_index = 1349, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'f', .end_of_word = false, .number = 1, .child_index = 1350, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 11, .child_index = 91, .children_len = 1 },
    .{ .char = 'q', .end_of_word = false, .number = 12, .child_index = 1275, .children_len = 3 },
    .{ .char = 's', .end_of_word = false, .number = 15, .child_index = 1351, .children_len = 5 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1219, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 1, .child_index = 1356, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 2, .child_index = 91, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'E', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1357, .children_len = 1 },
    .{ .char = 'b', .end_of_word = false, .number = 3, .child_index = 1358, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 327, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 2, .child_index = 1359, .children_len = 1 },
    .{ .char = 'h', .end_of_word = false, .number = 3, .child_index = 1360, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 4, .child_index = 1361, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 318, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 1, .child_index = 1362, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1363, .children_len = 2 },
    .{ .char = 'b', .end_of_word = false, .number = 2, .child_index = 828, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 3, .child_index = 1365, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 7, .child_index = 1366, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 9, .child_index = 1367, .children_len = 3 },
    .{ .char = 't', .end_of_word = false, .number = 12, .child_index = 1370, .children_len = 1 },
    .{ .char = 'w', .end_of_word = false, .number = 13, .child_index = 1371, .children_len = 2 },
    .{ .char = 'z', .end_of_word = false, .number = 15, .child_index = 1373, .children_len = 3 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1376, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 327, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 1, .child_index = 1359, .children_len = 1 },
    .{ .char = 'h', .end_of_word = false, .number = 2, .child_index = 1377, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 4, .child_index = 91, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 5, .child_index = 1361, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 269, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 1, .child_index = 7, .children_len = 1 },
    .{ .char = 'h', .end_of_word = false, .number = 2, .child_index = 91, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 3, .child_index = 1378, .children_len = 1 },
    .{ .char = 'q', .end_of_word = false, .number = 6, .child_index = 1379, .children_len = 2 },
    .{ .char = 't', .end_of_word = false, .number = 9, .child_index = 971, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'c', .end_of_word = false, .number = 1, .child_index = 1288, .children_len = 2 },
    .{ .char = 'd', .end_of_word = false, .number = 3, .child_index = 39, .children_len = 1 },
    .{ .char = 'h', .end_of_word = false, .number = 4, .child_index = 1381, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 5, .child_index = 1382, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 6, .child_index = 172, .children_len = 1 },
    .{ .char = 'q', .end_of_word = false, .number = 7, .child_index = 1291, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 8, .child_index = 1383, .children_len = 2 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1385, .children_len = 2 },
    .{ .char = 'D', .end_of_word = false, .number = 0, .child_index = 39, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1387, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 2, .child_index = 1388, .children_len = 2 },
    .{ .char = 'p', .end_of_word = false, .number = 5, .child_index = 1390, .children_len = 2 },
    .{ .char = 'r', .end_of_word = false, .number = 10, .child_index = 1392, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1393, .children_len = 1 },
    .{ .char = 'y', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1394, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1395, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 2, .child_index = 1396, .children_len = 4 },
    .{ .char = 'n', .end_of_word = false, .number = 7, .child_index = 1400, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 140, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 1, .child_index = 7, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 1401, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 1402, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 1, .child_index = 920, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 7, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 1, .child_index = 1403, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'l', .end_of_word = false, .number = 1, .child_index = 1404, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 2, .child_index = 894, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 1, .child_index = 1405, .children_len = 2 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1407, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 2, .child_index = 91, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 3, .child_index = 1405, .children_len = 2 },
    .{ .char = 'D', .end_of_word = false, .number = 0, .child_index = 229, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 1, .child_index = 229, .children_len = 1 },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 1408, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 1, .child_index = 934, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 2, .child_index = 1002, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 3, .child_index = 1409, .children_len = 5 },
    .{ .char = 't', .end_of_word = false, .number = 8, .child_index = 1414, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 1415, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 2, .child_index = 1416, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1417, .children_len = 2 },
    .{ .char = 'e', .end_of_word = false, .number = 2, .child_index = 984, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 3, .child_index = 1419, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 5, .child_index = 140, .children_len = 1 },
    .{ .char = 'y', .end_of_word = false, .number = 6, .child_index = 91, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'A', .end_of_word = false, .number = 1, .child_index = 327, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 2, .child_index = 1420, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 5, .child_index = 39, .children_len = 1 },
    .{ .char = 'q', .end_of_word = false, .number = 6, .child_index = 1421, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 7, .child_index = 1422, .children_len = 2 },
    .{ .char = 'x', .end_of_word = false, .number = 9, .child_index = 1424, .children_len = 1 },
    .{ .char = 'E', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 1425, .children_len = 3 },
    .{ .char = 's', .end_of_word = false, .number = 6, .child_index = 1286, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 7, .child_index = 244, .children_len = 2 },
    .{ .char = 'A', .end_of_word = false, .number = 0, .child_index = 327, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 327, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 2, .child_index = 200, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 's', .end_of_word = false, .number = 1, .child_index = 1428, .children_len = 2 },
    .{ .char = 'v', .end_of_word = false, .number = 3, .child_index = 91, .children_len = 1 },
    .{ .char = 'A', .end_of_word = false, .number = 0, .child_index = 327, .children_len = 1 },
    .{ .char = 'E', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 2, .child_index = 327, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 3, .child_index = 7, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 4, .child_index = 1430, .children_len = 4 },
    .{ .char = 's', .end_of_word = false, .number = 12, .child_index = 1286, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 13, .child_index = 1434, .children_len = 2 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 11, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 920, .children_len = 1 },
    .{ .char = 't', .end_of_word = true, .number = 1, .child_index = 1436, .children_len = 3 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1439, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 4, .child_index = 1440, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 5, .child_index = 1441, .children_len = 3 },
    .{ .char = 'A', .end_of_word = false, .number = 0, .child_index = 327, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 1444, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 4, .child_index = 1050, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 5, .child_index = 1445, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1446, .children_len = 4 },
    .{ .char = 'h', .end_of_word = false, .number = 4, .child_index = 1450, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 6, .child_index = 1451, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 9, .child_index = 637, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 10, .child_index = 200, .children_len = 1 },
    .{ .char = 'q', .end_of_word = false, .number = 11, .child_index = 1452, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 13, .child_index = 1453, .children_len = 3 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 1091, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 924, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 3, .child_index = 1002, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 4, .child_index = 1456, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'm', .end_of_word = false, .number = 1, .child_index = 1457, .children_len = 3 },
    .{ .char = 'D', .end_of_word = false, .number = 0, .child_index = 229, .children_len = 1 },
    .{ .char = 'H', .end_of_word = false, .number = 1, .child_index = 172, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 2, .child_index = 140, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 3, .child_index = 229, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 4, .child_index = 1460, .children_len = 2 },
    .{ .char = 'i', .end_of_word = false, .number = 6, .child_index = 1462, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 7, .child_index = 1463, .children_len = 3 },
    .{ .char = 'r', .end_of_word = false, .number = 11, .child_index = 1466, .children_len = 2 },
    .{ .char = 's', .end_of_word = false, .number = 13, .child_index = 1286, .children_len = 1 },
    .{ .char = 'A', .end_of_word = false, .number = 0, .child_index = 327, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 1420, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 4, .child_index = 1468, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 915, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 2, .child_index = 942, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1243, .children_len = 1 },
    .{ .char = 'y', .end_of_word = false, .number = 3, .child_index = 91, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1085, .children_len = 1 },
    .{ .char = 'b', .end_of_word = false, .number = 1, .child_index = 1030, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 2, .child_index = 1469, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 3, .child_index = 942, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 4, .child_index = 1470, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1471, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1472, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 917, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 3, .child_index = 91, .children_len = 1 },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 200, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 942, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 327, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 1, .child_index = 1473, .children_len = 2 },
    .{ .char = 'i', .end_of_word = false, .number = 3, .child_index = 1475, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 4, .child_index = 91, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 28, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 1031, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 2, .child_index = 1476, .children_len = 3 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 7, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 1479, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 2, .child_index = 1251, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 327, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 2, .child_index = 1480, .children_len = 4 },
    .{ .char = 'i', .end_of_word = false, .number = 9, .child_index = 1484, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 10, .child_index = 7, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 11, .child_index = 1485, .children_len = 1 },
    .{ .char = 'v', .end_of_word = false, .number = 12, .child_index = 91, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 7, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 1, .child_index = 1034, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 3, .child_index = 1091, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1486, .children_len = 2 },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 200, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1488, .children_len = 4 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1492, .children_len = 5 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1405, .children_len = 2 },
    .{ .char = 'm', .end_of_word = false, .number = 2, .child_index = 1497, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 3, .child_index = 1475, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 't', .end_of_word = false, .number = 1, .child_index = 1498, .children_len = 1 },
    .{ .char = 'v', .end_of_word = false, .number = 2, .child_index = 91, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1499, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 3, .child_index = 1500, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1501, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 1, .child_index = 920, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 2, .child_index = 1502, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'E', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 2, .child_index = 140, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 3, .child_index = 1503, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 4, .child_index = 1504, .children_len = 2 },
    .{ .char = 'i', .end_of_word = false, .number = 13, .child_index = 1506, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 15, .child_index = 1507, .children_len = 3 },
    .{ .char = 'o', .end_of_word = false, .number = 18, .child_index = 1510, .children_len = 3 },
    .{ .char = 's', .end_of_word = false, .number = 24, .child_index = 1286, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 25, .child_index = 1513, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1514, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1515, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 2, .child_index = 1516, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 4, .child_index = 1517, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1518, .children_len = 2 },
    .{ .char = 'd', .end_of_word = false, .number = 2, .child_index = 1520, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 3, .child_index = 1333, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 4, .child_index = 1521, .children_len = 1 },
    .{ .char = 'q', .end_of_word = false, .number = 8, .child_index = 1336, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 10, .child_index = 1522, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 22, .child_index = 1523, .children_len = 2 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 79, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 1, .child_index = 1525, .children_len = 1 },
    .{ .char = 'q', .end_of_word = false, .number = 2, .child_index = 1346, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 4, .child_index = 1349, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1526, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 4, .child_index = 942, .children_len = 1 },
    .{ .char = 'g', .end_of_word = true, .number = 5, .child_index = 86, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1357, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 3, .child_index = 1405, .children_len = 2 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 1527, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 9, .child_index = 1002, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 10, .child_index = 1528, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 327, .children_len = 1 },
    .{ .char = 'h', .end_of_word = false, .number = 1, .child_index = 200, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 2, .child_index = 91, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1362, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 637, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1363, .children_len = 2 },
    .{ .char = 'b', .end_of_word = false, .number = 2, .child_index = 828, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 3, .child_index = 1367, .children_len = 3 },
    .{ .char = 't', .end_of_word = false, .number = 6, .child_index = 1370, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1529, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 2, .child_index = 1530, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 269, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 1, .child_index = 7, .children_len = 1 },
    .{ .char = 'h', .end_of_word = false, .number = 2, .child_index = 91, .children_len = 1 },
    .{ .char = 'q', .end_of_word = false, .number = 3, .child_index = 1379, .children_len = 2 },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 1381, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 1382, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 2, .child_index = 1531, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1532, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'E', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 2, .child_index = 1417, .children_len = 2 },
    .{ .char = 'c', .end_of_word = false, .number = 4, .child_index = 1503, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 5, .child_index = 1533, .children_len = 2 },
    .{ .char = 'i', .end_of_word = false, .number = 7, .child_index = 940, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 8, .child_index = 1507, .children_len = 3 },
    .{ .char = 'p', .end_of_word = false, .number = 11, .child_index = 1530, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 12, .child_index = 1286, .children_len = 1 },
    .{ .char = 'y', .end_of_word = false, .number = 13, .child_index = 91, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1535, .children_len = 1 },
    .{ .char = 'A', .end_of_word = false, .number = 0, .child_index = 327, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 1420, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 4, .child_index = 1517, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 6, .child_index = 42, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 7, .child_index = 1536, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 8, .child_index = 1537, .children_len = 1 },
    .{ .char = 'x', .end_of_word = false, .number = 10, .child_index = 942, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1538, .children_len = 2 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1479, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 1, .child_index = 1540, .children_len = 2 },
    .{ .char = 'o', .end_of_word = false, .number = 3, .child_index = 1542, .children_len = 1 },
    .{ .char = 'y', .end_of_word = true, .number = 5, .child_index = 86, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 1543, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 3, .child_index = 1544, .children_len = 8 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1552, .children_len = 2 },
    .{ .char = 'e', .end_of_word = false, .number = 2, .child_index = 1260, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 3, .child_index = 1554, .children_len = 2 },
    .{ .char = 't', .end_of_word = false, .number = 5, .child_index = 1556, .children_len = 2 },
    .{ .char = 'f', .end_of_word = false, .number = 0, .child_index = 1558, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 1, .child_index = 1559, .children_len = 2 },
    .{ .char = 'p', .end_of_word = false, .number = 4, .child_index = 920, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1561, .children_len = 2 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1563, .children_len = 2 },
    .{ .char = 's', .end_of_word = false, .number = 4, .child_index = 1565, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 12, .child_index = 1566, .children_len = 3 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 7, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 1569, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 2, .child_index = 1570, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 3, .child_index = 1571, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1572, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 2, .child_index = 1573, .children_len = 2 },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 1575, .children_len = 9 },
    .{ .char = 'c', .end_of_word = false, .number = 18, .child_index = 1584, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 26, .child_index = 91, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 27, .child_index = 1002, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 28, .child_index = 1585, .children_len = 13 },
    .{ .char = 'A', .end_of_word = false, .number = 0, .child_index = 327, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 1420, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 4, .child_index = 1536, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1598, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1599, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1600, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1601, .children_len = 2 },
    .{ .char = 'i', .end_of_word = false, .number = 5, .child_index = 1603, .children_len = 2 },
    .{ .char = 'k', .end_of_word = false, .number = 8, .child_index = 1605, .children_len = 2 },
    .{ .char = 'o', .end_of_word = false, .number = 10, .child_index = 1607, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1608, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 1, .child_index = 1609, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 6, .child_index = 942, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 79, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 1, .child_index = 1610, .children_len = 4 },
    .{ .char = 's', .end_of_word = false, .number = 6, .child_index = 79, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1608, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 1614, .children_len = 7 },
    .{ .char = 'p', .end_of_word = false, .number = 14, .child_index = 1621, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1238, .children_len = 2 },
    .{ .char = 'h', .end_of_word = false, .number = 2, .child_index = 30, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 3, .child_index = 971, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1622, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 1, .child_index = 1623, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 915, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 2, .child_index = 7, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 327, .children_len = 1 },
    .{ .char = 'b', .end_of_word = false, .number = 1, .child_index = 1030, .children_len = 1 },
    .{ .char = 'h', .end_of_word = false, .number = 2, .child_index = 200, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1220, .children_len = 1 },
    .{ .char = 'b', .end_of_word = false, .number = 2, .child_index = 1358, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1624, .children_len = 2 },
    .{ .char = 't', .end_of_word = false, .number = 3, .child_index = 1361, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 28, .children_len = 1 },
    .{ .char = 'l', .end_of_word = true, .number = 1, .child_index = 86, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1081, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 1, .child_index = 1082, .children_len = 1 },
    .{ .char = 'h', .end_of_word = false, .number = 2, .child_index = 1626, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 4, .child_index = 1251, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 5, .child_index = 1627, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 8, .child_index = 1628, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1624, .children_len = 2 },
    .{ .char = 'i', .end_of_word = false, .number = 3, .child_index = 1084, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 4, .child_index = 1361, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 39, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 998, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 2, .child_index = 1240, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 327, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 1, .child_index = 925, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1629, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1630, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 1631, .children_len = 7 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1638, .children_len = 3 },
    .{ .char = 'l', .end_of_word = false, .number = 3, .child_index = 1304, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 4, .child_index = 1641, .children_len = 2 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 1361, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 1643, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1644, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 7, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 1, .child_index = 1645, .children_len = 2 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1647, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 1648, .children_len = 2 },
    .{ .char = 'i', .end_of_word = false, .number = 3, .child_index = 1650, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 499, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 140, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 940, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 2, .child_index = 140, .children_len = 1 },
    .{ .char = 'A', .end_of_word = false, .number = 0, .child_index = 327, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 327, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 140, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1111, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 39, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 1, .child_index = 1651, .children_len = 2 },
    .{ .char = 't', .end_of_word = false, .number = 3, .child_index = 1157, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 7, .children_len = 1 },
    .{ .char = 'q', .end_of_word = false, .number = 1, .child_index = 1653, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 1401, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 1, .child_index = 1361, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1654, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 234, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1655, .children_len = 2 },
    .{ .char = 'n', .end_of_word = true, .number = 0, .child_index = 86, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 22, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 1, .child_index = 925, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1657, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 1, .child_index = 79, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 1658, .children_len = 1 },
    .{ .char = 'j', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 1, .child_index = 1659, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1660, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 1093, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1661, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1662, .children_len = 1 },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 79, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1472, .children_len = 1 },
    .{ .char = 'f', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1663, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1660, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1664, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1665, .children_len = 1 },
    .{ .char = 'l', .end_of_word = true, .number = 0, .child_index = 86, .children_len = 1 },
    .{ .char = 'k', .end_of_word = false, .number = 0, .child_index = 1666, .children_len = 1 },
    .{ .char = 'v', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'w', .end_of_word = false, .number = 1, .child_index = 1210, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1667, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1668, .children_len = 1 },
    .{ .char = 'v', .end_of_word = false, .number = 0, .child_index = 1654, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 1669, .children_len = 1 },
    .{ .char = 'Y', .end_of_word = true, .number = 0, .child_index = 86, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 1670, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 1671, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1672, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 919, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 1175, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1673, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1674, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1675, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 1676, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1677, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1678, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 1, .child_index = 1679, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1680, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 1681, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 688, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 2, .child_index = 1682, .children_len = 1 },
    .{ .char = 'f', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 1683, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1684, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 1111, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'C', .end_of_word = false, .number = 1, .child_index = 894, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 1685, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 1686, .children_len = 1 },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 1469, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 't', .end_of_word = false, .number = 1, .child_index = 79, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1687, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 5, .child_index = 1688, .children_len = 1 },
    .{ .char = 'f', .end_of_word = false, .number = 0, .child_index = 1689, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'D', .end_of_word = false, .number = 1, .child_index = 39, .children_len = 1 },
    .{ .char = 'E', .end_of_word = false, .number = 2, .child_index = 1690, .children_len = 1 },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 1691, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1692, .children_len = 6 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1698, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 1699, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 1700, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1244, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1701, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 2, .child_index = 1702, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 1703, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1704, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1705, .children_len = 1 },
    .{ .char = 'A', .end_of_word = false, .number = 0, .child_index = 1706, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1707, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 1708, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 1709, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1710, .children_len = 1 },
    .{ .char = 'D', .end_of_word = false, .number = 0, .child_index = 30, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1599, .children_len = 1 },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 1711, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1712, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 1713, .children_len = 2 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1002, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 7, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 1, .child_index = 1715, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1716, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 1717, .children_len = 2 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1719, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1608, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 30, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 79, .children_len = 1 },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 1720, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1721, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 1722, .children_len = 10 },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 1732, .children_len = 6 },
    .{ .char = 'f', .end_of_word = false, .number = 0, .child_index = 1738, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 1739, .children_len = 4 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1743, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1744, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1745, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 1746, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1747, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 1748, .children_len = 1 },
    .{ .char = 'L', .end_of_word = false, .number = 0, .child_index = 1749, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1750, .children_len = 1 },
    .{ .char = 'B', .end_of_word = false, .number = 0, .child_index = 1751, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'C', .end_of_word = false, .number = 1, .child_index = 1752, .children_len = 2 },
    .{ .char = 'D', .end_of_word = false, .number = 3, .child_index = 1754, .children_len = 1 },
    .{ .char = 'E', .end_of_word = false, .number = 4, .child_index = 1755, .children_len = 3 },
    .{ .char = 'G', .end_of_word = false, .number = 8, .child_index = 1758, .children_len = 1 },
    .{ .char = 'H', .end_of_word = false, .number = 15, .child_index = 1759, .children_len = 1 },
    .{ .char = 'L', .end_of_word = false, .number = 17, .child_index = 1760, .children_len = 1 },
    .{ .char = 'N', .end_of_word = false, .number = 26, .child_index = 1761, .children_len = 1 },
    .{ .char = 'P', .end_of_word = false, .number = 28, .child_index = 1762, .children_len = 1 },
    .{ .char = 'R', .end_of_word = false, .number = 31, .child_index = 1763, .children_len = 2 },
    .{ .char = 'S', .end_of_word = false, .number = 35, .child_index = 1765, .children_len = 2 },
    .{ .char = 'T', .end_of_word = false, .number = 47, .child_index = 1767, .children_len = 1 },
    .{ .char = 'V', .end_of_word = false, .number = 51, .child_index = 1768, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1214, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 79, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 938, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1769, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1770, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1665, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 2, .child_index = 1771, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1772, .children_len = 2 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 1774, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 1775, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1776, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1777, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 1654, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 1778, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 1, .child_index = 1779, .children_len = 1 },
    .{ .char = 'T', .end_of_word = true, .number = 0, .child_index = 86, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1780, .children_len = 2 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1782, .children_len = 1 },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 1783, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1784, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 1785, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1786, .children_len = 1 },
    .{ .char = 'H', .end_of_word = false, .number = 0, .child_index = 30, .children_len = 1 },
    .{ .char = 'T', .end_of_word = false, .number = 0, .child_index = 30, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1787, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 79, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1788, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1789, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 's', .end_of_word = false, .number = 1, .child_index = 1790, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1791, .children_len = 1 },
    .{ .char = 'h', .end_of_word = false, .number = 4, .child_index = 1792, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 1793, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 3, .child_index = 1794, .children_len = 1 },
    .{ .char = 'R', .end_of_word = false, .number = 0, .child_index = 1795, .children_len = 1 },
    .{ .char = 'D', .end_of_word = false, .number = 0, .child_index = 1298, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1796, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 1, .child_index = 79, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1797, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 1, .child_index = 1798, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 1799, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 1800, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1801, .children_len = 2 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 22, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 931, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1803, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1804, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1805, .children_len = 1 },
    .{ .char = 'q', .end_of_word = false, .number = 0, .child_index = 1806, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1807, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1134, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1808, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1809, .children_len = 2 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1002, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 1349, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 1811, .children_len = 1 },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 200, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 1, .child_index = 1812, .children_len = 2 },
    .{ .char = 'y', .end_of_word = false, .number = 6, .child_index = 1814, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 1654, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1815, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 1816, .children_len = 1 },
    .{ .char = 'f', .end_of_word = false, .number = 0, .child_index = 1817, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 1, .child_index = 1349, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 7, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 1, .child_index = 1002, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 1818, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 2, .child_index = 91, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 3, .child_index = 1485, .children_len = 1 },
    .{ .char = 'v', .end_of_word = false, .number = 4, .child_index = 91, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 2, .child_index = 1654, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 3, .child_index = 1819, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 12, .child_index = 1820, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 15, .child_index = 1821, .children_len = 2 },
    .{ .char = 'z', .end_of_word = false, .number = 17, .child_index = 172, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1471, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1823, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 1824, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 941, .children_len = 1 },
    .{ .char = 'k', .end_of_word = false, .number = 0, .child_index = 1825, .children_len = 4 },
    .{ .char = 'v', .end_of_word = false, .number = 0, .child_index = 903, .children_len = 1 },
    .{ .char = 'w', .end_of_word = false, .number = 1, .child_index = 1829, .children_len = 1 },
    .{ .char = 'k', .end_of_word = false, .number = 0, .child_index = 1830, .children_len = 2 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 179, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1832, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 1833, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 42, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1834, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'h', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'w', .end_of_word = false, .number = 2, .child_index = 1331, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 889, .children_len = 3 },
    .{ .char = 'o', .end_of_word = false, .number = 3, .child_index = 1835, .children_len = 3 },
    .{ .char = 's', .end_of_word = false, .number = 6, .child_index = 1838, .children_len = 2 },
    .{ .char = 't', .end_of_word = false, .number = 8, .child_index = 1840, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 10, .child_index = 586, .children_len = 1 },
    .{ .char = 'v', .end_of_word = false, .number = 11, .child_index = 903, .children_len = 1 },
    .{ .char = 'w', .end_of_word = false, .number = 12, .child_index = 904, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1841, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1842, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 6, .child_index = 1599, .children_len = 1 },
    .{ .char = '1', .end_of_word = false, .number = 0, .child_index = 1843, .children_len = 2 },
    .{ .char = '3', .end_of_word = false, .number = 2, .child_index = 1845, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1599, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'q', .end_of_word = false, .number = 1, .child_index = 1421, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 't', .end_of_word = false, .number = 1, .child_index = 1846, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 1847, .children_len = 1 },
    .{ .char = 'D', .end_of_word = false, .number = 0, .child_index = 1848, .children_len = 4 },
    .{ .char = 'H', .end_of_word = false, .number = 4, .child_index = 1852, .children_len = 5 },
    .{ .char = 'U', .end_of_word = false, .number = 9, .child_index = 1848, .children_len = 4 },
    .{ .char = 'V', .end_of_word = false, .number = 13, .child_index = 1857, .children_len = 7 },
    .{ .char = 'b', .end_of_word = false, .number = 20, .child_index = 1864, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 21, .child_index = 1848, .children_len = 4 },
    .{ .char = 'h', .end_of_word = false, .number = 25, .child_index = 1852, .children_len = 5 },
    .{ .char = 'm', .end_of_word = false, .number = 30, .child_index = 1865, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 31, .child_index = 1401, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 32, .child_index = 1370, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 33, .child_index = 1848, .children_len = 4 },
    .{ .char = 'v', .end_of_word = false, .number = 37, .child_index = 1857, .children_len = 7 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1042, .children_len = 1 },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 1866, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 42, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 1867, .children_len = 2 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1869, .children_len = 3 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1872, .children_len = 2 },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 1874, .children_len = 3 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 1818, .children_len = 1 },
    .{ .char = 'b', .end_of_word = false, .number = 2, .child_index = 1877, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 3, .child_index = 1878, .children_len = 2 },
    .{ .char = 'd', .end_of_word = false, .number = 5, .child_index = 39, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 6, .child_index = 91, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 942, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 1, .child_index = 1472, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 1111, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 919, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 1880, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 925, .children_len = 1 },
    .{ .char = 't', .end_of_word = true, .number = 0, .child_index = 1881, .children_len = 2 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1883, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'E', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 2, .child_index = 1884, .children_len = 3 },
    .{ .char = 'e', .end_of_word = false, .number = 11, .child_index = 91, .children_len = 1 },
    .{ .char = 'f', .end_of_word = false, .number = 12, .child_index = 941, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 13, .child_index = 637, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 14, .child_index = 1110, .children_len = 1 },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 1887, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1888, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 1889, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 2, .child_index = 1890, .children_len = 3 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 1245, .children_len = 2 },
    .{ .char = 'i', .end_of_word = false, .number = 2, .child_index = 688, .children_len = 1 },
    .{ .char = 'f', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 1326, .children_len = 1 },
    .{ .char = 'y', .end_of_word = true, .number = 2, .child_index = 1893, .children_len = 2 },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 1867, .children_len = 2 },
    .{ .char = 'p', .end_of_word = false, .number = 2, .child_index = 1867, .children_len = 2 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1895, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 7, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 1, .child_index = 1673, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1896, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'b', .end_of_word = false, .number = 1, .child_index = 1897, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 2, .child_index = 1878, .children_len = 2 },
    .{ .char = 'd', .end_of_word = false, .number = 4, .child_index = 39, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 5, .child_index = 7, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 6, .child_index = 91, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1898, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 2, .child_index = 1899, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 6, .child_index = 1900, .children_len = 1 },
    .{ .char = 'v', .end_of_word = false, .number = 8, .child_index = 1901, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 11, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1902, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1329, .children_len = 1 },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 1405, .children_len = 2 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1673, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 959, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 7, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 1903, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 79, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 1904, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1905, .children_len = 2 },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 1907, .children_len = 3 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1393, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1472, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 1910, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 4, .child_index = 1911, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1912, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 1644, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 200, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 1913, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 3, .child_index = 1865, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 4, .child_index = 1401, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 5, .child_index = 1914, .children_len = 1 },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 1915, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1916, .children_len = 3 },
    .{ .char = 'k', .end_of_word = false, .number = 0, .child_index = 276, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'y', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1919, .children_len = 2 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1921, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 1686, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1922, .children_len = 2 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 919, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'd', .end_of_word = false, .number = 1, .child_index = 39, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1924, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 1925, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 1926, .children_len = 2 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1928, .children_len = 2 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 1111, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1930, .children_len = 3 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 940, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 1, .child_index = 1244, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 977, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 1, .child_index = 1933, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1934, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 1261, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 2, .child_index = 1935, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 1936, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 942, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1937, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 1, .child_index = 1938, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1528, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1939, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1002, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 1, .child_index = 991, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1111, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1706, .children_len = 1 },
    .{ .char = 'k', .end_of_word = false, .number = 1, .child_index = 1405, .children_len = 2 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1940, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1941, .children_len = 6 },
    .{ .char = 's', .end_of_word = false, .number = 18, .child_index = 1091, .children_len = 1 },
    .{ .char = 'w', .end_of_word = false, .number = 0, .child_index = 1472, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'q', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 2, .child_index = 1947, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'c', .end_of_word = false, .number = 1, .child_index = 1673, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 2, .child_index = 1948, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 5, .child_index = 1949, .children_len = 2 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1091, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 1951, .children_len = 2 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'q', .end_of_word = false, .number = 1, .child_index = 1953, .children_len = 2 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 977, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 1955, .children_len = 3 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 7, .children_len = 1 },
    .{ .char = 'P', .end_of_word = false, .number = 0, .child_index = 200, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 1958, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1959, .children_len = 2 },
    .{ .char = 'd', .end_of_word = false, .number = 2, .child_index = 39, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 3, .child_index = 1961, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 5, .child_index = 1962, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 6, .child_index = 1286, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1963, .children_len = 1 },
    .{ .char = 'E', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1964, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1965, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 30, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 1966, .children_len = 3 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1969, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1970, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 919, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 276, .children_len = 1 },
    .{ .char = 'w', .end_of_word = false, .number = 1, .child_index = 276, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 1904, .children_len = 1 },
    .{ .char = 'k', .end_of_word = false, .number = 0, .child_index = 1971, .children_len = 2 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 1706, .children_len = 1 },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 1973, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 925, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 688, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 1, .child_index = 942, .children_len = 1 },
    .{ .char = 'f', .end_of_word = false, .number = 0, .child_index = 1223, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 7, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 1, .child_index = 1974, .children_len = 3 },
    .{ .char = 't', .end_of_word = false, .number = 4, .child_index = 1349, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1977, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1978, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'c', .end_of_word = false, .number = 1, .child_index = 1979, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 2, .child_index = 1980, .children_len = 2 },
    .{ .char = 'l', .end_of_word = false, .number = 4, .child_index = 1982, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 5, .child_index = 493, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 11, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1983, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1984, .children_len = 5 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 1349, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 1989, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1973, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1709, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 1121, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1990, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 1991, .children_len = 3 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 1994, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1995, .children_len = 8 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 1709, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 2, .child_index = 2003, .children_len = 2 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2005, .children_len = 1 },
    .{ .char = 'k', .end_of_word = false, .number = 2, .child_index = 2006, .children_len = 2 },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 1709, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 1091, .children_len = 1 },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2008, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 2009, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 1, .child_index = 2010, .children_len = 1 },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2011, .children_len = 5 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'c', .end_of_word = false, .number = 1, .child_index = 1673, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 2, .child_index = 2016, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 5, .child_index = 1949, .children_len = 2 },
    .{ .char = 's', .end_of_word = false, .number = 7, .child_index = 2017, .children_len = 5 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2022, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2023, .children_len = 2 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1599, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2025, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2026, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 42, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2027, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1002, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 7, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 2028, .children_len = 3 },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 2031, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 7, .children_len = 1 },
    .{ .char = 'f', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 2, .child_index = 1251, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1382, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1261, .children_len = 1 },
    .{ .char = 'b', .end_of_word = false, .number = 1, .child_index = 200, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 2032, .children_len = 1 },
    .{ .char = 'f', .end_of_word = false, .number = 2, .child_index = 91, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2033, .children_len = 2 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2035, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 2036, .children_len = 3 },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 1, .child_index = 2008, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 903, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 1771, .children_len = 1 },
    .{ .char = 'P', .end_of_word = false, .number = 0, .child_index = 200, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 2039, .children_len = 3 },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 2010, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 1, .child_index = 2009, .children_len = 1 },
    .{ .char = 'r', .end_of_word = true, .number = 0, .child_index = 86, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 1, .child_index = 2042, .children_len = 2 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 's', .end_of_word = false, .number = 1, .child_index = 2044, .children_len = 1 },
    .{ .char = 'k', .end_of_word = false, .number = 0, .child_index = 1686, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 1055, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 2045, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1994, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 1261, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 2, .child_index = 1471, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 3, .child_index = 2046, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2047, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1251, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1934, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 2048, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2049, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'v', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'f', .end_of_word = false, .number = 0, .child_index = 2050, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 79, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'E', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 2, .child_index = 11, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 3, .child_index = 1111, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 4, .child_index = 2051, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2052, .children_len = 1 },
    .{ .char = 'p', .end_of_word = true, .number = 0, .child_index = 86, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 2053, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 919, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2054, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2055, .children_len = 2 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2057, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 200, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 977, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2058, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'q', .end_of_word = false, .number = 1, .child_index = 1275, .children_len = 3 },
    .{ .char = 's', .end_of_word = false, .number = 4, .child_index = 91, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'd', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'f', .end_of_word = false, .number = 1, .child_index = 2050, .children_len = 1 },
    .{ .char = 'q', .end_of_word = false, .number = 3, .child_index = 1275, .children_len = 3 },
    .{ .char = 's', .end_of_word = false, .number = 6, .child_index = 2003, .children_len = 2 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 2059, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 2060, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 7, .child_index = 2061, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2062, .children_len = 4 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1674, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'c', .end_of_word = false, .number = 1, .child_index = 1503, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 2, .child_index = 2066, .children_len = 2 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2068, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2059, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'c', .end_of_word = false, .number = 1, .child_index = 1503, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 2, .child_index = 91, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 3, .child_index = 91, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1542, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 2069, .children_len = 2 },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 2071, .children_len = 1 },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 2072, .children_len = 4 },
    .{ .char = 'c', .end_of_word = false, .number = 6, .child_index = 2076, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 8, .child_index = 2072, .children_len = 4 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2077, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 2078, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 2, .child_index = 140, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1315, .children_len = 1 },
    .{ .char = 'A', .end_of_word = false, .number = 0, .child_index = 327, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 2, .child_index = 2079, .children_len = 2 },
    .{ .char = 'A', .end_of_word = false, .number = 0, .child_index = 327, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 1, .child_index = 2081, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 200, .children_len = 1 },
    .{ .char = 'v', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2082, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 7, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 7, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 49, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1654, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 938, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 2, .child_index = 1251, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 140, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 2083, .children_len = 1 },
    .{ .char = 'f', .end_of_word = true, .number = 3, .child_index = 86, .children_len = 1 },
    .{ .char = 'm', .end_of_word = true, .number = 5, .child_index = 86, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 415, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2084, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1665, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 2, .child_index = 2085, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'a', .end_of_word = true, .number = 1, .child_index = 2086, .children_len = 2 },
    .{ .char = 's', .end_of_word = false, .number = 4, .child_index = 2088, .children_len = 2 },
    .{ .char = 't', .end_of_word = false, .number = 6, .child_index = 91, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 688, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 1326, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 2, .child_index = 1709, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 3, .child_index = 91, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 4, .child_index = 2090, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 2091, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 2092, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2093, .children_len = 2 },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 2095, .children_len = 9 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1940, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2104, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 1654, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'c', .end_of_word = false, .number = 1, .child_index = 2105, .children_len = 6 },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 2111, .children_len = 1 },
    .{ .char = 'E', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 140, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 2, .child_index = 1286, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'f', .end_of_word = false, .number = 1, .child_index = 2112, .children_len = 3 },
    .{ .char = 'p', .end_of_word = false, .number = 4, .child_index = 2115, .children_len = 2 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1282, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1964, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2117, .children_len = 2 },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 2119, .children_len = 1 },
    .{ .char = 't', .end_of_word = true, .number = 0, .child_index = 86, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 1, .child_index = 1670, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1673, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 2120, .children_len = 4 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2124, .children_len = 11 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1709, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 2135, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 2009, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2136, .children_len = 4 },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 2140, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2141, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2142, .children_len = 2 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1440, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2144, .children_len = 4 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2009, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'd', .end_of_word = false, .number = 1, .child_index = 1709, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2148, .children_len = 3 },
    .{ .char = 'w', .end_of_word = false, .number = 0, .child_index = 200, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 2151, .children_len = 2 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'o', .end_of_word = false, .number = 1, .child_index = 1274, .children_len = 1 },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 30, .children_len = 1 },
    .{ .char = 'y', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2153, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 2154, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'd', .end_of_word = false, .number = 1, .child_index = 39, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 2, .child_index = 1953, .children_len = 2 },
    .{ .char = 'g', .end_of_word = false, .number = 4, .child_index = 533, .children_len = 2 },
    .{ .char = 'l', .end_of_word = false, .number = 6, .child_index = 533, .children_len = 2 },
    .{ .char = 'n', .end_of_word = false, .number = 8, .child_index = 1654, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 9, .child_index = 1401, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 10, .child_index = 172, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2155, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 1, .child_index = 2156, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 1, .child_index = 1654, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 2003, .children_len = 2 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 30, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'b', .end_of_word = false, .number = 1, .child_index = 2157, .children_len = 2 },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 2159, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 2, .child_index = 91, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2160, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 2, .child_index = 2160, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2161, .children_len = 2 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 2163, .children_len = 1 },
    .{ .char = 'f', .end_of_word = false, .number = 3, .child_index = 91, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2164, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1939, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2165, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1919, .children_len = 2 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2166, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 2, .child_index = 1111, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'E', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 2, .child_index = 39, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 3, .child_index = 1245, .children_len = 2 },
    .{ .char = 'm', .end_of_word = false, .number = 5, .child_index = 2167, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 6, .child_index = 2168, .children_len = 2 },
    .{ .char = 'p', .end_of_word = false, .number = 8, .child_index = 1401, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 9, .child_index = 172, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 10, .child_index = 2170, .children_len = 3 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 2105, .children_len = 6 },
    .{ .char = '1', .end_of_word = true, .number = 0, .child_index = 86, .children_len = 1 },
    .{ .char = '2', .end_of_word = true, .number = 2, .child_index = 86, .children_len = 1 },
    .{ .char = '3', .end_of_word = true, .number = 4, .child_index = 86, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 6, .child_index = 0, .children_len = 0 },
    .{ .char = 'E', .end_of_word = false, .number = 7, .child_index = 91, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 8, .child_index = 2173, .children_len = 2 },
    .{ .char = 'e', .end_of_word = false, .number = 10, .child_index = 1245, .children_len = 2 },
    .{ .char = 'h', .end_of_word = false, .number = 12, .child_index = 2175, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 14, .child_index = 172, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 15, .child_index = 2167, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 16, .child_index = 2168, .children_len = 2 },
    .{ .char = 'p', .end_of_word = false, .number = 18, .child_index = 1401, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 19, .child_index = 2170, .children_len = 3 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 1794, .children_len = 1 },
    .{ .char = 'k', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2176, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2177, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 2, .child_index = 2178, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 2179, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 2, .child_index = 1964, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 140, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 1, .child_index = 1286, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 906, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 1654, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2180, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'b', .end_of_word = false, .number = 1, .child_index = 39, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 2, .child_index = 1471, .children_len = 1 },
    .{ .char = 'f', .end_of_word = false, .number = 3, .child_index = 2181, .children_len = 2 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2183, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 7, .child_index = 39, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 8, .child_index = 91, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 9, .child_index = 1865, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 10, .child_index = 1401, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 11, .child_index = 1345, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 12, .child_index = 1157, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2184, .children_len = 1 },
    .{ .char = 'x', .end_of_word = false, .number = 0, .child_index = 942, .children_len = 1 },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 2185, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2186, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 2, .child_index = 1644, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2187, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2188, .children_len = 3 },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 2191, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1405, .children_len = 2 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 2192, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2193, .children_len = 1 },
    .{ .char = 'k', .end_of_word = false, .number = 1, .child_index = 2194, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 2, .child_index = 2195, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 3, .child_index = 2196, .children_len = 3 },
    .{ .char = 'r', .end_of_word = false, .number = 6, .child_index = 2199, .children_len = 2 },
    .{ .char = 's', .end_of_word = false, .number = 8, .child_index = 2201, .children_len = 2 },
    .{ .char = 't', .end_of_word = false, .number = 13, .child_index = 2203, .children_len = 2 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'b', .end_of_word = false, .number = 1, .child_index = 200, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 2, .child_index = 2205, .children_len = 1 },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 200, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2206, .children_len = 2 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 140, .children_len = 1 },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 2208, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 2, .child_index = 2208, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 2209, .children_len = 1 },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 200, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 1, .child_index = 2210, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1479, .children_len = 1 },
    .{ .char = 'f', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 1, .child_index = 1251, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 2211, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 1093, .children_len = 1 },
    .{ .char = 'y', .end_of_word = false, .number = 2, .child_index = 91, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2165, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 172, .children_len = 1 },
    .{ .char = 'j', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'g', .end_of_word = true, .number = 0, .child_index = 86, .children_len = 1 },
    .{ .char = 'c', .end_of_word = true, .number = 0, .child_index = 86, .children_len = 1 },
    .{ .char = 'v', .end_of_word = false, .number = 0, .child_index = 1816, .children_len = 1 },
    .{ .char = 'y', .end_of_word = false, .number = 0, .child_index = 2212, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 1472, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 1816, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 2213, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2214, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2215, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2205, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 1654, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2216, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2217, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 688, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1408, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2218, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2219, .children_len = 1 },
    .{ .char = 'k', .end_of_word = false, .number = 0, .child_index = 2220, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1769, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1867, .children_len = 2 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2221, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2222, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2223, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2224, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2225, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 7, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2226, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1818, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2227, .children_len = 1 },
    .{ .char = 'q', .end_of_word = false, .number = 0, .child_index = 2228, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2229, .children_len = 1 },
    .{ .char = 'A', .end_of_word = false, .number = 0, .child_index = 2230, .children_len = 1 },
    .{ .char = 'B', .end_of_word = false, .number = 3, .child_index = 4, .children_len = 1 },
    .{ .char = 'L', .end_of_word = false, .number = 4, .child_index = 2231, .children_len = 1 },
    .{ .char = 'R', .end_of_word = false, .number = 8, .child_index = 2232, .children_len = 1 },
    .{ .char = 'T', .end_of_word = false, .number = 11, .child_index = 1080, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 13, .child_index = 1081, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1599, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 688, .children_len = 1 },
    .{ .char = 'y', .end_of_word = false, .number = 0, .child_index = 2233, .children_len = 2 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2235, .children_len = 2 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2237, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 1111, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2238, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2239, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1091, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2240, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1428, .children_len = 2 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1091, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2241, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2242, .children_len = 1 },
    .{ .char = 'z', .end_of_word = false, .number = 0, .child_index = 2243, .children_len = 1 },
    .{ .char = 'D', .end_of_word = false, .number = 0, .child_index = 2244, .children_len = 1 },
    .{ .char = 'E', .end_of_word = false, .number = 1, .child_index = 1690, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2245, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1771, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 2246, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 2247, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 2248, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 79, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2249, .children_len = 1 },
    .{ .char = 'A', .end_of_word = false, .number = 0, .child_index = 2250, .children_len = 2 },
    .{ .char = 'C', .end_of_word = false, .number = 4, .child_index = 2252, .children_len = 1 },
    .{ .char = 'D', .end_of_word = false, .number = 5, .child_index = 2253, .children_len = 1 },
    .{ .char = 'F', .end_of_word = false, .number = 9, .child_index = 2254, .children_len = 1 },
    .{ .char = 'R', .end_of_word = false, .number = 10, .child_index = 2255, .children_len = 1 },
    .{ .char = 'T', .end_of_word = false, .number = 12, .child_index = 2256, .children_len = 2 },
    .{ .char = 'U', .end_of_word = false, .number = 18, .child_index = 2258, .children_len = 1 },
    .{ .char = 'V', .end_of_word = false, .number = 22, .child_index = 2259, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 24, .child_index = 1081, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 25, .child_index = 183, .children_len = 1 },
    .{ .char = 'E', .end_of_word = false, .number = 0, .child_index = 2260, .children_len = 1 },
    .{ .char = 'F', .end_of_word = false, .number = 1, .child_index = 2261, .children_len = 1 },
    .{ .char = 'G', .end_of_word = false, .number = 2, .child_index = 2262, .children_len = 1 },
    .{ .char = 'L', .end_of_word = false, .number = 3, .child_index = 1962, .children_len = 1 },
    .{ .char = 'S', .end_of_word = false, .number = 4, .child_index = 2263, .children_len = 1 },
    .{ .char = 'T', .end_of_word = false, .number = 5, .child_index = 110, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2264, .children_len = 1 },
    .{ .char = 'L', .end_of_word = false, .number = 0, .child_index = 2265, .children_len = 1 },
    .{ .char = 'R', .end_of_word = false, .number = 2, .child_index = 2266, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 3, .child_index = 2267, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 5, .child_index = 183, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2268, .children_len = 2 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2270, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2271, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 2272, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2273, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2274, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1475, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2275, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2276, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2277, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 1, .child_index = 2278, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2279, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 72, .children_len = 1 },
    .{ .char = 'q', .end_of_word = false, .number = 1, .child_index = 2280, .children_len = 1 },
    .{ .char = 'x', .end_of_word = false, .number = 3, .child_index = 2281, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2282, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 100, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2283, .children_len = 2 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2285, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2286, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2287, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 2288, .children_len = 1 },
    .{ .char = 'q', .end_of_word = false, .number = 0, .child_index = 2289, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 4, .child_index = 2290, .children_len = 3 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 213, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2293, .children_len = 1 },
    .{ .char = 'C', .end_of_word = false, .number = 0, .child_index = 2294, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 2295, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1111, .children_len = 1 },
    .{ .char = 'B', .end_of_word = false, .number = 0, .child_index = 2296, .children_len = 2 },
    .{ .char = 'P', .end_of_word = false, .number = 3, .child_index = 2298, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2299, .children_len = 1 },
    .{ .char = 'M', .end_of_word = false, .number = 0, .child_index = 1865, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 2300, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2301, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2302, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2303, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 't', .end_of_word = false, .number = 1, .child_index = 1091, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2304, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2305, .children_len = 8 },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 2313, .children_len = 1 },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 1738, .children_len = 1 },
    .{ .char = 'D', .end_of_word = false, .number = 0, .child_index = 2314, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2315, .children_len = 4 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2319, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2320, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2321, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2322, .children_len = 1 },
    .{ .char = 'T', .end_of_word = false, .number = 0, .child_index = 2323, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2324, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 942, .children_len = 1 },
    .{ .char = 'N', .end_of_word = true, .number = 0, .child_index = 86, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2325, .children_len = 1 },
    .{ .char = 'k', .end_of_word = false, .number = 0, .child_index = 1798, .children_len = 1 },
    .{ .char = 'S', .end_of_word = false, .number = 0, .child_index = 2326, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2327, .children_len = 4 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2331, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'o', .end_of_word = false, .number = 1, .child_index = 1110, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2332, .children_len = 2 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2334, .children_len = 1 },
    .{ .char = 'w', .end_of_word = false, .number = 0, .child_index = 2335, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2336, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2337, .children_len = 2 },
    .{ .char = 'w', .end_of_word = false, .number = 0, .child_index = 2339, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'l', .end_of_word = false, .number = 1, .child_index = 919, .children_len = 1 },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 421, .children_len = 2 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 2340, .children_len = 1 },
    .{ .char = 'T', .end_of_word = false, .number = 0, .child_index = 2341, .children_len = 1 },
    .{ .char = 'W', .end_of_word = false, .number = 0, .child_index = 2342, .children_len = 1 },
    .{ .char = 'e', .end_of_word = true, .number = 0, .child_index = 86, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 2343, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 11, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 2344, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2345, .children_len = 2 },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 1349, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2347, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 2348, .children_len = 2 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 2350, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 2193, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 2, .child_index = 286, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 3, .child_index = 2351, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2352, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 't', .end_of_word = false, .number = 1, .child_index = 2353, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2354, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2355, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2356, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 39, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 1, .child_index = 1401, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 2, .child_index = 1370, .children_len = 1 },
    .{ .char = 'q', .end_of_word = false, .number = 0, .child_index = 1653, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 1, .child_index = 200, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2357, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2358, .children_len = 1 },
    .{ .char = 'k', .end_of_word = false, .number = 0, .child_index = 2359, .children_len = 3 },
    .{ .char = '2', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = '4', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = '4', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 977, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1654, .children_len = 1 },
    .{ .char = 'L', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'R', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 2, .child_index = 91, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 3, .child_index = 91, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'D', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'U', .end_of_word = false, .number = 2, .child_index = 91, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 3, .child_index = 91, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 4, .child_index = 91, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'H', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'L', .end_of_word = false, .number = 2, .child_index = 91, .children_len = 1 },
    .{ .char = 'R', .end_of_word = false, .number = 3, .child_index = 91, .children_len = 1 },
    .{ .char = 'h', .end_of_word = false, .number = 4, .child_index = 91, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 5, .child_index = 91, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 6, .child_index = 91, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2362, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2363, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1387, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'b', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'h', .end_of_word = false, .number = 2, .child_index = 2364, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 942, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'E', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 2, .child_index = 1953, .children_len = 2 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1653, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 140, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 1, .child_index = 140, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 2365, .children_len = 2 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 2367, .children_len = 1 },
    .{ .char = 'k', .end_of_word = false, .number = 0, .child_index = 2368, .children_len = 2 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 2205, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 2, .child_index = 2370, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 2371, .children_len = 2 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2069, .children_len = 2 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2373, .children_len = 2 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'f', .end_of_word = false, .number = 1, .child_index = 1472, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 2, .child_index = 2375, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 's', .end_of_word = false, .number = 1, .child_index = 7, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1220, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2376, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2377, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2378, .children_len = 1 },
    .{ .char = 'y', .end_of_word = false, .number = 0, .child_index = 2379, .children_len = 3 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 906, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2031, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 22, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 1669, .children_len = 1 },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 942, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'o', .end_of_word = false, .number = 1, .child_index = 2382, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 3, .child_index = 91, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 2383, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2362, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1472, .children_len = 1 },
    .{ .char = 'q', .end_of_word = false, .number = 0, .child_index = 1245, .children_len = 2 },
    .{ .char = 'q', .end_of_word = false, .number = 0, .child_index = 2384, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2385, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1081, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 1, .child_index = 2386, .children_len = 1 },
    .{ .char = 'h', .end_of_word = false, .number = 2, .child_index = 1626, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'f', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 1939, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'c', .end_of_word = true, .number = 1, .child_index = 86, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2387, .children_len = 1 },
    .{ .char = 'y', .end_of_word = false, .number = 0, .child_index = 2388, .children_len = 3 },
    .{ .char = '1', .end_of_word = false, .number = 0, .child_index = 2391, .children_len = 2 },
    .{ .char = ';', .end_of_word = true, .number = 2, .child_index = 0, .children_len = 0 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 's', .end_of_word = false, .number = 1, .child_index = 1091, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'l', .end_of_word = false, .number = 1, .child_index = 919, .children_len = 1 },
    .{ .char = 'v', .end_of_word = false, .number = 2, .child_index = 91, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2393, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1111, .children_len = 1 },
    .{ .char = 'v', .end_of_word = false, .number = 0, .child_index = 2394, .children_len = 2 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2396, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 2397, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2398, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1654, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 1674, .children_len = 1 },
    .{ .char = '1', .end_of_word = false, .number = 0, .child_index = 2399, .children_len = 6 },
    .{ .char = '2', .end_of_word = false, .number = 8, .child_index = 2405, .children_len = 2 },
    .{ .char = '3', .end_of_word = false, .number = 10, .child_index = 2407, .children_len = 3 },
    .{ .char = '4', .end_of_word = false, .number = 14, .child_index = 2410, .children_len = 1 },
    .{ .char = '5', .end_of_word = false, .number = 15, .child_index = 2411, .children_len = 2 },
    .{ .char = '7', .end_of_word = false, .number = 17, .child_index = 2413, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2414, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2415, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 1111, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'p', .end_of_word = false, .number = 1, .child_index = 2051, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'q', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 2, .child_index = 91, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1261, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 2416, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 7, .children_len = 1 },
    .{ .char = 'q', .end_of_word = false, .number = 0, .child_index = 2417, .children_len = 2 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 955, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2419, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 140, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 942, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'c', .end_of_word = false, .number = 1, .child_index = 1471, .children_len = 1 },
    .{ .char = 'w', .end_of_word = false, .number = 2, .child_index = 91, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 1887, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 140, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2420, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 183, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1472, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 1, .child_index = 1749, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 2, .child_index = 2421, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1654, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2422, .children_len = 2 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1091, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 2387, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 2424, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2425, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 1517, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'E', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 2, .child_index = 39, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 3, .child_index = 1405, .children_len = 2 },
    .{ .char = 'v', .end_of_word = false, .number = 5, .child_index = 91, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1405, .children_len = 2 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1472, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'd', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 2, .child_index = 1654, .children_len = 1 },
    .{ .char = 'o', .end_of_word = true, .number = 0, .child_index = 86, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'b', .end_of_word = false, .number = 1, .child_index = 2426, .children_len = 2 },
    .{ .char = 'f', .end_of_word = false, .number = 3, .child_index = 1111, .children_len = 1 },
    .{ .char = 'h', .end_of_word = false, .number = 4, .child_index = 1599, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 5, .child_index = 140, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 6, .child_index = 1091, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 7, .child_index = 1286, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 8, .child_index = 1091, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 's', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 2428, .children_len = 2 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 1, .child_index = 2430, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 244, .children_len = 2 },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 200, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 2009, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2431, .children_len = 1 },
    .{ .char = 'h', .end_of_word = false, .number = 2, .child_index = 2432, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 4, .child_index = 2433, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 5, .child_index = 2434, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 9, .child_index = 2435, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2436, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2437, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 1, .child_index = 39, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 2, .child_index = 2438, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 4, .child_index = 2439, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 5, .child_index = 1286, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 7, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 1, .child_index = 421, .children_len = 2 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2440, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 11, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 2441, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2267, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 2, .child_index = 2442, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 3, .child_index = 183, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2443, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1090, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'l', .end_of_word = false, .number = 1, .child_index = 942, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1428, .children_len = 2 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 2, .child_index = 91, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'f', .end_of_word = false, .number = 2, .child_index = 91, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 2214, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2444, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2445, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1517, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 2446, .children_len = 3 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1111, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2449, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2450, .children_len = 2 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1864, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2452, .children_len = 2 },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 1867, .children_len = 2 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 1245, .children_len = 2 },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 1599, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 2454, .children_len = 2 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1469, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 2456, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1867, .children_len = 2 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2457, .children_len = 4 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2461, .children_len = 2 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 2463, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 2, .child_index = 1091, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 3, .child_index = 91, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'c', .end_of_word = false, .number = 1, .child_index = 2348, .children_len = 2 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2464, .children_len = 3 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 1953, .children_len = 2 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2467, .children_len = 2 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'E', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 2, .child_index = 91, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 3, .child_index = 2469, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 2348, .children_len = 2 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2470, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 179, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 1847, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1847, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 11, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2471, .children_len = 2 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2473, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2474, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'l', .end_of_word = false, .number = 1, .child_index = 2475, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 977, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2476, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 942, .children_len = 1 },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 2477, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 2478, .children_len = 1 },
    .{ .char = 'k', .end_of_word = false, .number = 2, .child_index = 1469, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 1110, .children_len = 1 },
    .{ .char = 'b', .end_of_word = false, .number = 2, .child_index = 91, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 3, .child_index = 1471, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 4, .child_index = 2479, .children_len = 2 },
    .{ .char = 'e', .end_of_word = false, .number = 6, .child_index = 91, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 7, .child_index = 906, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 9, .child_index = 1286, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 10, .child_index = 2481, .children_len = 1 },
    .{ .char = 'd', .end_of_word = true, .number = 0, .child_index = 86, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 2437, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 2, .child_index = 2482, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 3, .child_index = 2205, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 4, .child_index = 2483, .children_len = 3 },
    .{ .char = 's', .end_of_word = false, .number = 7, .child_index = 1286, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2003, .children_len = 2 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1229, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 1, .child_index = 1749, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 2, .child_index = 2486, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 't', .end_of_word = false, .number = 1, .child_index = 179, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2487, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 688, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2348, .children_len = 2 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'd', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 2, .child_index = 91, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 3, .child_index = 1654, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 140, .children_len = 1 },
    .{ .char = 'b', .end_of_word = false, .number = 2, .child_index = 2426, .children_len = 2 },
    .{ .char = 'c', .end_of_word = false, .number = 4, .child_index = 91, .children_len = 1 },
    .{ .char = 'f', .end_of_word = false, .number = 5, .child_index = 1111, .children_len = 1 },
    .{ .char = 'h', .end_of_word = false, .number = 6, .child_index = 1599, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 7, .child_index = 140, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 8, .child_index = 1091, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 9, .child_index = 1286, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 10, .child_index = 1091, .children_len = 1 },
    .{ .char = 'w', .end_of_word = false, .number = 11, .child_index = 91, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2488, .children_len = 2 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 1475, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 2, .child_index = 2421, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 3, .child_index = 91, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2490, .children_len = 6 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2496, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'g', .end_of_word = false, .number = 1, .child_index = 942, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'f', .end_of_word = false, .number = 2, .child_index = 91, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 3, .child_index = 879, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'b', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 2, .child_index = 91, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2363, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2497, .children_len = 2 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2499, .children_len = 3 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2502, .children_len = 1 },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 140, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 7, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1887, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 2003, .children_len = 2 },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 2503, .children_len = 3 },
    .{ .char = 'p', .end_of_word = false, .number = 4, .child_index = 2503, .children_len = 3 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2506, .children_len = 2 },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 1472, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 920, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2508, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 1965, .children_len = 1 },
    .{ .char = 'E', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2509, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 5, .child_index = 977, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 6, .child_index = 2206, .children_len = 2 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 942, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 1, .child_index = 2510, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 2511, .children_len = 2 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1673, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2513, .children_len = 2 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2515, .children_len = 3 },
    .{ .char = 'k', .end_of_word = false, .number = 0, .child_index = 2518, .children_len = 2 },
    .{ .char = 's', .end_of_word = true, .number = 0, .child_index = 2520, .children_len = 3 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'o', .end_of_word = false, .number = 1, .child_index = 828, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2523, .children_len = 1 },
    .{ .char = 'z', .end_of_word = false, .number = 0, .child_index = 2524, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2525, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2526, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2527, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'h', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 2, .child_index = 919, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2528, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 942, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 75, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 118, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2529, .children_len = 1 },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 42, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 2, .child_index = 2530, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'h', .end_of_word = false, .number = 1, .child_index = 179, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 196, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 1, .child_index = 2531, .children_len = 2 },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 2533, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 2534, .children_len = 1 },
    .{ .char = 'q', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2168, .children_len = 2 },
    .{ .char = 'z', .end_of_word = false, .number = 0, .child_index = 2535, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1953, .children_len = 2 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 140, .children_len = 1 },
    .{ .char = 'F', .end_of_word = false, .number = 0, .child_index = 2536, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 229, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 1654, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2537, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2538, .children_len = 1 },
    .{ .char = 'y', .end_of_word = false, .number = 0, .child_index = 1111, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 573, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2539, .children_len = 4 },
    .{ .char = 'w', .end_of_word = false, .number = 0, .child_index = 2543, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 1699, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2544, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 1778, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2545, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2546, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2547, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2548, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 1979, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2549, .children_len = 6 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2555, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2556, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2557, .children_len = 1 },
    .{ .char = 'S', .end_of_word = false, .number = 0, .child_index = 2558, .children_len = 1 },
    .{ .char = 'V', .end_of_word = false, .number = 1, .child_index = 2559, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'T', .end_of_word = false, .number = 1, .child_index = 110, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2560, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2561, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 2233, .children_len = 2 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2562, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2563, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2564, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2565, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2566, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2567, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1979, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 2568, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2569, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 2570, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2571, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 2572, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2573, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2574, .children_len = 2 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1356, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2576, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2577, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 3, .child_index = 2578, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 2579, .children_len = 3 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2582, .children_len = 1 },
    .{ .char = 'q', .end_of_word = false, .number = 0, .child_index = 2583, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2584, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2585, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2586, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1081, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2587, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2588, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1407, .children_len = 1 },
    .{ .char = 'L', .end_of_word = false, .number = 0, .child_index = 2589, .children_len = 1 },
    .{ .char = 'R', .end_of_word = false, .number = 1, .child_index = 2266, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 1798, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1657, .children_len = 1 },
    .{ .char = 'P', .end_of_word = false, .number = 0, .child_index = 1401, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2590, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 2591, .children_len = 2 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1599, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2593, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2594, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 2595, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2596, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2597, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 978, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2598, .children_len = 1 },
    .{ .char = 'f', .end_of_word = false, .number = 0, .child_index = 2599, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 3, .child_index = 2600, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 1013, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2601, .children_len = 1 },
    .{ .char = 'v', .end_of_word = false, .number = 0, .child_index = 2602, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 2603, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2604, .children_len = 1 },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 2324, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 2, .child_index = 2605, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 6, .child_index = 2606, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2607, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2608, .children_len = 1 },
    .{ .char = 'h', .end_of_word = true, .number = 0, .child_index = 86, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 7, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 2609, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2610, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2611, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2612, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 2613, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 942, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2614, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 2615, .children_len = 1 },
    .{ .char = 'A', .end_of_word = false, .number = 0, .child_index = 2616, .children_len = 2 },
    .{ .char = 'C', .end_of_word = false, .number = 4, .child_index = 2252, .children_len = 1 },
    .{ .char = 'D', .end_of_word = false, .number = 5, .child_index = 2253, .children_len = 1 },
    .{ .char = 'F', .end_of_word = false, .number = 9, .child_index = 2254, .children_len = 1 },
    .{ .char = 'T', .end_of_word = false, .number = 10, .child_index = 2256, .children_len = 2 },
    .{ .char = 'U', .end_of_word = false, .number = 16, .child_index = 2258, .children_len = 1 },
    .{ .char = 'V', .end_of_word = false, .number = 20, .child_index = 2259, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 22, .child_index = 1081, .children_len = 1 },
    .{ .char = 'I', .end_of_word = false, .number = 0, .child_index = 2618, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2619, .children_len = 1 },
    .{ .char = 'D', .end_of_word = false, .number = 0, .child_index = 1078, .children_len = 1 },
    .{ .char = 'L', .end_of_word = false, .number = 1, .child_index = 2589, .children_len = 1 },
    .{ .char = 'R', .end_of_word = false, .number = 2, .child_index = 2266, .children_len = 1 },
    .{ .char = 'U', .end_of_word = false, .number = 3, .child_index = 2620, .children_len = 1 },
    .{ .char = 'C', .end_of_word = false, .number = 0, .child_index = 2621, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2622, .children_len = 4 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2626, .children_len = 2 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2628, .children_len = 1 },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 2091, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 1790, .children_len = 1 },
    .{ .char = 'f', .end_of_word = false, .number = 0, .child_index = 2629, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 2630, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'E', .end_of_word = false, .number = 1, .child_index = 1690, .children_len = 1 },
    .{ .char = 'F', .end_of_word = false, .number = 2, .child_index = 2261, .children_len = 1 },
    .{ .char = 'T', .end_of_word = false, .number = 3, .child_index = 110, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 573, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'P', .end_of_word = false, .number = 1, .child_index = 1401, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2631, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2632, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1702, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'A', .end_of_word = false, .number = 1, .child_index = 1081, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2264, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 2633, .children_len = 1 },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 2634, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2635, .children_len = 1 },
    .{ .char = 'y', .end_of_word = false, .number = 0, .child_index = 977, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 2636, .children_len = 2 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'v', .end_of_word = false, .number = 1, .child_index = 2638, .children_len = 1 },
    .{ .char = 'x', .end_of_word = false, .number = 0, .child_index = 2348, .children_len = 2 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 2205, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1084, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2639, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 2640, .children_len = 2 },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 828, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 1867, .children_len = 2 },
    .{ .char = 'y', .end_of_word = false, .number = 0, .child_index = 1469, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2642, .children_len = 1 },
    .{ .char = 'w', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2643, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 1, .child_index = 1914, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 2, .child_index = 2644, .children_len = 1 },
    .{ .char = 'x', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1251, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 2510, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 's', .end_of_word = false, .number = 1, .child_index = 977, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 318, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'm', .end_of_word = false, .number = 1, .child_index = 2645, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2646, .children_len = 2 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'u', .end_of_word = false, .number = 1, .child_index = 2648, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 't', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2649, .children_len = 2 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2651, .children_len = 2 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 894, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2653, .children_len = 2 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2655, .children_len = 1 },
    .{ .char = 'v', .end_of_word = false, .number = 2, .child_index = 903, .children_len = 1 },
    .{ .char = 'w', .end_of_word = false, .number = 3, .child_index = 904, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2656, .children_len = 1 },
    .{ .char = 'e', .end_of_word = true, .number = 0, .child_index = 2657, .children_len = 2 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 1319, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2659, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2660, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2661, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 's', .end_of_word = false, .number = 1, .child_index = 1794, .children_len = 1 },
    .{ .char = 'v', .end_of_word = false, .number = 2, .child_index = 91, .children_len = 1 },
    .{ .char = '3', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = '4', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2662, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'D', .end_of_word = false, .number = 1, .child_index = 2663, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2664, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2665, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2666, .children_len = 1 },
    .{ .char = '2', .end_of_word = true, .number = 0, .child_index = 86, .children_len = 1 },
    .{ .char = '3', .end_of_word = false, .number = 2, .child_index = 91, .children_len = 1 },
    .{ .char = '4', .end_of_word = true, .number = 3, .child_index = 86, .children_len = 1 },
    .{ .char = '5', .end_of_word = false, .number = 5, .child_index = 91, .children_len = 1 },
    .{ .char = '6', .end_of_word = false, .number = 6, .child_index = 91, .children_len = 1 },
    .{ .char = '8', .end_of_word = false, .number = 7, .child_index = 91, .children_len = 1 },
    .{ .char = '3', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = '5', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = '4', .end_of_word = true, .number = 0, .child_index = 86, .children_len = 1 },
    .{ .char = '5', .end_of_word = false, .number = 2, .child_index = 91, .children_len = 1 },
    .{ .char = '8', .end_of_word = false, .number = 3, .child_index = 91, .children_len = 1 },
    .{ .char = '5', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = '6', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = '8', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = '8', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 688, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2667, .children_len = 2 },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 2051, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1962, .children_len = 1 },
    .{ .char = 'q', .end_of_word = false, .number = 1, .child_index = 2669, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2670, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1006, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2192, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 't', .end_of_word = false, .number = 1, .child_index = 1847, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1979, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2671, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'f', .end_of_word = false, .number = 1, .child_index = 1111, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'k', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2672, .children_len = 2 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2674, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2675, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2676, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2677, .children_len = 1 },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 2678, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2679, .children_len = 2 },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 2416, .children_len = 1 },
    .{ .char = 'q', .end_of_word = false, .number = 0, .child_index = 2681, .children_len = 2 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 7, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1686, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2683, .children_len = 2 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2685, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2686, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2687, .children_len = 4 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2691, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'b', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 2, .child_index = 2692, .children_len = 2 },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 894, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1081, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 183, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 2694, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'o', .end_of_word = false, .number = 1, .child_index = 2358, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2003, .children_len = 2 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'E', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 2, .child_index = 39, .children_len = 1 },
    .{ .char = 'v', .end_of_word = false, .number = 3, .child_index = 2695, .children_len = 3 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'v', .end_of_word = false, .number = 1, .child_index = 2695, .children_len = 3 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2475, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'c', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'w', .end_of_word = false, .number = 2, .child_index = 91, .children_len = 1 },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 1654, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 1, .child_index = 1654, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2698, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2699, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'o', .end_of_word = false, .number = 1, .child_index = 920, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 1654, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 2700, .children_len = 2 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1282, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1599, .children_len = 1 },
    .{ .char = 'f', .end_of_word = false, .number = 0, .child_index = 2702, .children_len = 1 },
    .{ .char = 'k', .end_of_word = false, .number = 0, .child_index = 2703, .children_len = 2 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'w', .end_of_word = false, .number = 0, .child_index = 179, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2705, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2437, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 2706, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 2, .child_index = 1286, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2165, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2707, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'n', .end_of_word = false, .number = 1, .child_index = 2708, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2431, .children_len = 1 },
    .{ .char = 'h', .end_of_word = false, .number = 2, .child_index = 2432, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 4, .child_index = 2709, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 6, .child_index = 2710, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 7, .child_index = 2711, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 8, .child_index = 2435, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 2712, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 637, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 1, .child_index = 2713, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'f', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'v', .end_of_word = false, .number = 2, .child_index = 91, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 2714, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 2, .child_index = 2715, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'f', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 2716, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2717, .children_len = 3 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 1345, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1091, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 1, .child_index = 1345, .children_len = 1 },
    .{ .char = '4', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'f', .end_of_word = false, .number = 1, .child_index = 2629, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 's', .end_of_word = false, .number = 1, .child_index = 2343, .children_len = 1 },
    .{ .char = 'v', .end_of_word = false, .number = 2, .child_index = 91, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2437, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 1, .child_index = 1286, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'b', .end_of_word = false, .number = 1, .child_index = 2157, .children_len = 2 },
    .{ .char = 'd', .end_of_word = false, .number = 3, .child_index = 91, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 2720, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2721, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2722, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2723, .children_len = 2 },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 2725, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2726, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2727, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2728, .children_len = 1 },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 2729, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 2, .child_index = 2729, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1218, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2730, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1002, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2731, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2732, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2733, .children_len = 1 },
    .{ .char = 'D', .end_of_word = false, .number = 0, .child_index = 39, .children_len = 1 },
    .{ .char = 'M', .end_of_word = false, .number = 1, .child_index = 1865, .children_len = 1 },
    .{ .char = 'P', .end_of_word = false, .number = 2, .child_index = 1401, .children_len = 1 },
    .{ .char = 'T', .end_of_word = false, .number = 3, .child_index = 1370, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2734, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2735, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2736, .children_len = 1 },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 11, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2737, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2738, .children_len = 1 },
    .{ .char = 'C', .end_of_word = false, .number = 0, .child_index = 2739, .children_len = 1 },
    .{ .char = 'D', .end_of_word = false, .number = 1, .child_index = 2740, .children_len = 1 },
    .{ .char = 'L', .end_of_word = false, .number = 3, .child_index = 2741, .children_len = 2 },
    .{ .char = 'R', .end_of_word = false, .number = 9, .child_index = 2743, .children_len = 1 },
    .{ .char = 'U', .end_of_word = false, .number = 11, .child_index = 2744, .children_len = 1 },
    .{ .char = 'V', .end_of_word = false, .number = 13, .child_index = 1768, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2745, .children_len = 1 },
    .{ .char = 'f', .end_of_word = false, .number = 0, .child_index = 2746, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 2747, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 2748, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2749, .children_len = 1 },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 2750, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2751, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1657, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2752, .children_len = 6 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 1798, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2758, .children_len = 1 },
    .{ .char = 'w', .end_of_word = false, .number = 0, .child_index = 2759, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2760, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2761, .children_len = 1 },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 2762, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1657, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 2763, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2764, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2765, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2766, .children_len = 1 },
    .{ .char = 'w', .end_of_word = false, .number = 1, .child_index = 2767, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 2768, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2769, .children_len = 3 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2772, .children_len = 1 },
    .{ .char = 'D', .end_of_word = false, .number = 0, .child_index = 2773, .children_len = 1 },
    .{ .char = 'T', .end_of_word = false, .number = 1, .child_index = 2774, .children_len = 1 },
    .{ .char = 'V', .end_of_word = false, .number = 2, .child_index = 2259, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 2775, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2776, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2777, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2778, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2779, .children_len = 1 },
    .{ .char = 'f', .end_of_word = false, .number = 0, .child_index = 2780, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 2781, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2782, .children_len = 1 },
    .{ .char = 'v', .end_of_word = false, .number = 0, .child_index = 2783, .children_len = 1 },
    .{ .char = 'G', .end_of_word = false, .number = 0, .child_index = 2784, .children_len = 1 },
    .{ .char = 'L', .end_of_word = false, .number = 1, .child_index = 2785, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2786, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 1681, .children_len = 1 },
    .{ .char = 'C', .end_of_word = false, .number = 0, .child_index = 894, .children_len = 1 },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 2787, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1701, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2788, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2789, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 2790, .children_len = 6 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 2796, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2797, .children_len = 1 },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 2599, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2798, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1791, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1793, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2799, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2800, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2801, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2802, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2663, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2803, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2804, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2805, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2806, .children_len = 2 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2571, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 2808, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 2809, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2810, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 2632, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2811, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'I', .end_of_word = false, .number = 1, .child_index = 2812, .children_len = 1 },
    .{ .char = 'S', .end_of_word = false, .number = 2, .child_index = 2813, .children_len = 1 },
    .{ .char = 'U', .end_of_word = false, .number = 6, .child_index = 2814, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'E', .end_of_word = false, .number = 1, .child_index = 1690, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 2804, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1977, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2815, .children_len = 1 },
    .{ .char = 'w', .end_of_word = false, .number = 0, .child_index = 2816, .children_len = 3 },
    .{ .char = 'A', .end_of_word = false, .number = 0, .child_index = 1081, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2819, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2820, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 2821, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 2822, .children_len = 8 },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 1428, .children_len = 2 },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 2348, .children_len = 2 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'g', .end_of_word = false, .number = 1, .child_index = 1654, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2830, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2831, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2832, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 828, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2443, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 2, .child_index = 2833, .children_len = 5 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 942, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 1699, .children_len = 1 },
    .{ .char = 'x', .end_of_word = false, .number = 1, .child_index = 1771, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'p', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'm', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'q', .end_of_word = false, .number = 0, .child_index = 2838, .children_len = 2 },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 2840, .children_len = 2 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'o', .end_of_word = false, .number = 1, .child_index = 2842, .children_len = 1 },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 2843, .children_len = 1 },
    .{ .char = 'w', .end_of_word = false, .number = 0, .child_index = 2844, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1111, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2845, .children_len = 2 },
    .{ .char = 'D', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 1091, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2847, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2848, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'o', .end_of_word = false, .number = 1, .child_index = 421, .children_len = 2 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1962, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2706, .children_len = 1 },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 1599, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2849, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2850, .children_len = 1 },
    .{ .char = 'f', .end_of_word = false, .number = 0, .child_index = 2851, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 2852, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2853, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'o', .end_of_word = false, .number = 1, .child_index = 244, .children_len = 2 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 2439, .children_len = 1 },
    .{ .char = 'q', .end_of_word = false, .number = 1, .child_index = 2854, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 2855, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 2856, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2857, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'd', .end_of_word = false, .number = 1, .child_index = 2858, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 2, .child_index = 2859, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 3, .child_index = 140, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2860, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'u', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2003, .children_len = 2 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'b', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 2, .child_index = 91, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2861, .children_len = 2 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 2863, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 1111, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 828, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'h', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2864, .children_len = 1 },
    .{ .char = 'q', .end_of_word = false, .number = 0, .child_index = 2205, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2865, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1934, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2866, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2867, .children_len = 1 },
    .{ .char = 'q', .end_of_word = false, .number = 0, .child_index = 2868, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 2869, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2870, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2871, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2119, .children_len = 1 },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 2872, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 2873, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 3, .child_index = 2874, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2875, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 977, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 1971, .children_len = 2 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 7, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2876, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2877, .children_len = 1 },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 228, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 2878, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 2879, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2880, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2761, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 895, .children_len = 1 },
    .{ .char = 'D', .end_of_word = false, .number = 0, .child_index = 2881, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 2882, .children_len = 1 },
    .{ .char = 'I', .end_of_word = false, .number = 0, .child_index = 2883, .children_len = 1 },
    .{ .char = 'C', .end_of_word = false, .number = 0, .child_index = 2884, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2885, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1038, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2886, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2887, .children_len = 2 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2889, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 3, .child_index = 2890, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2891, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 2892, .children_len = 2 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2894, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2895, .children_len = 3 },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 2898, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2899, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2900, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2524, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2901, .children_len = 1 },
    .{ .char = 'E', .end_of_word = false, .number = 0, .child_index = 2902, .children_len = 1 },
    .{ .char = 'F', .end_of_word = false, .number = 2, .child_index = 2261, .children_len = 1 },
    .{ .char = 'G', .end_of_word = false, .number = 3, .child_index = 2262, .children_len = 1 },
    .{ .char = 'L', .end_of_word = false, .number = 4, .child_index = 1962, .children_len = 1 },
    .{ .char = 'S', .end_of_word = false, .number = 5, .child_index = 2263, .children_len = 1 },
    .{ .char = 'T', .end_of_word = false, .number = 6, .child_index = 110, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2903, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2904, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2905, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 2847, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2906, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2907, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2908, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 228, .children_len = 1 },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 2763, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2909, .children_len = 2 },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 2911, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'A', .end_of_word = false, .number = 1, .child_index = 1081, .children_len = 1 },
    .{ .char = 'V', .end_of_word = false, .number = 2, .child_index = 2912, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2913, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2914, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2915, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2916, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2917, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2918, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1242, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2919, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2920, .children_len = 2 },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 2922, .children_len = 1 },
    .{ .char = 'f', .end_of_word = false, .number = 0, .child_index = 2922, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2923, .children_len = 3 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2926, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2927, .children_len = 1 },
    .{ .char = 'k', .end_of_word = false, .number = 0, .child_index = 2928, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2929, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2930, .children_len = 1 },
    .{ .char = 'T', .end_of_word = false, .number = 0, .child_index = 2931, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'E', .end_of_word = false, .number = 1, .child_index = 1690, .children_len = 1 },
    .{ .char = 'G', .end_of_word = false, .number = 2, .child_index = 2262, .children_len = 1 },
    .{ .char = 'L', .end_of_word = false, .number = 3, .child_index = 1962, .children_len = 1 },
    .{ .char = 'S', .end_of_word = false, .number = 4, .child_index = 2263, .children_len = 1 },
    .{ .char = 'T', .end_of_word = false, .number = 5, .child_index = 110, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2932, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2933, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2934, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2935, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2936, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 2937, .children_len = 2 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2939, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2940, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 2941, .children_len = 4 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2945, .children_len = 1 },
    .{ .char = 'E', .end_of_word = false, .number = 0, .child_index = 2946, .children_len = 2 },
    .{ .char = 'U', .end_of_word = false, .number = 2, .child_index = 2948, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2949, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 994, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2950, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2951, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2952, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2953, .children_len = 2 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2955, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1654, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'B', .end_of_word = false, .number = 1, .child_index = 200, .children_len = 1 },
    .{ .char = 'D', .end_of_word = false, .number = 2, .child_index = 1078, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2956, .children_len = 4 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1798, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2960, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'b', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 2, .child_index = 91, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 3, .child_index = 91, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 4, .child_index = 91, .children_len = 1 },
    .{ .char = 'f', .end_of_word = false, .number = 5, .child_index = 91, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 6, .child_index = 91, .children_len = 1 },
    .{ .char = 'h', .end_of_word = false, .number = 7, .child_index = 91, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2961, .children_len = 1 },
    .{ .char = 'z', .end_of_word = false, .number = 0, .child_index = 2962, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2963, .children_len = 1 },
    .{ .char = 'R', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'S', .end_of_word = false, .number = 1, .child_index = 91, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 2, .child_index = 1261, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 3, .child_index = 96, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 4, .child_index = 229, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 1600, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 1, .child_index = 2964, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 's', .end_of_word = false, .number = 1, .child_index = 2965, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2966, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2967, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2191, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 2439, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 1, .child_index = 1962, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2955, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2968, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2969, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 2970, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2191, .children_len = 1 },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 2971, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2972, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 2439, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 2973, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 2878, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2974, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1274, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2975, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 363, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 2873, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2976, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2977, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2978, .children_len = 1 },
    .{ .char = 'f', .end_of_word = false, .number = 0, .child_index = 2979, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 2980, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2981, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1217, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2982, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2983, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2984, .children_len = 2 },
    .{ .char = 'q', .end_of_word = false, .number = 0, .child_index = 1953, .children_len = 2 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2873, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2986, .children_len = 5 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2991, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2992, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 179, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2993, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2994, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2995, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2996, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2997, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2998, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 2999, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 3000, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'w', .end_of_word = false, .number = 1, .child_index = 2335, .children_len = 1 },
    .{ .char = 'f', .end_of_word = false, .number = 0, .child_index = 3001, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 3002, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 3003, .children_len = 1 },
    .{ .char = 'A', .end_of_word = false, .number = 0, .child_index = 1081, .children_len = 1 },
    .{ .char = 'D', .end_of_word = false, .number = 1, .child_index = 1078, .children_len = 1 },
    .{ .char = 'w', .end_of_word = false, .number = 0, .child_index = 3004, .children_len = 3 },
    .{ .char = 'R', .end_of_word = false, .number = 0, .child_index = 3007, .children_len = 1 },
    .{ .char = 'T', .end_of_word = false, .number = 1, .child_index = 2774, .children_len = 1 },
    .{ .char = 'V', .end_of_word = false, .number = 2, .child_index = 2259, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2909, .children_len = 2 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 3008, .children_len = 1 },
    .{ .char = 'y', .end_of_word = false, .number = 0, .child_index = 3009, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 3010, .children_len = 1 },
    .{ .char = 'q', .end_of_word = false, .number = 0, .child_index = 3011, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 3012, .children_len = 1 },
    .{ .char = 'H', .end_of_word = false, .number = 0, .child_index = 3013, .children_len = 1 },
    .{ .char = 'y', .end_of_word = false, .number = 0, .child_index = 3014, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 3015, .children_len = 2 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 3017, .children_len = 1 },
    .{ .char = 'w', .end_of_word = false, .number = 0, .child_index = 3018, .children_len = 3 },
    .{ .char = 'T', .end_of_word = false, .number = 0, .child_index = 2774, .children_len = 1 },
    .{ .char = 'V', .end_of_word = false, .number = 1, .child_index = 2259, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 3021, .children_len = 2 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 3023, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 3024, .children_len = 1 },
    .{ .char = 'w', .end_of_word = false, .number = 0, .child_index = 3025, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 3026, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 3027, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 3028, .children_len = 1 },
    .{ .char = 'E', .end_of_word = false, .number = 0, .child_index = 1690, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2918, .children_len = 1 },
    .{ .char = 'A', .end_of_word = false, .number = 0, .child_index = 1081, .children_len = 1 },
    .{ .char = 'R', .end_of_word = false, .number = 1, .child_index = 2266, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2632, .children_len = 1 },
    .{ .char = 'M', .end_of_word = false, .number = 0, .child_index = 3029, .children_len = 1 },
    .{ .char = 'T', .end_of_word = false, .number = 1, .child_index = 3030, .children_len = 1 },
    .{ .char = 'V', .end_of_word = false, .number = 3, .child_index = 3031, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 3032, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 3033, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 3034, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 3035, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 3036, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2578, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 3037, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 3038, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 3039, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 3040, .children_len = 1 },
    .{ .char = 'y', .end_of_word = false, .number = 0, .child_index = 3041, .children_len = 2 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'k', .end_of_word = false, .number = 1, .child_index = 1794, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 3043, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 3044, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'E', .end_of_word = false, .number = 1, .child_index = 1690, .children_len = 1 },
    .{ .char = 'S', .end_of_word = false, .number = 2, .child_index = 2263, .children_len = 1 },
    .{ .char = 'T', .end_of_word = false, .number = 3, .child_index = 110, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 3045, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 72, .children_len = 1 },
    .{ .char = 'q', .end_of_word = false, .number = 1, .child_index = 1806, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 3046, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 3047, .children_len = 1 },
    .{ .char = 'y', .end_of_word = false, .number = 0, .child_index = 1210, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1939, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 3048, .children_len = 1 },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 2324, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 2, .child_index = 2606, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 919, .children_len = 1 },
    .{ .char = 'B', .end_of_word = false, .number = 0, .child_index = 200, .children_len = 1 },
    .{ .char = 'L', .end_of_word = false, .number = 1, .child_index = 1749, .children_len = 1 },
    .{ .char = 'S', .end_of_word = false, .number = 2, .child_index = 3049, .children_len = 1 },
    .{ .char = 'T', .end_of_word = false, .number = 3, .child_index = 110, .children_len = 1 },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 1798, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 3050, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2032, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 3051, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 3052, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2648, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 1370, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 3053, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1265, .children_len = 1 },
    .{ .char = 'w', .end_of_word = false, .number = 0, .child_index = 3054, .children_len = 2 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 3056, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 3057, .children_len = 3 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2966, .children_len = 1 },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 1654, .children_len = 1 },
    .{ .char = 'w', .end_of_word = false, .number = 0, .child_index = 3060, .children_len = 2 },
    .{ .char = 'f', .end_of_word = false, .number = 0, .child_index = 942, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 3062, .children_len = 2 },
    .{ .char = 'y', .end_of_word = false, .number = 0, .child_index = 1669, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1268, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 3064, .children_len = 2 },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 2851, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 3066, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2463, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 1865, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2193, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 1, .child_index = 3067, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'd', .end_of_word = false, .number = 1, .child_index = 2858, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 2, .child_index = 3068, .children_len = 1 },
    .{ .char = 'q', .end_of_word = false, .number = 4, .child_index = 91, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 5, .child_index = 3069, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 3060, .children_len = 2 },
    .{ .char = 'w', .end_of_word = false, .number = 0, .child_index = 1111, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 3070, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 3071, .children_len = 1 },
    .{ .char = 'f', .end_of_word = false, .number = 0, .child_index = 965, .children_len = 1 },
    .{ .char = 'C', .end_of_word = false, .number = 0, .child_index = 2739, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 3072, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 3073, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 3074, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 1682, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 3075, .children_len = 3 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 3078, .children_len = 2 },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 3080, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'B', .end_of_word = false, .number = 1, .child_index = 200, .children_len = 1 },
    .{ .char = 'U', .end_of_word = false, .number = 2, .child_index = 2620, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 3081, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 3082, .children_len = 1 },
    .{ .char = 'S', .end_of_word = false, .number = 0, .child_index = 2558, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 3083, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 3084, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1014, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 3085, .children_len = 1 },
    .{ .char = 'I', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'C', .end_of_word = false, .number = 0, .child_index = 3086, .children_len = 1 },
    .{ .char = 'T', .end_of_word = false, .number = 1, .child_index = 1370, .children_len = 1 },
    .{ .char = 'B', .end_of_word = false, .number = 0, .child_index = 3087, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'B', .end_of_word = false, .number = 1, .child_index = 200, .children_len = 1 },
    .{ .char = 'R', .end_of_word = false, .number = 2, .child_index = 2266, .children_len = 1 },
    .{ .char = 'A', .end_of_word = false, .number = 0, .child_index = 1081, .children_len = 1 },
    .{ .char = 'V', .end_of_word = false, .number = 1, .child_index = 2912, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 3088, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 3089, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 3026, .children_len = 1 },
    .{ .char = 'V', .end_of_word = false, .number = 0, .child_index = 2912, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 3090, .children_len = 2 },
    .{ .char = 'G', .end_of_word = false, .number = 0, .child_index = 2262, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 3092, .children_len = 1 },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 3093, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 3094, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 3095, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 3096, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 3097, .children_len = 1 },
    .{ .char = 'V', .end_of_word = false, .number = 0, .child_index = 1768, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 3098, .children_len = 7 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 3105, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 3106, .children_len = 1 },
    .{ .char = 'S', .end_of_word = false, .number = 0, .child_index = 2813, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 3107, .children_len = 1 },
    .{ .char = 'D', .end_of_word = false, .number = 0, .child_index = 3108, .children_len = 1 },
    .{ .char = 'Q', .end_of_word = false, .number = 1, .child_index = 3109, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 3110, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 3111, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 3112, .children_len = 2 },
    .{ .char = 'E', .end_of_word = false, .number = 0, .child_index = 1079, .children_len = 1 },
    .{ .char = 'w', .end_of_word = false, .number = 0, .child_index = 3114, .children_len = 3 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 3117, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 3118, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 3119, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 3120, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1673, .children_len = 1 },
    .{ .char = 'w', .end_of_word = false, .number = 0, .child_index = 904, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 't', .end_of_word = false, .number = 1, .child_index = 1332, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 3121, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 3122, .children_len = 1 },
    .{ .char = 'h', .end_of_word = false, .number = 2, .child_index = 3123, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 3, .child_index = 2711, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2859, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 3124, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 3068, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 2, .child_index = 3069, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2528, .children_len = 1 },
    .{ .char = 'h', .end_of_word = false, .number = 1, .child_index = 3123, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 2264, .children_len = 1 },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 42, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 3125, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 3126, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2874, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 3127, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 3128, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1678, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 3129, .children_len = 4 },
    .{ .char = 'A', .end_of_word = false, .number = 0, .child_index = 1081, .children_len = 1 },
    .{ .char = 'R', .end_of_word = false, .number = 1, .child_index = 2266, .children_len = 1 },
    .{ .char = 'T', .end_of_word = false, .number = 2, .child_index = 903, .children_len = 1 },
    .{ .char = 'L', .end_of_word = false, .number = 0, .child_index = 2265, .children_len = 1 },
    .{ .char = 'R', .end_of_word = false, .number = 2, .child_index = 2266, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 3133, .children_len = 2 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 3135, .children_len = 1 },
    .{ .char = 'S', .end_of_word = false, .number = 0, .child_index = 1914, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1298, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 3136, .children_len = 1 },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 140, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1393, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 3137, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2022, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 3138, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'B', .end_of_word = false, .number = 1, .child_index = 200, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 1009, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1069, .children_len = 2 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 3139, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 3140, .children_len = 1 },
    .{ .char = 'L', .end_of_word = false, .number = 0, .child_index = 1962, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 1798, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'E', .end_of_word = false, .number = 1, .child_index = 1690, .children_len = 1 },
    .{ .char = 'F', .end_of_word = false, .number = 2, .child_index = 2261, .children_len = 1 },
    .{ .char = 'G', .end_of_word = false, .number = 3, .child_index = 2262, .children_len = 1 },
    .{ .char = 'L', .end_of_word = false, .number = 4, .child_index = 1962, .children_len = 1 },
    .{ .char = 'S', .end_of_word = false, .number = 5, .child_index = 2263, .children_len = 1 },
    .{ .char = 'T', .end_of_word = false, .number = 6, .child_index = 110, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 3141, .children_len = 3 },
    .{ .char = 'E', .end_of_word = false, .number = 0, .child_index = 3144, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 3145, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 3146, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 3147, .children_len = 1 },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 3148, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1475, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 1091, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'B', .end_of_word = false, .number = 1, .child_index = 200, .children_len = 1 },
    .{ .char = 'L', .end_of_word = false, .number = 2, .child_index = 2589, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2247, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 3149, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 3150, .children_len = 2 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 3152, .children_len = 1 },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 3150, .children_len = 2 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 3153, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 3154, .children_len = 1 },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 3155, .children_len = 1 },
    .{ .char = 'f', .end_of_word = false, .number = 0, .child_index = 2119, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 3156, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 3060, .children_len = 2 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 2246, .children_len = 1 },
    .{ .char = 'A', .end_of_word = false, .number = 0, .child_index = 144, .children_len = 1 },
    .{ .char = 'D', .end_of_word = false, .number = 1, .child_index = 3157, .children_len = 1 },
    .{ .char = 'G', .end_of_word = false, .number = 3, .child_index = 3158, .children_len = 1 },
    .{ .char = 'T', .end_of_word = false, .number = 4, .child_index = 110, .children_len = 1 },
    .{ .char = 'A', .end_of_word = false, .number = 0, .child_index = 1081, .children_len = 1 },
    .{ .char = 'T', .end_of_word = false, .number = 1, .child_index = 903, .children_len = 1 },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 3159, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 3160, .children_len = 2 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 3162, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 3163, .children_len = 3 },
    .{ .char = 'y', .end_of_word = false, .number = 0, .child_index = 1814, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 3166, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'E', .end_of_word = false, .number = 1, .child_index = 1690, .children_len = 1 },
    .{ .char = 'S', .end_of_word = false, .number = 2, .child_index = 2263, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 72, .children_len = 1 },
    .{ .char = 'B', .end_of_word = false, .number = 0, .child_index = 200, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 3167, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1670, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 3168, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 3169, .children_len = 1 },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 2858, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 1, .child_index = 140, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 3170, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 3171, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 3172, .children_len = 1 },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 1904, .children_len = 1 },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 2119, .children_len = 1 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 3173, .children_len = 2 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 441, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 3026, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'L', .end_of_word = false, .number = 1, .child_index = 1962, .children_len = 1 },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 3175, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'B', .end_of_word = false, .number = 1, .child_index = 200, .children_len = 1 },
    .{ .char = 'E', .end_of_word = false, .number = 2, .child_index = 1690, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 3028, .children_len = 1 },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 3176, .children_len = 1 },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 895, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 3177, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 3178, .children_len = 4 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 3182, .children_len = 1 },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 3183, .children_len = 1 },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 91, .children_len = 1 },
    .{ .char = 'u', .end_of_word = false, .number = 1, .child_index = 3184, .children_len = 1 },
    .{ .char = 'k', .end_of_word = false, .number = 0, .child_index = 1794, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 3185, .children_len = 1 },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 3088, .children_len = 1 },
    .{ .char = ';', .end_of_word = true, .number = 0, .child_index = 0, .children_len = 0 },
    .{ .char = 'd', .end_of_word = false, .number = 1, .child_index = 2858, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 2, .child_index = 2859, .children_len = 1 },
    .{ .char = 'r', .end_of_word = false, .number = 3, .child_index = 3124, .children_len = 1 },
    .{ .char = 'w', .end_of_word = false, .number = 0, .child_index = 2003, .children_len = 2 },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2978, .children_len = 1 },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 3186, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 3187, .children_len = 1 },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 3188, .children_len = 1 },
    .{ .char = 'Q', .end_of_word = false, .number = 0, .child_index = 3109, .children_len = 1 },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 3189, .children_len = 1 },
    .{ .char = 'A', .end_of_word = false, .number = 0, .child_index = 144, .children_len = 1 },
};
