const std = @import("std");
const terrain_mod = @import("terrain.zig");

pub const max_buildings: usize = 24;
pub const max_paths: usize = 64;

pub const Point = struct { x: f32, z: f32 };

pub const Kind = enum(u8) {
    home,
    farm,
    workshop,
    granary,
    well,
};

pub const Building = struct {
    /// World-space center of the axis-aligned footprint.
    x: f32,
    z: f32,
    /// Ground elevation at the footprint center; height extends upward.
    y: f32,
    width: f32,
    depth: f32,
    height: f32,
    kind: Kind,
    seed: u64,
};

pub const Path = struct {
    a: Point,
    b: Point,
    width: f32,
};

pub const Surface = enum(u8) { none, path, field };

/// A deterministic small settlement. `terrain_ref` is borrowed: the Terrain
/// passed to init must remain alive at a stable address for this value's life.
pub const Village = struct {
    buildings: [max_buildings]Building = undefined,
    /// Door or field-edge position joined to the public path graph.
    entry_points: [max_buildings]Point = undefined,
    paths: [max_paths]Path = undefined,
    building_count: usize = 0,
    path_count: usize = 0,
    center: Point = .{ .x = 0, .z = 0 },
    arrival: terrain_mod.Place = .{},
    seed: u64 = 0,
    terrain_ref: *const terrain_mod.Terrain,
    bounds_min_x: f32 = 0,
    bounds_max_x: f32 = 0,
    bounds_min_z: f32 = 0,
    bounds_max_z: f32 = 0,

    pub fn init(terrain: *const terrain_mod.Terrain) !Village {
        if (terrain.settlement.score == 0) return error.NoSettlementSite;

        var best: ?Village = null;
        var best_score: f32 = -std.math.inf(f32);
        // The M2 settlement is a useful search anchor, not an accepted village
        // site. Each candidate below is checked against fine terrain, water,
        // building pads and the complete local path network.
        const anchors = [_]Point{
            .{ .x = terrain.settlement.x, .z = terrain.settlement.z },
            .{ .x = terrain.start.x, .z = terrain.start.z },
        };
        for (0..2) |pass| {
            const step: f32 = if (pass == 0) 40 else 72;
            const extent: f32 = if (pass == 0) 240 else 720;
            const count: i32 = @intFromFloat(@floor(extent / step));
            for (anchors) |anchor| {
                var iz: i32 = -count;
                while (iz <= count) : (iz += 1) {
                    var ix: i32 = -count;
                    while (ix <= count) : (ix += 1) {
                        const candidate_center = Point{
                            .x = anchor.x + @as(f32, @floatFromInt(ix)) * step,
                            .z = anchor.z + @as(f32, @floatFromInt(iz)) * step,
                        };
                        if (@abs(candidate_center.x) > 3890 or @abs(candidate_center.z) > 3890) continue;
                        const candidate = try makeAt(terrain, candidate_center) orelse continue;
                        const score = siteScore(terrain, candidate_center, &candidate);
                        if (!std.math.isFinite(score)) continue;
                        if (score > best_score) {
                            best_score = score;
                            best = candidate;
                        }
                    }
                }
            }
            // Only scan the broader ring if the focused search found no viable
            // local site. This keeps normal startup bounded and cache-friendly.
            if (best != null) break;
        }

        if (best == null) try searchRegional(terrain, &best, &best_score, 256, 48);
        if (best == null) try searchRegional(terrain, &best, &best_score, 128, 128);
        var result = best orelse return error.NoViableVillageSite;
        result.rebuildBounds();
        try result.validate();
        return result;
    }

    pub fn buildingsSlice(self: *const Village) []const Building {
        return self.buildings[0..self.building_count];
    }

    pub fn pathsSlice(self: *const Village) []const Path {
        return self.paths[0..self.path_count];
    }

    pub fn entryPoint(self: *const Village, building_index: usize) Point {
        std.debug.assert(building_index < self.building_count);
        return self.entry_points[building_index];
    }

    pub fn doorPoint(self: *const Village, building_index: usize) Point {
        return self.entryPoint(building_index);
    }

    pub fn homeCount(self: *const Village) usize {
        var count: usize = 0;
        for (self.buildingsSlice()) |building| if (building.kind == .home) {
            count += 1;
        };
        return count;
    }

    /// Return the terrain's physical ground elevation at a world coordinate.
    pub fn surfaceY(self: *const Village, x: f32, z: f32) f32 {
        return self.terrain_ref.standingHeight(x, z);
    }

    /// Return path material first, then cultivated field, otherwise none.
    pub fn surfaceAt(self: *const Village, x: f32, z: f32) Surface {
        if (!self.insideBounds(x, z)) return .none;
        for (self.pathsSlice()) |path| {
            const half_width = path.width * 0.5;
            if (distanceToSegmentSquared(x, z, path.a, path.b) <= half_width * half_width) return .path;
        }
        for (self.buildingsSlice()) |building| {
            if (building.kind == .farm and insideFootprint(building, x, z)) return .field;
        }
        return .none;
    }

    /// Mark roads, buildings and fields as cleared of generated vegetation.
    pub fn cleared(self: *const Village, x: f32, z: f32) bool {
        if (!self.insideBounds(x, z)) return false;
        if (self.surfaceAt(x, z) != .none) return true;
        for (self.buildingsSlice()) |building| {
            if (insideFootprint(building, x, z)) return true;
        }
        return false;
    }

    /// Horizontal collision against building and field footprints, expanded by
    /// the caller's actor radius. Roads remain traversable.
    pub fn blocked(self: *const Village, x: f32, z: f32, radius: f32) bool {
        const r = @max(0, radius);
        if (x + r < self.bounds_min_x or x - r > self.bounds_max_x or z + r < self.bounds_min_z or z - r > self.bounds_max_z) return false;
        for (self.buildingsSlice()) |building| {
            const nearest_x = std.math.clamp(x, building.x - building.width * 0.5, building.x + building.width * 0.5);
            const nearest_z = std.math.clamp(z, building.z - building.depth * 0.5, building.z + building.depth * 0.5);
            const dx = x - nearest_x;
            const dz = z - nearest_z;
            if (dx * dx + dz * dz <= r * r or (dx == 0 and dz == 0)) return true;
        }
        return false;
    }

    /// Check building counts, non-overlap, terrain fit, route grades and graph
    /// connectivity. The borrowed Terrain is used for the physical checks.
    pub fn validate(self: *const Village) !void {
        if (self.building_count > max_buildings or self.path_count > max_paths) return error.InvalidVillageCounts;
        if (self.homeCount() < 6) return error.MissingVillageHomes;
        if (countKind(self, .farm) < 2 or countKind(self, .workshop) == 0 or countKind(self, .granary) == 0 or countKind(self, .well) == 0) return error.MissingVillageNeeds;
        if (self.path_count == 0 or self.seed != self.terrain_ref.seed) return error.InvalidVillageIdentity;

        for (self.buildingsSlice(), 0..) |building, index| {
            if (!(building.width > 0 and building.depth > 0 and building.height > 0)) return error.InvalidBuildingDimensions;
            const water = self.terrain_ref.water(building.x, building.z);
            if (water.wet) return error.WetBuilding;
            if (@abs(building.y - self.terrain_ref.height(building.x, building.z)) > 0.001) return error.InvalidBuildingElevation;
            for (self.buildingsSlice()[index + 1 ..]) |other| {
                if (footprintsOverlap(building, other)) return error.OverlappingBuildings;
            }
            var has_entry = false;
            for (self.pathsSlice()) |path| {
                if (samePoint(path.a, self.entry_points[index]) or samePoint(path.b, self.entry_points[index])) {
                    has_entry = true;
                    break;
                }
            }
            if (!has_entry) return error.UnconnectedBuildingEntry;
        }

        for (self.pathsSlice()) |path| {
            if (!(path.width > 0 and pointFinite(path.a) and pointFinite(path.b))) return error.InvalidPath;
            if (!routeValid(self.terrain_ref, path.a, path.b, null)) return error.InvalidPathTerrain;
        }
        if (!self.pathsConnected()) return error.DisconnectedVillagePaths;
        const arrival_distance = std.math.sqrt(squaredDistance(self.arrival.x, self.arrival.z, self.center.x, self.center.z));
        if (arrival_distance < 100 or arrival_distance > 190) return error.InvalidArrivalDistance;
        if (std.math.sqrt(squaredDistance(self.arrival.x, self.arrival.z, self.center.x, self.center.z)) == 0) return error.InvalidArrivalFacing;
        if (!std.math.isFinite(self.arrival.yaw)) return error.InvalidArrivalFacing;
    }

    /// Stable checksum of the generated data; it deliberately excludes the
    /// borrowed terrain pointer and cache state.
    pub fn layoutFingerprint(self: *const Village) u64 {
        var hash = mixWord(0xcbf29ce484222325, self.seed);
        hash = mixWord(hash, @as(u64, @intCast(self.building_count)));
        hash = mixWord(hash, @as(u64, @intCast(self.path_count)));
        for (self.buildingsSlice()) |building| {
            hash = mixWord(hash, floatWord(building.x));
            hash = mixWord(hash, floatWord(building.z));
            hash = mixWord(hash, floatWord(building.y));
            hash = mixWord(hash, floatWord(building.width));
            hash = mixWord(hash, floatWord(building.depth));
            hash = mixWord(hash, floatWord(building.height));
            hash = mixWord(hash, @intFromEnum(building.kind));
            hash = mixWord(hash, building.seed);
        }
        for (self.pathsSlice()) |path| {
            hash = mixWord(hash, floatWord(path.a.x));
            hash = mixWord(hash, floatWord(path.a.z));
            hash = mixWord(hash, floatWord(path.b.x));
            hash = mixWord(hash, floatWord(path.b.z));
            hash = mixWord(hash, floatWord(path.width));
        }
        hash = mixWord(hash, floatWord(self.arrival.x));
        hash = mixWord(hash, floatWord(self.arrival.z));
        hash = mixWord(hash, floatWord(self.arrival.yaw));
        return hash;
    }

    fn pathsConnected(self: *const Village) bool {
        if (self.path_count == 0) return false;
        const Node = struct { point: Point, seen: bool = false };
        var nodes: [max_paths * 2]Node = undefined;
        var node_count: usize = 0;
        for (self.pathsSlice()) |path| {
            for ([_]Point{ path.a, path.b }) |point| {
                var found = false;
                for (nodes[0..node_count]) |node| {
                    if (samePoint(node.point, point)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    nodes[node_count] = .{ .point = point };
                    node_count += 1;
                }
            }
        }
        if (node_count == 0) return false;
        nodes[0].seen = true;
        var changed = true;
        while (changed) {
            changed = false;
            for (self.pathsSlice()) |path| {
                const a = nodeIndex(Node, nodes[0..node_count], path.a) orelse return false;
                const b = nodeIndex(Node, nodes[0..node_count], path.b) orelse return false;
                if (nodes[a].seen and !nodes[b].seen) {
                    nodes[b].seen = true;
                    changed = true;
                }
                if (nodes[b].seen and !nodes[a].seen) {
                    nodes[a].seen = true;
                    changed = true;
                }
            }
        }
        for (nodes[0..node_count]) |node| if (!node.seen) return false;
        return true;
    }

    fn insideBounds(self: *const Village, x: f32, z: f32) bool {
        return x >= self.bounds_min_x and x <= self.bounds_max_x and z >= self.bounds_min_z and z <= self.bounds_max_z;
    }

    fn rebuildBounds(self: *Village) void {
        self.bounds_min_x = std.math.inf(f32);
        self.bounds_max_x = -std.math.inf(f32);
        self.bounds_min_z = std.math.inf(f32);
        self.bounds_max_z = -std.math.inf(f32);
        for (self.buildingsSlice()) |building| {
            self.bounds_min_x = @min(self.bounds_min_x, building.x - building.width * 0.5);
            self.bounds_max_x = @max(self.bounds_max_x, building.x + building.width * 0.5);
            self.bounds_min_z = @min(self.bounds_min_z, building.z - building.depth * 0.5);
            self.bounds_max_z = @max(self.bounds_max_z, building.z + building.depth * 0.5);
        }
        for (self.pathsSlice()) |path| {
            const half_width = path.width * 0.5;
            self.bounds_min_x = @min(self.bounds_min_x, @min(path.a.x, path.b.x) - half_width);
            self.bounds_max_x = @max(self.bounds_max_x, @max(path.a.x, path.b.x) + half_width);
            self.bounds_min_z = @min(self.bounds_min_z, @min(path.a.z, path.b.z) - half_width);
            self.bounds_max_z = @max(self.bounds_max_z, @max(path.a.z, path.b.z) + half_width);
        }
    }
};

const PlanBuilding = struct {
    x: f32,
    z: f32,
    width: f32,
    depth: f32,
    height: f32,
    kind: Kind,
};

const building_plan = [_]PlanBuilding{
    .{ .x = -26, .z = -38, .width = 9, .depth = 8, .height = 7.2, .kind = .home },
    .{ .x = 26, .z = -38, .width = 9, .depth = 8, .height = 7.2, .kind = .home },
    .{ .x = -26, .z = -14, .width = 9, .depth = 8, .height = 7.2, .kind = .home },
    .{ .x = 26, .z = -14, .width = 9, .depth = 8, .height = 7.2, .kind = .home },
    .{ .x = -26, .z = 22, .width = 9, .depth = 8, .height = 7.2, .kind = .home },
    .{ .x = 26, .z = 22, .width = 9, .depth = 8, .height = 7.2, .kind = .home },
    .{ .x = 78, .z = -42, .width = 34, .depth = 28, .height = 0.18, .kind = .farm },
    .{ .x = -78, .z = 42, .width = 34, .depth = 28, .height = 0.18, .kind = .farm },
    .{ .x = -34, .z = 58, .width = 14, .depth = 12, .height = 7.8, .kind = .workshop },
    .{ .x = 34, .z = -58, .width = 12, .depth = 11, .height = 6.5, .kind = .granary },
    .{ .x = -9, .z = 9, .width = 5, .depth = 5, .height = 2.2, .kind = .well },
};

const RelativePath = struct { ax: f32, az: f32, bx: f32, bz: f32, width: f32 };

fn makeAt(terrain: *const terrain_mod.Terrain, center: Point) !?Village {
    var village = Village{
        .terrain_ref = terrain,
        .center = center,
        .seed = terrain.seed,
    };

    for (building_plan, 0..) |plan, i| {
        const x = center.x + plan.x;
        const z = center.z + plan.z;
        if (!validPad(terrain, x, z, plan.width, plan.depth, plan.kind)) return null;
        village.buildings[village.building_count] = .{
            .x = x,
            .z = z,
            .y = terrain.height(x, z),
            .width = plan.width,
            .depth = plan.depth,
            .height = plan.height,
            .kind = plan.kind,
            .seed = hashWord(terrain.seed, 0x6275696c64696e67 +% i),
        };
        village.entry_points[village.building_count] = switch (plan.kind) {
            .home, .workshop, .granary => .{ .x = x, .z = z - plan.depth * 0.5 - 0.6 },
            .farm => .{ .x = x, .z = z + (if (plan.z < 0) @as(f32, 1) else -1) * (plan.depth * 0.5 + 2) },
            .well => .{ .x = center.x - 5.5, .z = center.z + 5.5 },
        };
        village.building_count += 1;
    }
    for (0..village.building_count) |i| for (village.buildingsSlice()[i + 1 ..]) |other| {
        if (footprintsOverlap(village.buildings[i], other)) return null;
    };

    const main_zs = [_]f32{ -68, -66.5, -45, -21, 0, 15, 49, 68 };
    for (0..main_zs.len - 1) |i| {
        try appendPath(&village, .{ .x = center.x, .z = center.z + main_zs[i] }, .{ .x = center.x, .z = center.z + main_zs[i + 1] }, 4.0);
    }
    try appendPath(&village, .{ .x = center.x - 100, .z = center.z }, .{ .x = center.x, .z = center.z }, 4.0);
    try appendPath(&village, .{ .x = center.x, .z = center.z }, .{ .x = center.x + 100, .z = center.z }, 4.0);

    // Home doors face the local street to the north (-Z). Every spur meets an
    // exact node in the main street and ends at the front edge of its house.
    for (building_plan) |plan| {
        if (plan.kind != .home) continue;
        const front_z = plan.z - plan.depth * 0.5;
        const road_z = front_z - 3.0;
        const inner_x = plan.x - std.math.sign(plan.x) * (plan.width * 0.5 + 3.0);
        try appendPath(&village, .{ .x = center.x, .z = center.z + road_z }, .{ .x = center.x + inner_x, .z = center.z + road_z }, 3.2);
        try appendPath(&village, .{ .x = center.x + inner_x, .z = center.z + road_z }, .{ .x = center.x + plan.x, .z = center.z + front_z - 0.6 }, 3.2);
    }
    // Public buildings also open toward -Z and sit beyond the residential rows.
    for (building_plan) |plan| {
        if (plan.kind != .workshop and plan.kind != .granary) continue;
        const front_z = plan.z - plan.depth * 0.5;
        const road_z = front_z - 3.0;
        const inner_x = plan.x - std.math.sign(plan.x) * (plan.width * 0.5 + 3.0);
        try appendPath(&village, .{ .x = center.x, .z = center.z + road_z }, .{ .x = center.x + inner_x, .z = center.z + road_z }, 3.6);
        try appendPath(&village, .{ .x = center.x + inner_x, .z = center.z + road_z }, .{ .x = center.x + plan.x, .z = center.z + front_z - 0.6 }, 3.6);
    }
    // A short spur gives the shared well an explicit street connection.
    try appendPath(&village, .{ .x = center.x, .z = center.z }, .{ .x = center.x - 5.5, .z = center.z + 5.5 }, 2.2);

    // Fields sit outside the house rows. Farm lanes skirt their outside edges
    // and end at the field boundary without cutting through cultivated ground.
    try appendPath(&village, .{ .x = center.x + 100, .z = center.z }, .{ .x = center.x + 100, .z = center.z - 26 }, 3.2);
    try appendPath(&village, .{ .x = center.x + 100, .z = center.z - 26 }, .{ .x = center.x + 78, .z = center.z - 26 }, 3.2);
    try appendPath(&village, .{ .x = center.x - 100, .z = center.z }, .{ .x = center.x - 100, .z = center.z + 26 }, 3.2);
    try appendPath(&village, .{ .x = center.x - 100, .z = center.z + 26 }, .{ .x = center.x - 78, .z = center.z + 26 }, 3.2);

    for (village.pathsSlice()) |path| {
        if (!routeValid(terrain, path.a, path.b, null)) return null;
    }

    var best_entry: ?Point = null;
    var best_route_score = std.math.inf(f32);
    // The player arrives on an existing road, 60 m past one of four village
    // edges. Prefer the gentlest dry approach, with a seed-stable tie break.
    const entries = [_]Point{
        .{ .x = center.x + 160, .z = center.z },
        .{ .x = center.x - 160, .z = center.z },
        .{ .x = center.x, .z = center.z - 128 },
        .{ .x = center.x, .z = center.z + 128 },
    };
    const joins = [_]Point{
        .{ .x = center.x + 100, .z = center.z },
        .{ .x = center.x - 100, .z = center.z },
        .{ .x = center.x, .z = center.z - 68 },
        .{ .x = center.x, .z = center.z + 68 },
    };
    const center_identity = @as(u64, @bitCast(@as(i64, @intFromFloat(center.x)))) ^ std.math.rotl(u64, @as(u64, @bitCast(@as(i64, @intFromFloat(center.z)))), 29);
    const tie_start: usize = @intCast(hashWord(terrain.seed, center_identity) % entries.len);
    for (0..entries.len) |step| {
        const i = (tie_start + step) % entries.len;
        var route_cost: f32 = 0;
        if (!routeValid(terrain, joins[i], entries[i], &route_cost)) continue;
        if (route_cost < best_route_score) {
            best_route_score = route_cost;
            best_entry = entries[i];
        }
    }
    const arrival_point = best_entry orelse return null;
    const join = if (arrival_point.x > center.x) joins[0] else if (arrival_point.x < center.x) joins[1] else if (arrival_point.z < center.z) joins[2] else joins[3];
    try appendPath(&village, join, arrival_point, 4.0);
    village.arrival = .{
        .x = arrival_point.x,
        .z = arrival_point.z,
        .yaw = std.math.atan2(center.x - arrival_point.x, center.z - arrival_point.z),
        .score = terrain.settlement.score,
    };
    village.rebuildBounds();
    village.validate() catch return null;
    return village;
}

fn siteScore(terrain: *const terrain_mod.Terrain, center: Point, village: *const Village) f32 {
    const water = terrain.water(center.x, center.z);
    if (water.wet) return -std.math.inf(f32);
    const bank_distance = nearbyRiverBankDistance(terrain, center);
    if (bank_distance < 24 or bank_distance > 250) return -std.math.inf(f32);
    const height = terrain.height(center.x, center.z);
    if (height < terrain_mod.sea_level + 8 or height > 500) return -std.math.inf(f32);
    const geography = terrain.geography(center.x, center.z, water);
    var pad_variation: f32 = 0;
    for (village.buildingsSlice()) |building| {
        pad_variation += padRange(terrain, building.x, building.z, building.width, building.depth);
    }
    const local_grade = localGrade(terrain, center);
    const water_penalty = @abs(bank_distance - 92) * 0.22;
    const height_penalty = @abs(height - 145) * 0.05;
    const distance = std.math.sqrt(squaredDistance(center.x, center.z, terrain.settlement.x, terrain.settlement.z));
    return @as(f32, @floatFromInt(geography.resources.fertility)) * 1.1 - water_penalty - height_penalty - pad_variation * 2.0 - local_grade * 80 - distance * 0.012;
}

const RegionalCandidate = struct { center: Point, score: f32 };

fn searchRegional(
    terrain: *const terrain_mod.Terrain,
    best: *?Village,
    best_score: *f32,
    spacing: f32,
    keep_count: usize,
) !void {
    const capacity: usize = @min(128, keep_count);
    var candidates: [128]RegionalCandidate = undefined;
    var candidate_count: usize = 0;
    // Coarse regional scans cover sites that the local riverbank anchors miss.
    // The second pass uses half spacing and more shortlisted sites, but only
    // runs when the first bounded scan found no fully validated layout.
    const index_limit: i32 = @intFromFloat(@floor(3890 / spacing));
    var iz: i32 = -index_limit;
    while (iz <= index_limit) : (iz += 1) {
        var ix: i32 = -index_limit;
        while (ix <= index_limit) : (ix += 1) {
            const center = Point{ .x = @as(f32, @floatFromInt(ix)) * spacing, .z = @as(f32, @floatFromInt(iz)) * spacing };
            const score = coarseSiteScore(terrain, center) orelse continue;
            var insertion = candidate_count;
            while (insertion > 0 and candidates[insertion - 1].score < score) : (insertion -= 1) {}
            if (insertion >= capacity) continue;
            if (candidate_count < capacity) candidate_count += 1;
            var shift = candidate_count - 1;
            while (shift > insertion) : (shift -= 1) candidates[shift] = candidates[shift - 1];
            candidates[insertion] = .{ .center = center, .score = score };
        }
    }

    for (candidates[0..candidate_count]) |candidate_site| {
        const village = try makeAt(terrain, candidate_site.center) orelse continue;
        const score = siteScore(terrain, candidate_site.center, &village);
        if (!std.math.isFinite(score)) continue;
        if (score > best_score.*) {
            best_score.* = score;
            best.* = village;
        }
    }
}

fn coarseSiteScore(terrain: *const terrain_mod.Terrain, center: Point) ?f32 {
    if (@abs(center.x) > 3890 or @abs(center.z) > 3890) return null;
    const origin_height = terrain.macroHeight(center.x, center.z);
    if (origin_height < terrain_mod.sea_level + 8 or origin_height > 550) return null;
    const west = terrain.macroHeight(center.x - 100, center.z);
    const east = terrain.macroHeight(center.x + 100, center.z);
    const north = terrain.macroHeight(center.x, center.z - 68);
    const south = terrain.macroHeight(center.x, center.z + 68);
    const grade = @max(@abs(east - west) / 200, @abs(south - north) / 136);
    if (grade > 0.38) return null;

    var iz: i32 = -2;
    while (iz <= 2) : (iz += 1) {
        var ix: i32 = -3;
        while (ix <= 3) : (ix += 1) {
            if (terrain.water(center.x + @as(f32, @floatFromInt(ix)) * 32, center.z + @as(f32, @floatFromInt(iz)) * 32).wet) return null;
        }
    }
    const river_bank = nearbyRiverBankDistance(terrain, center);
    if (river_bank > 300) return null;
    const geography = terrain.geography(center.x, center.z, terrain.water(center.x, center.z));
    const river_penalty = @abs(river_bank - 100) * 0.13;
    const height_penalty = @abs(origin_height - 145) * 0.02;
    const anchor_distance = @min(
        std.math.sqrt(squaredDistance(center.x, center.z, terrain.settlement.x, terrain.settlement.z)),
        std.math.sqrt(squaredDistance(center.x, center.z, terrain.start.x, terrain.start.z)),
    );
    return @as(f32, @floatFromInt(geography.resources.fertility)) - grade * 70 - river_penalty - height_penalty - anchor_distance * 0.004;
}

fn nearbyRiverBankDistance(terrain: *const terrain_mod.Terrain, center: Point) f32 {
    var nearest = std.math.inf(f32);
    const center_water = terrain.water(center.x, center.z);
    if (!center_water.wet and std.math.isFinite(center_water.river_distance)) {
        nearest = @max(0, center_water.river_distance - center_water.river_width * 0.5);
    }
    const directions = [_]Point{
        .{ .x = 1, .z = 0 },                   .{ .x = -1, .z = 0 },                   .{ .x = 0, .z = 1 },                    .{ .x = 0, .z = -1 },
        .{ .x = 0.70710677, .z = 0.70710677 }, .{ .x = 0.70710677, .z = -0.70710677 }, .{ .x = -0.70710677, .z = 0.70710677 }, .{ .x = -0.70710677, .z = -0.70710677 },
    };
    for (directions) |direction| {
        var radius: f32 = 32;
        while (radius <= 256) : (radius += 32) {
            const sample = terrain.water(center.x + direction.x * radius, center.z + direction.z * radius);
            if (std.math.isFinite(sample.river_distance)) {
                const estimate = @max(0, radius + sample.river_distance - sample.river_width * 0.5);
                nearest = @min(nearest, estimate);
            }
        }
    }
    return nearest;
}

fn validPad(terrain: *const terrain_mod.Terrain, x: f32, z: f32, width: f32, depth: f32, kind: Kind) bool {
    const nx: usize = @max(2, @as(usize, @intFromFloat(@ceil(width / 10)))) + 1;
    const nz: usize = @max(2, @as(usize, @intFromFloat(@ceil(depth / 10)))) + 1;
    var min_height = std.math.inf(f32);
    var max_height: f32 = -std.math.inf(f32);
    var iy: usize = 0;
    while (iy < nz) : (iy += 1) {
        const fz = @as(f32, @floatFromInt(iy)) / @as(f32, @floatFromInt(nz - 1)) - 0.5;
        var ix: usize = 0;
        while (ix < nx) : (ix += 1) {
            const fx = @as(f32, @floatFromInt(ix)) / @as(f32, @floatFromInt(nx - 1)) - 0.5;
            const sx = x + width * fx;
            const sz = z + depth * fz;
            if (terrain.water(sx, sz).wet) return false;
            const y = terrain.height(sx, sz);
            min_height = @min(min_height, y);
            max_height = @max(max_height, y);
        }
    }
    const spread_limit: f32 = switch (kind) {
        .farm => 4.8,
        .home => 3.6,
        .workshop, .granary => 3.2,
        .well => 1.8,
    };
    if (max_height - min_height > spread_limit) return false;
    const normal = terrain.normal(x, z);
    const minimum_up: f32 = if (kind == .farm) 0.955 else 0.94;
    return normal[1] >= minimum_up;
}

fn padRange(terrain: *const terrain_mod.Terrain, x: f32, z: f32, width: f32, depth: f32) f32 {
    const center = terrain.height(x, z);
    var range: f32 = 0;
    for ([_]Point{
        .{ .x = x - width * 0.5, .z = z - depth * 0.5 },
        .{ .x = x + width * 0.5, .z = z - depth * 0.5 },
        .{ .x = x - width * 0.5, .z = z + depth * 0.5 },
        .{ .x = x + width * 0.5, .z = z + depth * 0.5 },
    }) |point| range = @max(range, @abs(terrain.height(point.x, point.z) - center));
    return range;
}

fn localGrade(terrain: *const terrain_mod.Terrain, center: Point) f32 {
    const normal = terrain.normal(center.x, center.z);
    return @sqrt(normal[0] * normal[0] + normal[2] * normal[2]) / @max(0.001, normal[1]);
}

fn routeValid(terrain: *const terrain_mod.Terrain, a: Point, b: Point, out_cost: ?*f32) bool {
    const dx = b.x - a.x;
    const dz = b.z - a.z;
    const distance = @sqrt(dx * dx + dz * dz);
    const steps: usize = @max(1, @as(usize, @intFromFloat(@ceil(distance / 6.0))));
    var previous_y: ?f32 = null;
    var route_cost: f32 = 0;
    for (0..steps + 1) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
        const x = a.x + dx * t;
        const z = a.z + dz * t;
        if (terrain.water(x, z).wet) return false;
        const height = terrain.height(x, z);
        if (previous_y) |prior| {
            const segment_grade = @abs(height - prior) / @max(1, distance / @as(f32, @floatFromInt(steps)));
            if (segment_grade > 0.22) return false;
            route_cost += segment_grade;
        }
        const normal = terrain.normal(x, z);
        if (normal[1] < 0.955) return false;
        previous_y = height;
    }
    if (out_cost) |cost| cost.* = route_cost;
    return true;
}

