const std = @import("std");

pub const world_size: f32 = 8192.0;
pub const world_half_size: f32 = world_size * 0.5;
pub const sample_spacing: f32 = 8.0;
pub const tile_size: f32 = 512.0;
pub const tile_capacity: usize = 64;
pub const tile_node_side: usize = 65;
pub const tile_sample_count: usize = tile_node_side * tile_node_side;

const nodes_per_tile: usize = 64;
const world_tile_side: usize = 16;
const world_tile_count: usize = world_tile_side * world_tile_side;
const no_slot: u8 = std.math.maxInt(u8);
const height_quantum: f32 = 0.25;
const minimum_height: f32 = 0.0;
const maximum_height: f32 = 4095.75;

/// The callback must return the same finite height for the same context and
/// coordinates for the lifetime of a cache.
pub const HeightFn = *const fn (context: *const anyopaque, x: f32, z: f32) f32;

pub const Stats = struct {
    hits: u64 = 0,
    misses: u64 = 0,
    evictions: u64 = 0,
};

const Tile = struct {
    tile_x: u8 = 0,
    tile_z: u8 = 0,
    used_at: u64 = 0,
    valid: bool = false,
};

/// A bounded, transient 8 m height-sample cache. The 64 resident tiles hold
/// 65x65 u16 samples each (quarter-metre precision), using about 0.52 MiB.
/// Neighboring tiles duplicate their shared edge from the same absolute sample
/// coordinates so eviction and reload cannot change a seam.
pub const Cache = struct {
    allocator: std.mem.Allocator,
    samples: []u16,
    tiles: [tile_capacity]Tile,
    tile_lookup: [world_tile_count]u8,
    use_clock: u64 = 0,
    counters: Stats = .{},

    pub fn init(allocator: std.mem.Allocator) !Cache {
        const samples = try allocator.alloc(u16, tile_capacity * tile_sample_count);
        return .{
            .allocator = allocator,
            .samples = samples,
            .tiles = [_]Tile{.{}} ** tile_capacity,
            .tile_lookup = [_]u8{no_slot} ** world_tile_count,
        };
    }

    pub fn deinit(self: *Cache) void {
        self.allocator.free(self.samples);
        self.* = undefined;
    }

    /// Drop all resident tiles and reset counters. The next query regenerates
    /// its tile through the callback without allocating again.
    pub fn reset(self: *Cache) void {
        @memset(&self.tile_lookup, no_slot);
        for (&self.tiles) |*tile| tile.valid = false;
        self.use_clock = 0;
        self.counters = .{};
    }

    /// Bilinearly sample the cached 8 m lattice. Coordinates clamp to the
    /// finite world edges; NaN maps to the world origin. The cache belongs to
    /// one callback/context pair and should be reset before either changes.
    pub fn height(self: *Cache, context: *const anyopaque, callback: HeightFn, x: f32, z: f32) f32 {
        @setFloatMode(.strict);
        const bounded_x = boundedCoordinate(x);
        const bounded_z = boundedCoordinate(z);
        const sx = (bounded_x + world_half_size) / sample_spacing;
        const sz = (bounded_z + world_half_size) / sample_spacing;

        const x0 = @min(@as(usize, @intFromFloat(@floor(sx))), world_tile_side * nodes_per_tile);
        const z0 = @min(@as(usize, @intFromFloat(@floor(sz))), world_tile_side * nodes_per_tile);
        const x1 = @min(x0 + 1, world_tile_side * nodes_per_tile);
        const z1 = @min(z0 + 1, world_tile_side * nodes_per_tile);
        const tx = sx - @as(f32, @floatFromInt(x0));
        const tz = sz - @as(f32, @floatFromInt(z0));

        // Assign an exact shared boundary to the tile on its positive side,
        // except at the finite maximum edge, which belongs to the last tile.
        const tile_x = @min(x0 / nodes_per_tile, world_tile_side - 1);
        const tile_z = @min(z0 / nodes_per_tile, world_tile_side - 1);
        const local_x0 = x0 - tile_x * nodes_per_tile;
        const local_x1 = x1 - tile_x * nodes_per_tile;
        const local_z0 = z0 - tile_z * nodes_per_tile;
        const local_z1 = z1 - tile_z * nodes_per_tile;

        const slot = self.getOrCreateTile(context, callback, tile_x, tile_z);
        const tile_start = slot * tile_sample_count;
        const h00 = decodeHeight(self.samples[tile_start + local_z0 * tile_node_side + local_x0]);
        const h10 = decodeHeight(self.samples[tile_start + local_z0 * tile_node_side + local_x1]);
        const h01 = decodeHeight(self.samples[tile_start + local_z1 * tile_node_side + local_x0]);
        const h11 = decodeHeight(self.samples[tile_start + local_z1 * tile_node_side + local_x1]);
        const north = h00 + (h10 - h00) * tx;
        const south = h01 + (h11 - h01) * tx;
        return north + (south - north) * tz;
    }

    pub fn stats(self: *const Cache) Stats {
        return self.counters;
    }

    fn getOrCreateTile(self: *Cache, context: *const anyopaque, callback: HeightFn, tile_x: usize, tile_z: usize) usize {
        const key = tile_z * world_tile_side + tile_x;
        const mapped_slot = self.tile_lookup[key];
        if (mapped_slot != no_slot) {
            const slot: usize = mapped_slot;
            self.counters.hits += 1;
            self.touch(slot);
            return slot;
        }

        self.counters.misses += 1;
        const slot = self.chooseSlot();
        const tile = self.tiles[slot];
        if (tile.valid) {
            const old_key = @as(usize, tile.tile_z) * world_tile_side + tile.tile_x;
            self.tile_lookup[old_key] = no_slot;
            self.counters.evictions += 1;
        }

        const start_x = tile_x * nodes_per_tile;
        const start_z = tile_z * nodes_per_tile;
        const tile_start = slot * tile_sample_count;
        for (0..tile_node_side) |local_z| {
            const sample_z = worldCoordinate(start_z + local_z);
            for (0..tile_node_side) |local_x| {
                const sample_x = worldCoordinate(start_x + local_x);
                const index = tile_start + local_z * tile_node_side + local_x;
                self.samples[index] = encodeHeight(callback(context, sample_x, sample_z));
            }
        }

        self.tiles[slot] = .{
            .tile_x = @intCast(tile_x),
            .tile_z = @intCast(tile_z),
            .used_at = 0,
            .valid = true,
        };
        self.tile_lookup[key] = @intCast(slot);
        self.touch(slot);
        return slot;
    }

    fn chooseSlot(self: *const Cache) usize {
        for (self.tiles, 0..) |tile, slot| {
            if (!tile.valid) return slot;
        }

        var oldest_slot: usize = 0;
        var oldest_use = self.tiles[0].used_at;
        for (self.tiles[1..], 1..) |tile, slot| {
            if (tile.used_at < oldest_use) {
                oldest_slot = slot;
                oldest_use = tile.used_at;
            }
        }
        return oldest_slot;
    }

    fn touch(self: *Cache, slot: usize) void {
        // This is a deterministic access sequence, unrelated to wall time.
        self.use_clock += 1;
        self.tiles[slot].used_at = self.use_clock;
    }
};

