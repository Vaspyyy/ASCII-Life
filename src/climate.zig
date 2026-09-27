const std = @import("std");

/// Climate lattice matches every fourth sample of the 8 m terrain cache.
pub const side: usize = 257;
pub const spacing: f32 = 32.0;
pub const origin: f32 = -4096.0;
pub const count: usize = side * side;

const water_level_m: f32 = 80.0;
const water_level_quarters: u16 = 320;
const infinity_distance: u16 = std.math.maxInt(u16);

pub const Biome = enum(u8) {
    water,
    shore,
    woodland,
    grassland,
    scrub,
    steppe,
    desert,
    savanna,
    alpine,
    tundra,
    snowfield,
    wetland,
};

pub fn biomeName(biome: Biome) []const u8 {
    return switch (biome) {
        .water => "water",
        .shore => "shore",
        .woodland => "woodland",
        .grassland => "grassland",
        .scrub => "scrub",
        .steppe => "steppe",
        .desert => "desert",
        .savanna => "savanna",
        .alpine => "alpine",
        .tundra => "tundra",
        .snowfield => "snowfield",
        .wetland => "wetland",
    };
}

pub const ResourcePotential = struct {
    /// Relative food-growing and wild-harvest potential, 0..255.
    fertility: u8,
    /// Relative sustainable timber potential, 0..255.
    timber: u8,
    /// Relative exposed stone potential, 0..255.
    stone: u8,
    /// Relative mineral-bearing geology potential, 0..255.
    ore: u8,
};

pub const Sample = struct {
    biome: Biome,
    /// Mean annual temperature in tenths of a degree Celsius.
    temperature_tenths_c: i16,
    /// Approximate annual precipitation in millimetres.
    rainfall_mm: u16,
    /// Effective soil moisture and local water influence, 0..255.
    moisture: u8,
    elevation_m: f32,
    resources: ResourcePotential,
};

