const std = @import("std");
const named_character_references = @import("named_character_references.zig");

pub const ParseResult = struct {
    /// UTF-8
    output: []u8,
    status: Status = .ok,
    pub const Status = enum { ok, missing_semicolon };
};

/// Stripped down version of the 'Named character reference state' detailed here:
/// https://html.spec.whatwg.org/multipage/parsing.html#named-character-reference-state
///
/// Assumes that all inputs start with '&' and only implements enough to handle the
/// `tokenizer/namedEntities.test` test cases from https://github.com/html5lib/html5lib-tests
fn parse(input: []const u8, output_buf: []u8) !ParseResult {
    std.debug.assert(input[0] == '&');

    var tmp_buf = try std.BoundedArray(u8, 128).init(0);
    tmp_buf.append('&') catch unreachable;

    var matcher = named_character_references.Matcher{};
    var longest_matched_len: usize = 0;
    for (input[1..]) |c| {
        if (!matcher.char(c)) break;
        try tmp_buf.append(c);
        if (matcher.matched()) {
            longest_matched_len = tmp_buf.len;
        }
    }

    // match
    if (longest_matched_len != 0) {
        const codepoints = named_character_references.getCodepoints(tmp_buf.constSlice()[0..longest_matched_len]);

        var output_len: usize = try std.unicode.utf8Encode(codepoints.first, output_buf);
        if (codepoints.second.asInt()) |codepoint| {
            output_len += try std.unicode.utf8Encode(codepoint, output_buf[output_len..]);
        }
        return .{
            .output = output_buf[0..output_len],
            .status = if (tmp_buf.constSlice()[tmp_buf.len - 1] == ';') .ok else .missing_semicolon,
        };
    } else {
        @memcpy(output_buf[0..tmp_buf.len], tmp_buf.constSlice());
        return .{ .output = output_buf[0..tmp_buf.len] };
    }
}

test {
    const allocator = std.testing.allocator;

    const test_json_contents = try std.fs.cwd().readFileAlloc(allocator, "namedEntities.test", std.math.maxInt(usize));
    defer allocator.free(test_json_contents);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, test_json_contents, .{});
    defer parsed.deinit();

    var buf: [128]u8 = undefined;

    for (parsed.value.object.get("tests").?.array.items) |item| {
        const object = item.object;
        const input = object.get("input").?.string;
        const result = try parse(input, &buf);

        const expected_output = object.get("output").?.array.items[0].array.items[1].string;
        try std.testing.expectEqualStrings(expected_output, result.output);

        const expected_status: ParseResult.Status = if (object.get("errors") == null) .ok else .missing_semicolon;
        try std.testing.expectEqual(expected_status, result.status);
    }
}

test "backtracking" {
    var buf: [128]u8 = undefined;
    // Should match &not, but &noti could lead to valid character references so it needs to
    // backtrack from &noti to get back to the last match (&not -> U+00AC)
    const result = try parse("&notit;", &buf);
    try std.testing.expectEqualStrings("\u{00AC}", result.output);
}
