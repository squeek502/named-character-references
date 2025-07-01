const std = @import("std");
const builtin = @import("builtin");

const want_safety = builtin.mode == .Debug;

pub const Matcher = struct {
    children_to_check: ChildrenToCheck = .init,
    semicolon_termination: SemicolonTermination = .no,
    last_matched_unique_index: u12 = 0,
    pending_unique_index: u12 = 0,
    /// This will be true if the last match ends with a semicolon
    ends_with_semicolon: bool = false,

    const ChildrenToCheck = union(enum) {
        init: void,
        second_layer: LinkNode,
        dafsa: u12,
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
                    self.children_to_check = .{ .second_layer = bit_masks[index] };
                    std.debug.assert(bit_masks[index].index == index);
                    //self.overconsumed_code_points += 1;
                    self.pending_unique_index = @intCast(node.number);
                    return true;
                }
                return false;
            },
            .second_layer => |link| {
                if (std.ascii.isAlphabetic(c)) {
                    const bit_index = charToIndex(c).?;
                    const bit_mask = link.mask();
                    if (@as(u64, 1) << bit_index & bit_mask == 0) return false;

                    const mask = (@as(u64, 1) << bit_index) -% 1;
                    const char_index = @popCount(bit_mask & mask);
                    if (want_safety) {
                        std.debug.assert(char_index < second_layer[link.index].len);
                    }
                    const node1 = second_layer[link.index].nodes1[char_index];
                    //self.overconsumed_code_points += 1;
                    self.pending_unique_index += node1.number;
                    const node2 = second_layer[link.index].nodes2[char_index];
                    if (node2.end_of_word) {
                        self.pending_unique_index += 1;
                        self.last_matched_unique_index = self.pending_unique_index;
                        self.ends_with_semicolon = c == ';';
                    }
                    self.semicolon_termination = if (node2.semicolon_termination) .yes else .no;
                    self.children_to_check = .{ .dafsa = node2.child_index };
                    return true;
                }
                return false;
            },
            .dafsa => |child_index| {
                if (c == ';' and self.semicolon_termination != .no) {
                    // always the end of a word so we always add 1
                    self.pending_unique_index += 1 + self.semicolon_termination.number();
                    self.last_matched_unique_index = self.pending_unique_index;
                    self.ends_with_semicolon = true;
                    self.children_to_check.dafsa = 0;
                    self.semicolon_termination = .no;
                    return true;
                }
                for (dafsa[child_index..]) |node| {
                    if (node.char == c) {
                        self.pending_unique_index += node.number;
                        if (node.end_of_word) {
                            self.pending_unique_index += 1;
                            self.last_matched_unique_index = self.pending_unique_index;
                            self.ends_with_semicolon = c == ';';
                        }
                        self.semicolon_termination = node.semicolon_termination;
                        self.children_to_check.dafsa = node.child_index;
                        return true;
                    }
                    if (node.last_sibling) break;
                }
                return false;
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
    char: u8,
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
    number: u8, // could be u6
    /// If true, this node is the end of a valid named character reference.
    /// Note: This does not necessarily mean that this node does not have child nodes.
    end_of_word: bool,
    last_sibling: bool,

    semicolon_termination: SemicolonTermination,

    /// Index of the first child of this node.
    /// There are 3872 nodes in our DAFSA, so all indexes can fit in a u12.
    child_index: u12,
};

pub const SemicolonTermination = enum(u2) {
    no,
    yes,
    yes_num_2,
    yes_num_6,

    pub fn number(self: SemicolonTermination) u8 {
        return switch (self) {
            .no, .yes => 0,
            .yes_num_2 => 2,
            .yes_num_6 => 6,
        };
    }
};

const FirstLayerNode = packed struct {
    number: u16, // could be u12
};

fn charToIndex(c: u7) ?u6 {
    return switch (c) {
        '1'...';' => return @intCast(c - '1'),
        'A'...'Z' => return @intCast(c - 'A' + (';' - '1' + 1)),
        'a'...'z' => return @intCast(c - 'a' + (';' - '1' + 1) + ('Z' - 'A' + 1)),
        else => return null,
    };
}

const LinkNode = packed struct {
    shifted_mask: u58,
    index: u6,

    pub fn mask(self: LinkNode) u64 {
        return @as(u64, self.shifted_mask) << 6;
    }
};

const SecondLayerNodes = struct {
    nodes1: [*]const SecondLayerNode1,
    nodes2: [*]const SecondLayerNode2,
    len: if (want_safety) u8 else void,
};

const SecondLayerNode1 = packed struct {
    number: u8,
};

