const std = @import("std");
const hydro_mod = @import("hydrology.zig");
pub const climate_mod = @import("climate.zig");
const streaming = @import("streaming.zig");

pub const size: f32 = 8192.0;
pub const sea_level: f32 = 80.0;
pub const spawn_x: f32 = 80.0;
pub const spawn_z: f32 = -370.0;
pub const spawn_yaw: f32 = 0.0;
pub const default_seed: u64 = 0xa11fe;
const half_size: f32 = size * 0.5;
const spacing: f32 = 8.0;
pub const sample_side: usize = 257;
const sample_count: usize = sample_side * sample_side;
const macro_spacing: f32 = 32.0;
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
pub const Place = struct { x: f32 = spawn_x, z: f32 = spawn_z, yaw: f32 = spawn_yaw, score: u16 = 0 };
pub const Water = hydro_mod.Sample;

/// Compact regional causes plus a bounded, disposable cache of local detail.
pub const Terrain = struct {
    allocator: std.mem.Allocator,
    seed: u64,
    generation_seed: u64,
    repaired: bool,
    samples: []u16,
    row_frames: []RowFrame,
    climate: climate_mod.Climate,
    hydro: hydro_mod.Hydro,
    cache: *streaming.Cache,
    start: Place = .{},
    settlement: Place = .{},

    pub fn init(allocator: std.mem.Allocator, seed: u64) !Terrain {
        const samples = try allocator.alloc(u16, sample_count);
        errdefer allocator.free(samples);
        generateMacro(seed, samples);
        const generation_seed = try repairMacro(seed, samples);
        const row_frames = try allocator.alloc(RowFrame, 1025);
        errdefer allocator.free(row_frames);
        for (row_frames, 0..) |*frame, i| frame.* = rowFrame(generation_seed, @as(f32, @floatFromInt(i)) * 8 - half_size);
        var climate = try climate_mod.Climate.init(allocator, generation_seed, samples);
        errdefer climate.deinit();
        var hydro = try hydro_mod.Hydro.init(allocator, generation_seed, samples, climate.rainfall);
        errdefer hydro.deinit();
        try hydro.validate();
        const cache = try allocator.create(streaming.Cache);
        errdefer allocator.destroy(cache);
        cache.* = try streaming.Cache.init(allocator);
        errdefer cache.deinit();
        var result = Terrain{ .allocator = allocator, .seed = seed, .generation_seed = generation_seed, .repaired = generation_seed != seed, .samples = samples, .row_frames = row_frames, .climate = climate, .hydro = hydro, .cache = cache };
        result.choosePlaces();
        result.refineStart();
        return result;
    }

    pub fn deinit(self: *Terrain) void {
        self.cache.deinit();
        self.allocator.destroy(self.cache);
        self.hydro.deinit();
        self.climate.deinit();
        self.allocator.free(self.samples);
        self.allocator.free(self.row_frames);
        self.* = undefined;
    }

    pub fn height(self: *const Terrain, x: f32, z: f32) f32 {
        return self.cache.height(self, generateDetail, x, z);
    }

    pub fn macroHeight(self: *const Terrain, x: f32, z: f32) f32 {
        const sx = std.math.clamp((x + half_size) / macro_spacing, 0, 256);
        const sz = std.math.clamp((z + half_size) / macro_spacing, 0, 256);
        const ix: usize = @intFromFloat(@floor(sx));
        const iz: usize = @intFromFloat(@floor(sz));
        const nx = @min(ix + 1, 256);
        const nz = @min(iz + 1, 256);
        const tx = sx - @as(f32, @floatFromInt(ix));
        const tz = sz - @as(f32, @floatFromInt(iz));
        return mix(mix(decodeHeight(self.samples[iz * sample_side + ix]), decodeHeight(self.samples[iz * sample_side + nx]), tx), mix(decodeHeight(self.samples[nz * sample_side + ix]), decodeHeight(self.samples[nz * sample_side + nx]), tx), tz);
    }

    pub fn water(self: *const Terrain, x: f32, z: f32) Water {
        return self.hydro.sample(x, z);
    }

    pub fn standingHeight(self: *const Terrain, x: f32, z: f32) f32 {
        const bed = self.height(x, z);
        const w = self.water(x, z);
        return if (w.wet) @max(bed, w.water_y) else bed;
    }

    /// Only visual sampling uses distant macro LOD. Physical positions and tree
    /// identities always use the same fine field, regardless of view distance.
    pub fn renderHeight(self: *const Terrain, x: f32, z: f32, depth: f32, w: Water) f32 {
        if (depth <= 800) return self.height(x, z);
        const coarse = carve(self.macroHeight(x, z), w);
        if (depth >= 1000) return coarse;
        return mix(self.height(x, z), coarse, (depth - 800) / 200);
    }

    pub fn geography(self: *const Terrain, x: f32, z: f32, w: Water) climate_mod.Sample {
        const distance: ?f32 = if (w.wet) 0 else if (std.math.isFinite(w.river_distance)) @max(0, w.river_distance - w.river_width * 0.5) else null;
        var geo = self.climate.sampleWithWater(x, z, distance);
        if (w.wet) {
            geo.biome = .water;
            geo.resources = .{ .fertility = 0, .timber = 0, .stone = 0, .ore = 0 };
        }
        return geo;
    }

    pub fn normal(self: *const Terrain, x: f32, z: f32) [3]f32 {
        const dx = (self.height(x + spacing, z) - self.height(x - spacing, z)) / (spacing * 2.0);
        const dz = (self.height(x, z + spacing) - self.height(x, z - spacing)) / (spacing * 2.0);
        const length = @sqrt(dx * dx + 1.0 + dz * dz);
        return .{ -dx / length, 1.0 / length, -dz / length };
    }

    pub fn renderNormal(self: *const Terrain, x: f32, z: f32, depth: f32) [3]f32 {
        if (depth < 1000) return self.normal(x, z);
        const dx = (self.macroHeight(x + 16, z) - self.macroHeight(x - 16, z)) / 32;
        const dz = (self.macroHeight(x, z + 16) - self.macroHeight(x, z - 16)) / 32;
        const magnitude = @sqrt(dx * dx + 1 + dz * dz);
        return .{ -dx / magnitude, 1 / magnitude, -dz / magnitude };
    }

    pub fn peak(self: *const Terrain) f32 {
        var highest: f32 = 0;
        for (0..1025) |iz| for (0..1025) |ix| {
            highest = @max(highest, self.height(@as(f32, @floatFromInt(ix)) * 8 - half_size, @as(f32, @floatFromInt(iz)) * 8 - half_size));
        };
        return highest;
    }

    fn choosePlaces(self: *Terrain) void {
        var best: f32 = -1;
        var strongest: f32 = -1;
        // Candidates derive from drainage, slope, food potential, and water.
        // This reserves a plausible future village site; it creates no village.
        for (2..sample_side - 2) |iz| for (2..sample_side - 2) |ix| {
            const x = @as(f32, @floatFromInt(ix)) * macro_spacing - half_size;
            const z = @as(f32, @floatFromInt(iz)) * macro_spacing - half_size;
            const w = self.water(x, z);
            if (w.kind != .river or w.river_strength < 0.1) continue;
            const bank = w.river_width * 0.5 + 20;
            const bx = x + w.flow_z * bank;
            const bz = z - w.flow_x * bank;
            const bw = self.water(bx, bz);
            if (bw.wet or @abs(bx) > 3800 or @abs(bz) > 3800) continue;
            const h = self.macroHeight(bx, bz);
            const grade = @abs(self.macroHeight(bx + 32, bz) - self.macroHeight(bx - 32, bz)) / 64 + @abs(self.macroHeight(bx, bz + 32) - self.macroHeight(bx, bz - 32)) / 64;
            const geo = self.geography(bx, bz, bw);
            const suitability = @as(f32, @floatFromInt(geo.resources.fertility)) * @max(0, 1 - grade * 3) / (1 + @max(0, h - 150) / 200);
            const place = Place{ .x = bx, .z = bz, .yaw = std.math.atan2(w.flow_x, w.flow_z), .score = @intFromFloat(@max(0, suitability)) };
            if (suitability > best) {
                best = suitability;
                self.settlement = place;
            }
            const vista = w.river_strength * 100 / (1 + @abs(h - 135) / 100) / (1 + grade) / (1 + @abs(z) / 1800);
            if (vista > strongest) {
                strongest = vista;
                self.start = place;
            }
        };
    }

    fn refineStart(self: *Terrain) void {
        const original = self.start;
        const fx = @sin(original.yaw);
        const fz = @cos(original.yaw);
        var best_score: f32 = -1e6;
        for (0..17) |step| {
            const offset = (@as(f32, @floatFromInt(step)) - 8) * 12;
            const x = original.x + fx * offset;
            const z = original.z + fz * offset;
            const water_here = self.water(x, z);
            const bank_distance = water_here.river_distance - water_here.river_width * 0.5;
            if (water_here.wet or bank_distance < 8 or bank_distance > 40 or self.normal(x, z)[1] < 0.88) continue;
            var clearance: f32 = 60;
            const gx: i32 = @intFromFloat(@floor(x / 24));
            const gz: i32 = @intFromFloat(@floor(z / 24));
            var dz: i32 = -3;
            while (dz <= 3) : (dz += 1) {
                var dx: i32 = -3;
                while (dx <= 3) : (dx += 1) {
                    if (self.tree(gx + dx, gz + dz)) |t| {
                        const tx = t.x - x;
                        const tz = t.z - z;
                        if (tx * fx + tz * fz > -4) clearance = @min(clearance, @sqrt(tx * tx + tz * tz) - t.radius);
                    }
                }
            }
            const score = clearance - @abs(offset) * 0.02;
            if (score > best_score) {
                best_score = score;
                self.start.x = x;
                self.start.z = z;
                // Look slightly into the channel while retaining its downstream view.
                self.start.yaw = original.yaw - 0.20;
            }
        }
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
        const water_here = self.water(x, z);
        if (water_here.wet or ground > 900.0) return null;
        const geo = self.geography(x, z, water_here);
        if (geo.resources.timber < 25) return null;
        const up = self.normal(x, z)[1];
        if (up < 0.68) return null;

        const broad_forest = valueNoise2(self.seed, x, z, 720.0, 0x666f726573742d61);
        const local_forest = valueNoise2(self.seed, x, z, 240.0, 0x666f726573742d62);
        const forest_density = std.math.clamp((0.35 + 0.20 * broad_forest + 0.17 * local_forest) * @as(f32, @floatFromInt(geo.resources.timber)) / 100, 0.02, 0.94);
        const choice = unitFloat(identity);
        if (choice > forest_density * 0.74) return null;

        const species_roll = hash2(self.seed, ix, iz, 0x747265652d6b696e);
        const kind: u32 = if (geo.temperature_tenths_c > 90 and species_roll % 100 < 65) 1 else 0;
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

fn generateMacro(seed: u64, samples: []u16) void {
    for (0..sample_side) |iz| {
        const z = @as(f32, @floatFromInt(iz)) * macro_spacing - half_size;
        const frame = rowFrame(seed, z);
        for (0..sample_side) |ix| {
            const x = @as(f32, @floatFromInt(ix)) * macro_spacing - half_size;
            samples[iz * sample_side + ix] = quantizeHeight(generateHeight(seed, x, z, frame));
        }
    }
}

fn validMacro(samples: []const u16) bool {
    var water_count: usize = 0;
    var peak_value: u16 = 0;
    for (samples) |v| {
        if (v < 320) water_count += 1;
        peak_value = @max(peak_value, v);
    }
    return water_count > samples.len / 100 and water_count < samples.len / 2 and peak_value > 2000;
}

fn repairMacro(seed: u64, samples: []u16) !u64 {
    if (validMacro(samples)) return seed;
    for (1..9) |attempt| {
        const candidate = hash2(seed, @intCast(attempt), 0, 0x7265706169722d32);
        generateMacro(candidate, samples);
        if (validMacro(samples)) return candidate;
    }
    return error.InvalidMacroGeography;
}

fn generateDetail(context: *const anyopaque, x: f32, z: f32) f32 {
    const self: *const Terrain = @ptrCast(@alignCast(context));
    const raw = generateHeight(self.generation_seed, x, z, self.row_frames[@min(1024, @as(usize, @intFromFloat((z + half_size) / 8)))]);
    return carve(raw, self.water(x, z));
}

fn carve(raw: f32, w: Water) f32 {
    if (w.kind == .ocean or w.kind == .lake) return raw;
    if (!std.math.isFinite(w.river_distance) or w.river_width <= 0) return raw;
    const half_width = w.river_width * 0.5;
    const bank_distance = @max(0, w.river_distance - half_width);
    if (bank_distance > 24) return raw;
    const channel_floor = @max(0, w.water_y - 2.0 - w.river_strength * 3);
    const blend = fade(std.math.clamp(bank_distance / 24, 0, 1));
    return @min(raw, mix(channel_floor, @max(raw, channel_floor), blend));
}

test "macro identity, deterministic repair and riverbank starting site" {
    var a = try Terrain.init(std.testing.allocator, default_seed);
    defer a.deinit();
    var b = try Terrain.init(std.testing.allocator, default_seed);
    defer b.deinit();
    try std.testing.expectEqualSlices(u16, a.samples, b.samples);
    try std.testing.expectEqual(a.start, b.start);
    try std.testing.expect(validMacro(a.samples));
    try std.testing.expect(!a.water(a.start.x, a.start.z).wet);
    try std.testing.expect(a.settlement.score > 0);
    @memset(b.samples, 0);
    const repaired_seed = try repairMacro(default_seed, b.samples);
    try std.testing.expect(repaired_seed != default_seed);
    try std.testing.expect(validMacro(b.samples));
    const fingerprint = sampleFingerprint(b.samples);
    @memset(b.samples, 0);
    try std.testing.expectEqual(repaired_seed, try repairMacro(default_seed, b.samples));
    try std.testing.expectEqual(fingerprint, sampleFingerprint(b.samples));
}

test "fine terrain and tree identities survive cache eviction" {
    var terrain = try Terrain.init(std.testing.allocator, 42);
    defer terrain.deinit();
    const x: f32 = -732;
    const z: f32 = -582;
    const before = terrain.height(x, z);
    var tree_before: ?Tree = null;
    var tree_x: i32 = 0;
    var tree_z: i32 = 0;
    const center_x: i32 = @intFromFloat(@floor(terrain.start.x / 24));
    const center_z: i32 = @intFromFloat(@floor(terrain.start.z / 24));
    search: for (0..25) |iz| {
        for (0..25) |ix| {
            const gx = center_x + @as(i32, @intCast(ix)) - 12;
            const gz = center_z + @as(i32, @intCast(iz)) - 12;
            if (terrain.tree(gx, gz)) |tree| {
                tree_before = tree;
                tree_x = gx;
                tree_z = gz;
                break :search;
            }
        }
    }
    try std.testing.expect(tree_before != null);
    for (0..16) |iz| for (0..16) |ix| {
        _ = terrain.height(-4080 + @as(f32, @floatFromInt(ix)) * 512, -4080 + @as(f32, @floatFromInt(iz)) * 512);
    };
    try std.testing.expectEqual(before, terrain.height(x, z));
    try std.testing.expectEqual(tree_before, terrain.tree(tree_x, tree_z));
    try std.testing.expectEqual(terrain.height(-4096, 4096), terrain.height(-5000, 5000));
    const normal = terrain.normal(x, z);
    try std.testing.expectApproxEqAbs(@as(f32, 1), normal[0] * normal[0] + normal[1] * normal[1] + normal[2] * normal[2], 0.001);
}
