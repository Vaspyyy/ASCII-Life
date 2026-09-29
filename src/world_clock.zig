const Village = @import("village.zig").Village;
const Sim = @import("village_sim.zig").Sim;
const Social = @import("people.zig").Social;

/// Schedules social observation at absolute world hours. Large developer clock
/// steps and frame-sized advances visit exactly the same simulation states.
pub fn advance(sim: *Sim, social: *Social, village: *const Village, seconds: u64) void {
    var remaining = seconds;
    while (remaining != 0) {
        const step = @min(remaining, 3600 - sim.elapsed_seconds % 3600);
        sim.advance(step, village);
        remaining -= step;
        if (sim.elapsed_seconds % 3600 == 0) social.tick(sim);
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
