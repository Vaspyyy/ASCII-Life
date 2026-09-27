const std = @import("std");

pub const size: f32 = 8192.0;
pub const sea_level: f32 = 80.0;
pub const spawn_x: f32 = 80.0;
pub const spawn_z: f32 = -370.0;
pub const spawn_yaw: f32 = 0.0;
pub const default_seed: u64 = 0xa11fe;

const half_size: f32 = size * 0.5;
const spacing: f32 = 8.0;
const sample_side: usize = 1025;
const sample_count: usize = sample_side * sample_side;
const height_quantum: f32 = 0.25;
const maximum_height: f32 = 4095.75;

pub const Tree = struct {
    x: f32,
    z: f32,
    ground: f32,
    height: f32,
    radius: f32,
    tint: u32,
    /// 0 is a conifer, 1 is a broadleaf tree.
    kind: u32,
};

/// A finite, seed-stable regional heightfield with an 8 m cached lattice.
/// The cache is transient; all samples are reconstructed from the seed and
/// absolute lattice coordinates during initialization.
pub const Terrain = struct {
    allocator: std.mem.Allocator,
    seed: u64,
    samples: []u16,

    pub fn init(allocator: std.mem.Allocator, seed: u64) !Terrain {
        @setFloatMode(.strict);
        const samples = try allocator.alloc(u16, sample_count);
        errdefer allocator.free(samples);

        for (0..sample_side) |iz| {
            const z = @as(f32, @floatFromInt(iz)) * spacing - half_size;
            const row = samples[iz * sample_side ..][0..sample_side];
            const frame = rowFrame(seed, z);
            for (0..sample_side) |ix| {
                const x = @as(f32, @floatFromInt(ix)) * spacing - half_size;
                row[ix] = quantizeHeight(generateHeight(seed, x, z, frame));
            }
        }

        return .{ .allocator = allocator, .seed = seed, .samples = samples };
    }

    pub fn deinit(self: *Terrain) void {
        self.allocator.free(self.samples);
        self.* = undefined;
    }

    /// Bilinear sample of the cached 8 m heightfield. Coordinates outside the
    /// finite region use the nearest edge, so the field remains bounded.
    pub fn height(self: *const Terrain, x: f32, z: f32) f32 {
        @setFloatMode(.strict);
        const cx = std.math.clamp(x, -half_size, half_size);
        const cz = std.math.clamp(z, -half_size, half_size);
        const sx = (cx + half_size) / spacing;
        const sz = (cz + half_size) / spacing;
        const x0 = @min(@as(usize, @intFromFloat(@floor(sx))), sample_side - 1);
        const z0 = @min(@as(usize, @intFromFloat(@floor(sz))), sample_side - 1);
        const x1 = @min(x0 + 1, sample_side - 1);
        const z1 = @min(z0 + 1, sample_side - 1);
        const tx = sx - @as(f32, @floatFromInt(x0));
        const tz = sz - @as(f32, @floatFromInt(z0));

        const h00 = decodeHeight(self.samples[z0 * sample_side + x0]);
        const h10 = decodeHeight(self.samples[z0 * sample_side + x1]);
        const h01 = decodeHeight(self.samples[z1 * sample_side + x0]);
        const h11 = decodeHeight(self.samples[z1 * sample_side + x1]);
        const north = h00 + (h10 - h00) * tx;
        const south = h01 + (h11 - h01) * tx;
        return north + (south - north) * tz;
    }

    /// Upward-facing normal estimated from the cached field.
    pub fn normal(self: *const Terrain, x: f32, z: f32) [3]f32 {
        @setFloatMode(.strict);
        const dx = (self.height(x + spacing, z) - self.height(x - spacing, z)) / (spacing * 2.0);
        const dz = (self.height(x, z + spacing) - self.height(x, z - spacing)) / (spacing * 2.0);
        const length = @sqrt(dx * dx + 1.0 + dz * dz);
        return .{ -dx / length, 1.0 / length, -dz / length };
    }

    /// Generate a stable tree from its signed 24 m lattice identity. Grid
    /// coordinates are world identities, not indices into a render chunk.
    pub fn tree(self: *const Terrain, gx: i32, gz: i32) ?Tree {
        @setFloatMode(.strict);
        const ix: i64 = gx;
        const iz: i64 = gz;
        const identity = hash2(self.seed, ix, iz, 0x747265652d696465);
        const ox = signedUnit(hash2(self.seed, ix, iz, 0x747265652d6a6978)) * 8.0;
        const oz = signedUnit(hash2(self.seed, ix, iz, 0x747265652d6a697a)) * 8.0;
        const x = @as(f32, @floatFromInt(gx)) * 24.0 + ox;
        const z = @as(f32, @floatFromInt(gz)) * 24.0 + oz;
        if (x < -half_size or x > half_size or z < -half_size or z > half_size) return null;

        const ground = self.height(x, z);
        if (ground <= sea_level + 4.0 or ground > 780.0) return null;
        const up = self.normal(x, z)[1];
        if (up < 0.68) return null;

        const broad_forest = valueNoise2(self.seed, x, z, 720.0, 0x666f726573742d61);
        const local_forest = valueNoise2(self.seed, x, z, 240.0, 0x666f726573742d62);
        const forest_density = std.math.clamp(0.60 + 0.27 * broad_forest + 0.17 * local_forest, 0.16, 0.96);
        const choice = unitFloat(identity);
        if (choice > forest_density * 0.74) return null;

        const species_roll = hash2(self.seed, ix, iz, 0x747265652d6b696e);
        const kind: u32 = if (ground < 380.0 and species_roll % 100 < 39) 1 else 0;
        const size_roll = unitFloat(hash2(self.seed, ix, iz, 0x747265652d73697a));
        const tree_height = if (kind == 0) 10.0 + 12.0 * size_roll else 7.0 + 8.0 * size_roll;
        const radius = if (kind == 0) 2.3 + 3.5 * size_roll else 3.0 + 4.2 * size_roll;
        const tint_roll = hash2(self.seed, ix, iz, 0x747265652d74696e);
        const red: u32 = 18 + @as(u32, @intCast(tint_roll & 15));
        const green: u32 = 57 + @as(u32, @intCast((tint_roll >> 8) & 43));
        const blue: u32 = 30 + @as(u32, @intCast((tint_roll >> 16) & 19));

        return .{
            .x = x,
            .z = z,
            .ground = ground,
            .height = tree_height,
            .radius = radius,
            .tint = red | (green << 8) | (blue << 16),
            .kind = kind,
        };
    }
};