/// Deterministic regional climate and resource-potential fields.
///
/// The input elevations are unsigned quarter-metre terrain samples, laid out
/// row-major from z=-4096 to +4096, then x=-4096 to +4096. Annual rainfall is
/// stored separately so hydrology can consume it without running biome logic.
pub const Climate = struct {
    allocator: std.mem.Allocator,
    seed: u64,
    heights: []u16,
    rainfall: []u16,
    temperature: []i16,
    moisture: []u8,

    pub fn init(allocator: std.mem.Allocator, seed: u64, heights: []const u16) !Climate {
        @setFloatMode(.strict);
        if (heights.len != count) return error.InvalidHeightCount;

        const stored_heights = try allocator.dupe(u16, heights);
        errdefer allocator.free(stored_heights);
        const rainfall = try allocator.alloc(u16, count);
        errdefer allocator.free(rainfall);
        const temperature = try allocator.alloc(i16, count);
        errdefer allocator.free(temperature);
        const moisture = try allocator.alloc(u8, count);
        errdefer allocator.free(moisture);
        const coast_distance = try allocator.alloc(u16, count);
        defer allocator.free(coast_distance);
        const queue = try allocator.alloc(usize, count);
        defer allocator.free(queue);

        calculateWaterDistance(stored_heights, coast_distance, queue);

        for (0..side) |iz| {
            const z = origin + @as(f32, @floatFromInt(iz)) * spacing;
            var air_moisture: f32 = 0.86;
            for (0..side) |ix| {
                const index = iz * side + ix;
                const x = origin + @as(f32, @floatFromInt(ix)) * spacing;
                const elevation = quarterMetres(stored_heights[index]);
                const previous_elevation = if (ix == 0) elevation else quarterMetres(stored_heights[index - 1]);
                const rise = @max(0.0, elevation - previous_elevation);
                const lift = std.math.clamp(rise / 380.0, 0.0, 0.9);
                const distance = coast_distance[index];
                const coast = if (distance == infinity_distance) 0.0 else 1.0 / (1.0 + @as(f32, @floatFromInt(distance)) / 1800.0);

                if (elevation <= water_level_m) air_moisture = @max(air_moisture, 0.94);

                // One regional latitude, with metres converted to degrees. Do not
                // compress an equator-to-pole climate sweep into an 8 km valley.
                const latitude_degrees = 44.0 + valueNoise(seed, 0, 0, 1, 0x6c61746974756465) * 12.0 + z / 111_000.0;
                const latitude = @abs(latitude_degrees) / 90.0;
                const temperature_noise = valueNoise(seed, x, z, 1900.0, 0x636c696d2d74656d) * 3.6 - 1.8;
                const temperature_c = 34.0 - 40.0 * latitude + temperature_noise - elevation * 0.0065;
                const temperature_tenths = @round(temperature_c * 10.0);
                temperature[index] = @intFromFloat(std.math.clamp(temperature_tenths, -800.0, 350.0));

                const rainfall_noise = 0.91 + 0.18 * valueNoise(seed, x, z, 1500.0, 0x636c696d2d726169);
                const latitude_rain = 1.0 - 0.20 * latitude;
                const coastal_base = 260.0 + 670.0 * coast;
                const rainfall_value = (coastal_base + 760.0 * lift) * air_moisture * rainfall_noise * latitude_rain;
                rainfall[index] = @intFromFloat(std.math.clamp(@round(rainfall_value), 35.0, 8000.0));

                const rain_wetness = @as(f32, @floatFromInt(rainfall[index])) * 0.12;
                const warmth_evaporation = @max(0.0, temperature_c - 18.0) * 2.1;
                const soil = std.math.clamp(rain_wetness + coast * 34.0 - warmth_evaporation, 0.0, 255.0);
                moisture[index] = @intFromFloat(@round(soil));

                // Orographic condensation removes moisture; gradual recovery
                // and actual lakes replenish the eastward-moving air mass.
                air_moisture *= 1.0 - lift * 0.56;
                air_moisture += (0.90 - air_moisture) * (0.012 + coast * 0.018);
                air_moisture = std.math.clamp(air_moisture, 0.12, 0.96);
            }
        }

        return .{
            .allocator = allocator,
            .seed = seed,
            .heights = stored_heights,
            .rainfall = rainfall,
            .temperature = temperature,
            .moisture = moisture,
        };
    }

    pub fn deinit(self: *Climate) void {
        self.allocator.free(self.heights);
        self.allocator.free(self.rainfall);
        self.allocator.free(self.temperature);
        self.allocator.free(self.moisture);
        self.* = undefined;
    }

    /// Sample climate and generated resource potential at a world coordinate.
    pub fn sample(self: *const Climate, x: f32, z: f32) Sample {
        return self.sampleWithWater(x, z, null);
    }

    /// Sample with distance to a nearby river, spring, or lake supplied by
    /// hydrology. The influence is local and affects soil moisture and biome,
    /// not atmospheric rainfall.
    pub fn sampleWithWater(self: *const Climate, x: f32, z: f32, water_distance_m: ?f32) Sample {
        @setFloatMode(.strict);
        const p = gridPosition(x, z);
        const elevation = interpolateU16(self.heights, p) * 0.25;
        const temp = interpolateI16(self.temperature, p);
        const rain = toU16(interpolateU16(self.rainfall, p));
        var soil = interpolateU8(self.moisture, p);
        if (water_distance_m) |distance| {
            if (std.math.isFinite(distance) and distance >= 0.0) {
                const reach = std.math.clamp(1.0 - distance / 64.0, 0.0, 1.0);
                const riparian = smooth(reach);
                soil = @intFromFloat(@round(std.math.clamp(soil + 95.0 * riparian, 0.0, 255.0)));
            }
        }

        const grid_distance = nearestWaterDistance(self.heights, p);
        const river_distance = if (water_distance_m) |d|
            (if (std.math.isFinite(d) and d >= 0.0) @min(grid_distance, d) else grid_distance)
        else
            grid_distance;
        const biome = classifyBiome(elevation, temp, rain, soil, river_distance);
        const resources = self.resourcePotential(x, z, elevation, temp, rain, soil, biome);

        return .{
            .biome = biome,
            .temperature_tenths_c = temp,
            .rainfall_mm = rain,
            .moisture = soil,
            .elevation_m = elevation,
            .resources = resources,
        };
    }

    fn resourcePotential(self: *const Climate, x: f32, z: f32, elevation: f32, temp_tenths: i16, rain: u16, soil: u8, biome: Biome) ResourcePotential {
        @setFloatMode(.strict);
        if (biome == .water) return .{ .fertility = 0, .timber = 0, .stone = 0, .ore = 0 };

        const temperature_c = @as(f32, @floatFromInt(temp_tenths)) * 0.1;
        const moisture_value: f32 = @floatFromInt(soil);
        const rainfall_value: f32 = @floatFromInt(rain);
        const geology = valueNoise(self.seed, x, z, 2300.0, 0x7265732d67656f31);
        const fertility_noise = 0.86 + 0.28 * valueNoise(self.seed, x, z, 760.0, 0x7265732d66657274);
        const timber_noise = 0.82 + 0.36 * valueNoise(self.seed, x, z, 920.0, 0x7265732d74696d62);
        const stone_noise = 0.78 + 0.44 * valueNoise(self.seed, x, z, 1100.0, 0x7265732d73746f6e);
        const ore_noise = valueNoise(self.seed, x, z, 1450.0, 0x7265732d6f726521);

        const moisture_suitability = std.math.clamp(1.0 - @abs(moisture_value - 132.0) / 155.0, 0.0, 1.0);
        const warmth_suitability = std.math.clamp(1.0 - @abs(temperature_c - 15.0) / 30.0, 0.0, 1.0);
        const water_table_bonus: f32 = if (rainfall_value > 300.0 and soil > 65) 0.08 else 0.0;
        const fertility = (0.18 + 0.72 * moisture_suitability * warmth_suitability + water_table_bonus) * fertility_noise;

        const tree_warmth = std.math.clamp(1.0 - @abs(temperature_c - 12.0) / 27.0, 0.0, 1.0);
        const tree_wetness = std.math.clamp((moisture_value - 22.0) / 175.0, 0.0, 1.0);
        const elevation_limit = std.math.clamp(1.0 - @max(0.0, elevation - 1200.0) / 1900.0, 0.0, 1.0);
        const timber = tree_warmth * tree_wetness * elevation_limit * timber_noise;

        const relief = std.math.clamp((elevation - 120.0) / 1700.0, 0.0, 1.0);
        const stone = (0.20 + 0.50 * relief + 0.30 * geology) * stone_noise;
        const ore = (0.10 + 0.62 * geology + 0.28 * ore_noise) * (0.52 + 0.48 * relief);

        return .{
            .fertility = toByte(fertility * 255.0),
            .timber = toByte(timber * 255.0),
            .stone = toByte(stone * 255.0),
            .ore = toByte(ore * 255.0),
        };
    }
};

