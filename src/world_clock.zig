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

pub const LifeMode = enum { idle, field, pen, routine };

/// Domestic and physical actions share the same clock and completion boundaries.
pub fn advanceLife(sim: *Sim, social: *Social, village: *const Village, ecology: *@import("ecology.zig").Ecology, life: *@import("life.zig").Life, mode: LifeMode, x: f32, z: f32, seconds: u64) void {
    if (mode == .routine and !life.canSkip(sim, village, x, z)) return;
    const saved_routine = life.routine;
    life.routine = mode == .routine and life.home_household != null and life.employer_id != null;
    defer life.routine = saved_routine;
    sim.seasonal_farming = true;
    var remaining = seconds;
    while (remaining != 0) {
        var step = @min(remaining, 3600 - sim.elapsed_seconds % 3600);
        if (mode == .field or life.routine) step = @min(step, life.workPeriodRemaining());
        if (mode == .pen and ecology.player_volunteered and ecology.notice and ecology.player_work_seconds < @import("ecology.zig").repair_seconds) step = @min(step, @import("ecology.zig").repair_seconds - ecology.player_work_seconds);
        sim.advance(step, village);
        if (mode == .field) life.work(sim, social, village, x, z, step);
        if (mode == .pen) _ = ecology.playerWork(sim, social, village, x, z, step);
        if (life.routine) if (life.fieldPoint(sim, village)) |field| life.work(sim, social, village, field.x, field.z, step);
        if (sim.elapsed_seconds % 3600 == 0) {
            ecology.tick(sim, social, village);
            life.tick(sim, social, village);
            social.tick(sim);
        }
        remaining -= step;
        // An unsafe home or unmet needs interrupt a domestic routine. The
        // caller observes the shorter duration and explains the interruption.
        if (mode == .routine and (life.home_household == null or life.hunger >= 950 or life.fatigue >= 950)) break;
    }
}

test "anchored life clock preserves all consequences across irregular time partitions" {
    const std = @import("std");
    const terrain_mod = @import("terrain.zig");
    const Ecology = @import("ecology.zig").Ecology;
    const Life = @import("life.zig").Life;
    var terrain = try terrain_mod.Terrain.init(std.testing.allocator, terrain_mod.default_seed);
    defer terrain.deinit();
    const village = try Village.init(&terrain);
    var sim = Sim.init(&village, terrain.seed);
    var social = Social.init(&sim, terrain.seed);
    var ecology = Ecology.init(&village, &sim, terrain.seed);
    var life = Life.init(&sim);
    const original_sim = sim.fingerprint();
    const original_social = social.fingerprint();
    const original_ecology = ecology.fingerprint();
    const original_life = life.fingerprint();
    advanceLife(&sim, &social, &village, &ecology, &life, .routine, village.arrival.x, village.arrival.z, 7 * @import("village_sim.zig").seconds_per_day);
    try std.testing.expectEqual(original_sim, sim.fingerprint());
    try std.testing.expectEqual(original_social, social.fingerprint());
    try std.testing.expectEqual(original_ecology, ecology.fingerprint());
    try std.testing.expectEqual(original_life, life.fingerprint());
    var farmer: ?u8 = null;
    for (sim.residents[0..sim.resident_count]) |resident| if (resident.job == .farmer) {
        farmer = resident.id;
        break;
    };
    try std.testing.expect(life.hire(farmer.?, &sim, &social));
    advanceLife(&sim, &social, &village, &ecology, &life, .idle, 0, 0, 8 * 3600);
    const field = life.fieldPoint(&sim, &village).?;
    advanceLife(&sim, &social, &village, &ecology, &life, .field, field.x, field.z, 9 * 3600);
    try std.testing.expect(life.paid_hours >= 4);
    try std.testing.expect(life.rentHome(farmer.?, &sim, &social));
    const door = village.doorPoint(life.home_building.?);
    const before_remote = sim.elapsed_seconds;
    const paid_before_remote = life.paid_hours;
    advanceLife(&sim, &social, &village, &ecology, &life, .routine, door.x + 1000, door.z + 1000, 7 * @import("village_sim.zig").seconds_per_day);
    try std.testing.expectEqual(before_remote, sim.elapsed_seconds);
    try std.testing.expectEqual(paid_before_remote, life.paid_hours);
    life.hunger = 950;
    advanceLife(&sim, &social, &village, &ecology, &life, .routine, door.x, door.z, 7 * @import("village_sim.zig").seconds_per_day);
    try std.testing.expectEqual(before_remote, sim.elapsed_seconds);
    life.hunger = 0;
    var hungry_sim = sim;
    var hungry_social = social;
    var hungry_ecology = ecology;
    var hungry_life = life;
    hungry_life.employer_id = null;
    hungry_life.food_milli = 0;
    hungry_life.hunger = 940;
    advanceLife(&hungry_sim, &hungry_social, &village, &hungry_ecology, &hungry_life, .routine, door.x, door.z, 7 * @import("village_sim.zig").seconds_per_day);
    try std.testing.expectEqual(before_remote + 3600, hungry_sim.elapsed_seconds);
    try std.testing.expect(hungry_life.hunger >= 950);
    var partitioned_sim = sim;
    var partitioned_social = social;
    var partitioned_ecology = ecology;
    var partitioned_life = life;
    const duration = 95 * @import("village_sim.zig").seconds_per_day + 617;
    advanceLife(&sim, &social, &village, &ecology, &life, .routine, door.x, door.z, duration);
    var remaining: u64 = duration;
    const intervals = [_]u64{ 137, 3701, 82_763, 17, 903, 43_119 };
    var index: usize = 0;
    while (remaining != 0) : (index += 1) {
        const step = @min(remaining, intervals[index % intervals.len]);
        advanceLife(&partitioned_sim, &partitioned_social, &village, &partitioned_ecology, &partitioned_life, .routine, door.x, door.z, step);
        remaining -= step;
    }
    try std.testing.expectEqual(sim.fingerprint(), partitioned_sim.fingerprint());
    try std.testing.expectEqual(social.fingerprint(), partitioned_social.fingerprint());
    try std.testing.expectEqual(ecology.fingerprint(), partitioned_ecology.fingerprint());
    try std.testing.expectEqual(life.fingerprint(), partitioned_life.fingerprint());
    try std.testing.expect(life.home_household != null);
    try std.testing.expectEqual(@as(u64, 0), life.food_shortage_milli);
    try sim.validate(&village);
    try social.validate(&sim);
    try ecology.validate(&sim);
    try life.validate(&sim);
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
