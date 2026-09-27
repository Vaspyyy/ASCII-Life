const std = @import("std");

/// Matches std430: three independent cell properties, padded to 16 bytes.
pub const Cell = extern struct { glyph: u32, foreground: u32, background: u32, pad: u32 = 0 };
pub const cols = 160;
pub const rows = 90;
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
    return table;
}
fn rgb(r: u32, g: u32, b: u32) u32 {
    return r | (g << 8) | (b << 16);
}
fn mix(a: u32, b: u32, t: u32) u32 {
    var result: u32 = 0;
    inline for (0..3) |channel| {
        const shift = channel * 8;
        const av = (a >> shift) & 255;
        const bv = (b >> shift) & 255;
        result |= ((av * (255 - t) + bv * t) / 255) << shift;
    }
    return result;
}
fn hash(x: u32, y: u32) u32 {
    var h = x *% 0x9e3779b9 ^ y *% 0x85ebca6b ^ 0x51f15e;
    h = (h ^ (h >> 16)) *% 0x7feb352d;
    return h ^ (h >> 15);
}
fn ridge(x: i32, spacing: i32, phase: i32, base: i32, amplitude: i32) i32 {
    const p = @mod(x + phase, spacing);
    return base + @divTrunc(@as(i32, @intCast(@abs(p - @divTrunc(spacing, 2)))) * amplitude, @divTrunc(spacing, 2));
}
fn label(cells: []Cell, x: usize, y: usize, text: []const u8, color: u32) void {
    for (text, 0..) |ch, i| {
        if (x + i >= cols) break;
        cells[y * cols + x + i].glyph = ch;
        cells[y * cols + x + i].foreground = color;
    }
}
/// A fixed graphic test composition, not terrain or world generation.
/// Tick is explicit: the same input produces identical cells.
pub fn fill(cells: []Cell, tick: u32, paused: bool) void {
    std.debug.assert(cells.len == cols * rows);
    for (0..rows) |yy| for (0..cols) |xx| {
        const x: i32 = @intCast(xx);
        const y: i32 = @intCast(yy);
        const h = hash(@intCast(xx), @intCast(yy));
        var bg = mix(rgb(13, 19, 43), rgb(226, 137, 115), @intCast(@min(yy * 255 / 56, 255)));
        var fg = mix(bg, rgb(251, 221, 169), 35);
        var glyph: u32 = if (h % 11 == 0) '.' else ' ';
        if (yy < 29 and h % 157 == 0) {
            glyph = '+';
            fg = rgb(183, 205, 215);
        }
        // A small sun and broad layered silhouettes expose edge-direction glyphs.
        const dx = x - 113;
        const dy = y - 29;
        if (dx * dx + dy * dy < 100) {
            bg = rgb(255, 214, 154);
            fg = rgb(255, 231, 184);
            glyph = if (h % 3 == 0) ':' else ' ';
        }
        const far = ridge(x, 67, 14, 32, 15);
        const near = ridge(x, 53, 33, 42, 12);
        if (y >= far) {
            bg = rgb(84, 77, 108);
            fg = rgb(134, 111, 137);
            glyph = if (y == far) '/' else '.';
        }
        if (y >= near) {
            bg = rgb(43, 58, 83);
            fg = rgb(72, 88, 109);
            glyph = if (h % 7 == 0) '/' else ':';
        }
        if (y >= 57) {
            bg = mix(rgb(65, 86, 111), rgb(15, 32, 53), @intCast((yy - 57) * 255 / 32));
            fg = mix(bg, rgb(126, 152, 165), 90);
            glyph = if ((h +% tick / 8) % 7 == 0) '~' else '-';
            const spread = 3 + @divTrunc(y - 57, 2);
            if (@abs(x - 113) < @as(u32, @intCast(spread)) and h % 4 < 2) {
                fg = mix(rgb(204, 142, 118), rgb(248, 198, 137), h % 150);
                glyph = '=';
            }
        }
        // Foreground bank and tiny conifer silhouettes are fixed test geometry.
        const bank = 77 + @divTrunc(x, 18);
        if (y > bank) {
            bg = rgb(10, 25, 34);
            fg = rgb(34, 65, 67);
            glyph = if (h % 3 == 0) '/' else ',';
        }
        for ([_]i32{ 8, 20, 32, 145, 153 }, 0..) |tx, i| {
            const base: i32 = if (i < 3) 79 else 85;
            const top: i32 = base - @as(i32, @intCast(19 + (i * 7) % 13));
            if (y >= top and y < base and @abs(x - tx) <= @as(u32, @intCast(@divTrunc(y - top, 4)))) {
                bg = rgb(9, 29, 37);
                fg = rgb(37, 64, 66);
                glyph = if (x < tx) '/' else '\\';
            }
        }
        cells[yy * cols + xx] = .{ .glyph = glyph, .foreground = fg, .background = bg };
    };
    label(cells, 7, 5, "A LIFE", rgb(245, 222, 181));
    label(cells, 7, 8, "NATIVE GLYPH STUDY / 00", rgb(157, 177, 193));
    label(cells, 7, 84, " .,:;+=*#@  / \\ | -", rgb(202, 190, 160));
    label(cells, 7, 87, if (paused) "SPACE RESUME   F11 FULLSCREEN   ESC CLOSE" else "SPACE PAUSE    F11 FULLSCREEN   ESC CLOSE", rgb(149, 176, 173));
}

test "cell layout and glyph orientation" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Cell));
    try std.testing.expectEqual(@as(u32, 0), glyph_bits[' '][0]);
    try std.testing.expect(glyph_bits['/'][0] != glyph_bits['\\'][0]);
    try std.testing.expect(glyph_bits['A'][0] != 0);
}
test "scene is repeatable and animation affects only explicit tick" {
    var a: [cols * rows]Cell = undefined;
    var b: [cols * rows]Cell = undefined;
    fill(&a, 0, false);
    fill(&b, 0, false);
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&a), std.mem.sliceAsBytes(&b));
    fill(&b, 64, false);
    try std.testing.expect(!std.mem.eql(u8, std.mem.sliceAsBytes(&a), std.mem.sliceAsBytes(&b)));
    for (a) |cell| try std.testing.expect(cell.glyph < 128);
}

test "fixed tick-zero visual regression fingerprint" {
    var cells: [cols * rows]Cell = undefined;
    fill(&cells, 0, false);
    var fingerprint: u64 = 0xcbf29ce484222325;
    for (cells) |cell| {
        for ([_]u32{ cell.glyph, cell.foreground, cell.background }) |value| {
            inline for (0..4) |i| {
                fingerprint = (fingerprint ^ ((value >> (i * 8)) & 255)) *% 0x100000001b3;
            }
        }
    }
    try std.testing.expectEqual(@as(u64, 0x76a0d685d17a9a7b), fingerprint);
}