fn classifyBiome(elevation: f32, temp_tenths: i16, rain: u16, soil: u8, water_distance: f32) Biome {
    const temp_c = @as(f32, @floatFromInt(temp_tenths)) * 0.1;
    const rain_mm: f32 = @floatFromInt(rain);
    if (elevation <= water_level_m) return .water;
    if (water_distance < 58.0 and elevation < water_level_m + 34.0) return .shore;
    if (temp_c < -3.0 or (elevation > 2600.0 and temp_c < 3.0)) return .snowfield;
    if (elevation > 1650.0) return if (temp_c < 5.0) .tundra else .alpine;
    if (temp_c < 3.5) return if (soil > 150 and temp_c > 0.0) .woodland else .tundra;
    if (soil > 210 and water_distance < 500.0) return .wetland;

    if (temp_c > 22.0) {
        if (rain_mm < 390.0 or soil < 38) return .desert;
        if (rain_mm < 900.0 or soil < 86) return .savanna;
        if (soil > 155) return .woodland;
        return .grassland;
    }
    if (rain_mm < 330.0 or soil < 36) return .desert;
    if (rain_mm < 600.0 or soil < 67) return .steppe;
    if (soil < 102) return .scrub;
    if (soil > 144 or rain_mm > 1180.0) return .woodland;
    return .grassland;
}

fn calculateWaterDistance(heights: []const u16, distances: []u16, queue: []usize) void {
    @memset(distances, infinity_distance);
    var tail: usize = 0;
    for (heights, 0..) |height, index| {
        if (height <= water_level_quarters) {
            distances[index] = 0;
            queue[tail] = index;
            tail += 1;
        }
    }

    var head: usize = 0;
    while (head < tail) : (head += 1) {
        const index = queue[head];
        const x = index % side;
        const z = index / side;
        const distance = distances[index];
        if (x > 0) visit(index - 1, distance, distances, queue, &tail);
        if (x + 1 < side) visit(index + 1, distance, distances, queue, &tail);
        if (z > 0) visit(index - side, distance, distances, queue, &tail);
        if (z + 1 < side) visit(index + side, distance, distances, queue, &tail);
    }
}

fn visit(index: usize, from: u16, distances: []u16, queue: []usize, tail: *usize) void {
    const candidate = @as(u32, from) + @as(u32, @intFromFloat(spacing));
    if (candidate >= distances[index]) return;
    distances[index] = @intCast(candidate);
    queue[tail.*] = index;
    tail.* += 1;
}