fn appendPath(village: *Village, a: Point, b: Point, width: f32) !void {
    if (village.path_count >= max_paths) return error.TooManyVillagePaths;
    village.paths[village.path_count] = .{ .a = a, .b = b, .width = width };
    village.path_count += 1;
}

fn countKind(village: *const Village, kind: Kind) usize {
    var count: usize = 0;
    for (village.buildingsSlice()) |building| if (building.kind == kind) {
        count += 1;
    };
    return count;
}

fn insideFootprint(building: Building, x: f32, z: f32) bool {
    return @abs(x - building.x) <= building.width * 0.5 and @abs(z - building.z) <= building.depth * 0.5;
}

fn footprintsOverlap(a: Building, b: Building) bool {
    return @abs(a.x - b.x) < (a.width + b.width) * 0.5 and @abs(a.z - b.z) < (a.depth + b.depth) * 0.5;
}

fn distanceToSegmentSquared(x: f32, z: f32, a: Point, b: Point) f32 {
    const dx = b.x - a.x;
    const dz = b.z - a.z;
    const length_squared = dx * dx + dz * dz;
    const t = if (length_squared == 0) 0 else std.math.clamp(((x - a.x) * dx + (z - a.z) * dz) / length_squared, 0, 1);
    const nearest_x = a.x + dx * t;
    const nearest_z = a.z + dz * t;
    return squaredDistance(x, z, nearest_x, nearest_z);
}

