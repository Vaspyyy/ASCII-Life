const std = @import("std");

pub const side: usize = 257;
pub const spacing: f32 = 32.0;
pub const origin: f32 = -4096.0;
pub const region_size: f32 = @as(f32, @floatFromInt(side - 1)) * spacing;
pub const cell_count: usize = side * side;
pub const sea_level: f32 = 80.0;

const sea_units: u16 = @intFromFloat(sea_level * 4.0);
const min_lake_depth_units: u16 = 4; // one metre of filled water
const minimum_river_cells: u64 = 24;
const segment_search_radius: i32 = 2;

pub const WaterKind = enum(u8) {
    dry,
    ocean,
    lake,
    river,
};

pub const Sample = struct {
    ground_y: f32,
    /// Surface height in metres. On a dry bank with a nearby river segment,
    /// this is the segment's surface so callers can shape a smooth channel.
    /// With no nearby water it equals ground_y.
    water_y: f32,
    wet: bool,
    kind: WaterKind,
    /// Accumulation-derived strength in [0, 1], including nearby dry banks.
    river_strength: f32,
    /// River's full width in metres, never less than 12 m when present.
    river_width: f32,
    /// Distance in metres to the nearest local river centreline segment.
    /// Is +infinity when no segment is within the search neighbourhood.
    river_distance: f32,
    /// Normalized downstream direction in world x/z coordinates.
    flow_x: f32,
    flow_z: f32,
};

pub const Summary = struct {
    outlet_count: usize,
    ocean_cells: usize,
    lake_cells: usize,
    river_cells: usize,
    peak_discharge: u64,
    total_rainfall: u64,
};