fn nearestWaterDistance(heights: []const u16, p: GridPosition) f32 {
    const index = p.z0 * side + p.x0;
    const candidates = [_]usize{
        index,
        p.z0 * side + p.x1,
        p.z1 * side + p.x0,
        p.z1 * side + p.x1,
    };
    var distance: f32 = std.math.inf(f32);
    for (candidates) |candidate| {
        if (heights[candidate] <= water_level_quarters) {
            const dx = (@as(f32, @floatFromInt(candidate % side)) - (p.x0f + p.tx)) * spacing;
            const dz = (@as(f32, @floatFromInt(candidate / side)) - (p.z0f + p.tz)) * spacing;
            distance = @min(distance, @sqrt(dx * dx + dz * dz));
        }
    }
    return distance;
}

const GridPosition = struct {
    x0: usize,
    x1: usize,
    z0: usize,
    z1: usize,
    tx: f32,
    tz: f32,
    x0f: f32,
    z0f: f32,
};

fn gridPosition(x: f32, z: f32) GridPosition {
    @setFloatMode(.strict);
    const sx = std.math.clamp((x - origin) / spacing, 0.0, @as(f32, @floatFromInt(side - 1)));
    const sz = std.math.clamp((z - origin) / spacing, 0.0, @as(f32, @floatFromInt(side - 1)));
    const x0 = @as(usize, @intFromFloat(@floor(sx)));
    const z0 = @as(usize, @intFromFloat(@floor(sz)));
    const x1 = @min(x0 + 1, side - 1);
    const z1 = @min(z0 + 1, side - 1);
    return .{ .x0 = x0, .x1 = x1, .z0 = z0, .z1 = z1, .tx = sx - @as(f32, @floatFromInt(x0)), .tz = sz - @as(f32, @floatFromInt(z0)), .x0f = @as(f32, @floatFromInt(x0)), .z0f = @as(f32, @floatFromInt(z0)) };
}

fn interpolateU16(values: []const u16, p: GridPosition) f32 {
    const a = @as(f32, @floatFromInt(values[p.z0 * side + p.x0]));
    const b = @as(f32, @floatFromInt(values[p.z0 * side + p.x1]));
    const c = @as(f32, @floatFromInt(values[p.z1 * side + p.x0]));
    const d = @as(f32, @floatFromInt(values[p.z1 * side + p.x1]));
    return mix(mix(a, b, p.tx), mix(c, d, p.tx), p.tz);
}

fn interpolateI16(values: []const i16, p: GridPosition) i16 {
    const a = @as(f32, @floatFromInt(values[p.z0 * side + p.x0]));
    const b = @as(f32, @floatFromInt(values[p.z0 * side + p.x1]));
    const c = @as(f32, @floatFromInt(values[p.z1 * side + p.x0]));
    const d = @as(f32, @floatFromInt(values[p.z1 * side + p.x1]));
    return @intFromFloat(@round(mix(mix(a, b, p.tx), mix(c, d, p.tx), p.tz)));
}

fn interpolateU8(values: []const u8, p: GridPosition) u8 {
    const a = @as(f32, @floatFromInt(values[p.z0 * side + p.x0]));
    const b = @as(f32, @floatFromInt(values[p.z0 * side + p.x1]));
    const c = @as(f32, @floatFromInt(values[p.z1 * side + p.x0]));
    const d = @as(f32, @floatFromInt(values[p.z1 * side + p.x1]));
    return @intFromFloat(@round(mix(mix(a, b, p.tx), mix(c, d, p.tx), p.tz)));
}

fn quarterMetres(value: u16) f32 {
    return @as(f32, @floatFromInt(value)) * 0.25;
}

fn valueNoise(seed: u64, x: f32, z: f32, scale: f32, tag: u64) f32 {
    @setFloatMode(.strict);
    const gx = x / scale;
    const gz = z / scale;
    const x_floor = @floor(gx);
    const z_floor = @floor(gz);
    const ix: i64 = @intFromFloat(x_floor);
    const iz: i64 = @intFromFloat(z_floor);
    const tx = smooth(gx - x_floor);
    const tz = smooth(gz - z_floor);
    const n00 = unitFloat(hash2(seed, ix, iz, tag));
    const n10 = unitFloat(hash2(seed, ix + 1, iz, tag));
    const n01 = unitFloat(hash2(seed, ix, iz + 1, tag));
    const n11 = unitFloat(hash2(seed, ix + 1, iz + 1, tag));
    return mix(mix(n00, n10, tx), mix(n01, n11, tx), tz);
}

fn hash2(seed: u64, x: i64, z: i64, tag: u64) u64 {
    const x_bits: u64 = @bitCast(x);
    const z_bits: u64 = @bitCast(z);
    return mixHash(seed ^ mixHash(x_bits +% 0x9e3779b97f4a7c15) ^ mixHash(z_bits +% 0xd1b54a32d192ed03) ^ mixHash(tag));
}

