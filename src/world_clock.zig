const Village = @import("village.zig").Village;
const Sim = @import("village_sim.zig").Sim;
const Social = @import("people.zig").Social;

/// Schedules social observation at absolute world hours. Large developer clock
/// steps and frame-sized advances visit exactly the same simulation states.
pub fn advance(sim: *Sim, social: *Social, village: *const Village, seconds: u64) void {
    advanceWithEcology(sim, social, village, null, seconds);
}

pub fn advanceWithEcology(sim: *Sim, social: *Social, village: *const Village, ecology: ?*@import("ecology.zig").Ecology, seconds: u64) void {
    var remaining = seconds;
    while (remaining != 0) {
        const step = @min(remaining, 3600 - sim.elapsed_seconds % 3600);
        sim.advance(step, village);
        remaining -= step;
        if (sim.elapsed_seconds % 3600 == 0) {
            if (ecology) |life| life.tick(sim, social, village);
            social.tick(sim);
        }
    }
}

/// Advance physical pen labor alongside the simulation. Split at both world
/// checkpoints and repair completion so no future result reaches an earlier hour.
pub fn advanceWorking(sim: *Sim, social: *Social, village: *const Village, ecology: *@import("ecology.zig").Ecology, x: f32, z: f32, seconds: u64) void {
    var remaining = seconds;
    while (remaining != 0) {
        var step = @min(remaining, 3600 - sim.elapsed_seconds % 3600);
        if (ecology.player_volunteered and ecology.notice and ecology.player_work_seconds < @import("ecology.zig").repair_seconds) {
            step = @min(step, @import("ecology.zig").repair_seconds - ecology.player_work_seconds);
        }
        sim.advance(step, village);
        _ = ecology.playerWork(sim, social, village, x, z, step);
        remaining -= step;
        if (sim.elapsed_seconds % 3600 == 0) {
            ecology.tick(sim, social, village);
            social.tick(sim);
        }
    }
}

test "social world clock agrees across uneven advancement chunks" {
    const std = @import("std");
    const terrain_mod = @import("terrain.zig");
    var terrain = try terrain_mod.Terrain.init(std.testing.allocator, terrain_mod.default_seed);
    defer terrain.deinit();
    const village = try Village.init(&terrain);
    var a = Sim.init(&village, terrain.seed);
    var b = a;
    var sa = Social.init(&a, terrain.seed);
    var sb = sa;
    const duration = 3 * 86400 + 617;
    advance(&a, &sa, &village, duration);
    var remaining: u64 = duration;
    while (remaining != 0) {
        const step = @min(remaining, 1973);
        advance(&b, &sb, &village, step);
        remaining -= step;
    }
    try std.testing.expectEqual(a.fingerprint(), b.fingerprint());
    try std.testing.expectEqual(sa.fingerprint(), sb.fingerprint());
}

test "physical work uses real clock and is invariant across irregular frame partitions" {
    const std = @import("std");
    const terrain_mod = @import("terrain.zig");
    const Ecology = @import("ecology.zig").Ecology;
    var terrain = try terrain_mod.Terrain.init(std.testing.allocator, terrain_mod.default_seed);
    defer terrain.deinit();
    const village = try Village.init(&terrain);
    var a = Sim.init(&village, terrain.seed);
    var sa = Social.init(&a, terrain.seed);
    var ea = Ecology.init(&village, &a, terrain.seed);
    advanceWithEcology(&a, &sa, &village, &ea, 9 * 3600 + 3599);
    try std.testing.expect(ea.volunteer(ea.owner_id));
    // Exercise a nearly finished player repair across an hourly boundary,
    // before the household has allocated enough labor to finish it itself.
    ea.npc_work_seconds = 0;
    for (sa.persons[0..sa.count], 0..) |*person, index| {
        if (index != ea.owner_id) person.knowledge_count = 0;
    }
    ea.player_work_seconds = @import("ecology.zig").repair_seconds - 2;
    var b = a;
    var sb = sa;
    var eb = ea;
    advanceWorking(&a, &sa, &village, &ea, ea.pen.x, ea.pen.z, 4003);
    var remaining: u64 = 4003;
    while (remaining != 0) {
        const step = @min(remaining, 137);
        advanceWorking(&b, &sb, &village, &eb, eb.pen.x, eb.pen.z, step);
        remaining -= step;
    }
    try a.validate(&village);
    try b.validate(&village);
    try ea.validate(&a);
    try eb.validate(&b);
    try std.testing.expectEqual(a.fingerprint(), b.fingerprint());
    try std.testing.expectEqual(sa.fingerprint(), sb.fingerprint());
    try std.testing.expectEqual(ea.fingerprint(), eb.fingerprint());
    try std.testing.expectEqual(@as(u32, 1), ea.player_repaired);
}
