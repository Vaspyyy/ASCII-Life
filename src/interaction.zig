const std = @import("std");
const Village = @import("village.zig").Village;
const sim_mod = @import("village_sim.zig");
const Camera = @import("camera.zig").Camera;

/// Match the renderer's treatment of people who are indoors.
pub fn visible(resident: *const sim_mod.Resident, village: *const Village) bool {
    if (resident.activity == .sleeping) return false;
    if (resident.activity == .resting and resident.home_building < village.building_count) {
        const home = village.buildingsSlice()[resident.home_building];
        const dx = resident.position.x - home.x;
        const dz = resident.position.z - home.z;
        const radius = @max(home.width, home.depth) * 0.68 + 1;
        if (dx * dx + dz * dz <= radius * radius) return false;
    }
    return true;
}

/// Conversation is local and requires a clear line between the two people.
pub fn target(sim: *const sim_mod.Sim, village: *const Village, camera: *const Camera) ?usize {
    var result: ?usize = null;
    var best: f32 = std.math.inf(f32);
    for (sim.residents[0..sim.resident_count], 0..) |*resident, i| {
        if (!visible(resident, village)) continue;
        const p = resident.position;
        const dx = p.x - camera.player_x;
        const dz = p.z - camera.player_z;
        const distance = @sqrt(dx * dx + dz * dz);
        if (distance > 7 or @abs(p.y - camera.player_y) > 3) continue;
        const facing = (dx * @sin(camera.yaw) + dz * @cos(camera.yaw)) / @max(0.01, distance);
        if (distance > 1.0 and facing < 0.35) continue;
        if (!lineClear(village, .{ camera.player_x, camera.player_y + 1.7, camera.player_z }, .{ p.x, p.y + 1.4, p.z })) continue;
        const score = distance + (1 - facing) * 3;
        if (score < best) {
            best = score;
            result = i;
        }
    }
    return result;
}

fn lineClear(village: *const Village, a: [3]f32, b: [3]f32) bool {
    for (1..16) |i| {
        const t = @as(f32, @floatFromInt(i)) / 16;
        const x = a[0] + (b[0] - a[0]) * t;
        const y = a[1] + (b[1] - a[1]) * t;
        const z = a[2] + (b[2] - a[2]) * t;
        if (village.surfaceY(x, z) > y - 0.15) return false;
        for (village.buildingsSlice()) |building| {
            if (building.kind == .farm) continue;
            if (y < building.y + building.height and @abs(x - building.x) < building.width * 0.5 and @abs(z - building.z) < building.depth * 0.5) return false;
        }
    }
    return true;
}

test "conversation targeting needs an awake visible person nearby and in front" {
    const Terrain = @import("terrain.zig").Terrain;
    var terrain = try Terrain.init(std.testing.allocator, @import("terrain.zig").default_seed);
    defer terrain.deinit();
    const village = try Village.init(&terrain);
    var sim = sim_mod.Sim.init(&village, terrain.seed);
    const p = village.arrival;
    sim.resident_count = 1;
    sim.residents[0].position = .{ .x = p.x, .y = village.surfaceY(p.x, p.z + 2), .z = p.z + 2 };
    sim.residents[0].activity = .visiting;
    var camera = Camera.init(&terrain);
    camera.setPose(&terrain, p.x, p.z, 0, 0, 0);
    try std.testing.expectEqual(@as(?usize, 0), target(&sim, &village, &camera));
    camera.yaw = std.math.pi;
    try std.testing.expectEqual(@as(?usize, null), target(&sim, &village, &camera));
    camera.yaw = 0;
    sim.residents[0].activity = .sleeping;
    try std.testing.expectEqual(@as(?usize, null), target(&sim, &village, &camera));
    sim.residents[0].activity = .visiting;
    camera.player_y += 10;
    try std.testing.expectEqual(@as(?usize, null), target(&sim, &village, &camera));
}

test "building walls occlude conversation lines" {
    const Terrain = @import("terrain.zig").Terrain;
    var terrain = try Terrain.init(std.testing.allocator, @import("terrain.zig").default_seed);
    defer terrain.deinit();
    const village = try Village.init(&terrain);
    const house = village.buildingsSlice()[0];
    try std.testing.expect(!lineClear(&village, .{ house.x - house.width, house.y + 1.5, house.z }, .{ house.x + house.width, house.y + 1.5, house.z }));
}