fn mixHash(value: u64) u64 {
    var x = value +% 0x9e3779b97f4a7c15;
    x = (x ^ (x >> 30)) *% 0xbf58476d1ce4e5b9;
    x = (x ^ (x >> 27)) *% 0x94d049bb133111eb;
    return x ^ (x >> 31);
}

fn unitFloat(value: u64) f32 {
    return @as(f32, @floatFromInt(value >> 40)) / 16777216.0;
}

fn smooth(value: f32) f32 {
    return value * value * value * (value * (value * 6.0 - 15.0) + 10.0);
}

fn mix(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

fn toByte(value: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(value, 0.0, 255.0)));
}

fn toU16(value: f32) u16 {
    return @intFromFloat(@round(std.math.clamp(value, 0.0, 8000.0)));
}

test "climate is repeatable, bounded, and clamps sample edges" {
    const allocator = std.testing.allocator;
    const heights = try allocator.alloc(u16, count);
    defer allocator.free(heights);
    for (heights, 0..) |*height, index| {
        const x = index % side;
        const z = index / side;
        const dx = @as(i32, @intCast(x)) - 128;
        const dz = @as(i32, @intCast(z)) - 128;
        const ridge = @max(0, 600 - @max(dx, -dx) * 4);
        const valley = @max(0, 300 - @max(dz, -dz) * 3);
        height.* = @intCast(400 + ridge + valley);
    }

    var first = try Climate.init(allocator, 0x12345678, heights);
    defer first.deinit();
    var second = try Climate.init(allocator, 0x12345678, heights);
    defer second.deinit();
    try std.testing.expectEqualSlices(u16, first.rainfall, second.rainfall);
    try std.testing.expectEqualSlices(i16, first.temperature, second.temperature);
    try std.testing.expectEqualSlices(u8, first.moisture, second.moisture);

    const edge = first.sample(origin, origin);
    const outside = first.sample(origin - 1000.0, origin - 1000.0);
    try std.testing.expectEqual(edge.biome, outside.biome);
    try std.testing.expectEqual(edge.rainfall_mm, outside.rainfall_mm);
    try std.testing.expect(edge.rainfall_mm > 0);
    try std.testing.expect(edge.temperature_tenths_c >= -800 and edge.temperature_tenths_c <= 350);
}

test "temperature responds to elevation and west wind creates a rain shadow" {
    const allocator = std.testing.allocator;
    const heights = try allocator.alloc(u16, count);
    defer allocator.free(heights);
    @memset(heights, 400); // 100 m rolling plain.

    // A north-south ridge intercepts the prevailing west-to-east wind.
    for (0..side) |z| heights[z * side + 126] = 4000; // 1000 m.
    var climate = try Climate.init(allocator, 0x99887766, heights);
    defer climate.deinit();

    const windward = climate.sample(origin + 126.0 * spacing, 0.0);
    const lee = climate.sample(origin + 150.0 * spacing, 0.0);
    try std.testing.expect(windward.rainfall_mm > lee.rainfall_mm);

    const plain = climate.sample(origin + 180.0 * spacing, 0.0);
    var highland_heights = try allocator.dupe(u16, heights);
    defer allocator.free(highland_heights);
    highland_heights[128 * side + 180] = 4800; // Same latitude and noise, +200 m.
    var highland = try Climate.init(allocator, 0x99887766, highland_heights);
    defer highland.deinit();
    const high = highland.sample(origin + 180.0 * spacing, 0.0);
    try std.testing.expect(high.temperature_tenths_c < plain.temperature_tenths_c);
}

test "riparian sample increases moisture without changing atmospheric rain" {
    const allocator = std.testing.allocator;
    const heights = try allocator.alloc(u16, count);
    defer allocator.free(heights);
    @memset(heights, 600);
    var climate = try Climate.init(allocator, 7, heights);
    defer climate.deinit();

    const dry = climate.sample(0, 0);
    const riverside = climate.sampleWithWater(0, 0, 0.0);
    // Eight kilometres must not span tropical and polar temperature zones.
    try std.testing.expect(@abs(@as(i32, climate.sample(0, -4096).temperature_tenths_c) - @as(i32, climate.sample(0, 4096).temperature_tenths_c)) < 40);
    try std.testing.expect(riverside.moisture > dry.moisture);
    try std.testing.expectEqual(dry.rainfall_mm, riverside.rainfall_mm);
}