const RowFrame = struct {
    center_x: f32,
    lake_half_width: f32,
    ridge_center: [2]f32,
    ridge_strength: [2]f32,
    foothill_center: [2]f32,
    foothill_strength: [2]f32,
};

fn rowFrame(seed: u64, z: f32) RowFrame {
    @setFloatMode(.strict);
    // This geographic origin must not move when the starting camera changes.
    const anchor: f32 = -450.0;
    const center_x = 450.0 +
        390.0 * (valueNoise1(seed, z, 2100.0, 0x76616c6c65792d31) - valueNoise1(seed, anchor, 2100.0, 0x76616c6c65792d31)) +
        170.0 * (valueNoise1(seed, z, 760.0, 0x76616c6c65792d32) - valueNoise1(seed, anchor, 760.0, 0x76616c6c65792d32));
    const lake_half_width = 320.0 +
        88.0 * valueNoise1(seed, z, 920.0, 0x6c616b652d776964) +
        38.0 * valueNoise1(seed, z, 310.0, 0x6c616b652d646574);

    var frame: RowFrame = .{
        .center_x = center_x,
        .lake_half_width = lake_half_width,
        .ridge_center = undefined,
        .ridge_strength = undefined,
        .foothill_center = undefined,
        .foothill_strength = undefined,
    };
    inline for (0..2) |side| {
        const tag: u64 = if (side == 0) 0x72696467652d6c66 else 0x72696467652d7274;
        const ridge_noise = 0.5 + 0.5 * valueNoise1(seed, z, 390.0, tag ^ 0x72696467652d706b);
        const ridge_rhythm = 0.25 + 0.75 * (0.5 + 0.5 * valueNoise1(seed, z, 250.0, tag ^ 0x72696467652d7268));
        frame.ridge_center[side] = 1380.0 +
            155.0 * valueNoise1(seed, z, 670.0, tag ^ 0x72696467652d6f66) +
            90.0 * valueNoise1(seed, z, 245.0, tag ^ 0x72696467652d6465);
        frame.ridge_strength[side] = (250.0 + 570.0 * ridge_noise) * (0.78 + 0.22 * ridge_rhythm);
        frame.foothill_center[side] = 790.0 + 95.0 * valueNoise1(seed, z, 520.0, tag ^ 0x666f6f7468696c6c);
        frame.foothill_strength[side] = 50.0 + 160.0 * (0.5 + 0.5 * valueNoise1(seed, z, 310.0, tag ^ 0x666f6f742d737472));
    }
    return frame;
}