fn boundedCoordinate(value: f32) f32 {
    if (std.math.isNan(value)) return 0;
    return std.math.clamp(value, -world_half_size, world_half_size);
}

fn worldCoordinate(index: usize) f32 {
    @setFloatMode(.strict);
    return -world_half_size + @as(f32, @floatFromInt(index)) * sample_spacing;
}

fn encodeHeight(height: f32) u16 {
    @setFloatMode(.strict);
    const finite_height = if (std.math.isFinite(height)) height else minimum_height;
    const bounded_height = std.math.clamp(finite_height, minimum_height, maximum_height);
    return @intFromFloat(@round(bounded_height / height_quantum));
}

fn decodeHeight(value: u16) f32 {
    @setFloatMode(.strict);
    return @as(f32, @floatFromInt(value)) * height_quantum;
}

const TestContext = struct { bias: f32 };

fn testHeight(context: *const anyopaque, x: f32, z: f32) f32 {
    const typed_context: *const TestContext = @ptrCast(@alignCast(context));
    return typed_context.bias + 0.0625 * x + 0.03125 * z;
}

fn testContextPointer(context: *const TestContext) *const anyopaque {
    return @ptrCast(context);
}

test "neighboring tiles share bit-identical edges and clamp finite bounds" {
    var cache = try Cache.init(std.testing.allocator);
    defer cache.deinit();
    const context = TestContext{ .bias = 1500.0 };
    const callback_context = testContextPointer(&context);

    const boundary_x = -world_half_size + tile_size;
    const sample_z = -world_half_size + 200.0 * sample_spacing;
    _ = cache.height(callback_context, testHeight, boundary_x - 0.5, sample_z);
    _ = cache.height(callback_context, testHeight, boundary_x + 0.5, sample_z);

    const sample_index_z: usize = 200;
    const tile_z = sample_index_z / nodes_per_tile;
    const local_z = sample_index_z - tile_z * nodes_per_tile;
    const left_slot = cache.tile_lookup[tile_z * world_tile_side];
    const right_slot = cache.tile_lookup[tile_z * world_tile_side + 1];
    try std.testing.expect(left_slot != no_slot);
    try std.testing.expect(right_slot != no_slot);
    const left_edge = cache.samples[@as(usize, left_slot) * tile_sample_count + local_z * tile_node_side + nodes_per_tile];
    const right_edge = cache.samples[@as(usize, right_slot) * tile_sample_count + local_z * tile_node_side];
    try std.testing.expectEqual(left_edge, right_edge);

    const seam_height = cache.height(callback_context, testHeight, boundary_x, sample_z);
    try std.testing.expectApproxEqAbs(testHeight(callback_context, boundary_x, sample_z), seam_height, 0.001);

    const edge_z = 123.0;
    const west = cache.height(callback_context, testHeight, -world_half_size, edge_z);
    const west_outside = cache.height(callback_context, testHeight, -world_size, edge_z);
    const east = cache.height(callback_context, testHeight, world_half_size, edge_z);
    const east_outside = cache.height(callback_context, testHeight, world_size, edge_z);
    try std.testing.expectEqual(@as(u32, @bitCast(west)), @as(u32, @bitCast(west_outside)));
    try std.testing.expectEqual(@as(u32, @bitCast(east)), @as(u32, @bitCast(east_outside)));
}