/// Deterministic D8 drainage for one 8.192 km square region. Heights are
/// quarter-metre values on the 32 m macro grid; untouched geography is never
/// serialized. The seed resolves equal-height priority-flood ties.
pub const Hydro = struct {
    allocator: std.mem.Allocator,
    seed: u64,
    ground: []u16,
    filled: []u16,
    /// Each non-outlet points to one of its eight neighbours. Outlets point
    /// to themselves. Parents always occur earlier in `order`.
    parent: []u32,
    discharge: []u64,
    /// Cells in ascending priority-flood order, including outlets first.
    order: []u32,
    rainfall: []u16,
    water_kind: []WaterKind,
    /// D8 channel centreline cells above the accumulation threshold.
    river_nodes: []u8,
    /// 25 bits per macro cell for river candidates in its 5 × 5 sampling
    /// neighbourhood. Zero masks make dry and far-water samples constant time.
    nearby_river_mask: []u32,
    river_threshold: u64,
    total_rainfall: u64,

    pub fn init(allocator: std.mem.Allocator, seed: u64, heights: []const u16, rain: []const u16) !Hydro {
        if (heights.len != cell_count) return error.InvalidHeightCount;
        if (rain.len != cell_count) return error.InvalidRainfallCount;
        for (rain) |value| if (value == 0) return error.RainfallMustBePositive;

        const ground = try allocator.dupe(u16, heights);
        errdefer allocator.free(ground);
        const filled = try allocator.alloc(u16, cell_count);
        errdefer allocator.free(filled);
        const parent = try allocator.alloc(u32, cell_count);
        errdefer allocator.free(parent);
        const discharge = try allocator.alloc(u64, cell_count);
        errdefer allocator.free(discharge);
        const order = try allocator.alloc(u32, cell_count);
        errdefer allocator.free(order);
        const rainfall = try allocator.dupe(u16, rain);
        errdefer allocator.free(rainfall);
        const water_kind = try allocator.alloc(WaterKind, cell_count);
        errdefer allocator.free(water_kind);
        const river_nodes = try allocator.alloc(u8, cell_count);
        errdefer allocator.free(river_nodes);
        const nearby_river_mask = try allocator.alloc(u32, cell_count);
        errdefer allocator.free(nearby_river_mask);

        const visited = try allocator.alloc(u8, cell_count);
        defer allocator.free(visited);
        const heap = try allocator.alloc(u32, cell_count);
        defer allocator.free(heap);

        try priorityFlood(seed, ground, filled, parent, order, visited, heap);

        var total_rainfall: u64 = 0;
        for (rainfall) |amount| total_rainfall += amount;
        @memset(discharge, 0);
        for (rainfall, 0..) |amount, i| discharge[i] = amount;
        var i = cell_count;
        while (i > 0) {
            i -= 1;
            const index: usize = order[i];
            const p: usize = parent[index];
            if (p != index) discharge[p] += discharge[index];
        }

        classifyWater(ground, filled, water_kind, visited, heap);
        const river_threshold = ceilDiv(total_rainfall * minimum_river_cells, cell_count);
        @memset(river_nodes, 0);
        for (0..cell_count) |index| {
            if (parent[index] != index and discharge[index] >= river_threshold and water_kind[index] == .dry) {
                river_nodes[index] = 1;
            }
        }
        buildNearbyRiverMasks(river_nodes, nearby_river_mask);

        return .{
            .allocator = allocator,
            .seed = seed,
            .ground = ground,
            .filled = filled,
            .parent = parent,
            .discharge = discharge,
            .order = order,
            .rainfall = rainfall,
            .water_kind = water_kind,
            .river_nodes = river_nodes,
            .nearby_river_mask = nearby_river_mask,
            .river_threshold = river_threshold,
            .total_rainfall = total_rainfall,
        };
    }

    pub fn deinit(self: *Hydro) void {
        self.allocator.free(self.ground);
        self.allocator.free(self.filled);
        self.allocator.free(self.parent);
        self.allocator.free(self.discharge);
        self.allocator.free(self.order);
        self.allocator.free(self.rainfall);
        self.allocator.free(self.water_kind);
        self.allocator.free(self.river_nodes);
        self.allocator.free(self.nearby_river_mask);
        self.* = undefined;
    }

    /// Check that the flood order is complete, every parent is an adjacent
    /// earlier cell, surfaces never rise downstream, and rainfall is conserved.
    pub fn validate(self: *const Hydro) !void {
        if (self.ground.len != cell_count or self.filled.len != cell_count or
            self.parent.len != cell_count or self.discharge.len != cell_count or
            self.order.len != cell_count or self.rainfall.len != cell_count or
            self.water_kind.len != cell_count or self.river_nodes.len != cell_count or
            self.nearby_river_mask.len != cell_count)
        {
            return error.InvalidHydrologyLengths;
        }

        const unseen = std.math.maxInt(u32);
        const rank = try self.allocator.alloc(u32, cell_count);
        defer self.allocator.free(rank);
        @memset(rank, unseen);
        var previous_filled: u16 = 0;
        for (self.order, 0..) |value, position| {
            const index: usize = value;
            if (index >= cell_count or rank[index] != unseen) return error.InvalidFloodOrder;
            if (position != 0 and self.filled[index] < previous_filled) return error.InvalidFloodOrder;
            rank[index] = @intCast(position);
            previous_filled = self.filled[index];
        }

        for (0..cell_count) |index| {
            if (self.nearby_river_mask[index] != expectedRiverMask(self.river_nodes, index)) {
                return error.InvalidRiverNeighbourMask;
            }
        }

        const expected = try self.allocator.alloc(u64, cell_count);
        defer self.allocator.free(expected);
        for (self.rainfall, 0..) |amount, index| expected[index] = amount;
        var cursor = cell_count;
        while (cursor > 0) {
            cursor -= 1;
            const index: usize = self.order[cursor];
            const p: usize = self.parent[index];
            if (p >= cell_count) return error.InvalidParent;
            if (self.filled[index] < self.ground[index]) return error.InvalidFilledElevation;
            if (self.rainfall[index] == 0 or self.discharge[index] < self.rainfall[index]) return error.InvalidAccumulation;

            if (p == index) {
                if (!isOutlet(index, self.ground[index])) return error.InvalidOutlet;
            } else {
                if (isOutlet(index, self.ground[index])) return error.InvalidOutlet;
                if (rank[p] >= rank[index]) return error.InvalidParentOrder;
                if (self.filled[p] > self.filled[index]) return error.NonMonotoneWaterSurface;
                if (self.parent[p] == p and !isOutlet(p, self.ground[p])) return error.InvalidOutlet;
                const x = index % side;
                const z = index / side;
                const px = p % side;
                const pz = p / side;
                const dx = if (x > px) x - px else px - x;
                const dz = if (z > pz) z - pz else pz - z;
                if (dx > 1 or dz > 1 or (dx == 0 and dz == 0)) return error.NonAdjacentParent;
                expected[p] += expected[index];
            }
        }

        var rainfall_sum: u64 = 0;
        var outlet_sum: u64 = 0;
        for (0..cell_count) |index| {
            rainfall_sum += self.rainfall[index];
            if (expected[index] != self.discharge[index]) return error.InvalidAccumulation;
            if (self.parent[index] == index) outlet_sum += self.discharge[index];
        }
        if (outlet_sum != rainfall_sum or rainfall_sum != self.total_rainfall) return error.RainfallNotConserved;
    }

    pub fn summary(self: *const Hydro) Summary {
        var result = Summary{
            .outlet_count = 0,
            .ocean_cells = 0,
            .lake_cells = 0,
            .river_cells = 0,
            .peak_discharge = 0,
            .total_rainfall = self.total_rainfall,
        };
        for (0..cell_count) |index| {
            if (self.parent[index] == index) result.outlet_count += 1;
            switch (self.water_kind[index]) {
                .ocean => result.ocean_cells += 1,
                .lake => result.lake_cells += 1,
                .dry, .river => {},
            }
            if (self.river_nodes[index] != 0) result.river_cells += 1;
            result.peak_discharge = @max(result.peak_discharge, self.discharge[index]);
        }
        return result;
    }

    /// Sample macro terrain and the nearest local channel segment. Lake and
    /// ocean classification comes from the nearest macro cell; river distance
    /// is measured against exact D8 parent segments in a 5 × 5 neighbourhood.
    pub fn sample(self: *const Hydro, x: f32, z: f32) Sample {
        @setFloatMode(.strict);
        const sample_x = std.math.clamp(x, origin, origin + region_size);
        const sample_z = std.math.clamp(z, origin, origin + region_size);
        const gx = (sample_x - origin) / spacing;
        const gz = (sample_z - origin) / spacing;
        const x0: usize = @intFromFloat(@floor(gx));
        const z0: usize = @intFromFloat(@floor(gz));
        const x1 = @min(x0 + 1, side - 1);
        const z1 = @min(z0 + 1, side - 1);
        const tx = gx - @as(f32, @floatFromInt(x0));
        const tz = gz - @as(f32, @floatFromInt(z0));
        const ground_y = bilerp(
            heightMetres(self.ground[z0 * side + x0]),
            heightMetres(self.ground[z0 * side + x1]),
            heightMetres(self.ground[z1 * side + x0]),
            heightMetres(self.ground[z1 * side + x1]),
            tx,
            tz,
        );
        const nearest_x = @min(@as(usize, @intFromFloat(@round(gx))), side - 1);
        const nearest_z = @min(@as(usize, @intFromFloat(@round(gz))), side - 1);
        const nearest = nearest_z * side + nearest_x;
        var result = Sample{
            .ground_y = ground_y,
            .water_y = ground_y,
            .wet = false,
            .kind = .dry,
            .river_strength = 0.0,
            .river_width = 0.0,
            .river_distance = std.math.inf(f32),
            .flow_x = 0.0,
            .flow_z = 0.0,
        };

        switch (self.water_kind[nearest]) {
            .ocean => {
                result.wet = true;
                result.kind = .ocean;
                result.water_y = sea_level;
            },
            .lake => {
                result.wet = true;
                result.kind = .lake;
                result.water_y = if (self.ground[nearest] <= sea_units) sea_level else heightMetres(self.filled[nearest]);
            },
            .dry, .river => {},
        }

        if (self.nearestRiverSegment(sample_x, sample_z, x0, z0)) |segment| {
            result.river_distance = segment.distance;
            result.river_strength = segment.strength;
            result.river_width = segment.width;
            result.flow_x = segment.flow_x;
            result.flow_z = segment.flow_z;
            if (result.kind == .dry) {
                result.water_y = segment.water_y;
                if (segment.distance <= segment.width * 0.5) {
                    result.wet = true;
                    result.kind = .river;
                }
            }
        }
        return result;
    }

    fn nearestRiverSegment(self: *const Hydro, x: f32, z: f32, x0: usize, z0: usize) ?SegmentSample {
        @setFloatMode(.strict);
        var best: ?SegmentSample = null;
        var best_index: usize = cell_count;
        const center_x: i32 = @intCast(x0);
        const center_z: i32 = @intCast(z0);
        var candidates = self.nearby_river_mask[z0 * side + x0];
        while (candidates != 0) {
            const bit: u32 = @ctz(candidates);
            candidates &= candidates - 1;
            const dx: i32 = @as(i32, @intCast(bit % 5)) - segment_search_radius;
            const dz: i32 = @as(i32, @intCast(bit / 5)) - segment_search_radius;
            const cell_x = center_x + dx;
            const cell_z = center_z + dz;
            const index = @as(usize, @intCast(cell_z)) * side + @as(usize, @intCast(cell_x));
            const p: usize = self.parent[index];
            if (p == index or p >= cell_count) continue;

            const px = p % side;
            const pz = p / side;
            const ax = origin + @as(f32, @floatFromInt(cell_x)) * spacing;
            const az = origin + @as(f32, @floatFromInt(cell_z)) * spacing;
            const bx = origin + @as(f32, @floatFromInt(px)) * spacing;
            const bz = origin + @as(f32, @floatFromInt(pz)) * spacing;
            const vx = bx - ax;
            const vz = bz - az;
            const length_sq = vx * vx + vz * vz;
            const t = std.math.clamp(((x - ax) * vx + (z - az) * vz) / length_sq, 0.0, 1.0);
            const nearest_x = ax + vx * t;
            const nearest_z = az + vz * t;
            const ex = x - nearest_x;
            const ez = z - nearest_z;
            const distance = @sqrt(ex * ex + ez * ez);
            if (best) |previous| {
                if (distance > previous.distance or (distance == previous.distance and index >= best_index)) continue;
            }

            const downstream_x = vx / @sqrt(length_sq);
            const downstream_z = vz / @sqrt(length_sq);
            const channel_rain = mixF64(self.discharge[index], self.discharge[p], t);
            const area = channel_rain * @as(f64, @floatFromInt(cell_count)) / @as(f64, @floatFromInt(self.total_rainfall));
            best = .{
                .distance = distance,
                .width = riverWidth(area),
                .strength = riverStrength(area),
                .water_y = mixF64(self.filled[index], self.filled[p], t) * 0.25,
                .flow_x = downstream_x,
                .flow_z = downstream_z,
            };
            best_index = index;
        }
        return best;
    }
};