fn generateHeight(seed: u64, x: f32, z: f32, frame: RowFrame) f32 {
    @setFloatMode(.strict);
    const offset = x - frame.center_x;
    const side: usize = if (offset < 0.0) 0 else 1;
    const distance = @abs(offset);
    const lake_edge = frame.lake_half_width;
    var h: f32 = undefined;
    var detail_scale: f32 = 1.0;

    if (distance <= lake_edge) {
        const across = distance / lake_edge;
        h = 55.0 + 33.0 * across * across;
        detail_scale = 0.45;
    } else {
        const q = distance - lake_edge;
        const q_for_slope = @min(q, 2750.0);
        h = 90.0 + 0.075 * q_for_slope + 0.00007 * q_for_slope * q_for_slope;

        const ridge_delta = @abs(distance - frame.ridge_center[side]);
        const ridge_u = std.math.clamp(1.0 - ridge_delta / 470.0, 0.0, 1.0);
        const ridge_shape = ridge_u * ridge_u * (3.0 - 2.0 * ridge_u);
        h += frame.ridge_strength[side] * ridge_shape;

        const foot_delta = @abs(distance - frame.foothill_center[side]);
        const foot_u = std.math.clamp(1.0 - foot_delta / 260.0, 0.0, 1.0);
        const foot_shape = foot_u * foot_u * (3.0 - 2.0 * foot_u);
        h += frame.foothill_strength[side] * foot_shape;
        detail_scale = 0.50 + 0.50 * std.math.clamp(distance / 1200.0, 0.0, 1.0);
    }

    const broad = valueNoise2(seed, x, z, 430.0, 0x7465727261696e31);
    const rolling = valueNoise2(seed, x, z, 145.0, 0x7465727261696e32);
    const surface = valueNoise2(seed, x, z, 43.0, 0x7465727261696e33);
    h += detail_scale * (11.0 * broad + 4.0 * rolling + 1.25 * surface);
    return std.math.clamp(h, 0.0, maximum_height);
}

fn quantizeHeight(h: f32) u16 {
    @setFloatMode(.strict);
    return @intFromFloat(@round(h / height_quantum));
}

fn decodeHeight(value: u16) f32 {
    return @as(f32, @floatFromInt(value)) * height_quantum;
}

