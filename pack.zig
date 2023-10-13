const std = @import("std");

pub fn main() !void {
    var packed_array = std.PackedIntArray(Codepoints, codepoints_lookup.len).init(codepoints_lookup);
    var stdout = std.io.getStdOut().writer();
    try stdout.print("\"{}\"", .{std.zig.fmtEscapes(packed_array.bytes[0..])});
}

pub const Codepoints = packed struct(u21) {
    first: u17, // Largest value is U+1D56B
    second: SecondCodepoint = .none,
};

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

// paste the generated codepoints_lookup array here