const SegmentSample = struct {
    distance: f32,
    width: f32,
    strength: f32,
    water_y: f32,
    flow_x: f32,
    flow_z: f32,
};

fn priorityFlood(seed: u64, ground: []const u16, filled: []u16, parent: []u32, order: []u32, visited: []u8, heap: []u32) !void {
    @memset(visited, 0);
    var heap_len: usize = 0;
    for (0..cell_count) |index| {
        if (!isOutlet(index, ground[index])) continue;
        visited[index] = 1;
        filled[index] = ground[index];
        parent[index] = @intCast(index);
        heapPush(heap, &heap_len, @intCast(index), filled, seed);
    }
    if (heap_len == 0) return error.NoDrainageOutlet;

    var order_len: usize = 0;
    while (heap_len > 0) {
        const current_u32 = heapPop(heap, &heap_len, filled, seed);
        const current: usize = current_u32;
        order[order_len] = current_u32;
        order_len += 1;
        const x: i32 = @intCast(current % side);
        const z: i32 = @intCast(current / side);
        var dz: i32 = -1;
        while (dz <= 1) : (dz += 1) {
            var dx: i32 = -1;
            while (dx <= 1) : (dx += 1) {
                if (dx == 0 and dz == 0) continue;
                const nx = x + dx;
                const nz = z + dz;
                if (nx < 0 or nz < 0 or nx >= side or nz >= side) continue;
                const next = @as(usize, @intCast(nz)) * side + @as(usize, @intCast(nx));
                if (visited[next] != 0) continue;
                visited[next] = 1;
                filled[next] = @max(ground[next], filled[current]);
                parent[next] = current_u32;
                heapPush(heap, &heap_len, @intCast(next), filled, seed);
            }
        }
    }
    if (order_len != cell_count) return error.UnreachedTerrainCell;
}