fn squaredDistance(ax: f32, az: f32, bx: f32, bz: f32) f32 {
    const dx = ax - bx;
    const dz = az - bz;
    return dx * dx + dz * dz;
}

fn samePoint(a: Point, b: Point) bool {
    return @abs(a.x - b.x) < 0.001 and @abs(a.z - b.z) < 0.001;
}

fn nodeIndex(comptime Node: type, nodes: []const Node, point: Point) ?usize {
    for (nodes, 0..) |node, i| if (samePoint(node.point, point)) return i;
    return null;
}

fn pointFinite(point: Point) bool {
    return std.math.isFinite(point.x) and std.math.isFinite(point.z);
}

fn floatWord(value: f32) u64 {
    return @as(u64, @as(u32, @bitCast(value)));
}

fn hashWord(seed: u64, word: u64) u64 {
    return mixWord(seed ^ 0x9e3779b97f4a7c15, word);
}

fn mixWord(state: u64, word: u64) u64 {
    var value = state ^ (word +% 0x9e3779b97f4a7c15 +% (state << 6) +% (state >> 2));
    value = (value ^ (value >> 30)) *% 0xbf58476d1ce4e5b9;
    value = (value ^ (value >> 27)) *% 0x94d049bb133111eb;
    return value ^ (value >> 31);
}

test "village layout is deterministic and valid across multiple terrain seeds" {
    const seeds = [_]u64{ 0, 1, 42, 659966, 72019, std.math.maxInt(u64) };
    for (seeds) |seed| {
        var terrain = try terrain_mod.Terrain.init(std.testing.allocator, seed);
        defer terrain.deinit();
        const first = try Village.init(&terrain);
        try first.validate();
        try std.testing.expect(first.homeCount() >= 6);
        try std.testing.expect(countKind(&first, .farm) >= 2);
        try std.testing.expect(countKind(&first, .workshop) >= 1);
        try std.testing.expect(countKind(&first, .granary) >= 1);
        try std.testing.expect(countKind(&first, .well) >= 1);
        const second = try Village.init(&terrain);
        try std.testing.expectEqual(first.layoutFingerprint(), second.layoutFingerprint());
        try std.testing.expect(first.cleared(first.arrival.x, first.arrival.z));
        try std.testing.expectEqual(Surface.path, first.surfaceAt(first.arrival.x, first.arrival.z));
    }
}