const SecondLayerNode2 = packed struct {
    child_index: u10,
    end_of_word: bool,
    // Semicolon nodes after the second character always have 0 as their number
    // so this can just be a boolean.
    semicolon_termination: bool,
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

pub const bit_masks = [_]LinkNode{
    .{ .shifted_mask = 0x000f7c3380020200, .index = 0 },
    .{ .shifted_mask = 0x000b201a80000000, .index = 1 },
    .{ .shifted_mask = 0x000b24de80081000, .index = 2 },
    .{ .shifted_mask = 0x0002209ac0804100, .index = 3 },
    .{ .shifted_mask = 0x004eec3681040000, .index = 4 },
    .{ .shifted_mask = 0x0002209200000000, .index = 5 },
    .{ .shifted_mask = 0x0007203781004000, .index = 6 },
    .{ .shifted_mask = 0x000a209280000020, .index = 7 },
    .{ .shifted_mask = 0x000e383680084200, .index = 8 },
    .{ .shifted_mask = 0x000a201200000000, .index = 9 },
    .{ .shifted_mask = 0x0002201280005000, .index = 10 },
    .{ .shifted_mask = 0x00062c1a81004000, .index = 11 },
    .{ .shifted_mask = 0x000a209a80000000, .index = 12 },
    .{ .shifted_mask = 0x000e201a80004000, .index = 13 },
    .{ .shifted_mask = 0x001f683680000200, .index = 14 },
    .{ .shifted_mask = 0x000324d280000000, .index = 15 },
    .{ .shifted_mask = 0x0002201002000000, .index = 16 },
    .{ .shifted_mask = 0x000b20da80000240, .index = 17 },
    .{ .shifted_mask = 0x000ea8d280081000, .index = 18 },
    .{ .shifted_mask = 0x000320d280c01000, .index = 19 },
    .{ .shifted_mask = 0x000f783780000000, .index = 20 },
    .{ .shifted_mask = 0x0012201f00000100, .index = 21 },
    .{ .shifted_mask = 0x0002201a00000000, .index = 22 },
    .{ .shifted_mask = 0x0002209000000000, .index = 23 },
    .{ .shifted_mask = 0x000a201282002020, .index = 24 },
    .{ .shifted_mask = 0x0002201e80001000, .index = 25 },
    .{ .shifted_mask = 0x002f7c3b80000000, .index = 26 },
    .{ .shifted_mask = 0x000b769f80040000, .index = 27 },
    .{ .shifted_mask = 0x00af24de80000000, .index = 28 },
    .{ .shifted_mask = 0x012f25df80001020, .index = 29 },
    .{ .shifted_mask = 0x004ffc3e80000100, .index = 30 },
    .{ .shifted_mask = 0x0003759a80000000, .index = 31 },
    .{ .shifted_mask = 0x001735bf80000200, .index = 32 },
    .{ .shifted_mask = 0x0082221b80000020, .index = 33 },
    .{ .shifted_mask = 0x000ef9ba80000000, .index = 34 },
    .{ .shifted_mask = 0x000a281200000000, .index = 35 },
    .{ .shifted_mask = 0x0002217280000000, .index = 36 },
    .{ .shifted_mask = 0x001f7d7f80001260, .index = 37 },
    .{ .shifted_mask = 0x000a74de80000100, .index = 38 },
    .{ .shifted_mask = 0x003f6dff84410800, .index = 39 },
    .{ .shifted_mask = 0x001f6cfe80800000, .index = 40 },
    .{ .shifted_mask = 0x000b2cda80000000, .index = 41 },
    .{ .shifted_mask = 0x000a609000000000, .index = 42 },
    .{ .shifted_mask = 0x004f7cdf80001060, .index = 43 },
    .{ .shifted_mask = 0x012fecdf80000000, .index = 44 },
    .{ .shifted_mask = 0x002360df80000000, .index = 45 },
    .{ .shifted_mask = 0x002f6c7780001020, .index = 46 },
    .{ .shifted_mask = 0x0103741e80000160, .index = 47 },
    .{ .shifted_mask = 0x0003601a00000000, .index = 48 },
    .{ .shifted_mask = 0x003b3cd600000000, .index = 49 },
    .{ .shifted_mask = 0x000a209a80000000, .index = 50 },
    .{ .shifted_mask = 0x002220de80000000, .index = 51 },
};

pub const second_layer = [_]SecondLayerNodes{
    .{
        .nodes1 = &[_]SecondLayerNode1{
            .{ .number = 0 }, // AE
            .{ .number = 2 }, // AM
            .{ .number = 4 }, // Aa
            .{ .number = 6 }, // Ab
            .{ .number = 7 }, // Ac
            .{ .number = 10 }, // Af
            .{ .number = 11 }, // Ag
            .{ .number = 13 }, // Al
            .{ .number = 14 }, // Am
            .{ .number = 15 }, // An
            .{ .number = 16 }, // Ao
            .{ .number = 18 }, // Ap
            .{ .number = 19 }, // Ar
            .{ .number = 21 }, // As
            .{ .number = 23 }, // At
            .{ .number = 25 }, // Au
        },
        .nodes2 = &[_]SecondLayerNode2{
            .{ .child_index = 1, .end_of_word = false, .semicolon_termination = false }, // AE
            .{ .child_index = 2, .end_of_word = false, .semicolon_termination = false }, // AM
            .{ .child_index = 3, .end_of_word = false, .semicolon_termination = false }, // Aa
            .{ .child_index = 4, .end_of_word = false, .semicolon_termination = false }, // Ab
            .{ .child_index = 5, .end_of_word = false, .semicolon_termination = false }, // Ac
            .{ .child_index = 7, .end_of_word = false, .semicolon_termination = false }, // Af
            .{ .child_index = 8, .end_of_word = false, .semicolon_termination = false }, // Ag
            .{ .child_index = 9, .end_of_word = false, .semicolon_termination = false }, // Al
            .{ .child_index = 10, .end_of_word = false, .semicolon_termination = false }, // Am
            .{ .child_index = 11, .end_of_word = false, .semicolon_termination = false }, // An
            .{ .child_index = 12, .end_of_word = false, .semicolon_termination = false }, // Ao
            .{ .child_index = 14, .end_of_word = false, .semicolon_termination = false }, // Ap
            .{ .child_index = 15, .end_of_word = false, .semicolon_termination = false }, // Ar
            .{ .child_index = 16, .end_of_word = false, .semicolon_termination = false }, // As
            .{ .child_index = 18, .end_of_word = false, .semicolon_termination = false }, // At
            .{ .child_index = 19, .end_of_word = false, .semicolon_termination = false }, // Au
        },
        .len = if (want_safety) 16 else {},
    },
    .{
        .nodes1 = &[_]SecondLayerNode1{
            .{ .number = 0 }, // Ba
            .{ .number = 3 }, // Bc
            .{ .number = 4 }, // Be
            .{ .number = 7 }, // Bf
            .{ .number = 8 }, // Bo
            .{ .number = 9 }, // Br
            .{ .number = 10 }, // Bs
            .{ .number = 11 }, // Bu
        },
        .nodes2 = &[_]SecondLayerNode2{
            .{ .child_index = 20, .end_of_word = false, .semicolon_termination = false }, // Ba
            .{ .child_index = 22, .end_of_word = false, .semicolon_termination = false }, // Bc
            .{ .child_index = 23, .end_of_word = false, .semicolon_termination = false }, // Be
            .{ .child_index = 7, .end_of_word = false, .semicolon_termination = false }, // Bf
            .{ .child_index = 26, .end_of_word = false, .semicolon_termination = false }, // Bo
            .{ .child_index = 27, .end_of_word = false, .semicolon_termination = false }, // Br
            .{ .child_index = 28, .end_of_word = false, .semicolon_termination = false }, // Bs
            .{ .child_index = 29, .end_of_word = false, .semicolon_termination = false }, // Bu
        },
        .len = if (want_safety) 8 else {},
    },
    .{
        .nodes1 = &[_]SecondLayerNode1{
            .{ .number = 0 }, // CH
            .{ .number = 1 }, // CO
            .{ .number = 3 }, // Ca
            .{ .number = 7 }, // Cc
            .{ .number = 12 }, // Cd
            .{ .number = 13 }, // Ce
            .{ .number = 15 }, // Cf
            .{ .number = 16 }, // Ch
            .{ .number = 17 }, // Ci
            .{ .number = 21 }, // Cl
            .{ .number = 24 }, // Co
            .{ .number = 32 }, // Cr
            .{ .number = 33 }, // Cs
            .{ .number = 34 }, // Cu
        },
        .nodes2 = &[_]SecondLayerNode2{
            .{ .child_index = 30, .end_of_word = false, .semicolon_termination = false }, // CH
            .{ .child_index = 31, .end_of_word = false, .semicolon_termination = false }, // CO
            .{ .child_index = 32, .end_of_word = false, .semicolon_termination = false }, // Ca
            .{ .child_index = 35, .end_of_word = false, .semicolon_termination = false }, // Cc
            .{ .child_index = 39, .end_of_word = false, .semicolon_termination = false }, // Cd
            .{ .child_index = 40, .end_of_word = false, .semicolon_termination = false }, // Ce
            .{ .child_index = 7, .end_of_word = false, .semicolon_termination = false }, // Cf
            .{ .child_index = 42, .end_of_word = false, .semicolon_termination = false }, // Ch
            .{ .child_index = 43, .end_of_word = false, .semicolon_termination = false }, // Ci
            .{ .child_index = 44, .end_of_word = false, .semicolon_termination = false }, // Cl
            .{ .child_index = 45, .end_of_word = false, .semicolon_termination = false }, // Co
            .{ .child_index = 49, .end_of_word = false, .semicolon_termination = false }, // Cr
            .{ .child_index = 28, .end_of_word = false, .semicolon_termination = false }, // Cs
            .{ .child_index = 50, .end_of_word = false, .semicolon_termination = false }, // Cu
        },
        .len = if (want_safety) 14 else {},
    },
    .{
        .nodes1 = &[_]SecondLayerNode1{
            .{ .number = 0 }, // DD
            .{ .number = 2 }, // DJ
            .{ .number = 3 }, // DS
            .{ .number = 4 }, // DZ
            .{ .number = 5 }, // Da
            .{ .number = 8 }, // Dc
            .{ .number = 10 }, // De
            .{ .number = 12 }, // Df
            .{ .number = 13 }, // Di
            .{ .number = 20 }, // Do
            .{ .number = 52 }, // Ds
        },
        .nodes2 = &[_]SecondLayerNode2{
            .{ .child_index = 51, .end_of_word = false, .semicolon_termination = true }, // DD
            .{ .child_index = 30, .end_of_word = false, .semicolon_termination = false }, // DJ
            .{ .child_index = 30, .end_of_word = false, .semicolon_termination = false }, // DS
            .{ .child_index = 30, .end_of_word = false, .semicolon_termination = false }, // DZ
            .{ .child_index = 52, .end_of_word = false, .semicolon_termination = false }, // Da
            .{ .child_index = 55, .end_of_word = false, .semicolon_termination = false }, // Dc
            .{ .child_index = 57, .end_of_word = false, .semicolon_termination = false }, // De
            .{ .child_index = 7, .end_of_word = false, .semicolon_termination = false }, // Df
            .{ .child_index = 58, .end_of_word = false, .semicolon_termination = false }, // Di
            .{ .child_index = 60, .end_of_word = false, .semicolon_termination = false }, // Do
            .{ .child_index = 64, .end_of_word = false, .semicolon_termination = false }, // Ds
        },
        .len = if (want_safety) 11 else {},
    },
    .{
        .nodes1 = &[_]SecondLayerNode1{
            .{ .number = 0 }, // EN
            .{ .number = 1 }, // ET
            .{ .number = 3 }, // Ea
            .{ .number = 5 }, // Ec
            .{ .number = 9 }, // Ed
            .{ .number = 10 }, // Ef
            .{ .number = 11 }, // Eg
            .{ .number = 13 }, // El
            .{ .number = 14 }, // Em
            .{ .number = 17 }, // Eo
            .{ .number = 19 }, // Ep
            .{ .number = 20 }, // Eq
            .{ .number = 23 }, // Es
            .{ .number = 25 }, // Et
            .{ .number = 26 }, // Eu
            .{ .number = 28 }, // Ex
        },
        .nodes2 = &[_]SecondLayerNode2{
            .{ .child_index = 66, .end_of_word = false, .semicolon_termination = false }, // EN
            .{ .child_index = 67, .end_of_word = false, .semicolon_termination = false }, // ET
            .{ .child_index = 3, .end_of_word = false, .semicolon_termination = false }, // Ea
            .{ .child_index = 68, .end_of_word = false, .semicolon_termination = false }, // Ec
            .{ .child_index = 39, .end_of_word = false, .semicolon_termination = false }, // Ed
            .{ .child_index = 7, .end_of_word = false, .semicolon_termination = false }, // Ef
            .{ .child_index = 8, .end_of_word = false, .semicolon_termination = false }, // Eg
            .{ .child_index = 71, .end_of_word = false, .semicolon_termination = false }, // El
            .{ .child_index = 72, .end_of_word = false, .semicolon_termination = false }, // Em
            .{ .child_index = 12, .end_of_word = false, .semicolon_termination = false }, // Eo
            .{ .child_index = 74, .end_of_word = false, .semicolon_termination = false }, // Ep
            .{ .child_index = 75, .end_of_word = false, .semicolon_termination = false }, // Eq
            .{ .child_index = 76, .end_of_word = false, .semicolon_termination = false }, // Es
            .{ .child_index = 78, .end_of_word = false, .semicolon_termination = false }, // Et
            .{ .child_index = 19, .end_of_word = false, .semicolon_termination = false }, // Eu
            .{ .child_index = 79, .end_of_word = false, .semicolon_termination = false }, // Ex
        },
        .len = if (want_safety) 16 else {},
    },
    .{
        .nodes1 = &[_]SecondLayerNode1{
            .{ .number = 0 }, // Fc
            .{ .number = 1 }, // Ff
            .{ .number = 2 }, // Fi
            .{ .number = 4 }, // Fo
            .{ .number = 7 }, // Fs
        },
        .nodes2 = &[_]SecondLayerNode2{
            .{ .child_index = 22, .end_of_word = false, .semicolon_termination = false }, // Fc
            .{ .child_index = 7, .end_of_word = false, .semicolon_termination = false }, // Ff
            .{ .child_index = 81, .end_of_word = false, .semicolon_termination = false }, // Fi
            .{ .child_index = 82, .end_of_word = false, .semicolon_termination = false }, // Fo
            .{ .child_index = 28, .end_of_word = false, .semicolon_termination = false }, // Fs
        },
        .len = if (want_safety) 5 else {},
    },
    .{
        .nodes1 = &[_]SecondLayerNode1{
            .{ .number = 0 }, // GJ
            .{ .number = 1 }, // GT
            .{ .number = 3 }, // Ga
            .{ .number = 5 }, // Gb
            .{ .number = 6 }, // Gc
            .{ .number = 9 }, // Gd
            .{ .number = 10 }, // Gf
            .{ .number = 11 }, // Gg
            .{ .number = 12 }, // Go
            .{ .number = 13 }, // Gr
            .{ .number = 20 }, // Gs
            .{ .number = 21 }, // Gt
        },
        .nodes2 = &[_]SecondLayerNode2{
            .{ .child_index = 30, .end_of_word = false, .semicolon_termination = false }, // GJ
            .{ .child_index = 0, .end_of_word = true, .semicolon_termination = true }, // GT
            .{ .child_index = 85, .end_of_word = false, .semicolon_termination = false }, // Ga
            .{ .child_index = 4, .end_of_word = false, .semicolon_termination = false }, // Gb
            .{ .child_index = 86, .end_of_word = false, .semicolon_termination = false }, // Gc
            .{ .child_index = 39, .end_of_word = false, .semicolon_termination = false }, // Gd
            .{ .child_index = 7, .end_of_word = false, .semicolon_termination = false }, // Gf
            .{ .child_index = 0, .end_of_word = false, .semicolon_termination = true }, // Gg
            .{ .child_index = 26, .end_of_word = false, .semicolon_termination = false }, // Go
            .{ .child_index = 89, .end_of_word = false, .semicolon_termination = false }, // Gr
            .{ .child_index = 28, .end_of_word = false, .semicolon_termination = false }, // Gs
            .{ .child_index = 0, .end_of_word = false, .semicolon_termination = true }, // Gt
        },
        .len = if (want_safety) 12 else {},
    },
    .{
        .nodes1 = &[_]SecondLayerNode1{
            .{ .number = 0 }, // HA
            .{ .number = 1 }, // Ha
            .{ .number = 3 }, // Hc
            .{ .number = 4 }, // Hf
            .{ .number = 5 }, // Hi
            .{ .number = 6 }, // Ho
            .{ .number = 8 }, // Hs
            .{ .number = 10 }, // Hu
        },
        .nodes2 = &[_]SecondLayerNode2{
            .{ .child_index = 90, .end_of_word = false, .semicolon_termination = false }, // HA
            .{ .child_index = 91, .end_of_word = false, .semicolon_termination = false }, // Ha
            .{ .child_index = 93, .end_of_word = false, .semicolon_termination = false }, // Hc
            .{ .child_index = 7, .end_of_word = false, .semicolon_termination = false }, // Hf
            .{ .child_index = 94, .end_of_word = false, .semicolon_termination = false }, // Hi
            .{ .child_index = 95, .end_of_word = false, .semicolon_termination = false }, // Ho
            .{ .child_index = 64, .end_of_word = false, .semicolon_termination = false }, // Hs
            .{ .child_index = 97, .end_of_word = false, .semicolon_termination = false }, // Hu
        },
        .len = if (want_safety) 8 else {},
    },
    .{
        .nodes1 = &[_]SecondLayerNode1{
            .{ .number = 0 }, // IE
            .{ .number = 1 }, // IJ
            .{ .number = 2 }, // IO
            .{ .number = 3 }, // Ia
            .{ .number = 5 }, // Ic
            .{ .number = 8 }, // Id
            .{ .number = 9 }, // If
            .{ .number = 10 }, // Ig
            .{ .number = 12 }, // Im
            .{ .number = 16 }, // In
            .{ .number = 21 }, // Io
            .{ .number = 24 }, // Is
            .{ .number = 25 }, // It
            .{ .number = 26 }, // Iu
        },
        .nodes2 = &[_]SecondLayerNode2{
            .{ .child_index = 30, .end_of_word = false, .semicolon_termination = false }, // IE
            .{ .child_index = 98, .end_of_word = false, .semicolon_termination = false }, // IJ
            .{ .child_index = 30, .end_of_word = false, .semicolon_termination = false }, // IO
            .{ .child_index = 3, .end_of_word = false, .semicolon_termination = false }, // Ia
            .{ .child_index = 5, .end_of_word = false, .semicolon_termination = false }, // Ic
            .{ .child_index = 39, .end_of_word = false, .semicolon_termination = false }, // Id
            .{ .child_index = 7, .end_of_word = false, .semicolon_termination = false }, // If
            .{ .child_index = 8, .end_of_word = false, .semicolon_termination = false }, // Ig
            .{ .child_index = 99, .end_of_word = false, .semicolon_termination = true }, // Im
            .{ .child_index = 101, .end_of_word = false, .semicolon_termination = false }, // In
            .{ .child_index = 103, .end_of_word = false, .semicolon_termination = false }, // Io
            .{ .child_index = 28, .end_of_word = false, .semicolon_termination = false }, // Is
            .{ .child_index = 106, .end_of_word = false, .semicolon_termination = false }, // It
            .{ .child_index = 107, .end_of_word = false, .semicolon_termination = false }, // Iu
        },
        .len = if (want_safety) 14 else {},
    },
    .{
        .nodes1 = &[_]SecondLayerNode1{
            .{ .number = 0 }, // Jc
            .{ .number = 2 }, // Jf
            .{ .number = 3 }, // Jo
            .{ .number = 4 }, // Js
            .{ .number = 6 }, // Ju
        },
        .nodes2 = &[_]SecondLayerNode2{
            .{ .child_index = 109, .end_of_word = false, .semicolon_termination = false }, // Jc
            .{ .child_index = 7, .end_of_word = false, .semicolon_termination = false }, // Jf
            .{ .child_index = 26, .end_of_word = false, .semicolon_termination = false }, // Jo
            .{ .child_index = 111, .end_of_word = false, .semicolon_termination = false }, // Js
            .{ .child_index = 113, .end_of_word = false, .semicolon_termination = false }, // Ju
        },
        .len = if (want_safety) 5 else {},
    },
    .{
        .nodes1 = &[_]SecondLayerNode1{
            .{ .number = 0 }, // KH
            .{ .number = 1 }, // KJ
            .{ .number = 2 }, // Ka
            .{ .number = 3 }, // Kc
            .{ .number = 5 }, // Kf
            .{ .number = 6 }, // Ko
            .{ .number = 7 }, // Ks
        },
        .nodes2 = &[_]SecondLayerNode2{
            .{ .child_index = 30, .end_of_word = false, .semicolon_termination = false }, // KH
            .{ .child_index = 30, .end_of_word = false, .semicolon_termination = false }, // KJ
            .{ .child_index = 114, .end_of_word = false, .semicolon_termination = false }, // Ka
            .{ .child_index = 115, .end_of_word = false, .semicolon_termination = false }, // Kc
            .{ .child_index = 7, .end_of_word = false, .semicolon_termination = false }, // Kf
            .{ .child_index = 26, .end_of_word = false, .semicolon_termination = false }, // Ko
            .{ .child_index = 28, .end_of_word = false, .semicolon_termination = false }, // Ks
        },
        .len = if (want_safety) 7 else {},
    },
    .{
        .nodes1 = &[_]SecondLayerNode1{
            .{ .number = 0 }, // LJ
            .{ .number = 1 }, // LT
            .{ .number = 3 }, // La
            .{ .number = 8 }, // Lc
            .{ .number = 11 }, // Le
            .{ .number = 43 }, // Lf
            .{ .number = 44 }, // Ll
            .{ .number = 46 }, // Lm
            .{ .number = 47 }, // Lo
            .{ .number = 56 }, // Ls
            .{ .number = 59 }, // Lt
        },
        .nodes2 = &[_]SecondLayerNode2{
            .{ .child_index = 30, .end_of_word = false, .semicolon_termination = false }, // LJ
            .{ .child_index = 0, .end_of_word = true, .semicolon_termination = true }, // LT
            .{ .child_index = 117, .end_of_word = false, .semicolon_termination = false }, // La
            .{ .child_index = 122, .end_of_word = false, .semicolon_termination = false }, // Lc
            .{ .child_index = 125, .end_of_word = false, .semicolon_termination = false }, // Le
            .{ .child_index = 7, .end_of_word = false, .semicolon_termination = false }, // Lf
            .{ .child_index = 127, .end_of_word = false, .semicolon_termination = true }, // Ll
            .{ .child_index = 128, .end_of_word = false, .semicolon_termination = false }, // Lm
            .{ .child_index = 129, .end_of_word = false, .semicolon_termination = false }, // Lo
            .{ .child_index = 132, .end_of_word = false, .semicolon_termination = false }, // Ls
            .{ .child_index = 0, .end_of_word = false, .semicolon_termination = true }, // Lt
        },
        .len = if (want_safety) 11 else {},
    },
    .{
        .nodes1 = &[_]SecondLayerNode1{
            .{ .number = 0 }, // Ma
            .{ .number = 1 }, // Mc
            .{ .number = 2 }, // Me
            .{ .number = 4 }, // Mf
            .{ .number = 5 }, // Mi
            .{ .number = 6 }, // Mo
            .{ .number = 7 }, // Ms
            .{ .number = 8 }, // Mu
        },
        .nodes2 = &[_]SecondLayerNode2{
            .{ .child_index = 135, .end_of_word = false, .semicolon_termination = false }, // Ma
            .{ .child_index = 22, .end_of_word = false, .semicolon_termination = false }, // Mc
            .{ .child_index = 136, .end_of_word = false, .semicolon_termination = false }, // Me
            .{ .child_index = 7, .end_of_word = false, .semicolon_termination = false }, // Mf
            .{ .child_index = 138, .end_of_word = false, .semicolon_termination = false }, // Mi
            .{ .child_index = 26, .end_of_word = false, .semicolon_termination = false }, // Mo
            .{ .child_index = 28, .end_of_word = false, .semicolon_termination = false }, // Ms
            .{ .child_index = 0, .end_of_word = false, .semicolon_termination = true }, // Mu
        },
        .len = if (want_safety) 8 else {},
    },
    .{
        .nodes1 = &[_]SecondLayerNode1{
            .{ .number = 0 }, // NJ
            .{ .number = 1 }, // Na
            .{ .number = 2 }, // Nc
            .{ .number = 5 }, // Ne
            .{ .number = 12 }, // Nf
            .{ .number = 13 }, // No
            .{ .number = 68 }, // Ns
            .{ .number = 69 }, // Nt
            .{ .number = 71 }, // Nu
        },
        .nodes2 = &[_]SecondLayerNode2{
            .{ .child_index = 30, .end_of_word = false, .semicolon_termination = false }, // NJ
            .{ .child_index = 139, .end_of_word = false, .semicolon_termination = false }, // Na
            .{ .child_index = 122, .end_of_word = false, .semicolon_termination = false }, // Nc
            .{ .child_index = 140, .end_of_word = false, .semicolon_termination = false }, // Ne
            .{ .child_index = 7, .end_of_word = false, .semicolon_termination = false }, // Nf
            .{ .child_index = 143, .end_of_word = false, .semicolon_termination = false }, // No
            .{ .child_index = 28, .end_of_word = false, .semicolon_termination = false }, // Ns
            .{ .child_index = 18, .end_of_word = false, .semicolon_termination = false }, // Nt
            .{ .child_index = 0, .end_of_word = false, .semicolon_termination = true }, // Nu
        },
        .len = if (want_safety) 9 else {},
    },
    .{
        .nodes1 = &[_]SecondLayerNode1{
            .{ .number = 0 }, // OE
            .{ .number = 1 }, // Oa
            .{ .number = 3 }, // Oc
            .{ .number = 6 }, // Od
            .{ .number = 7 }, // Of
            .{ .number = 8 }, // Og
            .{ .number = 10 }, // Om
            .{ .number = 13 }, // Oo
            .{ .number = 14 }, // Op
            .{ .number = 16 }, // Or
            .{ .number = 17 }, // Os
            .{ .number = 20 }, // Ot
            .{ .number = 23 }, // Ou
            .{ .number = 25 }, // Ov
        },
        .nodes2 = &[_]SecondLayerNode2{
            .{ .child_index = 98, .end_of_word = false, .semicolon_termination = false }, // OE
            .{ .child_index = 3, .end_of_word = false, .semicolon_termination = false }, // Oa
            .{ .child_index = 5, .end_of_word = false, .semicolon_termination = false }, // Oc
            .{ .child_index = 147, .end_of_word = false, .semicolon_termination = false }, // Od
            .{ .child_index = 7, .end_of_word = false, .semicolon_termination = false }, // Of
            .{ .child_index = 8, .end_of_word = false, .semicolon_termination = false }, // Og
            .{ .child_index = 148, .end_of_word = false, .semicolon_termination = false }, // Om
            .{ .child_index = 26, .end_of_word = false, .semicolon_termination = false }, // Oo
            .{ .child_index = 151, .end_of_word = false, .semicolon_termination = false }, // Op
            .{ .child_index = 0, .end_of_word = false, .semicolon_termination = true }, // Or
            .{ .child_index = 152, .end_of_word = false, .semicolon_termination = false }, // Os
            .{ .child_index = 154, .end_of_word = false, .semicolon_termination = false }, // Ot
            .{ .child_index = 19, .end_of_word = false, .semicolon_termination = false }, // Ou
            .{ .child_index = 155, .end_of_word = false, .semicolon_termination = false }, // Ov
        },
        .len = if (want_safety) 14 else {},
    },
    .{
        .nodes1 = &[_]SecondLayerNode1{
            .{ .number = 0 }, // Pa
            .{ .number = 1 }, // Pc
            .{ .number = 2 }, // Pf
            .{ .number = 3 }, // Ph
            .{ .number = 4 }, // Pi
            .{ .number = 5 }, // Pl
            .{ .number = 6 }, // Po
            .{ .number = 8 }, // Pr
            .{ .number = 17 }, // Ps
        },
        .nodes2 = &[_]SecondLayerNode2{
            .{ .child_index = 156, .end_of_word = false, .semicolon_termination = false }, // Pa
            .{ .child_index = 22, .end_of_word = false, .semicolon_termination = false }, // Pc
            .{ .child_index = 7, .end_of_word = false, .semicolon_termination = false }, // Pf
            .{ .child_index = 42, .end_of_word = false, .semicolon_termination = false }, // Ph
            .{ .child_index = 0, .end_of_word = false, .semicolon_termination = true }, // Pi
            .{ .child_index = 157, .end_of_word = false, .semicolon_termination = false }, // Pl
            .{ .child_index = 158, .end_of_word = false, .semicolon_termination = false }, // Po
            .{ .child_index = 160, .end_of_word = false, .semicolon_termination = true }, // Pr
            .{ .child_index = 163, .end_of_word = false, .semicolon_termination = false }, // Ps
        },
        .len = if (want_safety) 9 else {},
    },
    .{
        .nodes1 = &[_]SecondLayerNode1{
            .{ .number = 0 }, // QU
            .{ .number = 2 }, // Qf
            .{ .number = 3 }, // Qo
            .{ .number = 4 }, // Qs
        },
        .nodes2 = &[_]SecondLayerNode2{
            .{ .child_index = 165, .end_of_word = false, .semicolon_termination = false }, // QU
            .{ .child_index = 7, .end_of_word = false, .semicolon_termination = false }, // Qf
            .{ .child_index = 26, .end_of_word = false, .semicolon_termination = false }, // Qo
            .{ .child_index = 28, .end_of_word = false, .semicolon_termination = false }, // Qs
        },
        .len = if (want_safety) 4 else {},
    },
    .{
        .nodes1 = &[_]SecondLayerNode1{
            .{ .number = 0 }, // RB
            .{ .number = 1 }, // RE
            .{ .number = 3 }, // Ra
            .{ .number = 7 }, // Rc
            .{ .number = 10 }, // Re
            .{ .number = 14 }, // Rf
            .{ .number = 15 }, // Rh
            .{ .number = 16 }, // Ri
            .{ .number = 39 }, // Ro
            .{ .number = 41 }, // Rr
            .{ .number = 42 }, // Rs
            .{ .number = 44 }, // Ru
        },
        .nodes2 = &[_]SecondLayerNode2{
            .{ .child_index = 166, .end_of_word = false, .semicolon_termination = false }, // RB
            .{ .child_index = 167, .end_of_word = false, .semicolon_termination = false }, // RE
            .{ .child_index = 168, .end_of_word = false, .semicolon_termination = false }, // Ra
            .{ .child_index = 122, .end_of_word = false, .semicolon_termination = false }, // Rc
            .{ .child_index = 171, .end_of_word = false, .semicolon_termination = true }, // Re
            .{ .child_index = 7, .end_of_word = false, .semicolon_termination = false }, // Rf
            .{ .child_index = 172, .end_of_word = false, .semicolon_termination = false }, // Rh
            .{ .child_index = 173, .end_of_word = false, .semicolon_termination = false }, // Ri
            .{ .child_index = 174, .end_of_word = false, .semicolon_termination = false }, // Ro
            .{ .child_index = 176, .end_of_word = false, .semicolon_termination = false }, // Rr
            .{ .child_index = 177, .end_of_word = false, .semicolon_termination = false }, // Rs
            .{ .child_index = 179, .end_of_word = false, .semicolon_termination = false }, // Ru
        },
        .len = if (want_safety) 12 else {},
    },
    .{
        .nodes1 = &[_]SecondLayerNode1{
            .{ .number = 0 }, // SH
            .{ .number = 2 }, // SO
            .{ .number = 3 }, // Sa
            .{ .number = 4 }, // Sc
            .{ .number = 9 }, // Sf
            .{ .number = 10 }, // Sh
            .{ .number = 14 }, // Si
            .{ .number = 15 }, // Sm
            .{ .number = 16 }, // So
            .{ .number = 17 }, // Sq
            .{ .number = 25 }, // Ss
            .{ .number = 26 }, // St
            .{ .number = 27 }, // Su
        },
        .nodes2 = &[_]SecondLayerNode2{
            .{ .child_index = 180, .end_of_word = false, .semicolon_termination = false }, // SH
            .{ .child_index = 182, .end_of_word = false, .semicolon_termination = false }, // SO
            .{ .child_index = 139, .end_of_word = false, .semicolon_termination = false }, // Sa
            .{ .child_index = 183, .end_of_word = false, .semicolon_termination = true }, // Sc
            .{ .child_index = 7, .end_of_word = false, .semicolon_termination = false }, // Sf
            .{ .child_index = 187, .end_of_word = false, .semicolon_termination = false }, // Sh
            .{ .child_index = 188, .end_of_word = false, .semicolon_termination = false }, // Si
            .{ .child_index = 189, .end_of_word = false, .semicolon_termination = false }, // Sm
            .{ .child_index = 26, .end_of_word = false, .semicolon_termination = false }, // So
            .{ .child_index = 190, .end_of_word = false, .semicolon_termination = false }, // Sq
            .{ .child_index = 28, .end_of_word = false, .semicolon_termination = false }, // Ss
            .{ .child_index = 192, .end_of_word = false, .semicolon_termination = false }, // St
            .{ .child_index = 193, .end_of_word = false, .semicolon_termination = false }, // Su
        },
        .len = if (want_safety) 13 else {},
    },
    .{
        .nodes1 = &[_]SecondLayerNode1{
            .{ .number = 0 }, // TH
            .{ .number = 2 }, // TR
            .{ .number = 3 }, // TS
            .{ .number = 5 }, // Ta
            .{ .number = 7 }, // Tc
            .{ .number = 10 }, // Tf
            .{ .number = 11 }, // Th
            .{ .number = 15 }, // Ti
            .{ .number = 19 }, // To
            .{ .number = 20 }, // Tr
            .{ .number = 21 }, // Ts
        },
        .nodes2 = &[_]SecondLayerNode2{
            .{ .child_index = 197, .end_of_word = false, .semicolon_termination = false }, // TH
            .{ .child_index = 198, .end_of_word = false, .semicolon_termination = false }, // TR
            .{ .child_index = 199, .end_of_word = false, .semicolon_termination = false }, // TS
            .{ .child_index = 201, .end_of_word = false, .semicolon_termination = false }, // Ta
            .{ .child_index = 122, .end_of_word = false, .semicolon_termination = false }, // Tc
            .{ .child_index = 7, .end_of_word = false, .semicolon_termination = false }, // Tf
            .{ .child_index = 203, .end_of_word = false, .semicolon_termination = false }, // Th
            .{ .child_index = 205, .end_of_word = false, .semicolon_termination = false }, // Ti
            .{ .child_index = 26, .end_of_word = false, .semicolon_termination = false }, // To
            .{ .child_index = 206, .end_of_word = false, .semicolon_termination = false }, // Tr
            .{ .child_index = 64, .end_of_word = false, .semicolon_termination = false }, // Ts
        },
        .len = if (want_safety) 11 else {},
    },
    .{
        .nodes1 = &[_]SecondLayerNode1{
            .{ .number = 0 }, // Ua
            .{ .number = 4 }, // Ub
            .{ .number = 6 }, // Uc
            .{ .number = 9 }, // Ud
            .{ .number = 10 }, // Uf
            .{ .number = 11 }, // Ug
            .{ .number = 13 }, // Um
            .{ .number = 14 }, // Un
            .{ .number = 20 }, // Uo
            .{ .number = 22 }, // Up
            .{ .number = 35 }, // Ur
            .{ .number = 36 }, // Us
            .{ .number = 37 }, // Ut
            .{ .number = 38 }, // Uu
        },
        .nodes2 = &[_]SecondLayerNode2{
            .{ .child_index = 207, .end_of_word = false, .semicolon_termination = false }, // Ua
            .{ .child_index = 209, .end_of_word = false, .semicolon_termination = false }, // Ub
            .{ .child_index = 5, .end_of_word = false, .semicolon_termination = false }, // Uc
            .{ .child_index = 147, .end_of_word = false, .semicolon_termination = false }, // Ud
            .{ .child_index = 7, .end_of_word = false, .semicolon_termination = false }, // Uf
            .{ .child_index = 8, .end_of_word = false, .semicolon_termination = false }, // Ug
            .{ .child_index = 10, .end_of_word = false, .semicolon_termination = false }, // Um
            .{ .child_index = 210, .end_of_word = false, .semicolon_termination = false }, // Un
            .{ .child_index = 12, .end_of_word = false, .semicolon_termination = false }, // Uo
            .{ .child_index = 212, .end_of_word = false, .semicolon_termination = false }, // Up
            .{ .child_index = 220, .end_of_word = false, .semicolon_termination = false }, // Ur
            .{ .child_index = 28, .end_of_word = false, .semicolon_termination = false }, // Us
            .{ .child_index = 106, .end_of_word = false, .semicolon_termination = false }, // Ut
            .{ .child_index = 19, .end_of_word = false, .semicolon_termination = false }, // Uu
        },
        .len = if (want_safety) 14 else {},
    },
    .{
        .nodes1 = &[_]SecondLayerNode1{
            .{ .number = 0 }, // VD
            .{ .number = 1 }, // Vb
            .{ .number = 2 }, // Vc
            .{ .number = 3 }, // Vd
            .{ .number = 5 }, // Ve
            .{ .number = 13 }, // Vf
            .{ .number = 14 }, // Vo
            .{ .number = 15 }, // Vs
            .{ .number = 16 }, // Vv
        },
        .nodes2 = &[_]SecondLayerNode2{
            .{ .child_index = 221, .end_of_word = false, .semicolon_termination = false }, // VD
            .{ .child_index = 192, .end_of_word = false, .semicolon_termination = false }, // Vb
            .{ .child_index = 22, .end_of_word = false, .semicolon_termination = false }, // Vc
            .{ .child_index = 222, .end_of_word = false, .semicolon_termination = false }, // Vd
            .{ .child_index = 223, .end_of_word = false, .semicolon_termination = false }, // Ve
            .{ .child_index = 7, .end_of_word = false, .semicolon_termination = false }, // Vf
            .{ .child_index = 26, .end_of_word = false, .semicolon_termination = false }, // Vo
            .{ .child_index = 28, .end_of_word = false, .semicolon_termination = false }, // Vs
            .{ .child_index = 225, .end_of_word = false, .semicolon_termination = false }, // Vv
        },
        .len = if (want_safety) 9 else {},
    },
    .{
        .nodes1 = &[_]SecondLayerNode1{
            .{ .number = 0 }, // Wc
            .{ .number = 1 }, // We
            .{ .number = 2 }, // Wf
            .{ .number = 3 }, // Wo
            .{ .number = 4 }, // Ws
        },
        .nodes2 = &[_]SecondLayerNode2{
            .{ .child_index = 93, .end_of_word = false, .semicolon_termination = false }, // Wc
            .{ .child_index = 226, .end_of_word = false, .semicolon_termination = false }, // We
            .{ .child_index = 7, .end_of_word = false, .semicolon_termination = false }, // Wf
            .{ .child_index = 26, .end_of_word = false, .semicolon_termination = false }, // Wo
            .{ .child_index = 28, .end_of_word = false, .semicolon_termination = false }, // Ws
        },
        .len = if (want_safety) 5 else {},
    },
    .{
        .nodes1 = &[_]SecondLayerNode1{
            .{ .number = 0 }, // Xf
            .{ .number = 1 }, // Xi
            .{ .number = 2 }, // Xo
            .{ .number = 3 }, // Xs
        },
        .nodes2 = &[_]SecondLayerNode2{
            .{ .child_index = 7, .end_of_word = false, .semicolon_termination = false }, // Xf
            .{ .child_index = 0, .end_of_word = false, .semicolon_termination = true }, // Xi
            .{ .child_index = 26, .end_of_word = false, .semicolon_termination = false }, // Xo
            .{ .child_index = 28, .end_of_word = false, .semicolon_termination = false }, // Xs
        },
        .len = if (want_safety) 4 else {},
    },
    .{
        .nodes1 = &[_]SecondLayerNode1{
            .{ .number = 0 }, // YA
            .{ .number = 1 }, // YI
            .{ .number = 2 }, // YU
            .{ .number = 3 }, // Ya
            .{ .number = 5 }, // Yc
            .{ .number = 7 }, // Yf
            .{ .number = 8 }, // Yo
            .{ .number = 9 }, // Ys
            .{ .number = 10 }, // Yu
        },
        .nodes2 = &[_]SecondLayerNode2{
            .{ .child_index = 30, .end_of_word = false, .semicolon_termination = false }, // YA
            .{ .child_index = 30, .end_of_word = false, .semicolon_termination = false }, // YI
            .{ .child_index = 30, .end_of_word = false, .semicolon_termination = false }, // YU
            .{ .child_index = 3, .end_of_word = false, .semicolon_termination = false }, // Ya
            .{ .child_index = 109, .end_of_word = false, .semicolon_termination = false }, // Yc
            .{ .child_index = 7, .end_of_word = false, .semicolon_termination = false }, // Yf
            .{ .child_index = 26, .end_of_word = false, .semicolon_termination = false }, // Yo
            .{ .child_index = 28, .end_of_word = false, .semicolon_termination = false }, // Ys
            .{ .child_index = 227, .end_of_word = false, .semicolon_termination = false }, // Yu
        },
        .len = if (want_safety) 9 else {},
    },
    .{
        .nodes1 = &[_]SecondLayerNode1{
            .{ .number = 0 }, // ZH
            .{ .number = 1 }, // Za
            .{ .number = 2 }, // Zc
            .{ .number = 4 }, // Zd
            .{ .number = 5 }, // Ze
            .{ .number = 7 }, // Zf
            .{ .number = 8 }, // Zo
            .{ .number = 9 }, // Zs
        },
        .nodes2 = &[_]SecondLayerNode2{
            .{ .child_index = 30, .end_of_word = false, .semicolon_termination = false }, // ZH
            .{ .child_index = 139, .end_of_word = false, .semicolon_termination = false }, // Za
            .{ .child_index = 55, .end_of_word = false, .semicolon_termination = false }, // Zc
            .{ .child_index = 39, .end_of_word = false, .semicolon_termination = false }, // Zd
            .{ .child_index = 228, .end_of_word = false, .semicolon_termination = false }, // Ze
            .{ .child_index = 7, .end_of_word = false, .semicolon_termination = false }, // Zf
            .{ .child_index = 26, .end_of_word = false, .semicolon_termination = false }, // Zo
            .{ .child_index = 28, .end_of_word = false, .semicolon_termination = false }, // Zs
        },
        .len = if (want_safety) 8 else {},
    },
    .{
        .nodes1 = &[_]SecondLayerNode1{
            .{ .number = 0 }, // aa
            .{ .number = 2 }, // ab
            .{ .number = 3 }, // ac
            .{ .number = 11 }, // ae
            .{ .number = 13 }, // af
            .{ .number = 15 }, // ag
            .{ .number = 17 }, // al
            .{ .number = 20 }, // am
            .{ .number = 24 }, // an
            .{ .number = 47 }, // ao
            .{ .number = 49 }, // ap
            .{ .number = 57 }, // ar
            .{ .number = 59 }, // as
            .{ .number = 63 }, // at
            .{ .number = 65 }, // au
            .{ .number = 67 }, // aw
        },
        .nodes2 = &[_]SecondLayerNode2{
            .{ .child_index = 3, .end_of_word = false, .semicolon_termination = false }, // aa
            .{ .child_index = 4, .end_of_word = false, .semicolon_termination = false }, // ab
            .{ .child_index = 230, .end_of_word = false, .semicolon_termination = true }, // ac
            .{ .child_index = 1, .end_of_word = false, .semicolon_termination = false }, // ae
            .{ .child_index = 235, .end_of_word = false, .semicolon_termination = true }, // af
            .{ .child_index = 8, .end_of_word = false, .semicolon_termination = false }, // ag
            .{ .child_index = 236, .end_of_word = false, .semicolon_termination = false }, // al
            .{ .child_index = 238, .end_of_word = false, .semicolon_termination = false }, // am
            .{ .child_index = 240, .end_of_word = false, .semicolon_termination = false }, // an
            .{ .child_index = 12, .end_of_word = false, .semicolon_termination = false }, // ao
            .{ .child_index = 242, .end_of_word = false, .semicolon_termination = true }, // ap
            .{ .child_index = 15, .end_of_word = false, .semicolon_termination = false }, // ar
            .{ .child_index = 248, .end_of_word = false, .semicolon_termination = false }, // as
            .{ .child_index = 18, .end_of_word = false, .semicolon_termination = false }, // at
            .{ .child_index = 19, .end_of_word = false, .semicolon_termination = false }, // au
            .{ .child_index = 251, .end_of_word = false, .semicolon_termination = false }, // aw
        },
        .len = if (want_safety) 16 else {},
    },
    .{
        .nodes1 = &[_]SecondLayerNode1{
            .{ .number = 0 }, // bN
            .{ .number = 1 }, // ba
            .{ .number = 9 }, // bb
            .{ .number = 11 }, // bc
            .{ .number = 13 }, // bd
            .{ .number = 14 }, // be
            .{ .number = 22 }, // bf
            .{ .number = 23 }, // bi
            .{ .number = 36 }, // bk
            .{ .number = 37 }, // bl
            .{ .number = 48 }, // bn
            .{ .number = 51 }, // bo
            .{ .number = 99 }, // bp
            .{ .number = 100 }, // br
            .{ .number = 103 }, // bs
            .{ .number = 110 }, // bu
        },
        .nodes2 = &[_]SecondLayerNode2{
            .{ .child_index = 39, .end_of_word = false, .semicolon_termination = false }, // bN
            .{ .child_index = 253, .end_of_word = false, .semicolon_termination = false }, // ba
            .{ .child_index = 255, .end_of_word = false, .semicolon_termination = false }, // bb
            .{ .child_index = 256, .end_of_word = false, .semicolon_termination = false }, // bc
            .{ .child_index = 258, .end_of_word = false, .semicolon_termination = false }, // bd
            .{ .child_index = 259, .end_of_word = false, .semicolon_termination = false }, // be
            .{ .child_index = 7, .end_of_word = false, .semicolon_termination = false }, // bf
            .{ .child_index = 264, .end_of_word = false, .semicolon_termination = false }, // bi
            .{ .child_index = 265, .end_of_word = false, .semicolon_termination = false }, // bk
            .{ .child_index = 266, .end_of_word = false, .semicolon_termination = false }, // bl
            .{ .child_index = 269, .end_of_word = false, .semicolon_termination = false }, // bn
            .{ .child_index = 271, .end_of_word = false, .semicolon_termination = false }, // bo
            .{ .child_index = 275, .end_of_word = false, .semicolon_termination = false }, // bp
            .{ .child_index = 276, .end_of_word = false, .semicolon_termination = false }, // br
            .{ .child_index = 278, .end_of_word = false, .semicolon_termination = false }, // bs
            .{ .child_index = 282, .end_of_word = false, .semicolon_termination = false }, // bu
        },
        .len = if (want_safety) 16 else {},
    },
    .{
        .nodes1 = &[_]SecondLayerNode1{
            .{ .number = 0 }, // ca
            .{ .number = 10 }, // cc
            .{ .number = 17 }, // cd
            .{ .number = 18 }, // ce
            .{ .number = 24 }, // cf
            .{ .number = 25 }, // ch
            .{ .number = 29 }, // ci
            .{ .number = 44 }, // cl
            .{ .number = 46 }, // co
            .{ .number = 63 }, // cr
            .{ .number = 65 }, // cs
            .{ .number = 70 }, // ct
            .{ .number = 71 }, // cu
            .{ .number = 96 }, // cw
            .{ .number = 98 }, // cy
        },
        .nodes2 = &[_]SecondLayerNode2{
            .{ .child_index = 284, .end_of_word = false, .semicolon_termination = false }, // ca
            .{ .child_index = 287, .end_of_word = false, .semicolon_termination = false }, // cc
            .{ .child_index = 39, .end_of_word = false, .semicolon_termination = false }, // cd
            .{ .child_index = 291, .end_of_word = false, .semicolon_termination = false }, // ce
            .{ .child_index = 7, .end_of_word = false, .semicolon_termination = false }, // cf
            .{ .child_index = 294, .end_of_word = false, .semicolon_termination = false }, // ch
            .{ .child_index = 297, .end_of_word = false, .semicolon_termination = false }, // ci
            .{ .child_index = 298, .end_of_word = false, .semicolon_termination = false }, // cl
            .{ .child_index = 299, .end_of_word = false, .semicolon_termination = false }, // co
            .{ .child_index = 303, .end_of_word = false, .semicolon_termination = false }, // cr
            .{ .child_index = 305, .end_of_word = false, .semicolon_termination = false }, // cs
            .{ .child_index = 307, .end_of_word = false, .semicolon_termination = false }, // ct
            .{ .child_index = 308, .end_of_word = false, .semicolon_termination = false }, // cu
            .{ .child_index = 251, .end_of_word = false, .semicolon_termination = false }, // cw
            .{ .child_index = 315, .end_of_word = false, .semicolon_termination = false }, // cy
        },
        .len = if (want_safety) 15 else {},
    },
    .{
        .nodes1 = &[_]SecondLayerNode1{
            .{ .number = 0 }, // dA
            .{ .number = 1 }, // dH
            .{ .number = 2 }, // da
            .{ .number = 7 }, // db
            .{ .number = 9 }, // dc
            .{ .number = 11 }, // dd
            .{ .number = 15 }, // de
            .{ .number = 19 }, // df
            .{ .number = 21 }, // dh
            .{ .number = 23 }, // di
            .{ .number = 35 }, // dj
            .{ .number = 36 }, // dl
            .{ .number = 38 }, // do
            .{ .number = 51 }, // dr
            .{ .number = 54 }, // ds
            .{ .number = 58 }, // dt
            .{ .number = 61 }, // du
            .{ .number = 63 }, // dw
            .{ .number = 64 }, // dz
        },
        .nodes2 = &[_]SecondLayerNode2{
            .{ .child_index = 316, .end_of_word = false, .semicolon_termination = false }, // dA
            .{ .child_index = 192, .end_of_word = false, .semicolon_termination = false }, // dH
            .{ .child_index = 317, .end_of_word = false, .semicolon_termination = false }, // da
            .{ .child_index = 321, .end_of_word = false, .semicolon_termination = false }, // db
            .{ .child_index = 55, .end_of_word = false, .semicolon_termination = false }, // dc
            .{ .child_index = 323, .end_of_word = false, .semicolon_termination = true }, // dd
            .{ .child_index = 325, .end_of_word = false, .semicolon_termination = false }, // de
            .{ .child_index = 328, .end_of_word = false, .semicolon_termination = false }, // df
            .{ .child_index = 330, .end_of_word = false, .semicolon_termination = false }, // dh
            .{ .child_index = 331, .end_of_word = false, .semicolon_termination = false }, // di
            .{ .child_index = 30, .end_of_word = false, .semicolon_termination = false }, // dj
            .{ .child_index = 336, .end_of_word = false, .semicolon_termination = false }, // dl
            .{ .child_index = 337, .end_of_word = false, .semicolon_termination = false }, // do
            .{ .child_index = 342, .end_of_word = false, .semicolon_termination = false }, // dr
            .{ .child_index = 344, .end_of_word = false, .semicolon_termination = false }, // ds
            .{ .child_index = 347, .end_of_word = false, .semicolon_termination = false }, // dt
            .{ .child_index = 349, .end_of_word = false, .semicolon_termination = false }, // du
            .{ .child_index = 351, .end_of_word = false, .semicolon_termination = false }, // dw
            .{ .child_index = 352, .end_of_word = false, .semicolon_termination = false }, // dz
        },
        .len = if (want_safety) 19 else {},
    },
    .{
        .nodes1 = &[_]SecondLayerNode1{
            .{ .number = 0 }, // eD
            .{ .number = 2 }, // ea
            .{ .number = 5 }, // ec
            .{ .number = 11 }, // ed
            .{ .number = 12 }, // ee
            .{ .number = 13 }, // ef
            .{ .number = 15 }, // eg
            .{ .number = 20 }, // el
            .{ .number = 25 }, // em
            .{ .number = 32 }, // en
            .{ .number = 34 }, // eo
            .{ .number = 36 }, // ep
            .{ .number = 42 }, // eq
            .{ .number = 52 }, // er
            .{ .number = 54 }, // es
            .{ .number = 57 }, // et
            .{ .number = 60 }, // eu
            .{ .number = 63 }, // ex
        },
        .nodes2 = &[_]SecondLayerNode2{
            .{ .child_index = 354, .end_of_word = false, .semicolon_termination = false }, // eD
            .{ .child_index = 356, .end_of_word = false, .semicolon_termination = false }, // ea
            .{ .child_index = 358, .end_of_word = false, .semicolon_termination = false }, // ec
            .{ .child_index = 39, .end_of_word = false, .semicolon_termination = false }, // ed
            .{ .child_index = 0, .end_of_word = false, .semicolon_termination = true }, // ee
            .{ .child_index = 362, .end_of_word = false, .semicolon_termination = false }, // ef
            .{ .child_index = 364, .end_of_word = false, .semicolon_termination = true }, // eg
            .{ .child_index = 366, .end_of_word = false, .semicolon_termination = true }, // el
            .{ .child_index = 369, .end_of_word = false, .semicolon_termination = false }, // em
            .{ .child_index = 372, .end_of_word = false, .semicolon_termination = false }, // en
            .{ .child_index = 12, .end_of_word = false, .semicolon_termination = false }, // eo
            .{ .child_index = 374, .end_of_word = false, .semicolon_termination = false }, // ep
            .{ .child_index = 377, .end_of_word = false, .semicolon_termination = false }, // eq
            .{ .child_index = 381, .end_of_word = false, .semicolon_termination = false }, // er
            .{ .child_index = 383, .end_of_word = false, .semicolon_termination = false }, // es
            .{ .child_index = 386, .end_of_word = false, .semicolon_termination = false }, // et
            .{ .child_index = 388, .end_of_word = false, .semicolon_termination = false }, // eu
            .{ .child_index = 390, .end_of_word = false, .semicolon_termination = false }, // ex
        },
        .len = if (want_safety) 18 else {},
    },
    .{
        .nodes1 = &[_]SecondLayerNode1{
            .{ .number = 0 }, // fa
            .{ .number = 1 }, // fc
            .{ .number = 2 }, // fe
            .{ .number = 3 }, // ff
            .{ .number = 7 }, // fi
            .{ .number = 8 }, // fj
            .{ .number = 9 }, // fl
            .{ .number = 12 }, // fn
            .{ .number = 13 }, // fo
            .{ .number = 17 }, // fp
            .{ .number = 18 }, // fr
            .{ .number = 38 }, // fs
        },
        .nodes2 = &[_]SecondLayerNode2{
            .{ .child_index = 393, .end_of_word = false, .semicolon_termination = false }, // fa
            .{ .child_index = 22, .end_of_word = false, .semicolon_termination = false }, // fc
            .{ .child_index = 394, .end_of_word = false, .semicolon_termination = false }, // fe
            .{ .child_index = 395, .end_of_word = false, .semicolon_termination = false }, // ff
            .{ .child_index = 98, .end_of_word = false, .semicolon_termination = false }, // fi
            .{ .child_index = 98, .end_of_word = false, .semicolon_termination = false }, // fj
            .{ .child_index = 398, .end_of_word = false, .semicolon_termination = false }, // fl
            .{ .child_index = 401, .end_of_word = false, .semicolon_termination = false }, // fn
            .{ .child_index = 402, .end_of_word = false, .semicolon_termination = false }, // fo
            .{ .child_index = 404, .end_of_word = false, .semicolon_termination = false }, // fp
            .{ .child_index = 405, .end_of_word = false, .semicolon_termination = false }, // fr
            .{ .child_index = 28, .end_of_word = false, .semicolon_termination = false }, // fs
        },
        .len = if (want_safety) 12 else {},
    },
    .{
        .nodes1 = &[_]SecondLayerNode1{
            .{ .number = 0 }, // gE
            .{ .number = 2 }, // ga
            .{ .number = 6 }, // gb
            .{ .number = 7 }, // gc
            .{ .number = 9 }, // gd
            .{ .number = 10 }, // ge
            .{ .number = 22 }, // gf
            .{ .number = 23 }, // gg
            .{ .number = 25 }, // gi
            .{ .number = 26 }, // gj
            .{ .number = 27 }, // gl
            .{ .number = 31 }, // gn
            .{ .number = 38 }, // go
            .{ .number = 39 }, // gr
            .{ .number = 40 }, // gs
            .{ .number = 44 }, // gt
            .{ .number = 58 }, // gv
        },
        .nodes2 = &[_]SecondLayerNode2{
            .{ .child_index = 407, .end_of_word = false, .semicolon_termination = true }, // gE
            .{ .child_index = 408, .end_of_word = false, .semicolon_termination = false }, // ga
            .{ .child_index = 4, .end_of_word = false, .semicolon_termination = false }, // gb
            .{ .child_index = 109, .end_of_word = false, .semicolon_termination = false }, // gc
            .{ .child_index = 39, .end_of_word = false, .semicolon_termination = false }, // gd
            .{ .child_index = 411, .end_of_word = false, .semicolon_termination = true }, // ge
            .{ .child_index = 7, .end_of_word = false, .semicolon_termination = false }, // gf
            .{ .child_index = 414, .end_of_word = false, .semicolon_termination = true }, // gg
            .{ .child_index = 415, .end_of_word = false, .semicolon_termination = false }, // gi
            .{ .child_index = 30, .end_of_word = false, .semicolon_termination = false }, // gj
            .{ .child_index = 416, .end_of_word = false, .semicolon_termination = true }, // gl
            .{ .child_index = 419, .end_of_word = false, .semicolon_termination = false }, // gn
            .{ .child_index = 26, .end_of_word = false, .semicolon_termination = false }, // go
            .{ .child_index = 423, .end_of_word = false, .semicolon_termination = false }, // gr
            .{ .child_index = 424, .end_of_word = false, .semicolon_termination = false }, // gs
            .{ .child_index = 426, .end_of_word = true, .semicolon_termination = true }, // gt
            .{ .child_index = 431, .end_of_word = false, .semicolon_termination = false }, // gv
        },
        .len = if (want_safety) 17 else {},
    },
    .{
        .nodes1 = &[_]SecondLayerNode1{
            .{ .number = 0 }, // hA
            .{ .number = 1 }, // ha
            .{ .number = 8 }, // hb
            .{ .number = 9 }, // hc
            .{ .number = 10 }, // he
            .{ .number = 14 }, // hf
            .{ .number = 15 }, // hk
            .{ .number = 17 }, // ho
            .{ .number = 23 }, // hs
            .{ .number = 26 }, // hy
        },
        .nodes2 = &[_]SecondLayerNode2{
            .{ .child_index = 316, .end_of_word = false, .semicolon_termination = false }, // hA
            .{ .child_index = 433, .end_of_word = false, .semicolon_termination = false }, // ha
            .{ .child_index = 192, .end_of_word = false, .semicolon_termination = false }, // hb
            .{ .child_index = 93, .end_of_word = false, .semicolon_termination = false }, // hc
            .{ .child_index = 437, .end_of_word = false, .semicolon_termination = false }, // he
            .{ .child_index = 7, .end_of_word = false, .semicolon_termination = false }, // hf
            .{ .child_index = 440, .end_of_word = false, .semicolon_termination = false }, // hk
            .{ .child_index = 441, .end_of_word = false, .semicolon_termination = false }, // ho
            .{ .child_index = 446, .end_of_word = false, .semicolon_termination = false }, // hs
            .{ .child_index = 449, .end_of_word = false, .semicolon_termination = false }, // hy
        },
        .len = if (want_safety) 10 else {},
    },
    .{
        .nodes1 = &[_]SecondLayerNode1{
            .{ .number = 0 }, // ia
            .{ .number = 2 }, // ic
            .{ .number = 6 }, // ie
            .{ .number = 9 }, // if
            .{ .number = 11 }, // ig
            .{ .number = 13 }, // ii
            .{ .number = 18 }, // ij
            .{ .number = 19 }, // im
            .{ .number = 26 }, // in
            .{ .number = 37 }, // io
            .{ .number = 41 }, // ip
            .{ .number = 42 }, // iq
            .{ .number = 44 }, // is
            .{ .number = 51 }, // it
            .{ .number = 53 }, // iu
        },
        .nodes2 = &[_]SecondLayerNode2{
            .{ .child_index = 3, .end_of_word = false, .semicolon_termination = false }, // ia
            .{ .child_index = 451, .end_of_word = false, .semicolon_termination = true }, // ic
            .{ .child_index = 453, .end_of_word = false, .semicolon_termination = false }, // ie
            .{ .child_index = 455, .end_of_word = false, .semicolon_termination = false }, // if
            .{ .child_index = 8, .end_of_word = false, .semicolon_termination = false }, // ig
            .{ .child_index = 457, .end_of_word = false, .semicolon_termination = true }, // ii
            .{ .child_index = 98, .end_of_word = false, .semicolon_termination = false }, // ij
            .{ .child_index = 460, .end_of_word = false, .semicolon_termination = false }, // im
            .{ .child_index = 463, .end_of_word = false, .semicolon_termination = true }, // in
            .{ .child_index = 467, .end_of_word = false, .semicolon_termination = false }, // io
            .{ .child_index = 471, .end_of_word = false, .semicolon_termination = false }, // ip
            .{ .child_index = 472, .end_of_word = false, .semicolon_termination = false }, // iq
            .{ .child_index = 473, .end_of_word = false, .semicolon_termination = false }, // is
            .{ .child_index = 475, .end_of_word = false, .semicolon_termination = true }, // it
            .{ .child_index = 107, .end_of_word = false, .semicolon_termination = false }, // iu
        },
        .len = if (want_safety) 15 else {},
    },
    .{
        .nodes1 = &[_]SecondLayerNode1{
            .{ .number = 0 }, // jc
            .{ .number = 2 }, // jf
            .{ .number = 3 }, // jm
            .{ .number = 4 }, // jo
            .{ .number = 5 }, // js
            .{ .number = 7 }, // ju
        },
        .nodes2 = &[_]SecondLayerNode2{
            .{ .child_index = 109, .end_of_word = false, .semicolon_termination = false }, // jc
            .{ .child_index = 7, .end_of_word = false, .semicolon_termination = false }, // jf
            .{ .child_index = 476, .end_of_word = false, .semicolon_termination = false }, // jm
            .{ .child_index = 26, .end_of_word = false, .semicolon_termination = false }, // jo
            .{ .child_index = 111, .end_of_word = false, .semicolon_termination = false }, // js
            .{ .child_index = 113, .end_of_word = false, .semicolon_termination = false }, // ju
        },
        .len = if (want_safety) 6 else {},
    },
    .{
        .nodes1 = &[_]SecondLayerNode1{
            .{ .number = 0 }, // ka
            .{ .number = 2 }, // kc
            .{ .number = 4 }, // kf
            .{ .number = 5 }, // kg
            .{ .number = 6 }, // kh
            .{ .number = 7 }, // kj
            .{ .number = 8 }, // ko
            .{ .number = 9 }, // ks
        },
        .nodes2 = &[_]SecondLayerNode2{
            .{ .child_index = 477, .end_of_word = false, .semicolon_termination = false }, // ka
            .{ .child_index = 115, .end_of_word = false, .semicolon_termination = false }, // kc
            .{ .child_index = 7, .end_of_word = false, .semicolon_termination = false }, // kf
            .{ .child_index = 478, .end_of_word = false, .semicolon_termination = false }, // kg
            .{ .child_index = 30, .end_of_word = false, .semicolon_termination = false }, // kh
            .{ .child_index = 30, .end_of_word = false, .semicolon_termination = false }, // kj
            .{ .child_index = 26, .end_of_word = false, .semicolon_termination = false }, // ko
            .{ .child_index = 28, .end_of_word = false, .semicolon_termination = false }, // ks
        },
        .len = if (want_safety) 8 else {},
    },
    .{
        .nodes1 = &[_]SecondLayerNode1{
            .{ .number = 0 }, // lA
            .{ .number = 3 }, // lB
            .{ .number = 4 }, // lE
            .{ .number = 6 }, // lH
            .{ .number = 7 }, // la
            .{ .number = 30 }, // lb
            .{ .number = 37 }, // lc
            .{ .number = 42 }, // ld
            .{ .number = 48 }, // le
            .{ .number = 76 }, // lf
            .{ .number = 79 }, // lg
            .{ .number = 81 }, // lh
            .{ .number = 85 }, // lj
            .{ .number = 86 }, // ll
            .{ .number = 91 }, // lm
            .{ .number = 94 }, // ln
            .{ .number = 101 }, // lo
            .{ .number = 119 }, // lp
            .{ .number = 121 }, // lr
            .{ .number = 127 }, // ls
            .{ .number = 137 }, // lt
            .{ .number = 150 }, // lu
            .{ .number = 152 }, // lv
        },
        .nodes2 = &[_]SecondLayerNode2{
            .{ .child_index = 479, .end_of_word = false, .semicolon_termination = false }, // lA
            .{ .child_index = 166, .end_of_word = false, .semicolon_termination = false }, // lB
            .{ .child_index = 414, .end_of_word = false, .semicolon_termination = true }, // lE
            .{ .child_index = 192, .end_of_word = false, .semicolon_termination = false }, // lH
            .{ .child_index = 482, .end_of_word = false, .semicolon_termination = false }, // la
            .{ .child_index = 491, .end_of_word = false, .semicolon_termination = false }, // lb
            .{ .child_index = 494, .end_of_word = false, .semicolon_termination = false }, // lc
            .{ .child_index = 498, .end_of_word = false, .semicolon_termination = false }, // ld
            .{ .child_index = 502, .end_of_word = false, .semicolon_termination = true }, // le
            .{ .child_index = 506, .end_of_word = false, .semicolon_termination = false }, // lf
            .{ .child_index = 509, .end_of_word = false, .semicolon_termination = true }, // lg
            .{ .child_index = 510, .end_of_word = false, .semicolon_termination = false }, // lh
            .{ .child_index = 30, .end_of_word = false, .semicolon_termination = false }, // lj
            .{ .child_index = 512, .end_of_word = false, .semicolon_termination = true }, // ll
            .{ .child_index = 516, .end_of_word = false, .semicolon_termination = false }, // lm
            .{ .child_index = 419, .end_of_word = false, .semicolon_termination = false }, // ln
            .{ .child_index = 518, .end_of_word = false, .semicolon_termination = false }, // lo
            .{ .child_index = 526, .end_of_word = false, .semicolon_termination = false }, // lp
            .{ .child_index = 527, .end_of_word = false, .semicolon_termination = false }, // lr
            .{ .child_index = 532, .end_of_word = false, .semicolon_termination = false }, // ls
            .{ .child_index = 538, .end_of_word = true, .semicolon_termination = true }, // lt
            .{ .child_index = 545, .end_of_word = false, .semicolon_termination = false }, // lu
            .{ .child_index = 431, .end_of_word = false, .semicolon_termination = false }, // lv
        },
        .len = if (want_safety) 23 else {},
    },
    .{
        .nodes1 = &[_]SecondLayerNode1{
            .{ .number = 0 }, // mD
            .{ .number = 1 }, // ma
            .{ .number = 12 }, // mc
            .{ .number = 14 }, // md
            .{ .number = 15 }, // me
            .{ .number = 16 }, // mf
            .{ .number = 17 }, // mh
            .{ .number = 18 }, // mi
            .{ .number = 29 }, // ml
            .{ .number = 31 }, // mn
            .{ .number = 32 }, // mo
            .{ .number = 34 }, // mp
            .{ .number = 35 }, // ms
            .{ .number = 37 }, // mu
        },
        .nodes2 = &[_]SecondLayerNode2{
            .{ .child_index = 546, .end_of_word = false, .semicolon_termination = false }, // mD
            .{ .child_index = 547, .end_of_word = false, .semicolon_termination = false }, // ma
            .{ .child_index = 551, .end_of_word = false, .semicolon_termination = false }, // mc
            .{ .child_index = 221, .end_of_word = false, .semicolon_termination = false }, // md
            .{ .child_index = 553, .end_of_word = false, .semicolon_termination = false }, // me
            .{ .child_index = 7, .end_of_word = false, .semicolon_termination = false }, // mf
            .{ .child_index = 172, .end_of_word = false, .semicolon_termination = false }, // mh
            .{ .child_index = 554, .end_of_word = false, .semicolon_termination = false }, // mi
            .{ .child_index = 557, .end_of_word = false, .semicolon_termination = false }, // ml
            .{ .child_index = 559, .end_of_word = false, .semicolon_termination = false }, // mn
            .{ .child_index = 560, .end_of_word = false, .semicolon_termination = false }, // mo
            .{ .child_index = 0, .end_of_word = false, .semicolon_termination = true }, // mp
            .{ .child_index = 562, .end_of_word = false, .semicolon_termination = false }, // ms
            .{ .child_index = 564, .end_of_word = false, .semicolon_termination = true }, // mu
        },
        .len = if (want_safety) 14 else {},
    },
    .{
        .nodes1 = &[_]SecondLayerNode1{
            .{ .number = 0 }, // nG
            .{ .number = 3 }, // nL
            .{ .number = 8 }, // nR
            .{ .number = 9 }, // nV
            .{ .number = 11 }, // na
            .{ .number = 22 }, // nb
            .{ .number = 26 }, // nc
            .{ .number = 33 }, // nd
            .{ .number = 34 }, // ne
            .{ .number = 45 }, // nf
            .{ .number = 46 }, // ng
            .{ .number = 55 }, // nh
            .{ .number = 58 }, // ni
            .{ .number = 62 }, // nj
            .{ .number = 63 }, // nl
            .{ .number = 79 }, // nm
            .{ .number = 80 }, // no
            .{ .number = 93 }, // np
            .{ .number = 103 }, // nr
            .{ .number = 110 }, // ns
            .{ .number = 137 }, // nt
            .{ .number = 145 }, // nu
            .{ .number = 149 }, // nv
            .{ .number = 163 }, // nw
        },
        .nodes2 = &[_]SecondLayerNode2{
            .{ .child_index = 566, .end_of_word = false, .semicolon_termination = false }, // nG
            .{ .child_index = 568, .end_of_word = false, .semicolon_termination = false }, // nL
            .{ .child_index = 176, .end_of_word = false, .semicolon_termination = false }, // nR
            .{ .child_index = 571, .end_of_word = false, .semicolon_termination = false }, // nV
            .{ .child_index = 573, .end_of_word = false, .semicolon_termination = false }, // na
            .{ .child_index = 578, .end_of_word = false, .semicolon_termination = false }, // nb
            .{ .child_index = 580, .end_of_word = false, .semicolon_termination = false }, // nc
            .{ .child_index = 221, .end_of_word = false, .semicolon_termination = false }, // nd
            .{ .child_index = 585, .end_of_word = false, .semicolon_termination = true }, // ne
            .{ .child_index = 7, .end_of_word = false, .semicolon_termination = false }, // nf
            .{ .child_index = 591, .end_of_word = false, .semicolon_termination = false }, // ng
            .{ .child_index = 595, .end_of_word = false, .semicolon_termination = false }, // nh
            .{ .child_index = 598, .end_of_word = false, .semicolon_termination = true }, // ni
            .{ .child_index = 30, .end_of_word = false, .semicolon_termination = false }, // nj
            .{ .child_index = 600, .end_of_word = false, .semicolon_termination = false }, // nl
            .{ .child_index = 607, .end_of_word = false, .semicolon_termination = false }, // nm
            .{ .child_index = 608, .end_of_word = false, .semicolon_termination = false }, // no
            .{ .child_index = 610, .end_of_word = false, .semicolon_termination = false }, // np
            .{ .child_index = 613, .end_of_word = false, .semicolon_termination = false }, // nr
            .{ .child_index = 617, .end_of_word = false, .semicolon_termination = false }, // ns
            .{ .child_index = 624, .end_of_word = false, .semicolon_termination = false }, // nt
            .{ .child_index = 628, .end_of_word = false, .semicolon_termination = true }, // nu
            .{ .child_index = 629, .end_of_word = false, .semicolon_termination = false }, // nv
            .{ .child_index = 638, .end_of_word = false, .semicolon_termination = false }, // nw
        },
        .len = if (want_safety) 24 else {},
    },
    .{
        .nodes1 = &[_]SecondLayerNode1{
            .{ .number = 0 }, // oS
            .{ .number = 1 }, // oa
            .{ .number = 4 }, // oc
            .{ .number = 8 }, // od
            .{ .number = 13 }, // oe
            .{ .number = 14 }, // of
            .{ .number = 16 }, // og
            .{ .number = 20 }, // oh
            .{ .number = 22 }, // oi
            .{ .number = 23 }, // ol
            .{ .number = 28 }, // om
            .{ .number = 33 }, // oo
            .{ .number = 34 }, // op
            .{ .number = 37 }, // or
            .{ .number = 50 }, // os
            .{ .number = 54 }, // ot
            .{ .number = 58 }, // ou
            .{ .number = 60 }, // ov
        },
        .nodes2 = &[_]SecondLayerNode2{
            .{ .child_index = 0, .end_of_word = false, .semicolon_termination = true }, // oS
            .{ .child_index = 641, .end_of_word = false, .semicolon_termination = false }, // oa
            .{ .child_index = 643, .end_of_word = false, .semicolon_termination = false }, // oc
            .{ .child_index = 645, .end_of_word = false, .semicolon_termination = false }, // od
            .{ .child_index = 98, .end_of_word = false, .semicolon_termination = false }, // oe
            .{ .child_index = 650, .end_of_word = false, .semicolon_termination = false }, // of
            .{ .child_index = 652, .end_of_word = false, .semicolon_termination = false }, // og
            .{ .child_index = 655, .end_of_word = false, .semicolon_termination = false }, // oh
            .{ .child_index = 657, .end_of_word = false, .semicolon_termination = false }, // oi
            .{ .child_index = 658, .end_of_word = false, .semicolon_termination = false }, // ol
            .{ .child_index = 662, .end_of_word = false, .semicolon_termination = false }, // om
            .{ .child_index = 26, .end_of_word = false, .semicolon_termination = false }, // oo
            .{ .child_index = 665, .end_of_word = false, .semicolon_termination = false }, // op
            .{ .child_index = 668, .end_of_word = false, .semicolon_termination = true }, // or
            .{ .child_index = 674, .end_of_word = false, .semicolon_termination = false }, // os
            .{ .child_index = 677, .end_of_word = false, .semicolon_termination = false }, // ot
            .{ .child_index = 19, .end_of_word = false, .semicolon_termination = false }, // ou
            .{ .child_index = 678, .end_of_word = false, .semicolon_termination = false }, // ov
        },
        .len = if (want_safety) 18 else {},
    },
    .{
        .nodes1 = &[_]SecondLayerNode1{
            .{ .number = 0 }, // pa
            .{ .number = 7 }, // pc
            .{ .number = 8 }, // pe
            .{ .number = 13 }, // pf
            .{ .number = 14 }, // ph
            .{ .number = 18 }, // pi
            .{ .number = 21 }, // pl
            .{ .number = 35 }, // pm
            .{ .number = 36 }, // po
            .{ .number = 40 }, // pr
            .{ .number = 66 }, // ps
            .{ .number = 68 }, // pu
        },
        .nodes2 = &[_]SecondLayerNode2{
            .{ .child_index = 679, .end_of_word = false, .semicolon_termination = false }, // pa
            .{ .child_index = 22, .end_of_word = false, .semicolon_termination = false }, // pc
            .{ .child_index = 680, .end_of_word = false, .semicolon_termination = false }, // pe
            .{ .child_index = 7, .end_of_word = false, .semicolon_termination = false }, // pf
            .{ .child_index = 681, .end_of_word = false, .semicolon_termination = false }, // ph
            .{ .child_index = 684, .end_of_word = false, .semicolon_termination = true }, // pi
            .{ .child_index = 686, .end_of_word = false, .semicolon_termination = false }, // pl
            .{ .child_index = 0, .end_of_word = false, .semicolon_termination = true }, // pm
            .{ .child_index = 688, .end_of_word = false, .semicolon_termination = false }, // po
            .{ .child_index = 691, .end_of_word = false, .semicolon_termination = true }, // pr
            .{ .child_index = 163, .end_of_word = false, .semicolon_termination = false }, // ps
            .{ .child_index = 700, .end_of_word = false, .semicolon_termination = false }, // pu
        },
        .len = if (want_safety) 12 else {},
    },
    .{
        .nodes1 = &[_]SecondLayerNode1{
            .{ .number = 0 }, // qf
            .{ .number = 1 }, // qi
            .{ .number = 2 }, // qo
            .{ .number = 3 }, // qp
            .{ .number = 4 }, // qs
            .{ .number = 5 }, // qu
        },
        .nodes2 = &[_]SecondLayerNode2{
            .{ .child_index = 7, .end_of_word = false, .semicolon_termination = false }, // qf
            .{ .child_index = 657, .end_of_word = false, .semicolon_termination = false }, // qi
            .{ .child_index = 26, .end_of_word = false, .semicolon_termination = false }, // qo
            .{ .child_index = 275, .end_of_word = false, .semicolon_termination = false }, // qp
            .{ .child_index = 28, .end_of_word = false, .semicolon_termination = false }, // qs
            .{ .child_index = 701, .end_of_word = false, .semicolon_termination = false }, // qu
        },
        .len = if (want_safety) 6 else {},
    },
    .{
        .nodes1 = &[_]SecondLayerNode1{
            .{ .number = 0 }, // rA
            .{ .number = 3 }, // rB
            .{ .number = 4 }, // rH
            .{ .number = 5 }, // ra
            .{ .number = 30 }, // rb
            .{ .number = 37 }, // rc
            .{ .number = 42 }, // rd
            .{ .number = 47 }, // re
            .{ .number = 54 }, // rf
            .{ .number = 57 }, // rh
            .{ .number = 62 }, // ri
            .{ .number = 73 }, // rl
            .{ .number = 76 }, // rm
            .{ .number = 78 }, // rn
            .{ .number = 79 }, // ro
            .{ .number = 86 }, // rp
            .{ .number = 89 }, // rr
            .{ .number = 90 }, // rs
            .{ .number = 96 }, // rt
            .{ .number = 102 }, // ru
            .{ .number = 103 }, // rx
        },
        .nodes2 = &[_]SecondLayerNode2{
            .{ .child_index = 479, .end_of_word = false, .semicolon_termination = false }, // rA
            .{ .child_index = 166, .end_of_word = false, .semicolon_termination = false }, // rB
            .{ .child_index = 192, .end_of_word = false, .semicolon_termination = false }, // rH
            .{ .child_index = 704, .end_of_word = false, .semicolon_termination = false }, // ra
            .{ .child_index = 491, .end_of_word = false, .semicolon_termination = false }, // rb
            .{ .child_index = 494, .end_of_word = false, .semicolon_termination = false }, // rc
            .{ .child_index = 711, .end_of_word = false, .semicolon_termination = false }, // rd
            .{ .child_index = 715, .end_of_word = false, .semicolon_termination = false }, // re
            .{ .child_index = 506, .end_of_word = false, .semicolon_termination = false }, // rf
            .{ .child_index = 718, .end_of_word = false, .semicolon_termination = false }, // rh
            .{ .child_index = 720, .end_of_word = false, .semicolon_termination = false }, // ri
            .{ .child_index = 723, .end_of_word = false, .semicolon_termination = false }, // rl
            .{ .child_index = 726, .end_of_word = false, .semicolon_termination = false }, // rm
            .{ .child_index = 727, .end_of_word = false, .semicolon_termination = false }, // rn
            .{ .child_index = 728, .end_of_word = false, .semicolon_termination = false }, // ro
            .{ .child_index = 732, .end_of_word = false, .semicolon_termination = false }, // rp
            .{ .child_index = 166, .end_of_word = false, .semicolon_termination = false }, // rr
            .{ .child_index = 734, .end_of_word = false, .semicolon_termination = false }, // rs
            .{ .child_index = 738, .end_of_word = false, .semicolon_termination = false }, // rt
            .{ .child_index = 741, .end_of_word = false, .semicolon_termination = false }, // ru
            .{ .child_index = 0, .end_of_word = false, .semicolon_termination = true }, // rx
        },
        .len = if (want_safety) 21 else {},
    },
    .{
        .nodes1 = &[_]SecondLayerNode1{
            .{ .number = 0 }, // sa
            .{ .number = 1 }, // sb
            .{ .number = 2 }, // sc
            .{ .number = 16 }, // sd
            .{ .number = 19 }, // se
            .{ .number = 30 }, // sf
            .{ .number = 32 }, // sh
            .{ .number = 39 }, // si
            .{ .number = 53 }, // sl
            .{ .number = 54 }, // sm
            .{ .number = 62 }, // so
            .{ .number = 67 }, // sp
            .{ .number = 70 }, // sq
            .{ .number = 86 }, // sr
            .{ .number = 87 }, // ss
            .{ .number = 91 }, // st
            .{ .number = 96 }, // su
            .{ .number = 151 }, // sw
            .{ .number = 156 }, // sz
        },
        .nodes2 = &[_]SecondLayerNode2{
            .{ .child_index = 139, .end_of_word = false, .semicolon_termination = false }, // sa
            .{ .child_index = 258, .end_of_word = false, .semicolon_termination = false }, // sb
            .{ .child_index = 742, .end_of_word = false, .semicolon_termination = true }, // sc
            .{ .child_index = 751, .end_of_word = false, .semicolon_termination = false }, // sd
            .{ .child_index = 752, .end_of_word = false, .semicolon_termination = false }, // se
            .{ .child_index = 759, .end_of_word = false, .semicolon_termination = false }, // sf
            .{ .child_index = 760, .end_of_word = false, .semicolon_termination = false }, // sh
            .{ .child_index = 764, .end_of_word = false, .semicolon_termination = false }, // si
            .{ .child_index = 166, .end_of_word = false, .semicolon_termination = false }, // sl
            .{ .child_index = 766, .end_of_word = false, .semicolon_termination = false }, // sm
            .{ .child_index = 770, .end_of_word = false, .semicolon_termination = false }, // so
            .{ .child_index = 773, .end_of_word = false, .semicolon_termination = false }, // sp
            .{ .child_index = 774, .end_of_word = false, .semicolon_termination = false }, // sq
            .{ .child_index = 166, .end_of_word = false, .semicolon_termination = false }, // sr
            .{ .child_index = 777, .end_of_word = false, .semicolon_termination = false }, // ss
            .{ .child_index = 781, .end_of_word = false, .semicolon_termination = false }, // st
            .{ .child_index = 783, .end_of_word = false, .semicolon_termination = false }, // su
            .{ .child_index = 788, .end_of_word = false, .semicolon_termination = false }, // sw
            .{ .child_index = 1, .end_of_word = false, .semicolon_termination = false }, // sz
        },
        .len = if (want_safety) 19 else {},
    },
    .{
        .nodes1 = &[_]SecondLayerNode1{
            .{ .number = 0 }, // ta
            .{ .number = 2 }, // tb
            .{ .number = 3 }, // tc
            .{ .number = 6 }, // td
            .{ .number = 7 }, // te
            .{ .number = 8 }, // tf
            .{ .number = 9 }, // th
            .{ .number = 21 }, // ti
            .{ .number = 28 }, // to
            .{ .number = 35 }, // tp
            .{ .number = 36 }, // tr
            .{ .number = 51 }, // ts
            .{ .number = 55 }, // tw
        },
        .nodes2 = &[_]SecondLayerNode2{
            .{ .child_index = 791, .end_of_word = false, .semicolon_termination = false }, // ta
            .{ .child_index = 793, .end_of_word = false, .semicolon_termination = false }, // tb
            .{ .child_index = 122, .end_of_word = false, .semicolon_termination = false }, // tc
            .{ .child_index = 39, .end_of_word = false, .semicolon_termination = false }, // td
            .{ .child_index = 794, .end_of_word = false, .semicolon_termination = false }, // te
            .{ .child_index = 7, .end_of_word = false, .semicolon_termination = false }, // tf
            .{ .child_index = 795, .end_of_word = false, .semicolon_termination = false }, // th
            .{ .child_index = 799, .end_of_word = false, .semicolon_termination = false }, // ti
            .{ .child_index = 802, .end_of_word = false, .semicolon_termination = false }, // to
            .{ .child_index = 275, .end_of_word = false, .semicolon_termination = false }, // tp
            .{ .child_index = 805, .end_of_word = false, .semicolon_termination = false }, // tr
            .{ .child_index = 808, .end_of_word = false, .semicolon_termination = false }, // ts
            .{ .child_index = 811, .end_of_word = false, .semicolon_termination = false }, // tw
        },
        .len = if (want_safety) 13 else {},
    },
    .{
        .nodes1 = &[_]SecondLayerNode1{
            .{ .number = 0 }, // uA
            .{ .number = 1 }, // uH
            .{ .number = 2 }, // ua
            .{ .number = 5 }, // ub
            .{ .number = 7 }, // uc
            .{ .number = 10 }, // ud
            .{ .number = 13 }, // uf
            .{ .number = 15 }, // ug
            .{ .number = 17 }, // uh
            .{ .number = 20 }, // ul
            .{ .number = 24 }, // um
            .{ .number = 27 }, // uo
            .{ .number = 29 }, // up
            .{ .number = 38 }, // ur
            .{ .number = 43 }, // us
            .{ .number = 44 }, // ut
            .{ .number = 48 }, // uu
            .{ .number = 51 }, // uw
        },
        .nodes2 = &[_]SecondLayerNode2{
            .{ .child_index = 316, .end_of_word = false, .semicolon_termination = false }, // uA
            .{ .child_index = 192, .end_of_word = false, .semicolon_termination = false }, // uH
            .{ .child_index = 813, .end_of_word = false, .semicolon_termination = false }, // ua
            .{ .child_index = 209, .end_of_word = false, .semicolon_termination = false }, // ub
            .{ .child_index = 5, .end_of_word = false, .semicolon_termination = false }, // uc
            .{ .child_index = 815, .end_of_word = false, .semicolon_termination = false }, // ud
            .{ .child_index = 328, .end_of_word = false, .semicolon_termination = false }, // uf
            .{ .child_index = 8, .end_of_word = false, .semicolon_termination = false }, // ug
            .{ .child_index = 818, .end_of_word = false, .semicolon_termination = false }, // uh
            .{ .child_index = 820, .end_of_word = false, .semicolon_termination = false }, // ul
            .{ .child_index = 822, .end_of_word = false, .semicolon_termination = false }, // um
            .{ .child_index = 12, .end_of_word = false, .semicolon_termination = false }, // uo
            .{ .child_index = 824, .end_of_word = false, .semicolon_termination = false }, // up
            .{ .child_index = 830, .end_of_word = false, .semicolon_termination = false }, // ur
            .{ .child_index = 28, .end_of_word = false, .semicolon_termination = false }, // us
            .{ .child_index = 833, .end_of_word = false, .semicolon_termination = false }, // ut
            .{ .child_index = 836, .end_of_word = false, .semicolon_termination = false }, // uu
            .{ .child_index = 351, .end_of_word = false, .semicolon_termination = false }, // uw
        },
        .len = if (want_safety) 18 else {},
    },
    .{
        .nodes1 = &[_]SecondLayerNode1{
            .{ .number = 0 }, // vA
            .{ .number = 1 }, // vB
            .{ .number = 3 }, // vD
            .{ .number = 4 }, // va
            .{ .number = 21 }, // vc
            .{ .number = 22 }, // vd
            .{ .number = 23 }, // ve
            .{ .number = 29 }, // vf
            .{ .number = 30 }, // vl
            .{ .number = 31 }, // vn
            .{ .number = 33 }, // vo
            .{ .number = 34 }, // vp
            .{ .number = 35 }, // vr
            .{ .number = 36 }, // vs
            .{ .number = 41 }, // vz
        },
        .nodes2 = &[_]SecondLayerNode2{
            .{ .child_index = 316, .end_of_word = false, .semicolon_termination = false }, // vA
            .{ .child_index = 838, .end_of_word = false, .semicolon_termination = false }, // vB
            .{ .child_index = 221, .end_of_word = false, .semicolon_termination = false }, // vD
            .{ .child_index = 839, .end_of_word = false, .semicolon_termination = false }, // va
            .{ .child_index = 22, .end_of_word = false, .semicolon_termination = false }, // vc
            .{ .child_index = 221, .end_of_word = false, .semicolon_termination = false }, // vd
            .{ .child_index = 841, .end_of_word = false, .semicolon_termination = false }, // ve
            .{ .child_index = 7, .end_of_word = false, .semicolon_termination = false }, // vf
            .{ .child_index = 844, .end_of_word = false, .semicolon_termination = false }, // vl
            .{ .child_index = 845, .end_of_word = false, .semicolon_termination = false }, // vn
            .{ .child_index = 26, .end_of_word = false, .semicolon_termination = false }, // vo
            .{ .child_index = 846, .end_of_word = false, .semicolon_termination = false }, // vp
            .{ .child_index = 844, .end_of_word = false, .semicolon_termination = false }, // vr
            .{ .child_index = 847, .end_of_word = false, .semicolon_termination = false }, // vs
            .{ .child_index = 849, .end_of_word = false, .semicolon_termination = false }, // vz
        },
        .len = if (want_safety) 15 else {},
    },
    .{
        .nodes1 = &[_]SecondLayerNode1{
            .{ .number = 0 }, // wc
            .{ .number = 1 }, // we
            .{ .number = 5 }, // wf
            .{ .number = 6 }, // wo
            .{ .number = 7 }, // wp
            .{ .number = 8 }, // wr
            .{ .number = 10 }, // ws
        },
        .nodes2 = &[_]SecondLayerNode2{
            .{ .child_index = 93, .end_of_word = false, .semicolon_termination = false }, // wc
            .{ .child_index = 850, .end_of_word = false, .semicolon_termination = false }, // we
            .{ .child_index = 7, .end_of_word = false, .semicolon_termination = false }, // wf
            .{ .child_index = 26, .end_of_word = false, .semicolon_termination = false }, // wo
            .{ .child_index = 0, .end_of_word = false, .semicolon_termination = true }, // wp
            .{ .child_index = 852, .end_of_word = false, .semicolon_termination = true }, // wr
            .{ .child_index = 28, .end_of_word = false, .semicolon_termination = false }, // ws
        },
        .len = if (want_safety) 7 else {},
    },
    .{
        .nodes1 = &[_]SecondLayerNode1{
            .{ .number = 0 }, // xc
            .{ .number = 3 }, // xd
            .{ .number = 4 }, // xf
            .{ .number = 5 }, // xh
            .{ .number = 7 }, // xi
            .{ .number = 8 }, // xl
            .{ .number = 10 }, // xm
            .{ .number = 11 }, // xn
            .{ .number = 12 }, // xo
            .{ .number = 16 }, // xr
            .{ .number = 18 }, // xs
            .{ .number = 20 }, // xu
            .{ .number = 22 }, // xv
            .{ .number = 23 }, // xw
        },
        .nodes2 = &[_]SecondLayerNode2{
            .{ .child_index = 853, .end_of_word = false, .semicolon_termination = false }, // xc
            .{ .child_index = 844, .end_of_word = false, .semicolon_termination = false }, // xd
            .{ .child_index = 7, .end_of_word = false, .semicolon_termination = false }, // xf
            .{ .child_index = 856, .end_of_word = false, .semicolon_termination = false }, // xh
            .{ .child_index = 0, .end_of_word = false, .semicolon_termination = true }, // xi
            .{ .child_index = 856, .end_of_word = false, .semicolon_termination = false }, // xl
            .{ .child_index = 858, .end_of_word = false, .semicolon_termination = false }, // xm
            .{ .child_index = 859, .end_of_word = false, .semicolon_termination = false }, // xn
            .{ .child_index = 860, .end_of_word = false, .semicolon_termination = false }, // xo
            .{ .child_index = 856, .end_of_word = false, .semicolon_termination = false }, // xr
            .{ .child_index = 863, .end_of_word = false, .semicolon_termination = false }, // xs
            .{ .child_index = 865, .end_of_word = false, .semicolon_termination = false }, // xu
            .{ .child_index = 867, .end_of_word = false, .semicolon_termination = false }, // xv
            .{ .child_index = 868, .end_of_word = false, .semicolon_termination = false }, // xw
        },
        .len = if (want_safety) 14 else {},
    },
    .{
        .nodes1 = &[_]SecondLayerNode1{
            .{ .number = 0 }, // ya
            .{ .number = 3 }, // yc
            .{ .number = 5 }, // ye
            .{ .number = 7 }, // yf
            .{ .number = 8 }, // yi
            .{ .number = 9 }, // yo
            .{ .number = 10 }, // ys
            .{ .number = 11 }, // yu
        },
        .nodes2 = &[_]SecondLayerNode2{
            .{ .child_index = 869, .end_of_word = false, .semicolon_termination = false }, // ya
            .{ .child_index = 109, .end_of_word = false, .semicolon_termination = false }, // yc
            .{ .child_index = 870, .end_of_word = false, .semicolon_termination = false }, // ye
            .{ .child_index = 7, .end_of_word = false, .semicolon_termination = false }, // yf
            .{ .child_index = 30, .end_of_word = false, .semicolon_termination = false }, // yi
            .{ .child_index = 26, .end_of_word = false, .semicolon_termination = false }, // yo
            .{ .child_index = 28, .end_of_word = false, .semicolon_termination = false }, // ys
            .{ .child_index = 871, .end_of_word = false, .semicolon_termination = false }, // yu
        },
        .len = if (want_safety) 8 else {},
    },
    .{
        .nodes1 = &[_]SecondLayerNode1{
            .{ .number = 0 }, // za
            .{ .number = 1 }, // zc
            .{ .number = 3 }, // zd
            .{ .number = 4 }, // ze
            .{ .number = 6 }, // zf
            .{ .number = 7 }, // zh
            .{ .number = 8 }, // zi
            .{ .number = 9 }, // zo
            .{ .number = 10 }, // zs
            .{ .number = 11 }, // zw
        },
        .nodes2 = &[_]SecondLayerNode2{
            .{ .child_index = 139, .end_of_word = false, .semicolon_termination = false }, // za
            .{ .child_index = 55, .end_of_word = false, .semicolon_termination = false }, // zc
            .{ .child_index = 39, .end_of_word = false, .semicolon_termination = false }, // zd
            .{ .child_index = 873, .end_of_word = false, .semicolon_termination = false }, // ze
            .{ .child_index = 7, .end_of_word = false, .semicolon_termination = false }, // zf
            .{ .child_index = 30, .end_of_word = false, .semicolon_termination = false }, // zh
            .{ .child_index = 875, .end_of_word = false, .semicolon_termination = false }, // zi
            .{ .child_index = 26, .end_of_word = false, .semicolon_termination = false }, // zo
            .{ .child_index = 28, .end_of_word = false, .semicolon_termination = false }, // zs
            .{ .child_index = 876, .end_of_word = false, .semicolon_termination = false }, // zw
        },
        .len = if (want_safety) 10 else {},
    },
};

pub const dafsa = [_]Node{
    .{ .char = 0, .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 878, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'P', .end_of_word = true, .number = 0, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 879, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 27, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 880, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'y', .end_of_word = false, .number = 2, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 881, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 882, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 28, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 883, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 1, .child_index = 884, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 885, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 886, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 7, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 1, .child_index = 887, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 888, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 889, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 890, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 891, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'y', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 893, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 894, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 2, .child_index = 78, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 884, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 895, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 7, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 896, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 22, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'P', .end_of_word = false, .number = 0, .child_index = 897, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 898, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 1, .child_index = 899, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'y', .end_of_word = false, .number = 3, .child_index = 900, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 901, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 902, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 3, .child_index = 903, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 4, .child_index = 904, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 905, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 906, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 1, .child_index = 907, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 908, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 909, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 911, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 2, .child_index = 912, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 5, .child_index = 915, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 7, .child_index = 917, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 918, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 919, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'o', .end_of_word = false, .number = 1, .child_index = 920, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 921, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 7, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 2, .child_index = 922, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 901, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'y', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 923, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 924, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'f', .end_of_word = false, .number = 6, .child_index = 926, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 884, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 1, .child_index = 927, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'u', .end_of_word = false, .number = 4, .child_index = 929, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'w', .end_of_word = false, .number = 18, .child_index = 930, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 7, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 1, .child_index = 931, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'G', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'H', .end_of_word = true, .number = 0, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 901, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 880, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'y', .end_of_word = false, .number = 3, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 932, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 28, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 1, .child_index = 933, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 934, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 935, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 7, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 937, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 938, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 1, .child_index = 939, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 940, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 884, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 941, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 2, .child_index = 942, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 943, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 944, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 903, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'y', .end_of_word = false, .number = 2, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 945, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'R', .end_of_word = false, .number = 0, .child_index = 946, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 947, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 903, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 948, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 884, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 949, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 950, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 951, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 952, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 3, .child_index = 954, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 955, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'v', .end_of_word = false, .number = 3, .child_index = 956, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 883, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 1, .child_index = 884, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 2, .child_index = 78, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 957, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'k', .end_of_word = false, .number = 0, .child_index = 30, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 1, .child_index = 889, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 903, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'y', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 7, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 958, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'k', .end_of_word = false, .number = 0, .child_index = 30, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 959, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 944, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'y', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 898, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 1, .child_index = 960, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 2, .child_index = 961, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 3, .child_index = 962, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 4, .child_index = 7, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 901, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 944, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'y', .end_of_word = false, .number = 2, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'f', .end_of_word = false, .number = 0, .child_index = 963, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 26, .child_index = 964, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 965, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 307, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 966, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 6, .child_index = 884, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'w', .end_of_word = false, .number = 7, .child_index = 967, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 7, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 't', .end_of_word = false, .number = 2, .child_index = 931, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 968, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 1, .child_index = 969, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 970, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 898, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 971, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 4, .child_index = 972, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'w', .end_of_word = false, .number = 6, .child_index = 973, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'B', .end_of_word = false, .number = 0, .child_index = 974, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 1, .child_index = 975, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 2, .child_index = 884, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 3, .child_index = 976, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 988, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 28, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 989, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 2, .child_index = 990, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 991, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 7, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 1, .child_index = 992, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 993, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 995, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 996, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 997, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 998, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 1, .child_index = 884, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 999, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 5, .child_index = 1000, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 6, .child_index = 1001, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 7, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'O', .end_of_word = false, .number = 0, .child_index = 1003, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 316, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'G', .end_of_word = true, .number = 0, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 898, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 1, .child_index = 961, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 2, .child_index = 1004, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'v', .end_of_word = false, .number = 1, .child_index = 1005, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 1006, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 884, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 1, .child_index = 1007, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1008, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 7, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1009, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'C', .end_of_word = false, .number = 0, .child_index = 1010, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 1, .child_index = 22, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'F', .end_of_word = false, .number = 0, .child_index = 1011, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 901, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 2, .child_index = 944, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 3, .child_index = 903, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'y', .end_of_word = false, .number = 4, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1012, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 1013, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1014, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 905, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 1, .child_index = 1015, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 7, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 1016, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'c', .end_of_word = false, .number = 3, .child_index = 1017, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 8, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'p', .end_of_word = false, .number = 9, .child_index = 1019, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'O', .end_of_word = false, .number = 0, .child_index = 1021, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'A', .end_of_word = false, .number = 0, .child_index = 1022, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'H', .end_of_word = false, .number = 0, .child_index = 30, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 1, .child_index = 22, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'u', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1023, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 2, .child_index = 1025, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1027, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1028, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 879, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 2, .child_index = 1029, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1030, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 155, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 4, .child_index = 1032, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'A', .end_of_word = false, .number = 0, .child_index = 1033, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'D', .end_of_word = false, .number = 3, .child_index = 1034, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'E', .end_of_word = false, .number = 4, .child_index = 1035, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'T', .end_of_word = false, .number = 5, .child_index = 1036, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 7, .child_index = 1037, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 8, .child_index = 1038, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 9, .child_index = 967, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 11, .child_index = 1039, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1040, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1041, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1042, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 1043, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 221, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 1046, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 1047, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1048, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 1, .child_index = 78, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'E', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'd', .end_of_word = false, .number = 2, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'i', .end_of_word = false, .number = 3, .child_index = 880, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 5, .child_index = 1049, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'y', .end_of_word = false, .number = 7, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1050, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 2, .child_index = 882, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1052, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = true, .number = 2, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 1054, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'g', .end_of_word = false, .number = 5, .child_index = 1058, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'E', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'a', .end_of_word = false, .number = 2, .child_index = 1064, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 3, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'i', .end_of_word = false, .number = 4, .child_index = 11, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 5, .child_index = 1065, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 6, .child_index = 1066, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 7, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'y', .end_of_word = false, .number = 2, .child_index = 1067, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1068, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 657, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1069, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 5, .child_index = 1070, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1072, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1040, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'y', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'q', .end_of_word = false, .number = 0, .child_index = 1073, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1074, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 2, .child_index = 1075, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 3, .child_index = 1076, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 4, .child_index = 1077, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 5, .child_index = 1078, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 1081, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1088, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1089, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'k', .end_of_word = false, .number = 7, .child_index = 1091, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 10, .child_index = 1093, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1094, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'o', .end_of_word = false, .number = 2, .child_index = 905, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 884, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 1, .child_index = 1095, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'w', .end_of_word = false, .number = 3, .child_index = 1096, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'x', .end_of_word = false, .number = 4, .child_index = 1097, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1109, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 895, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'v', .end_of_word = false, .number = 1, .child_index = 1110, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 7, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 1111, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 2, .child_index = 1112, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 4, .child_index = 1113, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1114, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 2, .child_index = 1115, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 898, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 1, .child_index = 1116, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'r', .end_of_word = false, .number = 8, .child_index = 1121, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1123, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 2, .child_index = 902, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 4, .child_index = 903, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 5, .child_index = 1125, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 1126, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 2, .child_index = 1075, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 3, .child_index = 1127, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 22, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 1128, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 3, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1129, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 1135, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1136, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 3, .child_index = 1137, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 9, .child_index = 1139, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 12, .child_index = 1141, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 316, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 1, .child_index = 918, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 7, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 1, .child_index = 1144, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 39, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 1146, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 2, .child_index = 1147, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 4, .child_index = 1149, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 6, .child_index = 1150, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'r', .end_of_word = false, .number = 13, .child_index = 1155, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'v', .end_of_word = false, .number = 23, .child_index = 867, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'w', .end_of_word = false, .number = 24, .child_index = 1159, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1160, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 7, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 921, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 1, .child_index = 1161, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 2, .child_index = 7, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 3, .child_index = 1162, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'k', .end_of_word = false, .number = 0, .child_index = 265, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 1, .child_index = 1163, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 1164, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 3, .child_index = 1166, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = true, .number = 0, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'l', .end_of_word = false, .number = 2, .child_index = 1167, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 3, .child_index = 1075, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1168, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1169, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1170, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 4, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'g', .end_of_word = false, .number = 5, .child_index = 1171, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 6, .child_index = 1172, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'v', .end_of_word = false, .number = 7, .child_index = 1173, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1175, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1177, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 1, .child_index = 884, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 2, .child_index = 1178, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'u', .end_of_word = false, .number = 8, .child_index = 1182, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'w', .end_of_word = false, .number = 9, .child_index = 1183, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 1184, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 1, .child_index = 1175, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1185, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 2, .child_index = 1047, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 3, .child_index = 931, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 39, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 1187, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 316, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 1, .child_index = 192, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1188, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 22, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 875, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'D', .end_of_word = false, .number = 0, .child_index = 39, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 1, .child_index = 905, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 879, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 2, .child_index = 1189, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 901, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 1190, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 4, .child_index = 1191, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'y', .end_of_word = false, .number = 5, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'D', .end_of_word = false, .number = 0, .child_index = 39, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 881, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 3, .child_index = 1192, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 1193, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 2, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 's', .end_of_word = false, .number = 3, .child_index = 1192, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 28, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 1, .child_index = 1194, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 4, .child_index = 1195, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 's', .end_of_word = false, .number = 1, .child_index = 135, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1196, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 2, .child_index = 1197, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 3, .child_index = 1198, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1199, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 2, .child_index = 1201, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 5, .child_index = 1203, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'v', .end_of_word = false, .number = 9, .child_index = 1206, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'D', .end_of_word = false, .number = 0, .child_index = 39, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 316, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 7, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 1, .child_index = 39, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 2, .child_index = 937, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'h', .end_of_word = true, .number = 1, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 889, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 2, .child_index = 172, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1047, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 1207, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 2, .child_index = 1208, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1210, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 1211, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 98, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 1, .child_index = 1212, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 3, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 905, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 1, .child_index = 951, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 2, .child_index = 1214, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 884, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 884, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 1215, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1217, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1218, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 19, .child_index = 1220, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 898, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 1, .child_index = 943, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 3, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'l', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'q', .end_of_word = false, .number = 2, .child_index = 1221, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 's', .end_of_word = false, .number = 5, .child_index = 1223, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'g', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 1226, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'E', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'a', .end_of_word = false, .number = 2, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'j', .end_of_word = false, .number = 3, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'E', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 1227, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 3, .child_index = 1228, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 's', .end_of_word = false, .number = 6, .child_index = 1229, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 895, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 7, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 1230, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 1, .child_index = 1231, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 3, .child_index = 39, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 4, .child_index = 1233, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'q', .end_of_word = false, .number = 5, .child_index = 1234, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 6, .child_index = 1235, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1240, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 1, .child_index = 1241, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1242, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 1, .child_index = 884, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 2, .child_index = 1243, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 3, .child_index = 1244, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1246, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 2, .child_index = 1247, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 3, .child_index = 1248, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 1249, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 316, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 1, .child_index = 1251, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 2, .child_index = 1252, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 4, .child_index = 884, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 5, .child_index = 678, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 7, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 1, .child_index = 221, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 2, .child_index = 931, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 1253, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 1, .child_index = 1254, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 880, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'y', .end_of_word = false, .number = 3, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 22, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'x', .end_of_word = false, .number = 1, .child_index = 1255, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'f', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 1256, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 3, .child_index = 1258, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 4, .child_index = 1167, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1259, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 5, .child_index = 884, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 6, .child_index = 1159, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 1, .child_index = 1262, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'f', .end_of_word = false, .number = 2, .child_index = 1263, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 4, .child_index = 307, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 5, .child_index = 1264, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 22, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 1, .child_index = 883, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 2, .child_index = 884, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 3, .child_index = 78, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1268, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 1269, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 7, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 1270, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 957, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1271, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 1272, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1273, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 316, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 7, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 2, .child_index = 1274, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 898, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 1275, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 2, .child_index = 1276, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 3, .child_index = 960, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 4, .child_index = 1277, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 7, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'q', .end_of_word = false, .number = 8, .child_index = 1278, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 10, .child_index = 1279, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 19, .child_index = 1280, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 316, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'b', .end_of_word = false, .number = 1, .child_index = 793, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 2, .child_index = 1282, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 901, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 1284, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 3, .child_index = 1286, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'y', .end_of_word = false, .number = 4, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 78, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'q', .end_of_word = false, .number = 1, .child_index = 1287, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 3, .child_index = 1288, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 5, .child_index = 1290, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'f', .end_of_word = false, .number = 1, .child_index = 1291, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 11, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'q', .end_of_word = false, .number = 12, .child_index = 1221, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 's', .end_of_word = false, .number = 15, .child_index = 1292, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1168, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 1, .child_index = 1296, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 2, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'E', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1297, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'b', .end_of_word = false, .number = 3, .child_index = 1298, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 316, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 2, .child_index = 1299, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 3, .child_index = 1300, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 4, .child_index = 1301, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 307, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 1, .child_index = 1302, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1303, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'b', .end_of_word = false, .number = 2, .child_index = 793, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 3, .child_index = 1305, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 7, .child_index = 1306, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 9, .child_index = 1307, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 12, .child_index = 1310, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'w', .end_of_word = false, .number = 13, .child_index = 1311, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'z', .end_of_word = false, .number = 15, .child_index = 1313, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1315, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 316, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 1, .child_index = 1299, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 2, .child_index = 1316, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 4, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 't', .end_of_word = false, .number = 5, .child_index = 1301, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 258, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 1, .child_index = 7, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 2, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'i', .end_of_word = false, .number = 3, .child_index = 1317, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'q', .end_of_word = false, .number = 6, .child_index = 1318, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 9, .child_index = 931, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 1, .child_index = 1231, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 3, .child_index = 39, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 4, .child_index = 1320, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 5, .child_index = 1321, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 6, .child_index = 166, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'q', .end_of_word = false, .number = 7, .child_index = 1234, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 8, .child_index = 1322, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1324, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'D', .end_of_word = false, .number = 0, .child_index = 39, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1326, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 2, .child_index = 1327, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 5, .child_index = 1329, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'r', .end_of_word = false, .number = 10, .child_index = 1330, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1331, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'y', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1332, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1333, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 2, .child_index = 1334, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'n', .end_of_word = false, .number = 7, .child_index = 1337, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 135, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 1, .child_index = 7, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 1338, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 1339, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 1, .child_index = 884, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 7, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 1, .child_index = 1340, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 1, .child_index = 1341, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 2, .child_index = 858, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 't', .end_of_word = false, .number = 1, .child_index = 1342, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1343, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 2, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 't', .end_of_word = false, .number = 3, .child_index = 1342, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'D', .end_of_word = false, .number = 0, .child_index = 221, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 1, .child_index = 221, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 1344, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 1, .child_index = 898, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 2, .child_index = 961, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 3, .child_index = 1345, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 't', .end_of_word = false, .number = 8, .child_index = 1349, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 1350, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 2, .child_index = 1351, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1352, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 2, .child_index = 944, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 3, .child_index = 1354, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 5, .child_index = 135, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'y', .end_of_word = false, .number = 6, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'A', .end_of_word = false, .number = 1, .child_index = 316, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 2, .child_index = 1355, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 5, .child_index = 39, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'q', .end_of_word = false, .number = 6, .child_index = 1356, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 7, .child_index = 1357, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'x', .end_of_word = false, .number = 9, .child_index = 1359, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'E', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 1360, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 's', .end_of_word = false, .number = 6, .child_index = 1229, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 7, .child_index = 235, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'A', .end_of_word = false, .number = 0, .child_index = 316, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 316, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 2, .child_index = 192, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 1, .child_index = 1362, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'v', .end_of_word = false, .number = 3, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'A', .end_of_word = false, .number = 0, .child_index = 316, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'E', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'a', .end_of_word = false, .number = 2, .child_index = 316, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 3, .child_index = 7, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 4, .child_index = 1363, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 's', .end_of_word = false, .number = 12, .child_index = 1229, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 13, .child_index = 1366, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 11, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 884, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = true, .number = 1, .child_index = 1367, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1369, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 4, .child_index = 1370, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 5, .child_index = 1371, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'A', .end_of_word = false, .number = 0, .child_index = 316, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 1373, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 4, .child_index = 1008, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 5, .child_index = 1374, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1375, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'h', .end_of_word = false, .number = 4, .child_index = 1378, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 6, .child_index = 1379, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 9, .child_index = 607, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 10, .child_index = 192, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'q', .end_of_word = false, .number = 11, .child_index = 1380, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 13, .child_index = 1381, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 1047, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 888, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 3, .child_index = 961, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 4, .child_index = 1384, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 1, .child_index = 1385, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'D', .end_of_word = false, .number = 0, .child_index = 221, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'H', .end_of_word = false, .number = 1, .child_index = 166, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 2, .child_index = 135, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 3, .child_index = 221, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 4, .child_index = 1387, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 6, .child_index = 1389, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 7, .child_index = 1390, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 11, .child_index = 1393, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 13, .child_index = 1229, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'A', .end_of_word = false, .number = 0, .child_index = 316, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 1355, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 4, .child_index = 1395, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 879, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 2, .child_index = 905, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1190, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'y', .end_of_word = false, .number = 3, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1041, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'b', .end_of_word = false, .number = 1, .child_index = 988, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 2, .child_index = 1396, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 3, .child_index = 905, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 4, .child_index = 1397, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1398, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1399, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 881, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 3, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 192, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 905, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 316, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 1, .child_index = 1400, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 3, .child_index = 1402, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 4, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 28, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 989, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 2, .child_index = 1403, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 7, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 1406, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 2, .child_index = 1197, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 316, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 2, .child_index = 1407, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'i', .end_of_word = false, .number = 9, .child_index = 1410, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 10, .child_index = 7, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 11, .child_index = 1411, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'v', .end_of_word = false, .number = 12, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 7, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 1, .child_index = 992, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 3, .child_index = 1047, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1412, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 192, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1414, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1417, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1342, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'm', .end_of_word = false, .number = 2, .child_index = 1422, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 3, .child_index = 1402, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 1, .child_index = 1423, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'v', .end_of_word = false, .number = 2, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1424, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 3, .child_index = 1425, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1426, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 1, .child_index = 884, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 2, .child_index = 1427, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'E', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'a', .end_of_word = false, .number = 2, .child_index = 135, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 3, .child_index = 1428, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 4, .child_index = 1429, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'i', .end_of_word = false, .number = 13, .child_index = 1430, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 15, .child_index = 1431, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 18, .child_index = 1434, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 24, .child_index = 1229, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 25, .child_index = 1437, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1438, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1439, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 2, .child_index = 1440, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 4, .child_index = 1441, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1442, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 2, .child_index = 1444, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 3, .child_index = 1275, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 4, .child_index = 1445, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'q', .end_of_word = false, .number = 8, .child_index = 1278, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 10, .child_index = 1446, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 22, .child_index = 1447, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 78, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 1, .child_index = 1449, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'q', .end_of_word = false, .number = 2, .child_index = 1287, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 4, .child_index = 1290, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1450, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 4, .child_index = 905, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = true, .number = 5, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1297, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 3, .child_index = 1342, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 1451, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 9, .child_index = 961, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 10, .child_index = 1452, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 316, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 1, .child_index = 192, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 2, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1302, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 607, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1303, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'b', .end_of_word = false, .number = 2, .child_index = 793, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 3, .child_index = 1307, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 6, .child_index = 1310, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1453, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 2, .child_index = 1454, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 258, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 1, .child_index = 7, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 2, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'q', .end_of_word = false, .number = 3, .child_index = 1318, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 1320, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 1321, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 2, .child_index = 1455, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1456, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'E', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'a', .end_of_word = false, .number = 2, .child_index = 1352, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 4, .child_index = 1428, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 5, .child_index = 1457, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'i', .end_of_word = false, .number = 7, .child_index = 903, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 8, .child_index = 1431, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 11, .child_index = 1454, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 12, .child_index = 1229, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'y', .end_of_word = false, .number = 13, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1458, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'A', .end_of_word = false, .number = 0, .child_index = 316, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 1355, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 4, .child_index = 1441, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 6, .child_index = 42, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 7, .child_index = 1459, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 8, .child_index = 1460, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'x', .end_of_word = false, .number = 10, .child_index = 905, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1461, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1406, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 1, .child_index = 1462, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 3, .child_index = 1464, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'y', .end_of_word = true, .number = 5, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 1465, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 3, .child_index = 1466, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1473, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 2, .child_index = 1206, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 3, .child_index = 1475, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 5, .child_index = 1477, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'f', .end_of_word = false, .number = 0, .child_index = 1478, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 1, .child_index = 1479, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'p', .end_of_word = false, .number = 4, .child_index = 884, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1480, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1482, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 4, .child_index = 1484, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 12, .child_index = 1485, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 7, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 1487, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 2, .child_index = 1488, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 3, .child_index = 1489, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1490, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 2, .child_index = 1491, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 1493, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'c', .end_of_word = false, .number = 18, .child_index = 1501, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 26, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'n', .end_of_word = false, .number = 27, .child_index = 961, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 28, .child_index = 1502, .last_sibling = true, .semicolon_termination = .yes_num_6 },
    .{ .char = 'A', .end_of_word = false, .number = 0, .child_index = 316, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 1355, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 4, .child_index = 1459, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1514, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1515, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1516, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1517, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 5, .child_index = 1519, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'k', .end_of_word = false, .number = 8, .child_index = 1521, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 10, .child_index = 1523, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1524, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 1, .child_index = 1525, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 6, .child_index = 905, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 78, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 1, .child_index = 1526, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 's', .end_of_word = false, .number = 6, .child_index = 78, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1524, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 1529, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 14, .child_index = 1536, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1185, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 2, .child_index = 30, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 3, .child_index = 931, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1537, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 1, .child_index = 1538, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 879, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 2, .child_index = 7, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 316, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'b', .end_of_word = false, .number = 1, .child_index = 988, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 2, .child_index = 192, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1169, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'b', .end_of_word = false, .number = 2, .child_index = 1298, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1539, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 3, .child_index = 1301, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 28, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = true, .number = 1, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1037, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 1, .child_index = 1038, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 2, .child_index = 1541, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 4, .child_index = 1197, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 5, .child_index = 1542, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 8, .child_index = 1543, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1539, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 3, .child_index = 1040, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 4, .child_index = 1301, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 39, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 957, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 2, .child_index = 1187, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 316, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 1, .child_index = 889, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1544, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1545, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 1546, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1553, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'l', .end_of_word = false, .number = 3, .child_index = 1247, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 4, .child_index = 1555, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 1301, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 1557, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1558, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 7, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 1, .child_index = 1559, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1561, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 1562, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 3, .child_index = 1564, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 476, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 135, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 903, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 2, .child_index = 135, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'A', .end_of_word = false, .number = 0, .child_index = 316, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 316, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 135, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1065, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 39, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 1, .child_index = 1565, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 3, .child_index = 1109, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 7, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'q', .end_of_word = false, .number = 1, .child_index = 1567, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 1338, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 1, .child_index = 1301, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1568, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 226, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1569, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = true, .number = 0, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 22, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 1, .child_index = 889, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1571, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 1, .child_index = 78, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 1572, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'j', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'n', .end_of_word = false, .number = 1, .child_index = 1573, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1574, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 1049, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1575, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1576, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 78, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1399, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'f', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1577, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1574, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1578, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1579, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = true, .number = 0, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'k', .end_of_word = false, .number = 0, .child_index = 1580, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'v', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'w', .end_of_word = false, .number = 1, .child_index = 1159, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1581, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1582, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'v', .end_of_word = false, .number = 0, .child_index = 1568, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 1583, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'Y', .end_of_word = true, .number = 0, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 1584, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 1585, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1586, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 883, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 1126, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1587, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1588, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1589, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 1590, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1591, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1592, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 1, .child_index = 1593, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1594, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 1595, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 657, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 2, .child_index = 1596, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'f', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 1597, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1598, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 1065, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'C', .end_of_word = false, .number = 1, .child_index = 858, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 1599, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 1600, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 1396, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 1, .child_index = 78, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1601, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 5, .child_index = 1602, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'f', .end_of_word = false, .number = 0, .child_index = 1603, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'D', .end_of_word = false, .number = 1, .child_index = 39, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'E', .end_of_word = false, .number = 2, .child_index = 1604, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 1605, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1606, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1612, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 1613, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 1614, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1191, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1615, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 2, .child_index = 1616, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 1617, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1618, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1619, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'A', .end_of_word = false, .number = 0, .child_index = 1620, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1621, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 1622, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 1623, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1624, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'D', .end_of_word = false, .number = 0, .child_index = 30, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1515, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 1625, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1626, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 1627, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 961, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 7, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 1, .child_index = 1629, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1630, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 1631, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1633, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1524, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 30, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 78, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 1634, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1635, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 1636, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 1646, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'f', .end_of_word = false, .number = 0, .child_index = 1652, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 1653, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1657, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1658, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1659, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 1660, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1661, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 1662, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'L', .end_of_word = false, .number = 0, .child_index = 1663, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1664, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'B', .end_of_word = false, .number = 0, .child_index = 1665, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'C', .end_of_word = false, .number = 1, .child_index = 1666, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'D', .end_of_word = false, .number = 3, .child_index = 1668, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'E', .end_of_word = false, .number = 4, .child_index = 1669, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'G', .end_of_word = false, .number = 8, .child_index = 1672, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'H', .end_of_word = false, .number = 15, .child_index = 1673, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'L', .end_of_word = false, .number = 17, .child_index = 1674, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'N', .end_of_word = false, .number = 26, .child_index = 1675, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'P', .end_of_word = false, .number = 28, .child_index = 1676, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'R', .end_of_word = false, .number = 31, .child_index = 1677, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'S', .end_of_word = false, .number = 35, .child_index = 1679, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'T', .end_of_word = false, .number = 47, .child_index = 1681, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'V', .end_of_word = false, .number = 51, .child_index = 1682, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1163, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 78, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 901, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1683, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1684, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1579, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 2, .child_index = 1685, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1686, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 1688, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 1689, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1690, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1691, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 1568, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 1692, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 1, .child_index = 1693, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'T', .end_of_word = true, .number = 0, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1694, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1695, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 1696, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1697, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 1698, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1699, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'H', .end_of_word = false, .number = 0, .child_index = 30, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'T', .end_of_word = false, .number = 0, .child_index = 30, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1700, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 78, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1701, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1702, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 1, .child_index = 1703, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1704, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 4, .child_index = 1705, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 1706, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 3, .child_index = 1707, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'R', .end_of_word = false, .number = 0, .child_index = 1708, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'D', .end_of_word = false, .number = 0, .child_index = 1241, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1709, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 1, .child_index = 78, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1710, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 1, .child_index = 1711, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 1712, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 1713, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1714, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 22, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 895, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1715, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1716, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1717, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'q', .end_of_word = false, .number = 0, .child_index = 1718, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1719, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1088, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1720, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1721, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 961, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 1290, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 1722, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 192, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 1, .child_index = 1723, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'y', .end_of_word = false, .number = 6, .child_index = 1724, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 1568, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1725, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 1726, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'f', .end_of_word = false, .number = 0, .child_index = 1727, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 1, .child_index = 1290, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 7, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 1, .child_index = 961, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 1728, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 2, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 's', .end_of_word = false, .number = 3, .child_index = 1411, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'v', .end_of_word = false, .number = 4, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'l', .end_of_word = false, .number = 2, .child_index = 1568, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 3, .child_index = 1729, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 12, .child_index = 1730, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 15, .child_index = 1731, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'z', .end_of_word = false, .number = 17, .child_index = 166, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1398, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1733, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 1734, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 904, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'k', .end_of_word = false, .number = 0, .child_index = 1735, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'v', .end_of_word = false, .number = 0, .child_index = 867, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'w', .end_of_word = false, .number = 1, .child_index = 1739, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'k', .end_of_word = false, .number = 0, .child_index = 1740, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 172, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1741, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 1742, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 42, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1743, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'h', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'w', .end_of_word = false, .number = 2, .child_index = 1273, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 853, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 3, .child_index = 1744, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 6, .child_index = 1747, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 8, .child_index = 1749, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 10, .child_index = 559, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'v', .end_of_word = false, .number = 11, .child_index = 867, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'w', .end_of_word = false, .number = 12, .child_index = 868, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1750, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1751, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 6, .child_index = 1515, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = '1', .end_of_word = false, .number = 0, .child_index = 1752, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = '3', .end_of_word = false, .number = 2, .child_index = 1754, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1515, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'q', .end_of_word = false, .number = 1, .child_index = 1356, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 1, .child_index = 1755, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 1756, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'D', .end_of_word = false, .number = 0, .child_index = 1757, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'H', .end_of_word = false, .number = 4, .child_index = 1761, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'U', .end_of_word = false, .number = 9, .child_index = 1757, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'V', .end_of_word = false, .number = 13, .child_index = 1765, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'b', .end_of_word = false, .number = 20, .child_index = 1771, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 21, .child_index = 1757, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 25, .child_index = 1761, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'm', .end_of_word = false, .number = 30, .child_index = 1772, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 31, .child_index = 1338, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 32, .child_index = 1310, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 33, .child_index = 1757, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'v', .end_of_word = false, .number = 37, .child_index = 1765, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1000, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 1773, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 42, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 1774, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1775, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1777, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 1778, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 1728, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'b', .end_of_word = false, .number = 2, .child_index = 1780, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 3, .child_index = 1781, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 5, .child_index = 39, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 6, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 905, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 1, .child_index = 1399, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 1065, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 883, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 1783, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 889, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = true, .number = 0, .child_index = 1784, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1785, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'E', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'c', .end_of_word = false, .number = 2, .child_index = 1786, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'e', .end_of_word = false, .number = 11, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'f', .end_of_word = false, .number = 12, .child_index = 904, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 13, .child_index = 607, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 14, .child_index = 1064, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 1788, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1789, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 1790, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 2, .child_index = 1791, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 1192, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'i', .end_of_word = false, .number = 2, .child_index = 657, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'f', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 1268, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'y', .end_of_word = true, .number = 2, .child_index = 1793, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 1774, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'p', .end_of_word = false, .number = 2, .child_index = 1774, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1794, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 7, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 1, .child_index = 1587, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1795, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'b', .end_of_word = false, .number = 1, .child_index = 1796, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 2, .child_index = 1781, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 4, .child_index = 39, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 5, .child_index = 7, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 6, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1797, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 2, .child_index = 1798, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 6, .child_index = 1799, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'v', .end_of_word = false, .number = 8, .child_index = 1800, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 11, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1801, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1271, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 1342, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1587, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 921, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 7, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 1802, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 78, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 1803, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1804, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 1806, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1331, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1399, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 1808, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 4, .child_index = 1809, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1810, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 1558, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 192, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 1811, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 3, .child_index = 1772, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 4, .child_index = 1338, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 5, .child_index = 1812, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 1813, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1814, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'k', .end_of_word = false, .number = 0, .child_index = 265, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'y', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1817, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1818, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 1600, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1819, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 883, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 1, .child_index = 39, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1820, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 1821, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 1822, .last_sibling = true, .semicolon_termination = .yes_num_2 },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1823, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 1065, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1824, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 903, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 1, .child_index = 1191, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 937, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 1, .child_index = 1826, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1827, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 1207, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 2, .child_index = 1828, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 1829, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 905, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1830, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 1, .child_index = 1831, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1452, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1832, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 961, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 1, .child_index = 951, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1065, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1620, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'k', .end_of_word = false, .number = 1, .child_index = 1342, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1833, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1834, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 18, .child_index = 1047, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'w', .end_of_word = false, .number = 0, .child_index = 1399, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'q', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 's', .end_of_word = false, .number = 2, .child_index = 1840, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 1, .child_index = 1587, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 2, .child_index = 1841, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 5, .child_index = 1842, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1047, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 1843, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'q', .end_of_word = false, .number = 1, .child_index = 1844, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 937, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 1845, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 7, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'P', .end_of_word = false, .number = 0, .child_index = 192, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 1847, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1848, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 2, .child_index = 39, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 3, .child_index = 1850, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 5, .child_index = 1851, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 6, .child_index = 1229, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1852, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'E', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1853, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1854, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 30, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 1855, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1857, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1858, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 883, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 265, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'w', .end_of_word = false, .number = 1, .child_index = 265, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 1803, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'k', .end_of_word = false, .number = 0, .child_index = 1859, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 1620, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 1861, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 889, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 657, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 1, .child_index = 905, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'f', .end_of_word = false, .number = 0, .child_index = 1172, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 7, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 1, .child_index = 1862, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 4, .child_index = 1290, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1865, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1866, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 1, .child_index = 1867, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 2, .child_index = 1868, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 4, .child_index = 1870, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 5, .child_index = 471, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 11, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1871, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1872, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 1290, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 1876, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1861, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1623, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 1075, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1877, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 1878, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 1880, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1881, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 1623, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 2, .child_index = 1888, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1889, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'k', .end_of_word = false, .number = 2, .child_index = 1890, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 1623, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 1047, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 1892, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 1893, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 1, .child_index = 1894, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 1895, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 1, .child_index = 1587, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 2, .child_index = 1900, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 5, .child_index = 1842, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 's', .end_of_word = false, .number = 7, .child_index = 1901, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1906, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1907, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1515, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1909, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1910, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 42, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 1911, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 961, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 7, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 1912, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 1915, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 7, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'f', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'l', .end_of_word = false, .number = 2, .child_index = 1197, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1321, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1207, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'b', .end_of_word = false, .number = 1, .child_index = 192, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 1916, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'f', .end_of_word = false, .number = 2, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1917, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1918, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 1919, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'u', .end_of_word = false, .number = 1, .child_index = 1892, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 867, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 1685, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'P', .end_of_word = false, .number = 0, .child_index = 192, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 1921, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 1894, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 1, .child_index = 1893, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = true, .number = 0, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 't', .end_of_word = false, .number = 1, .child_index = 1923, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 's', .end_of_word = false, .number = 1, .child_index = 1924, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'k', .end_of_word = false, .number = 0, .child_index = 1600, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 1013, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 1925, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1880, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 1207, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 2, .child_index = 1398, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 3, .child_index = 1926, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 1927, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1197, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1827, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 1928, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 1929, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'v', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'f', .end_of_word = false, .number = 0, .child_index = 1930, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 78, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'E', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'i', .end_of_word = false, .number = 2, .child_index = 11, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 3, .child_index = 1065, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 4, .child_index = 1931, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 1932, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = true, .number = 0, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 1933, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 883, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1934, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1935, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 1937, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 192, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 937, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1938, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'q', .end_of_word = false, .number = 1, .child_index = 1221, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 's', .end_of_word = false, .number = 4, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'd', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'f', .end_of_word = false, .number = 1, .child_index = 1930, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'q', .end_of_word = false, .number = 3, .child_index = 1221, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 's', .end_of_word = false, .number = 6, .child_index = 1888, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 1939, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 1940, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 7, .child_index = 1941, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1942, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1588, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 1, .child_index = 1428, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 2, .child_index = 1945, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1946, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1939, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 1, .child_index = 1428, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 2, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'r', .end_of_word = false, .number = 3, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1464, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 1947, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 1948, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 1949, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'c', .end_of_word = false, .number = 6, .child_index = 1952, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 8, .child_index = 1949, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1953, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 1954, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 2, .child_index = 135, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 't', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1258, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'A', .end_of_word = false, .number = 0, .child_index = 316, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 't', .end_of_word = false, .number = 2, .child_index = 1955, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'A', .end_of_word = false, .number = 0, .child_index = 316, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 1, .child_index = 1956, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 192, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'v', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1957, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 7, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 7, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 49, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1568, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 901, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'n', .end_of_word = false, .number = 2, .child_index = 1197, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 135, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 1958, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'f', .end_of_word = true, .number = 3, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'm', .end_of_word = true, .number = 5, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 401, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1959, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1579, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 2, .child_index = 1960, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = true, .number = 1, .child_index = 1961, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 's', .end_of_word = false, .number = 4, .child_index = 1962, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 6, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 657, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 1268, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 2, .child_index = 1623, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 3, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 't', .end_of_word = false, .number = 4, .child_index = 1964, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 1965, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1966, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1967, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 1969, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1833, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1977, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 1568, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 1, .child_index = 1978, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 1983, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'E', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 135, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 2, .child_index = 1229, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'f', .end_of_word = false, .number = 1, .child_index = 1984, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 4, .child_index = 1987, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1226, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1853, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 1988, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 1990, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = true, .number = 0, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'u', .end_of_word = false, .number = 1, .child_index = 1584, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1587, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 1991, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1994, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1623, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 2004, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 1893, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2005, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 2008, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2009, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2010, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1370, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2011, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 1893, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 1, .child_index = 1623, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2014, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'w', .end_of_word = false, .number = 0, .child_index = 192, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 2016, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 1, .child_index = 1220, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 30, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'y', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2018, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 2019, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 1, .child_index = 39, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 2, .child_index = 1844, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'g', .end_of_word = false, .number = 4, .child_index = 509, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'l', .end_of_word = false, .number = 6, .child_index = 509, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'n', .end_of_word = false, .number = 8, .child_index = 1568, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 9, .child_index = 1338, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 10, .child_index = 166, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2020, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 1, .child_index = 2021, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'l', .end_of_word = false, .number = 1, .child_index = 1568, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 1888, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 30, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'b', .end_of_word = false, .number = 1, .child_index = 2022, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 2023, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 2, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2024, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 2, .child_index = 2024, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2025, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 2027, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'f', .end_of_word = false, .number = 3, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2028, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1832, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2029, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1817, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2030, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 2, .child_index = 1065, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'E', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'd', .end_of_word = false, .number = 2, .child_index = 39, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 3, .child_index = 1192, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'm', .end_of_word = false, .number = 5, .child_index = 2031, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 6, .child_index = 2032, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 8, .child_index = 1338, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 9, .child_index = 166, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 10, .child_index = 2034, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1978, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = '1', .end_of_word = true, .number = 0, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = '2', .end_of_word = true, .number = 2, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = '3', .end_of_word = true, .number = 4, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'E', .end_of_word = false, .number = 7, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'd', .end_of_word = false, .number = 8, .child_index = 2037, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 10, .child_index = 1192, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'h', .end_of_word = false, .number = 12, .child_index = 2039, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 14, .child_index = 166, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 15, .child_index = 2031, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 16, .child_index = 2032, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 18, .child_index = 1338, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 19, .child_index = 2034, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 1707, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'k', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2040, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2041, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 2, .child_index = 2042, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 2043, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 2, .child_index = 1853, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 135, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 1, .child_index = 1229, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 870, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 1568, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2044, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'b', .end_of_word = false, .number = 1, .child_index = 39, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 2, .child_index = 1398, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'f', .end_of_word = false, .number = 3, .child_index = 2045, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2046, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 7, .child_index = 39, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 8, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'm', .end_of_word = false, .number = 9, .child_index = 1772, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 10, .child_index = 1338, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 11, .child_index = 1286, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 12, .child_index = 1109, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2047, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'x', .end_of_word = false, .number = 0, .child_index = 905, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 2048, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2049, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 2, .child_index = 1558, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2050, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2051, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 2053, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1342, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 2054, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2055, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'k', .end_of_word = false, .number = 1, .child_index = 2056, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 2, .child_index = 2057, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 3, .child_index = 2058, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 6, .child_index = 2061, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 's', .end_of_word = false, .number = 8, .child_index = 2062, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 13, .child_index = 2064, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'b', .end_of_word = false, .number = 1, .child_index = 192, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 2, .child_index = 2066, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 192, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2067, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 135, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 2069, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 2, .child_index = 2069, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 2070, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 192, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 1, .child_index = 2071, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1406, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'f', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'l', .end_of_word = false, .number = 1, .child_index = 1197, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 2072, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 1049, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'y', .end_of_word = false, .number = 2, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2029, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 166, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'j', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'g', .end_of_word = true, .number = 0, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'c', .end_of_word = true, .number = 0, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'v', .end_of_word = false, .number = 0, .child_index = 1726, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'y', .end_of_word = false, .number = 0, .child_index = 2073, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 1399, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 1726, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 2074, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2075, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2076, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2066, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 1568, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2077, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2078, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 657, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1344, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2079, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2080, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'k', .end_of_word = false, .number = 0, .child_index = 2081, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1683, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1774, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2082, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2083, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2084, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2085, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2086, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 7, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2087, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1728, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2088, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'q', .end_of_word = false, .number = 0, .child_index = 2089, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2090, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'A', .end_of_word = false, .number = 0, .child_index = 2091, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'B', .end_of_word = false, .number = 3, .child_index = 4, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'L', .end_of_word = false, .number = 4, .child_index = 2092, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'R', .end_of_word = false, .number = 8, .child_index = 2093, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'T', .end_of_word = false, .number = 11, .child_index = 1036, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 13, .child_index = 1037, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1515, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 657, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'y', .end_of_word = false, .number = 0, .child_index = 2094, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2096, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2097, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 1065, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2098, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2099, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1047, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2100, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1362, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1047, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2101, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2102, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'z', .end_of_word = false, .number = 0, .child_index = 2103, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'D', .end_of_word = false, .number = 0, .child_index = 2104, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'E', .end_of_word = false, .number = 1, .child_index = 1604, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2105, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1685, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 2106, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 2107, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 2108, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 78, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2109, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'A', .end_of_word = false, .number = 0, .child_index = 2110, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'C', .end_of_word = false, .number = 4, .child_index = 2112, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'D', .end_of_word = false, .number = 5, .child_index = 2113, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'F', .end_of_word = false, .number = 9, .child_index = 2114, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'R', .end_of_word = false, .number = 10, .child_index = 2115, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'T', .end_of_word = false, .number = 12, .child_index = 2116, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'U', .end_of_word = false, .number = 18, .child_index = 2118, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'V', .end_of_word = false, .number = 22, .child_index = 2119, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 24, .child_index = 1037, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 25, .child_index = 176, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'E', .end_of_word = false, .number = 0, .child_index = 2120, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'F', .end_of_word = false, .number = 1, .child_index = 2121, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'G', .end_of_word = false, .number = 2, .child_index = 2122, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'L', .end_of_word = false, .number = 3, .child_index = 1851, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'S', .end_of_word = false, .number = 4, .child_index = 2123, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'T', .end_of_word = false, .number = 5, .child_index = 106, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2124, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'L', .end_of_word = false, .number = 0, .child_index = 2125, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'R', .end_of_word = false, .number = 2, .child_index = 2126, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 3, .child_index = 2127, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 5, .child_index = 176, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2128, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2130, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2131, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 2132, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2133, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2134, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1402, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2135, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2136, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2137, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 1, .child_index = 2138, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2139, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 71, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'q', .end_of_word = false, .number = 1, .child_index = 2140, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'x', .end_of_word = false, .number = 3, .child_index = 2141, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2142, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 97, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2143, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2145, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2146, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2147, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 2148, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'q', .end_of_word = false, .number = 0, .child_index = 2149, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 4, .child_index = 2150, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 205, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2153, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'C', .end_of_word = false, .number = 0, .child_index = 2154, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 2155, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1065, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'B', .end_of_word = false, .number = 0, .child_index = 2156, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'P', .end_of_word = false, .number = 3, .child_index = 2158, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2159, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'M', .end_of_word = false, .number = 0, .child_index = 1772, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 2160, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2161, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2162, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2163, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 1, .child_index = 1047, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2164, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2165, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 2173, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 1652, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'D', .end_of_word = false, .number = 0, .child_index = 2174, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2175, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2179, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2180, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2181, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2182, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'T', .end_of_word = false, .number = 0, .child_index = 2183, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2184, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 905, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'N', .end_of_word = true, .number = 0, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2185, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'k', .end_of_word = false, .number = 0, .child_index = 1711, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'S', .end_of_word = false, .number = 0, .child_index = 2186, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2187, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2190, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 1, .child_index = 1064, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2191, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2192, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'w', .end_of_word = false, .number = 0, .child_index = 2193, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2194, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2195, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'w', .end_of_word = false, .number = 0, .child_index = 2196, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 1, .child_index = 883, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 407, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 2197, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'T', .end_of_word = false, .number = 0, .child_index = 2198, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'W', .end_of_word = false, .number = 0, .child_index = 2199, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = true, .number = 0, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 2200, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 11, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 2201, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2202, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 1290, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2203, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 2204, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 2205, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 2055, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 2, .child_index = 275, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 3, .child_index = 2206, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2207, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 1, .child_index = 2208, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2209, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2210, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2211, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 39, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 1, .child_index = 1338, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 2, .child_index = 1310, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'q', .end_of_word = false, .number = 0, .child_index = 1567, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 1, .child_index = 192, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2212, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2213, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'k', .end_of_word = false, .number = 0, .child_index = 2214, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = '2', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = '4', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = '4', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 937, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1568, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'L', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'R', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'l', .end_of_word = false, .number = 2, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'r', .end_of_word = false, .number = 3, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'D', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'U', .end_of_word = false, .number = 2, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'd', .end_of_word = false, .number = 3, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'u', .end_of_word = false, .number = 4, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'H', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'L', .end_of_word = false, .number = 2, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'R', .end_of_word = false, .number = 3, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'h', .end_of_word = false, .number = 4, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'l', .end_of_word = false, .number = 5, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'r', .end_of_word = false, .number = 6, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2217, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2218, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1326, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'b', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'h', .end_of_word = false, .number = 2, .child_index = 2219, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 905, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'E', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'e', .end_of_word = false, .number = 2, .child_index = 1844, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1567, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 135, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 1, .child_index = 135, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 2220, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 2221, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'k', .end_of_word = false, .number = 0, .child_index = 2222, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 2066, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 2, .child_index = 2223, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 2224, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1947, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2225, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'f', .end_of_word = false, .number = 1, .child_index = 1399, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 2, .child_index = 2226, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 1, .child_index = 7, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1169, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2227, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2228, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2229, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'y', .end_of_word = false, .number = 0, .child_index = 2230, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 870, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1915, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 22, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 1583, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 905, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'o', .end_of_word = false, .number = 1, .child_index = 2233, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 3, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 2234, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2217, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1399, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'q', .end_of_word = false, .number = 0, .child_index = 1192, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'q', .end_of_word = false, .number = 0, .child_index = 2235, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2236, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1037, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 1, .child_index = 2237, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 2, .child_index = 1541, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'f', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 1832, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = true, .number = 1, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2238, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'y', .end_of_word = false, .number = 0, .child_index = 2239, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = '1', .end_of_word = false, .number = 0, .child_index = 2241, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 1, .child_index = 1047, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 1, .child_index = 883, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'v', .end_of_word = false, .number = 2, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2243, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1065, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'v', .end_of_word = false, .number = 0, .child_index = 2244, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2245, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 2246, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2247, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1568, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 1588, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = '1', .end_of_word = false, .number = 0, .child_index = 2248, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = '2', .end_of_word = false, .number = 8, .child_index = 2254, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = '3', .end_of_word = false, .number = 10, .child_index = 2256, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = '4', .end_of_word = false, .number = 14, .child_index = 2259, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = '5', .end_of_word = false, .number = 15, .child_index = 2260, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = '7', .end_of_word = false, .number = 17, .child_index = 2262, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2263, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2264, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 1065, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 1, .child_index = 1931, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'q', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'l', .end_of_word = false, .number = 2, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1207, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 2265, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 7, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'q', .end_of_word = false, .number = 0, .child_index = 2266, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 918, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2268, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 135, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 905, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 1, .child_index = 1398, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'w', .end_of_word = false, .number = 2, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 1788, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 135, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2269, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 176, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1399, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'l', .end_of_word = false, .number = 1, .child_index = 1663, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 2, .child_index = 2270, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1568, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2271, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1047, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 2238, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 2272, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2273, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 1441, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'E', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'd', .end_of_word = false, .number = 2, .child_index = 39, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 3, .child_index = 1342, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'v', .end_of_word = false, .number = 5, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1342, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1399, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'l', .end_of_word = false, .number = 2, .child_index = 1568, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = true, .number = 0, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'b', .end_of_word = false, .number = 1, .child_index = 2274, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'f', .end_of_word = false, .number = 3, .child_index = 1065, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 4, .child_index = 1515, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 5, .child_index = 135, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 6, .child_index = 1047, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 7, .child_index = 1229, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 8, .child_index = 1047, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 2275, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 's', .end_of_word = false, .number = 1, .child_index = 2277, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 235, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 192, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 1893, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2278, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 2, .child_index = 2279, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 4, .child_index = 2280, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 5, .child_index = 2281, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 9, .child_index = 2282, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2283, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2284, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 1, .child_index = 39, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 2, .child_index = 2285, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 4, .child_index = 2286, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 5, .child_index = 1229, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 7, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'u', .end_of_word = false, .number = 1, .child_index = 407, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2287, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 11, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 2288, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2127, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 2, .child_index = 2289, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 3, .child_index = 176, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2290, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1046, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 1, .child_index = 905, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1362, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'g', .end_of_word = false, .number = 2, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'f', .end_of_word = false, .number = 2, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 2075, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2291, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2292, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1441, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 2293, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1065, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2295, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2296, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1771, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2298, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 1774, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 1192, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 1515, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 2299, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1396, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 2300, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1774, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2301, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2304, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 2305, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 2, .child_index = 1047, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 3, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'c', .end_of_word = false, .number = 1, .child_index = 2204, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2306, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 1844, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2308, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'E', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'e', .end_of_word = false, .number = 2, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 's', .end_of_word = false, .number = 3, .child_index = 2310, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 2204, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2311, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 172, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 1756, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1756, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 11, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2312, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2313, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2314, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 1, .child_index = 2315, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 937, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2316, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 905, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 2317, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 2318, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'k', .end_of_word = false, .number = 2, .child_index = 1396, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 1064, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'b', .end_of_word = false, .number = 2, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'c', .end_of_word = false, .number = 3, .child_index = 1398, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 4, .child_index = 2319, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 6, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'm', .end_of_word = false, .number = 7, .child_index = 870, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 9, .child_index = 1229, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 10, .child_index = 2321, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = true, .number = 0, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 2284, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 2, .child_index = 2322, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 3, .child_index = 2066, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 4, .child_index = 2323, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 7, .child_index = 1229, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1888, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1177, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 1, .child_index = 1663, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 2, .child_index = 2326, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 1, .child_index = 172, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2327, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 657, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2204, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'd', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'e', .end_of_word = false, .number = 2, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'l', .end_of_word = false, .number = 3, .child_index = 1568, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 135, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'b', .end_of_word = false, .number = 2, .child_index = 2274, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'c', .end_of_word = false, .number = 4, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'f', .end_of_word = false, .number = 5, .child_index = 1065, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 6, .child_index = 1515, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 7, .child_index = 135, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 8, .child_index = 1047, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 9, .child_index = 1229, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 10, .child_index = 1047, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'w', .end_of_word = false, .number = 11, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2328, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 1402, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 2, .child_index = 2270, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 3, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2329, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2335, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 1, .child_index = 905, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'f', .end_of_word = false, .number = 2, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'l', .end_of_word = false, .number = 3, .child_index = 844, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'b', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'e', .end_of_word = false, .number = 2, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2218, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2336, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2338, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2340, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 135, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 7, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1788, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 1888, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 2341, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'p', .end_of_word = false, .number = 4, .child_index = 2341, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2343, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 1399, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 884, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2345, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 1854, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'E', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2346, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 5, .child_index = 937, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 6, .child_index = 2067, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 905, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 1, .child_index = 2347, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 2348, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1587, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2350, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2352, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'k', .end_of_word = false, .number = 0, .child_index = 2354, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = true, .number = 0, .child_index = 2356, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'o', .end_of_word = false, .number = 1, .child_index = 793, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2358, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'z', .end_of_word = false, .number = 0, .child_index = 2359, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2360, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2361, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2362, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'l', .end_of_word = false, .number = 2, .child_index = 883, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2363, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 905, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 74, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 114, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2364, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 42, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'r', .end_of_word = false, .number = 2, .child_index = 2365, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 1, .child_index = 172, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 188, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 1, .child_index = 2366, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 2368, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 2369, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'q', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'p', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2032, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'z', .end_of_word = false, .number = 0, .child_index = 2370, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1844, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 135, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'F', .end_of_word = false, .number = 0, .child_index = 2371, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 221, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 1568, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2372, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2373, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'y', .end_of_word = false, .number = 0, .child_index = 1065, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 546, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2374, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'w', .end_of_word = false, .number = 0, .child_index = 2378, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 1613, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2379, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 1692, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2380, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2381, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2382, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2383, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 1867, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2384, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2390, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2391, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2392, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'S', .end_of_word = false, .number = 0, .child_index = 2393, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'V', .end_of_word = false, .number = 1, .child_index = 2394, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'T', .end_of_word = false, .number = 1, .child_index = 106, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2395, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2396, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 2094, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2397, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2398, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2399, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2400, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2401, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2402, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1867, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 2403, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2404, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 2405, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2406, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 2407, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2408, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2409, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1296, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2411, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2412, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 3, .child_index = 2413, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 2414, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2417, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'q', .end_of_word = false, .number = 0, .child_index = 2418, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2419, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2420, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2421, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1037, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2422, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2423, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1343, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'L', .end_of_word = false, .number = 0, .child_index = 2424, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'R', .end_of_word = false, .number = 1, .child_index = 2126, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 1711, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1571, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'P', .end_of_word = false, .number = 0, .child_index = 1338, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2425, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 2426, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1515, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2428, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2429, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 2430, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2431, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2432, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 938, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2433, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'f', .end_of_word = false, .number = 0, .child_index = 2434, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 3, .child_index = 2435, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 972, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2436, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'v', .end_of_word = false, .number = 0, .child_index = 2437, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 2438, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2439, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 2184, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 2, .child_index = 2440, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 6, .child_index = 2441, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2442, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2443, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = true, .number = 0, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 7, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 2444, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2445, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2446, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2447, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 2448, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 905, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2449, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 2450, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'A', .end_of_word = false, .number = 0, .child_index = 2451, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'C', .end_of_word = false, .number = 4, .child_index = 2112, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'D', .end_of_word = false, .number = 5, .child_index = 2113, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'F', .end_of_word = false, .number = 9, .child_index = 2114, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'T', .end_of_word = false, .number = 10, .child_index = 2116, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'U', .end_of_word = false, .number = 16, .child_index = 2118, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'V', .end_of_word = false, .number = 20, .child_index = 2119, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 22, .child_index = 1037, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'I', .end_of_word = false, .number = 0, .child_index = 2453, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2454, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'D', .end_of_word = false, .number = 0, .child_index = 1034, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'L', .end_of_word = false, .number = 1, .child_index = 2424, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'R', .end_of_word = false, .number = 2, .child_index = 2126, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'U', .end_of_word = false, .number = 3, .child_index = 2455, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'C', .end_of_word = false, .number = 0, .child_index = 2456, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2457, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2460, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2461, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 1965, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 1703, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'f', .end_of_word = false, .number = 0, .child_index = 2462, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 2463, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'E', .end_of_word = false, .number = 1, .child_index = 1604, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'F', .end_of_word = false, .number = 2, .child_index = 2121, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'T', .end_of_word = false, .number = 3, .child_index = 106, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 546, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'P', .end_of_word = false, .number = 1, .child_index = 1338, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2464, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2465, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1616, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'A', .end_of_word = false, .number = 1, .child_index = 1037, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2124, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 2466, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 2467, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2468, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'y', .end_of_word = false, .number = 0, .child_index = 937, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 2469, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'v', .end_of_word = false, .number = 1, .child_index = 2470, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'x', .end_of_word = false, .number = 0, .child_index = 2204, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 2066, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1040, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2471, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 2472, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 793, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 1774, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'y', .end_of_word = false, .number = 0, .child_index = 1396, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2473, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'w', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2474, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 1, .child_index = 1812, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 2, .child_index = 2475, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'x', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1197, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 2347, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 1, .child_index = 937, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 307, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 1, .child_index = 2476, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2477, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 1, .child_index = 2479, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2480, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2482, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 858, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2483, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2484, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'v', .end_of_word = false, .number = 2, .child_index = 867, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'w', .end_of_word = false, .number = 3, .child_index = 868, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2485, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = true, .number = 0, .child_index = 2486, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 1262, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2487, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2488, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2489, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 1, .child_index = 1707, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'v', .end_of_word = false, .number = 2, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = '3', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = '4', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2490, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'D', .end_of_word = false, .number = 1, .child_index = 2491, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2492, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2493, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2494, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = '2', .end_of_word = true, .number = 0, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = '3', .end_of_word = false, .number = 2, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = '4', .end_of_word = true, .number = 3, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = '5', .end_of_word = false, .number = 5, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = '6', .end_of_word = false, .number = 6, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = '8', .end_of_word = false, .number = 7, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = '3', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = '5', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = '4', .end_of_word = true, .number = 0, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = '5', .end_of_word = false, .number = 2, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = '8', .end_of_word = false, .number = 3, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = '5', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = '6', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = '8', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = '8', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 657, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2495, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 1931, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1851, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'q', .end_of_word = false, .number = 1, .child_index = 2496, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2497, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 965, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2054, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 1, .child_index = 1756, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1867, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2498, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'f', .end_of_word = false, .number = 1, .child_index = 1065, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'k', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2499, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2501, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2502, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2503, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2504, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 2505, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2506, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 2265, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'q', .end_of_word = false, .number = 0, .child_index = 2507, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 7, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1600, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2509, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2510, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2511, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2512, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2515, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'b', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'd', .end_of_word = false, .number = 2, .child_index = 2516, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 858, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1037, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 176, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 2517, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 1, .child_index = 2213, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 1888, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'E', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'd', .end_of_word = false, .number = 2, .child_index = 39, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'v', .end_of_word = false, .number = 3, .child_index = 2518, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'v', .end_of_word = false, .number = 1, .child_index = 2518, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2315, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'w', .end_of_word = false, .number = 2, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 1568, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 1, .child_index = 1568, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2521, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2522, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 1, .child_index = 884, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 1568, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 2523, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1226, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1515, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'f', .end_of_word = false, .number = 0, .child_index = 2524, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'k', .end_of_word = false, .number = 0, .child_index = 2525, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'u', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'w', .end_of_word = false, .number = 0, .child_index = 172, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2526, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2284, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 2527, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 2, .child_index = 1229, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2029, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2528, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 1, .child_index = 2529, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2278, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 2, .child_index = 2279, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 4, .child_index = 2530, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 6, .child_index = 2531, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 7, .child_index = 2532, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 8, .child_index = 2282, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 2533, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 607, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 1, .child_index = 2534, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'f', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'v', .end_of_word = false, .number = 2, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 2535, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 's', .end_of_word = false, .number = 2, .child_index = 2536, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'f', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 2537, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2538, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 1286, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1047, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 1, .child_index = 1286, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = '4', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'f', .end_of_word = false, .number = 1, .child_index = 2462, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 1, .child_index = 2200, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'v', .end_of_word = false, .number = 2, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2284, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 1, .child_index = 1229, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'b', .end_of_word = false, .number = 1, .child_index = 2022, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'd', .end_of_word = false, .number = 3, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 2540, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2541, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2542, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2543, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 2544, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2545, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2546, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2547, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 2548, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 2, .child_index = 2548, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1167, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2549, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 961, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2550, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2551, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2552, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'D', .end_of_word = false, .number = 0, .child_index = 39, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'M', .end_of_word = false, .number = 1, .child_index = 1772, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'P', .end_of_word = false, .number = 2, .child_index = 1338, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'T', .end_of_word = false, .number = 3, .child_index = 1310, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2553, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2554, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2555, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 11, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2556, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2557, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'C', .end_of_word = false, .number = 0, .child_index = 2558, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'D', .end_of_word = false, .number = 1, .child_index = 2559, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'L', .end_of_word = false, .number = 3, .child_index = 2560, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'R', .end_of_word = false, .number = 9, .child_index = 2562, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'U', .end_of_word = false, .number = 11, .child_index = 2563, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'V', .end_of_word = false, .number = 13, .child_index = 1682, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2564, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'f', .end_of_word = false, .number = 0, .child_index = 2565, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 2566, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 2567, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2568, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 2569, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2570, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1571, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2571, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 1711, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2577, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'w', .end_of_word = false, .number = 0, .child_index = 2578, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2579, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2580, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 2581, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1571, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 2582, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2583, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2584, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2585, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'w', .end_of_word = false, .number = 1, .child_index = 2586, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 2587, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2588, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2590, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'D', .end_of_word = false, .number = 0, .child_index = 2591, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'T', .end_of_word = false, .number = 1, .child_index = 2592, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'V', .end_of_word = false, .number = 2, .child_index = 2119, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 2593, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2594, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2595, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2596, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2597, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'f', .end_of_word = false, .number = 0, .child_index = 2598, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 2599, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2600, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'v', .end_of_word = false, .number = 0, .child_index = 2601, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'G', .end_of_word = false, .number = 0, .child_index = 2602, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'L', .end_of_word = false, .number = 1, .child_index = 2603, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2604, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 1595, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'C', .end_of_word = false, .number = 0, .child_index = 858, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 2605, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1615, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2606, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2607, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 2608, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 2613, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2614, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 2434, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2615, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1704, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1706, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2616, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2617, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2618, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2619, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2491, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2620, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2621, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2622, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2623, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2406, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 2625, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 2626, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2627, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 2465, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2628, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'I', .end_of_word = false, .number = 1, .child_index = 2629, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'S', .end_of_word = false, .number = 2, .child_index = 2630, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'U', .end_of_word = false, .number = 6, .child_index = 2631, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'E', .end_of_word = false, .number = 1, .child_index = 1604, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 2621, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1865, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2632, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'w', .end_of_word = false, .number = 0, .child_index = 2633, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'A', .end_of_word = false, .number = 0, .child_index = 1037, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2635, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2636, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 2637, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 2638, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 1362, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 2204, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'g', .end_of_word = false, .number = 1, .child_index = 1568, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2646, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2647, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2648, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 793, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2290, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 2, .child_index = 2649, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 905, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 1613, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'x', .end_of_word = false, .number = 1, .child_index = 1685, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'm', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'q', .end_of_word = false, .number = 0, .child_index = 2654, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 2656, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'o', .end_of_word = false, .number = 1, .child_index = 2657, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 2658, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'w', .end_of_word = false, .number = 0, .child_index = 2659, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 1065, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2660, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'D', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 1047, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2662, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2663, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 1, .child_index = 407, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1851, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2527, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 1515, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'u', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2664, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2665, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'f', .end_of_word = false, .number = 0, .child_index = 2666, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 2667, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2668, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 1, .child_index = 235, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 2286, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'q', .end_of_word = false, .number = 1, .child_index = 2669, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 2670, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 2671, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2672, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 1, .child_index = 2673, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 2, .child_index = 2674, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 3, .child_index = 135, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2675, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1888, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'b', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'c', .end_of_word = false, .number = 2, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2676, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 2677, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 1065, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 793, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2678, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'q', .end_of_word = false, .number = 0, .child_index = 2066, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2679, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1827, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2680, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2681, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'q', .end_of_word = false, .number = 0, .child_index = 2682, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 2683, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2684, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2685, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1990, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 2686, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 2687, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 3, .child_index = 2688, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2689, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 937, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 1859, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 7, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2690, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2691, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 220, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 2692, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 2693, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2694, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2580, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 859, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'D', .end_of_word = false, .number = 0, .child_index = 2695, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 2696, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'I', .end_of_word = false, .number = 0, .child_index = 2697, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'C', .end_of_word = false, .number = 0, .child_index = 2698, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2699, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 996, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2700, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2701, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2703, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 3, .child_index = 2704, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2705, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 2706, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2708, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2709, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 2712, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2713, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2714, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2359, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2715, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'E', .end_of_word = false, .number = 0, .child_index = 2716, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'F', .end_of_word = false, .number = 2, .child_index = 2121, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'G', .end_of_word = false, .number = 3, .child_index = 2122, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'L', .end_of_word = false, .number = 4, .child_index = 1851, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'S', .end_of_word = false, .number = 5, .child_index = 2123, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'T', .end_of_word = false, .number = 6, .child_index = 106, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2717, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2718, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2719, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 2662, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2720, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2721, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2722, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 220, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 2582, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2723, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 2725, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'A', .end_of_word = false, .number = 1, .child_index = 1037, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'V', .end_of_word = false, .number = 2, .child_index = 2726, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2727, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2728, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2729, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2730, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2731, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2732, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1189, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2733, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2734, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 2736, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'f', .end_of_word = false, .number = 0, .child_index = 2736, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2737, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2740, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2741, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'k', .end_of_word = false, .number = 0, .child_index = 2742, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2743, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2744, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'T', .end_of_word = false, .number = 0, .child_index = 2745, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'E', .end_of_word = false, .number = 1, .child_index = 1604, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'G', .end_of_word = false, .number = 2, .child_index = 2122, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'L', .end_of_word = false, .number = 3, .child_index = 1851, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'S', .end_of_word = false, .number = 4, .child_index = 2123, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'T', .end_of_word = false, .number = 5, .child_index = 106, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2746, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2747, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2748, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2749, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2750, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 2751, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2753, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2754, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 2755, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2758, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'E', .end_of_word = false, .number = 0, .child_index = 2759, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'U', .end_of_word = false, .number = 2, .child_index = 2761, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2762, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 954, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2763, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2764, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2765, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2766, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2768, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1568, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'B', .end_of_word = false, .number = 1, .child_index = 192, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'D', .end_of_word = false, .number = 2, .child_index = 1034, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2769, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 1711, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2773, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'b', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'c', .end_of_word = false, .number = 2, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'd', .end_of_word = false, .number = 3, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'e', .end_of_word = false, .number = 4, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'f', .end_of_word = false, .number = 5, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'g', .end_of_word = false, .number = 6, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'h', .end_of_word = false, .number = 7, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2774, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'z', .end_of_word = false, .number = 0, .child_index = 2775, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2776, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'R', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'S', .end_of_word = false, .number = 1, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'a', .end_of_word = false, .number = 2, .child_index = 1207, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 3, .child_index = 93, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 4, .child_index = 221, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 1516, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 1, .child_index = 2777, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 1, .child_index = 2778, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2779, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2780, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2053, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 2286, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 1, .child_index = 1851, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2768, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2781, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2782, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 2783, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2053, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 2784, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2785, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 2286, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 2786, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 2692, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2787, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1220, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2788, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 351, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 1, .child_index = 2687, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2789, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2790, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2791, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'f', .end_of_word = false, .number = 0, .child_index = 2792, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 2793, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2794, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1166, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2795, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2796, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2797, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'q', .end_of_word = false, .number = 0, .child_index = 1844, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2687, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2799, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2803, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2804, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 172, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2805, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2806, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2807, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2808, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2809, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2810, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 2811, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2812, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'w', .end_of_word = false, .number = 1, .child_index = 2193, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'f', .end_of_word = false, .number = 0, .child_index = 2813, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2814, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 2815, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'A', .end_of_word = false, .number = 0, .child_index = 1037, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'D', .end_of_word = false, .number = 1, .child_index = 1034, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'w', .end_of_word = false, .number = 0, .child_index = 2816, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'R', .end_of_word = false, .number = 0, .child_index = 2818, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'T', .end_of_word = false, .number = 1, .child_index = 2592, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'V', .end_of_word = false, .number = 2, .child_index = 2119, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2723, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2819, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'y', .end_of_word = false, .number = 0, .child_index = 2820, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2821, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'q', .end_of_word = false, .number = 0, .child_index = 2822, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2823, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'H', .end_of_word = false, .number = 0, .child_index = 2824, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'y', .end_of_word = false, .number = 0, .child_index = 2825, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2826, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2828, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'w', .end_of_word = false, .number = 0, .child_index = 2829, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'T', .end_of_word = false, .number = 0, .child_index = 2592, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'V', .end_of_word = false, .number = 1, .child_index = 2119, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2831, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2833, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2834, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'w', .end_of_word = false, .number = 0, .child_index = 2835, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2836, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2837, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2838, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'E', .end_of_word = false, .number = 0, .child_index = 1604, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2732, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'A', .end_of_word = false, .number = 0, .child_index = 1037, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'R', .end_of_word = false, .number = 1, .child_index = 2126, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2465, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'M', .end_of_word = false, .number = 0, .child_index = 2839, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'T', .end_of_word = false, .number = 1, .child_index = 2840, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'V', .end_of_word = false, .number = 3, .child_index = 2841, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2842, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 2843, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2844, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2845, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2846, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2413, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 2847, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 2848, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2849, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 2850, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'y', .end_of_word = false, .number = 0, .child_index = 2851, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'k', .end_of_word = false, .number = 1, .child_index = 1707, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2853, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 2854, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'E', .end_of_word = false, .number = 1, .child_index = 1604, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'S', .end_of_word = false, .number = 2, .child_index = 2123, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'T', .end_of_word = false, .number = 3, .child_index = 106, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2855, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 71, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'q', .end_of_word = false, .number = 1, .child_index = 1718, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 2856, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2857, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'y', .end_of_word = false, .number = 0, .child_index = 1159, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1832, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2858, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 2184, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 2, .child_index = 2441, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 883, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'B', .end_of_word = false, .number = 0, .child_index = 192, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'L', .end_of_word = false, .number = 1, .child_index = 1663, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'S', .end_of_word = false, .number = 2, .child_index = 2859, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'T', .end_of_word = false, .number = 3, .child_index = 106, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 1711, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 2860, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 1916, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2861, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2862, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2479, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 1310, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2863, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1211, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'w', .end_of_word = false, .number = 0, .child_index = 2864, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2865, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2866, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2779, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 1568, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'w', .end_of_word = false, .number = 0, .child_index = 2869, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'f', .end_of_word = false, .number = 0, .child_index = 905, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2871, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'y', .end_of_word = false, .number = 0, .child_index = 1583, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1214, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2873, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 2666, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2875, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2305, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 1772, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2055, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 1, .child_index = 2876, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 1, .child_index = 2673, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 2, .child_index = 2877, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'q', .end_of_word = false, .number = 4, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'r', .end_of_word = false, .number = 5, .child_index = 2878, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2869, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'w', .end_of_word = false, .number = 0, .child_index = 1065, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2879, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 2880, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'f', .end_of_word = false, .number = 0, .child_index = 926, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'C', .end_of_word = false, .number = 0, .child_index = 2558, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2881, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2882, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2883, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 1596, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2884, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 2887, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 2889, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'B', .end_of_word = false, .number = 1, .child_index = 192, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'U', .end_of_word = false, .number = 2, .child_index = 2455, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2890, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2891, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'S', .end_of_word = false, .number = 0, .child_index = 2393, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2892, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2893, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 973, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2894, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'I', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'C', .end_of_word = false, .number = 0, .child_index = 2895, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'T', .end_of_word = false, .number = 1, .child_index = 1310, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'B', .end_of_word = false, .number = 0, .child_index = 2896, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'B', .end_of_word = false, .number = 1, .child_index = 192, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'R', .end_of_word = false, .number = 2, .child_index = 2126, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'A', .end_of_word = false, .number = 0, .child_index = 1037, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'V', .end_of_word = false, .number = 1, .child_index = 2726, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 2897, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 2898, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2836, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'V', .end_of_word = false, .number = 0, .child_index = 2726, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2899, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'G', .end_of_word = false, .number = 0, .child_index = 2122, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2900, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 2901, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2902, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2903, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 2904, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2905, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'V', .end_of_word = false, .number = 0, .child_index = 1682, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2906, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2912, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2913, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'S', .end_of_word = false, .number = 0, .child_index = 2630, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2914, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'D', .end_of_word = false, .number = 0, .child_index = 2915, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'Q', .end_of_word = false, .number = 1, .child_index = 2916, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2917, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2918, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2919, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'E', .end_of_word = false, .number = 0, .child_index = 1035, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'w', .end_of_word = false, .number = 0, .child_index = 2920, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2922, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2923, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2924, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2925, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1587, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'w', .end_of_word = false, .number = 0, .child_index = 868, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 1, .child_index = 1274, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2926, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2927, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 2, .child_index = 2928, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 3, .child_index = 2532, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2674, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 1, .child_index = 2929, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2877, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 2, .child_index = 2878, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2363, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 1, .child_index = 2928, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 2124, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 42, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2930, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2931, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2688, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2932, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2933, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 1592, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2934, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'A', .end_of_word = false, .number = 0, .child_index = 1037, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'R', .end_of_word = false, .number = 1, .child_index = 2126, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'T', .end_of_word = false, .number = 2, .child_index = 867, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'L', .end_of_word = false, .number = 0, .child_index = 2125, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'R', .end_of_word = false, .number = 2, .child_index = 2126, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2938, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 2940, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'S', .end_of_word = false, .number = 0, .child_index = 1812, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 1241, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2941, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'm', .end_of_word = false, .number = 0, .child_index = 135, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1331, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2942, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 1906, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2943, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'B', .end_of_word = false, .number = 1, .child_index = 192, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 968, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 1025, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2944, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2945, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'L', .end_of_word = false, .number = 0, .child_index = 1851, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 1711, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'E', .end_of_word = false, .number = 1, .child_index = 1604, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'F', .end_of_word = false, .number = 2, .child_index = 2121, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'G', .end_of_word = false, .number = 3, .child_index = 2122, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'L', .end_of_word = false, .number = 4, .child_index = 1851, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'S', .end_of_word = false, .number = 5, .child_index = 2123, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'T', .end_of_word = false, .number = 6, .child_index = 106, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 2946, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'E', .end_of_word = false, .number = 0, .child_index = 2948, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2949, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2950, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2951, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 2952, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 1402, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 1, .child_index = 1047, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'B', .end_of_word = false, .number = 1, .child_index = 192, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'L', .end_of_word = false, .number = 2, .child_index = 2424, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2107, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 2953, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2954, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 2956, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'n', .end_of_word = false, .number = 0, .child_index = 2954, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2957, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2958, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'i', .end_of_word = false, .number = 0, .child_index = 2959, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'f', .end_of_word = false, .number = 0, .child_index = 1990, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 2960, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2869, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 2106, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'A', .end_of_word = false, .number = 0, .child_index = 139, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'D', .end_of_word = false, .number = 1, .child_index = 2961, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'G', .end_of_word = false, .number = 3, .child_index = 2962, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'T', .end_of_word = false, .number = 4, .child_index = 106, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'A', .end_of_word = false, .number = 0, .child_index = 1037, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'T', .end_of_word = false, .number = 1, .child_index = 867, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 2963, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2964, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2965, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2966, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'y', .end_of_word = false, .number = 0, .child_index = 1724, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2968, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'E', .end_of_word = false, .number = 1, .child_index = 1604, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'S', .end_of_word = false, .number = 2, .child_index = 2123, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 71, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'B', .end_of_word = false, .number = 0, .child_index = 192, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 0, .child_index = 2969, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 1584, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2970, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2971, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 0, .child_index = 2673, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'u', .end_of_word = false, .number = 1, .child_index = 135, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2972, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2973, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2974, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'g', .end_of_word = false, .number = 0, .child_index = 1803, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'h', .end_of_word = false, .number = 0, .child_index = 1990, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2975, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 423, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 2836, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'L', .end_of_word = false, .number = 1, .child_index = 1851, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'c', .end_of_word = false, .number = 0, .child_index = 2977, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'B', .end_of_word = false, .number = 1, .child_index = 192, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'E', .end_of_word = false, .number = 2, .child_index = 1604, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2838, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 2978, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 's', .end_of_word = false, .number = 0, .child_index = 859, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 0, .child_index = 2979, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2980, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2983, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'p', .end_of_word = false, .number = 0, .child_index = 2984, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 't', .end_of_word = false, .number = 0, .child_index = 0, .last_sibling = false, .semicolon_termination = .yes },
    .{ .char = 'u', .end_of_word = false, .number = 1, .child_index = 2985, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'k', .end_of_word = false, .number = 0, .child_index = 1707, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2986, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'a', .end_of_word = false, .number = 0, .child_index = 2897, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'd', .end_of_word = false, .number = 1, .child_index = 2673, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 2, .child_index = 2674, .last_sibling = false, .semicolon_termination = .no },
    .{ .char = 'r', .end_of_word = false, .number = 3, .child_index = 2929, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'w', .end_of_word = false, .number = 0, .child_index = 1888, .last_sibling = true, .semicolon_termination = .yes },
    .{ .char = 'o', .end_of_word = false, .number = 0, .child_index = 2791, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'b', .end_of_word = false, .number = 0, .child_index = 2987, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2988, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'l', .end_of_word = false, .number = 0, .child_index = 2989, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'Q', .end_of_word = false, .number = 0, .child_index = 2916, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'e', .end_of_word = false, .number = 0, .child_index = 2990, .last_sibling = true, .semicolon_termination = .no },
    .{ .char = 'A', .end_of_word = false, .number = 0, .child_index = 139, .last_sibling = true, .semicolon_termination = .no },
};