fn classifyWater(ground: []const u16, filled: []const u16, kinds: []WaterKind, visited: []u8, queue: []u32) void {
    @memset(visited, 0);
    @memset(kinds, .dry);
    var queue_len: usize = 0;
    for (0..cell_count) |index| {
        if (!isBoundary(index) or ground[index] > sea_units) continue;
        visited[index] = 1;
        kinds[index] = .ocean;
        queue[queue_len] = @intCast(index);
        queue_len += 1;
    }

    var cursor: usize = 0;
    while (cursor < queue_len) : (cursor += 1) {
        const current: usize = queue[cursor];
        const x: i32 = @intCast(current % side);
        const z: i32 = @intCast(current / side);
        var dz: i32 = -1;
        while (dz <= 1) : (dz += 1) {
            var dx: i32 = -1;
            while (dx <= 1) : (dx += 1) {
                if (dx == 0 and dz == 0) continue;
                const nx = x + dx;
                const nz = z + dz;
                if (nx < 0 or nz < 0 or nx >= side or nz >= side) continue;
                const next = @as(usize, @intCast(nz)) * side + @as(usize, @intCast(nx));
                if (visited[next] != 0 or ground[next] > sea_units) continue;
                visited[next] = 1;
                kinds[next] = .ocean;
                queue[queue_len] = @intCast(next);
                queue_len += 1;
            }
        }
    }

    for (0..cell_count) |index| {
        if (ground[index] <= sea_units and kinds[index] == .dry) {
            kinds[index] = .lake;
        } else if (ground[index] > sea_units and filled[index] - ground[index] >= min_lake_depth_units) {
            kinds[index] = .lake;
        }
    }
}

