const std = @import("std");

/// Matches std430: three independent cell properties, padded to 16 bytes.
pub const Cell = extern struct { glyph: u32, foreground: u32, background: u32, pad: u32 = 0 };
pub const cols = 240;
pub const rows = 135;
pub const glyph_bits = makeGlyphs();

// Original 5x7 marks in an 8x8 cell. No font asset or rasterizer is shipped.
fn makeGlyphs() [128][2]u32 {
    @setEvalBranchQuota(20000);
    var table = [_][2]u32{.{ 0, 0 }} ** 128;
    const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.,:;!+-=/\\|_~*#@%<>[]()?";
    const shapes = [_][7]u5{
        .{ 14, 17, 17, 31, 17, 17, 17 }, .{ 30, 17, 17, 30, 17, 17, 30 }, .{ 14, 17, 16, 16, 16, 17, 14 },
        .{ 30, 17, 17, 17, 17, 17, 30 }, .{ 31, 16, 16, 30, 16, 16, 31 }, .{ 31, 16, 16, 30, 16, 16, 16 },
        .{ 14, 17, 16, 23, 17, 17, 15 }, .{ 17, 17, 17, 31, 17, 17, 17 }, .{ 14, 4, 4, 4, 4, 4, 14 },
        .{ 7, 2, 2, 2, 18, 18, 12 },     .{ 17, 18, 20, 24, 20, 18, 17 }, .{ 16, 16, 16, 16, 16, 16, 31 },
        .{ 17, 27, 21, 21, 17, 17, 17 }, .{ 17, 25, 21, 19, 17, 17, 17 }, .{ 14, 17, 17, 17, 17, 17, 14 },
        .{ 30, 17, 17, 30, 16, 16, 16 }, .{ 14, 17, 17, 17, 21, 18, 13 }, .{ 30, 17, 17, 30, 20, 18, 17 },
        .{ 15, 16, 16, 14, 1, 1, 30 },   .{ 31, 4, 4, 4, 4, 4, 4 },       .{ 17, 17, 17, 17, 17, 17, 14 },
        .{ 17, 17, 17, 17, 17, 10, 4 },  .{ 17, 17, 17, 21, 21, 21, 10 }, .{ 17, 17, 10, 4, 10, 17, 17 },
        .{ 17, 17, 10, 4, 4, 4, 4 },     .{ 31, 1, 2, 4, 8, 16, 31 },     .{ 14, 17, 19, 21, 25, 17, 14 },
        .{ 4, 12, 4, 4, 4, 4, 14 },      .{ 14, 17, 1, 2, 4, 8, 31 },     .{ 30, 1, 1, 14, 1, 1, 30 },
        .{ 2, 6, 10, 18, 31, 2, 2 },     .{ 31, 16, 16, 30, 1, 1, 30 },   .{ 14, 16, 16, 30, 17, 17, 14 },
        .{ 31, 1, 2, 4, 8, 8, 8 },       .{ 14, 17, 17, 14, 17, 17, 14 }, .{ 14, 17, 17, 15, 1, 1, 14 },
        .{ 0, 0, 0, 0, 0, 6, 6 },        .{ 0, 0, 0, 0, 6, 6, 4 },        .{ 0, 6, 6, 0, 6, 6, 0 },
        .{ 0, 6, 6, 0, 6, 6, 4 },        .{ 4, 4, 4, 4, 4, 0, 4 },        .{ 0, 4, 4, 31, 4, 4, 0 },
        .{ 0, 0, 0, 31, 0, 0, 0 },       .{ 0, 0, 31, 0, 31, 0, 0 },      .{ 1, 2, 2, 4, 8, 8, 16 },
        .{ 16, 8, 8, 4, 2, 2, 1 },       .{ 4, 4, 4, 4, 4, 4, 4 },        .{ 0, 0, 0, 0, 0, 0, 31 },
        .{ 0, 0, 9, 22, 0, 0, 0 },       .{ 0, 21, 14, 31, 14, 21, 0 },   .{ 10, 10, 31, 10, 31, 10, 10 },
        .{ 14, 17, 23, 21, 23, 16, 14 }, .{ 25, 26, 2, 4, 8, 11, 19 },    .{ 2, 4, 8, 16, 8, 4, 2 },
        .{ 8, 4, 2, 1, 2, 4, 8 },        .{ 14, 8, 8, 8, 8, 8, 14 },      .{ 14, 2, 2, 2, 2, 2, 14 },
        .{ 2, 4, 8, 8, 8, 4, 2 },        .{ 8, 4, 2, 2, 2, 4, 8 },        .{ 14, 17, 1, 2, 4, 0, 4 },
    };
    for (chars, shapes) |ch, shape| for (shape, 0..) |row, y| {
        for (0..5) |x| {
            if (row & (@as(u5, 16) >> @intCast(x)) != 0) {
                const bit = y * 8 + x + 1;
                table[ch][bit / 32] |= @as(u32, 1) << @intCast(bit % 32);
            }
        }
    };
    // Extra punctuation and lowercase aliases provide compact foliage/edge marks.
    for (0..26) |i| table['a' + i] = table['A' + i];
    const extras = .{
        .{ @as(u8, '^'), [7]u5{ 4, 10, 17, 0, 0, 0, 0 } },
        .{ @as(u8, '\''), [7]u5{ 4, 4, 0, 0, 0, 0, 0 } },
        .{ @as(u8, '"'), [7]u5{ 10, 10, 0, 0, 0, 0, 0 } },
        .{ @as(u8, '`'), [7]u5{ 8, 4, 0, 0, 0, 0, 0 } },
        .{ @as(u8, '$'), [7]u5{ 4, 15, 20, 14, 5, 30, 4 } },
        .{ @as(u8, '&'), [7]u5{ 12, 18, 20, 8, 21, 18, 13 } },
        .{ @as(u8, '{'), [7]u5{ 2, 4, 4, 8, 4, 4, 2 } },
        .{ @as(u8, '}'), [7]u5{ 8, 4, 4, 2, 4, 4, 8 } },
    };
    inline for (extras) |entry| {
        for (entry[1], 0..) |row, y| for (0..5) |x| {
            if (row & (@as(u5, 16) >> @intCast(x)) != 0) {
                const bit = y * 8 + x + 1;
                table[entry[0]][bit / 32] |= @as(u32, 1) << @intCast(bit % 32);
            }
        };
    }
    return table;
}

pub fn rgb(r: u32, g: u32, b: u32) u32 {
    return r | g << 8 | b << 16;
}
pub fn label(cells: []Cell, x: usize, y: usize, text: []const u8, color: u32) void {
    if (y >= rows) return;
    for (text, 0..) |ch, i| {
        if (x + i >= cols) break;
        cells[y * cols + x + i].glyph = ch;
        cells[y * cols + x + i].foreground = color;
    }
}
test "cell interface and compact glyph orientation" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Cell));
    try std.testing.expectEqual(@as(usize, 1024), @sizeOf(@TypeOf(glyph_bits)));
    try std.testing.expectEqual(@as(u32, 0), glyph_bits[' '][0]);
    try std.testing.expect(glyph_bits['/'][0] != glyph_bits['\\'][0]);
    try std.testing.expect(glyph_bits['^'][0] != 0);
    for (33..127) |ch| try std.testing.expect(glyph_bits[ch][0] | glyph_bits[ch][1] != 0);
}