fn fade(t: f32) f32 {
    @setFloatMode(.strict);
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

fn mix(a: f32, b: f32, t: f32) f32 {
    @setFloatMode(.strict);
    return a + (b - a) * t;
}

fn latticeCoordinate(v: f32, scale: f32) struct { base: i64, fraction: f32 } {
    @setFloatMode(.strict);
    const p = v / scale;
    const floored = @floor(p);
    return .{ .base = @intFromFloat(floored), .fraction = p - floored };
}

fn valueNoise1(seed: u64, x: f32, scale: f32, tag: u64) f32 {
    @setFloatMode(.strict);
    const grid = latticeCoordinate(x, scale);
    const a = unitFloat(hash2(seed, grid.base, 0, tag));
    const b = unitFloat(hash2(seed, grid.base + 1, 0, tag));
    return mix(a, b, fade(grid.fraction)) * 2.0 - 1.0;
}

fn valueNoise2(seed: u64, x: f32, z: f32, scale: f32, tag: u64) f32 {
    @setFloatMode(.strict);
    const gx = latticeCoordinate(x, scale);
    const gz = latticeCoordinate(z, scale);
    const tx = fade(gx.fraction);
    const tz = fade(gz.fraction);
    const a = unitFloat(hash2(seed, gx.base, gz.base, tag));
    const b = unitFloat(hash2(seed, gx.base + 1, gz.base, tag));
    const c = unitFloat(hash2(seed, gx.base, gz.base + 1, tag));
    const d = unitFloat(hash2(seed, gx.base + 1, gz.base + 1, tag));
    return (mix(mix(a, b, tx), mix(c, d, tx), tz) * 2.0) - 1.0;
}

fn hash2(seed: u64, x: i64, z: i64, tag: u64) u64 {
    var value = seed ^ tag;
    value ^= @as(u64, @bitCast(x)) *% 0x9e3779b185ebca87;
    value = std.math.rotl(u64, value, 27);
    value ^= @as(u64, @bitCast(z)) *% 0xc2b2ae3d27d4eb4f;
    value = (value ^ (value >> 30)) *% 0xbf58476d1ce4e5b9;
    value = (value ^ (value >> 27)) *% 0x94d049bb133111eb;
    return value ^ (value >> 31);
}

fn unitFloat(value: u64) f32 {
    @setFloatMode(.strict);
    return @as(f32, @floatFromInt(value >> 40)) * (1.0 / 16_777_216.0);
}

fn signedUnit(value: u64) f32 {
    @setFloatMode(.strict);
    return unitFloat(value) * 2.0 - 1.0;
}

fn sampleFingerprint(samples: []const u16) u64 {
    var fingerprint: u64 = 0xcbf29ce484222325;
    for (samples) |sample| {
        fingerprint = (fingerprint ^ @as(u64, sample & 0xff)) *% 0x100000001b3;
        fingerprint = (fingerprint ^ @as(u64, sample >> 8)) *% 0x100000001b3;
    }
    return fingerprint;
}

test "heightfield cache reproduces the same seed and distinguishes world identities" {
    var a = try Terrain.init(std.testing.allocator, default_seed);
    defer a.deinit();
    var b = try Terrain.init(std.testing.allocator, default_seed);
    defer b.deinit();
    var other = try Terrain.init(std.testing.allocator, default_seed + 1);
    defer other.deinit();

    try std.testing.expectEqualSlices(u16, a.samples, b.samples);
    try std.testing.expect(!std.mem.eql(u16, a.samples, other.samples));
    try std.testing.expectEqual(@as(u64, 0x19136d4cd87eabe7), sampleFingerprint(a.samples));
    try std.testing.expectApproxEqAbs(a.height(spawn_x, spawn_z), b.height(spawn_x, spawn_z), 0.0);

    const spawn_height = a.height(spawn_x, spawn_z);
    try std.testing.expect(spawn_height >= sea_level and spawn_height <= 115.0);
    try std.testing.expect(a.height(450.0, spawn_z) < sea_level);
    var ridge_peak: f32 = 0.0;
    for (0..501) |ix| {
        const x = -1200.0 + @as(f32, @floatFromInt(ix)) * spacing;
        ridge_peak = @max(ridge_peak, a.height(x, spawn_z));
    }
    try std.testing.expect(ridge_peak > 600.0);
}

test "heightfield edges are finite and normals point upward" {
    var terrain = try Terrain.init(std.testing.allocator, 42);
    defer terrain.deinit();

    try std.testing.expect(terrain.height(-half_size, -half_size) >= 0.0);
    try std.testing.expectEqual(terrain.height(-half_size, half_size), terrain.height(-half_size - 1000.0, half_size + 1000.0));
    try std.testing.expectEqual(terrain.height(half_size, -half_size), terrain.height(half_size + 1000.0, -half_size - 1000.0));
    const n = terrain.normal(0.0, 0.0);
    try std.testing.expect(n[1] > 0.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), n[0] * n[0] + n[1] * n[1] + n[2] * n[2], 0.0001);
}

test "tree identities remain stable and use the terrain surface" {
    var terrain = try Terrain.init(std.testing.allocator, 0x747265652d736565);
    defer terrain.deinit();

    var found: ?Tree = null;
    var coord: [2]i32 = .{ 0, 0 };
    for (0..121) |iz| {
        const gz: i32 = @as(i32, @intCast(iz)) - 60;
        for (0..121) |ix| {
            const gx: i32 = @as(i32, @intCast(ix)) - 60;
            if (terrain.tree(gx, gz)) |candidate| {
                found = candidate;
                coord = .{ gx, gz };
                break;
            }
        }
        if (found != null) break;
    }
    try std.testing.expect(found != null);
    const first = found.?;
    const again = terrain.tree(coord[0], coord[1]).?;
    try std.testing.expectEqual(first, again);
    try std.testing.expectApproxEqAbs(terrain.height(first.x, first.z), first.ground, 0.01);
    try std.testing.expect(first.kind <= 1);
}