fn buildNearbyRiverMasks(river_nodes: []const u8, masks: []u32) void {
    for (0..cell_count) |index| masks[index] = expectedRiverMask(river_nodes, index);
}

fn expectedRiverMask(river_nodes: []const u8, index: usize) u32 {
    const center_x: i32 = @intCast(index % side);
    const center_z: i32 = @intCast(index / side);
    var mask: u32 = 0;
    var dz: i32 = -segment_search_radius;
    while (dz <= segment_search_radius) : (dz += 1) {
        var dx: i32 = -segment_search_radius;
        while (dx <= segment_search_radius) : (dx += 1) {
            const cell_x = center_x + dx;
            const cell_z = center_z + dz;
            if (cell_x < 0 or cell_z < 0 or cell_x >= side or cell_z >= side) continue;
            const candidate = @as(usize, @intCast(cell_z)) * side + @as(usize, @intCast(cell_x));
            if (river_nodes[candidate] == 0) continue;
            const bit: u5 = @intCast((dz + segment_search_radius) * 5 + dx + segment_search_radius);
            mask |= @as(u32, 1) << bit;
        }
    }
    return mask;
}

fn heapPush(heap: []u32, len: *usize, value: u32, filled: []const u16, seed: u64) void {
    var child = len.*;
    len.* += 1;
    while (child > 0) {
        const parent_index = (child - 1) / 2;
        const parent_value = heap[parent_index];
        if (!lowerPriority(value, parent_value, filled, seed)) break;
        heap[child] = parent_value;
        child = parent_index;
    }
    heap[child] = value;
}

fn heapPop(heap: []u32, len: *usize, filled: []const u16, seed: u64) u32 {
    const result = heap[0];
    len.* -= 1;
    if (len.* == 0) return result;
    const tail = heap[len.*];
    var parent_index: usize = 0;
    while (true) {
        const left = parent_index * 2 + 1;
        if (left >= len.*) break;
        const right = left + 1;
        var child = left;
        if (right < len.* and lowerPriority(heap[right], heap[left], filled, seed)) child = right;
        if (!lowerPriority(heap[child], tail, filled, seed)) break;
        heap[parent_index] = heap[child];
        parent_index = child;
    }
    heap[parent_index] = tail;
    return result;
}

fn lowerPriority(a: u32, b: u32, filled: []const u16, seed: u64) bool {
    if (filled[a] != filled[b]) return filled[a] < filled[b];
    const ah = tieHash(seed, a);
    const bh = tieHash(seed, b);
    return if (ah == bh) a < b else ah < bh;
}

fn tieHash(seed: u64, index: u32) u64 {
    var value = seed ^ (@as(u64, index) *% 0x9e3779b185ebca87) ^ 0x687964726f2d7469;
    value = (value ^ (value >> 30)) *% 0xbf58476d1ce4e5b9;
    value = (value ^ (value >> 27)) *% 0x94d049bb133111eb;
    return value ^ (value >> 31);
}

fn isBoundary(index: usize) bool {
    const x = index % side;
    const z = index / side;
    return x == 0 or z == 0 or x == side - 1 or z == side - 1;
}

fn isOutlet(index: usize, height: u16) bool {
    return isBoundary(index) or height <= sea_units;
}

fn ceilDiv(numerator: u64, denominator: usize) u64 {
    const d: u64 = @intCast(denominator);
    return numerator / d + @intFromBool(numerator % d != 0);
}

fn riverWidth(area: f64) f32 {
    @setFloatMode(.strict);
    const w = 12.0 + 3.8 * @sqrt(@as(f32, @floatCast(@max(area, 0.0))));
    return @min(w, 96.0);
}