test "bounded tile LRU reload reproduces height bits" {
    var cache = try Cache.init(std.testing.allocator);
    defer cache.deinit();
    const context = TestContext{ .bias = 1500.0 };
    const callback_context = testContextPointer(&context);
    const replay_count = tile_capacity + 8;
    var recorded: [replay_count]u32 = undefined;

    for (0..replay_count) |i| {
        const tile_x = i % world_tile_side;
        const tile_z = i / world_tile_side;
        const x = -world_half_size + @as(f32, @floatFromInt(tile_x)) * tile_size + 80.0;
        const z = -world_half_size + @as(f32, @floatFromInt(tile_z)) * tile_size + 80.0;
        recorded[i] = @bitCast(cache.height(callback_context, testHeight, x, z));
    }

    const first_pass = cache.stats();
    try std.testing.expectEqual(@as(u64, replay_count), first_pass.misses);
    try std.testing.expectEqual(@as(u64, 8), first_pass.evictions);
    try std.testing.expectEqual(@as(u64, 0), first_pass.hits);

    cache.reset();
    for (0..replay_count) |i| {
        const tile_x = i % world_tile_side;
        const tile_z = i / world_tile_side;
        const x = -world_half_size + @as(f32, @floatFromInt(tile_x)) * tile_size + 80.0;
        const z = -world_half_size + @as(f32, @floatFromInt(tile_z)) * tile_size + 80.0;
        const reloaded: u32 = @bitCast(cache.height(callback_context, testHeight, x, z));
        try std.testing.expectEqual(recorded[i], reloaded);
    }
    const second_pass = cache.stats();
    try std.testing.expectEqual(first_pass.misses, second_pass.misses);
    try std.testing.expectEqual(first_pass.evictions, second_pass.evictions);

    const last_tile_x: f32 = @floatFromInt((replay_count - 1) % world_tile_side);
    const last_tile_z: f32 = @floatFromInt((replay_count - 1) / world_tile_side);
    _ = cache.height(
        callback_context,
        testHeight,
        -world_half_size + last_tile_x * tile_size + 80.0,
        -world_half_size + last_tile_z * tile_size + 80.0,
    );
    try std.testing.expectEqual(@as(u64, 1), cache.stats().hits);
}