fn riverStrength(area: f64) f32 {
    @setFloatMode(.strict);
    return std.math.clamp(@as(f32, @floatCast(area / 512.0)), 0.0, 1.0);
}

fn heightMetres(value: u16) f32 {
    return @as(f32, @floatFromInt(value)) * 0.25;
}

fn mixF64(a: anytype, b: anytype, t: f32) f32 {
    @setFloatMode(.strict);
    const af: f64 = @floatFromInt(a);
    const bf: f64 = @floatFromInt(b);
    return @floatCast(af + (bf - af) * @as(f64, t));
}

fn bilerp(a: f32, b: f32, c: f32, d: f32, tx: f32, tz: f32) f32 {
    @setFloatMode(.strict);
    const top = a + (b - a) * tx;
    const bottom = c + (d - c) * tx;
    return top + (bottom - top) * tz;
}

test "priority flood fills a closed basin and returns monotone lake and river surfaces" {
    const allocator = std.testing.allocator;
    const heights = try allocator.alloc(u16, cell_count);
    defer allocator.free(heights);
    const rain = try allocator.alloc(u16, cell_count);
    defer allocator.free(rain);
    @memset(heights, 720); // 180 m upland, with 120 m outward outlets.
    for (0..cell_count) |index| {
        if (isBoundary(index)) heights[index] = 480;
        rain[index] = @intCast(1 + index % 11);
    }
    // A 100 m basin surrounded by a 220 m rim, with a 140 m spill corridor.
    for (118..139) |z| {
        for (118..139) |x| {
            const in_basin = x >= 121 and x <= 135 and z >= 121 and z <= 135;
            heights[z * side + x] = if (in_basin) 400 else 880;
        }
    }
    for (136..side - 1) |z| heights[z * side + 128] = 560;
    // A separate below-sea channel connected to the outer edge is ocean.
    for (0..side) |z| heights[z * side] = 300;

    var hydro = try Hydro.init(allocator, 0x6d325f626173696e, heights, rain);
    defer hydro.deinit();
    try hydro.validate();

    const basin_center = 128 * side + 128;
    try std.testing.expectEqual(@as(u16, 400), hydro.ground[basin_center]);
    try std.testing.expectEqual(@as(u16, 560), hydro.filled[basin_center]);
    try std.testing.expectEqual(WaterKind.lake, hydro.water_kind[basin_center]);
    const lake = hydro.sample(0.0, 0.0);
    try std.testing.expect(lake.wet);
    try std.testing.expectEqual(WaterKind.lake, lake.kind);
    try std.testing.expectApproxEqAbs(@as(f32, 140.0), lake.water_y, 0.01);

    const ocean = hydro.sample(origin, 0.0);
    try std.testing.expect(ocean.wet);
    try std.testing.expectEqual(WaterKind.ocean, ocean.kind);
    try std.testing.expectEqual(sea_level, ocean.water_y);

    const spill = hydro.sample(0.0, origin + 140.0 * spacing);
    try std.testing.expectEqual(WaterKind.river, spill.kind);
    try std.testing.expect(spill.wet);
    try std.testing.expect(spill.river_width >= 12.0);
    try std.testing.expect(spill.river_distance < 1.0);
    try std.testing.expect(spill.flow_z > 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 140.0), spill.water_y, 0.01);

    const stats = hydro.summary();
    try std.testing.expect(stats.ocean_cells > 0);
    try std.testing.expect(stats.lake_cells > 0);
    try std.testing.expect(stats.river_cells > 0);
}

test "priority-flood identities repeat for the same seed" {
    const allocator = std.testing.allocator;
    const heights = try allocator.alloc(u16, cell_count);
    defer allocator.free(heights);
    const rain = try allocator.alloc(u16, cell_count);
    defer allocator.free(rain);
    for (0..cell_count) |index| {
        const x = index % side;
        const z = index / side;
        heights[index] = @intCast(520 + (x * 7 + z * 11 + (x * z) % 31) % 500);
        rain[index] = @intCast(1 + (index * 13) % 97);
    }

    var a = try Hydro.init(allocator, 101, heights, rain);
    defer a.deinit();
    var b = try Hydro.init(allocator, 101, heights, rain);
    defer b.deinit();
    try a.validate();
    try b.validate();
    try std.testing.expectEqualSlices(u16, a.filled, b.filled);
    try std.testing.expectEqualSlices(u32, a.parent, b.parent);
    try std.testing.expectEqualSlices(u64, a.discharge, b.discharge);
    try std.testing.expectEqualSlices(u32, a.order, b.order);
}
