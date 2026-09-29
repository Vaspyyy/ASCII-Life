const std = @import("std");
const village_mod = @import("village.zig");
const village_sim = @import("village_sim.zig");
const people = @import("people.zig");
const Village = village_mod.Village;
const Sim = village_sim.Sim;
const Social = people.Social;
const Point = village_mod.Point;

pub const repair_seconds: u64 = 1800;
pub const repair_goods_milli: u64 = 500;

/// One household's small flock and the nearby predators competing for food.
/// Bounded causes drive losses, local observation, public decisions and repair;
/// no contract or completion object is involved.
pub const Ecology = struct {
    seed: u64 = 0,
    pen: Point = .{ .x = 0, .z = 0 },
    well: Point = .{ .x = 0, .z = 0 },
    pen_half: f32 = 4,
    owner_id: u8 = people.player_id,
    animals: u8 = 0,
    initial_animals: u8 = 0,
    losses: u32 = 0,
    attacks: u32 = 0,
    defenses: u32 = 0,
    repaired: u32 = 0,
    player_repaired: u32 = 0,
    notice: bool = false,
    player_volunteered: bool = false,
    fence: u8 = 42,
    predators: u8 = 0,
    hunger: u16 = 0,
    pressure: u16 = 0,
    last_tick_seconds: u64 = 0,
    last_attack_seconds: u64 = 0,
    observed_attacks: u32 = 0,
    assessed_pressure: bool = false,
    event_serial: u32 = 0,
    informed_mask: u32 = 0,
    npc_work_seconds: u64 = 0,
    npc_responder_id: u8 = people.player_id,
    neighbor_repairs: u32 = 0,
    npc_assists: u32 = 0,
    player_work_seconds: u64 = 0,
    player_help_recorded: bool = false,
    guarded_from_seconds: u64 = 0,
    guard_until_seconds: u64 = 0,
    guard_defenses: u32 = 0,
    guard_pending: bool = false,
    player_repair_pending: bool = false,
    repair_pending: bool = false,
    posted_knowledge: ?people.Knowledge = null,

    pub fn init(village: *const Village, sim: *const Sim, seed: u64) Ecology {
        var self = Ecology{ .seed = seed, .last_tick_seconds = sim.elapsed_seconds, .well = village.center };
        for (village.buildingsSlice()) |building| {
            if (building.kind == .well) self.well = .{ .x = building.x, .z = building.z };
        }
        for (sim.residents[0..sim.resident_count]) |resident| {
            if (resident.job != .farmer or !resident.employed or resident.workplace >= village.building_count) continue;
            const field = village.buildings[resident.workplace];
            if (field.kind != .farm) continue;
            self.owner_id = resident.id;
            const entry = village.entryPoint(resident.workplace);
            // The field was already checked for dry, buildable terrain. Put the
            // pen inside its edge, close enough to reach from the clear path.
            self.pen = .{
                .x = std.math.clamp(entry.x, field.x - field.width / 2 + self.pen_half, field.x + field.width / 2 - self.pen_half),
                .z = std.math.clamp(entry.z, field.z - field.depth / 2 + self.pen_half, field.z + field.depth / 2 - self.pen_half),
            };
            self.animals = @intCast(5 + mix64(seed ^ 0xa519) % 4);
            self.initial_animals = self.animals;
            self.predators = @intCast(1 + mix64(seed ^ 0xcef8) % 3);
            self.hunger = @intCast(45 + mix64(seed ^ 0x947e) % 25);
            self.pressure = @intCast(35 + mix64(seed ^ 0x693c) % 30);
            break;
        }
        return self;
    }

    /// The clock calls this at each absolute hour after schedules/economy and
    /// before social observation. Calling twice at a checkpoint does no work.
    pub fn tick(self: *Ecology, sim: *Sim, social: *Social, village: *const Village) void {
        _ = village;
        const now = sim.elapsed_seconds;
        if (now <= self.last_tick_seconds) return;
        std.debug.assert(now / 3600 == self.last_tick_seconds / 3600 + 1);
        self.last_tick_seconds = now;
        if (self.owner_id >= sim.resident_count) return;
        self.informed_mask = 0;
        for (0..social.count) |index| {
            if (social.knowledgeAbout(@intCast(index), .livestock) != null) self.informed_mask |= @as(u32, 1) << @intCast(index);
        }
        self.produceFood(sim);
        const hour = now / 3600 % 24;
        const night = hour >= 20 or hour < 5;
        if (self.predators > 0) {
            self.hunger = @min(200, self.hunger + self.predators * 2);
            // Wild prey success varies by seed/day; predators do not exist only
            // to generate a fixed opening incident for the player.
            if (hour == 18 and mix64(self.seed ^ (now / village_sim.seconds_per_day) ^ 0x77a0) % 100 < 55) self.hunger -|= 28;
            if (night and self.animals > 0 and self.hunger >= 65) {
                const roll = mix64(self.seed ^ (now / 3600 *% 0x9e3779b97f4a7c15));
                if (roll % 100 < self.pressure) self.attack(sim, @intCast(roll >> 32));
            }
        }
        const owner = sim.residents[self.owner_id];
        if (owner.activity == .working and near(owner.position.x, owner.position.z, self.pen, 10)) {
            // A sleeping household cannot know about a remote attack instantly.
            if (!self.assessed_pressure and self.predators > 0 and self.hunger >= 60 and self.fence < 85 and self.animals > 0) {
                // Hungry predators leave fresh tracks beside a weak pen. The
                // farmer can assess that evidence before a loss has occurred.
                self.assessed_pressure = true;
                self.publish(social, now, .livestock_threatened);
                self.notice = true;
                self.posted_knowledge = self.knowledge(now, .livestock_threatened, .notice);
            }
            if (self.observed_attacks != self.attacks) {
                self.observed_attacks = self.attacks;
                self.publish(social, now, if (self.animals == 0) .livestock_lost_all else if (self.losses > 0) .livestock_taken else .livestock_threatened);
                self.notice = self.animals > 0 and self.fence < 85;
                if (self.notice) self.posted_knowledge = self.knowledge(now, .livestock_threatened, .notice);
            }
            if (self.guard_pending or self.player_repair_pending or self.repair_pending) {
                const player_helped = self.guard_pending or self.player_repair_pending;
                self.guard_pending = false;
                self.player_repair_pending = false;
                self.repair_pending = false;
                self.publish(social, now, if (self.animals == 0) .livestock_lost_all else if (self.fence >= 85) .livestock_protected else .livestock_threatened);
                if (player_helped and !self.player_help_recorded) {
                    social.recordPlayerAction(self.owner_id, .helpful_work, now);
                    self.player_help_recorded = true;
                }
            }
        }
        if (self.notice and self.animals > 0 and self.fence < 85) {
            for (sim.residents[0..sim.resident_count], 0..) |resident, index| {
                if (resident.activity != .working or (resident.job != .farmer and resident.job != .craftsperson) or !near(resident.position.x, resident.position.z, self.pen, 10)) continue;
                if (index != self.owner_id and social.knowledgeAbout(@intCast(index), .livestock) == null) continue;
                if (index != self.owner_id) {
                    if (resident.household != owner.household and social.persons[index].relationships[self.owner_id].affinity < 5) continue;
                    self.npc_assists += 1;
                }
                self.npc_work_seconds += 3600;
                self.npc_responder_id = @intCast(index);
                // Informed neighbors can help, but only on reaching this field.
                if (self.npc_work_seconds >= repair_seconds * 6 and self.repair(sim)) {
                    if (index != self.owner_id) self.neighbor_repairs += 1;
                    self.npc_work_seconds = 0;
                    if (owner.activity == .working and near(owner.position.x, owner.position.z, self.pen, 10)) {
                        self.publish(social, now, .livestock_protected);
                    } else self.repair_pending = true;
                    break;
                }
            }
        }
        if (self.notice) {
            // Reading is local to the public well; merely being a resident does
            // not grant omniscient access to a posted household announcement.
            for (sim.residents[0..sim.resident_count], 0..) |resident, index| {
                if (resident.activity == .sleeping or resident.activity == .walking) continue;
                if (!near(resident.position.x, resident.position.z, self.well, 5)) continue;
                social.observeLivestock(@intCast(index), self.posted_knowledge.?);
                self.informed_mask |= @as(u32, 1) << @intCast(index);
            }
        }
    }

    pub fn canVolunteer(self: *const Ecology, speaker: u8) bool {
        return self.notice and self.animals > 0 and self.fence < 85 and speaker < village_sim.max_residents and
            (speaker == self.owner_id or self.informed_mask & (@as(u32, 1) << @intCast(speaker)) != 0);
    }

    pub fn volunteer(self: *Ecology, speaker: u8) bool {
        if (!self.canVolunteer(speaker)) return false;
        self.player_volunteered = true;
        return true;
    }

    /// Actual elapsed local labor is supplied only while the player holds G.
    /// Goods are spent when a repair is possible; saying "help" earns nothing.
    pub fn playerWork(self: *Ecology, sim: *Sim, social: *Social, village: *const Village, x: f32, z: f32, seconds: u64) bool {
        _ = village;
        if (self.animals == 0 or seconds == 0 or !near(x, z, self.pen, 9)) return false;
        // The caller first advances to the end of this physical labor interval,
        // then records labor before that hour's ecology checkpoint.
        const interval_start = sim.elapsed_seconds -| seconds;
        if (self.guard_until_seconds < interval_start) self.guarded_from_seconds = interval_start;
        self.guard_until_seconds = sim.elapsed_seconds;
        if (!self.player_volunteered or !self.notice or self.fence >= 85) return false;
        self.player_work_seconds = @min(repair_seconds, self.player_work_seconds +| seconds);
        if (self.player_work_seconds < repair_seconds or !self.repair(sim)) return false;
        _ = social;
        // The owner must inspect the repaired pen before learning its outcome
        // and crediting the volunteer's promised physical work.
        self.player_repair_pending = true;
        self.player_repaired += 1;
        self.player_work_seconds = 0;
        self.player_volunteered = false;
        return true;
    }

    pub fn noticeKnowledge(self: *const Ecology) ?people.Knowledge {
        return if (self.notice) self.posted_knowledge else null;
    }

    pub fn animalPosition(self: *const Ecology, index: u8) Point {
        const slot = index % 8;
        return .{ .x = self.pen.x - 2.5 + @as(f32, @floatFromInt(slot % 4)) * 1.6, .z = self.pen.z - 1.5 + @as(f32, @floatFromInt(slot / 4)) * 2.8 };
    }

    pub fn predatorPosition(self: *const Ecology) ?Point {
        const hour = self.last_tick_seconds / 3600 % 24;
        if (self.predators == 0 or self.animals == 0 or self.hunger < 65 or (hour >= 5 and hour < 20)) return null;
        return .{ .x = self.pen.x + 7, .z = self.pen.z + 9 };
    }

    pub fn fingerprint(self: *const Ecology) u64 {
        var h = mix64(self.seed);
        inline for (.{ "owner_id", "animals", "initial_animals", "losses", "attacks", "defenses", "repaired", "player_repaired", "notice", "player_volunteered", "fence", "predators", "hunger", "pressure", "last_tick_seconds", "last_attack_seconds", "observed_attacks", "assessed_pressure", "event_serial", "informed_mask", "npc_work_seconds", "npc_responder_id", "neighbor_repairs", "npc_assists", "player_work_seconds", "player_help_recorded", "guarded_from_seconds", "guard_until_seconds", "guard_defenses", "guard_pending", "player_repair_pending", "repair_pending" }) |field| h = mix(h, @field(self, field));
        h = mix(h, @as(u32, @bitCast(self.pen.x)));
        h = mix(h, @as(u32, @bitCast(self.pen.z)));
        if (self.posted_knowledge) |k| {
            h = mix(h, k.event_id);
            h = mix(h, k.evidence_count);
            h = mix(h, k.evidence_losses);
            h = mix(h, k.observed_at);
        }
        return h;
    }

    pub fn validate(self: *const Ecology, sim: *const Sim) !void {
        if (self.last_tick_seconds > sim.elapsed_seconds or self.fence > 100 or self.pressure > 100 or self.hunger > 200 or self.predators > 3) return error.InvalidEcology;
        if (self.owner_id == people.player_id) {
            if (self.animals != 0 or self.initial_animals != 0) return error.InvalidEcology;
            return;
        }
        if (self.owner_id >= sim.resident_count or self.initial_animals > 8 or @as(u32, self.animals) + self.losses != self.initial_animals) return error.InvalidEcology;
        if (self.losses > self.attacks or self.defenses + self.losses != self.attacks or self.observed_attacks > self.attacks) return error.InvalidEcology;
        if (self.notice and (self.posted_knowledge == null or self.animals == 0 or self.fence >= 85)) return error.InvalidEcology;
        if (self.player_work_seconds > repair_seconds or self.guard_defenses > self.defenses or self.neighbor_repairs > self.repaired or self.player_repaired > self.repaired) return error.InvalidEcology;
    }

    fn produceFood(self: *Ecology, sim: *Sim) void {
        // Small aggregate milk/egg output; loses future production with animals.
        const produced = @as(u64, self.animals) * 30;
        sim.economy.livestock_food_produced_milli += produced;
        const stored = @min(produced, sim.food_stock_capacity_milli -| sim.economy.food_stock_milli);
        sim.economy.food_stock_milli += stored;
        sim.economy.food_discarded_milli += produced - stored;
    }

    fn attack(self: *Ecology, sim: *Sim, roll: u32) void {
        self.attacks += 1;
        self.last_attack_seconds = sim.elapsed_seconds;
        if (self.guarded_from_seconds < sim.elapsed_seconds and self.guard_until_seconds >= sim.elapsed_seconds) {
            self.defenses += 1;
            self.guard_defenses += 1;
            self.guard_pending = true;
            self.hunger -|= 45;
        } else if (roll % 100 < self.fence) {
            self.defenses += 1;
            self.fence -|= 2;
            self.hunger -|= 8;
        } else {
            self.animals -= 1;
            self.losses += 1;
            self.fence -|= 15;
            self.hunger -|= 60;
            // The breach also spoils household feed/provisions, measured apart
            // from normal resident consumption and from lost animal identity.
            const spoiled = @min(sim.economy.food_stock_milli, 1000);
            sim.economy.food_stock_milli -= spoiled;
            sim.economy.livestock_food_lost_milli += spoiled;
            if (self.animals == 0) {
                self.notice = false;
                self.player_volunteered = false;
            }
        }
    }

    fn repair(self: *Ecology, sim: *Sim) bool {
        if (sim.economy.goods_stock_milli < repair_goods_milli) return false;
        sim.economy.goods_stock_milli -= repair_goods_milli;
        sim.economy.repair_goods_consumed_milli += repair_goods_milli;
        self.fence = 100;
        self.repaired += 1;
        self.notice = false;
        self.posted_knowledge = null;
        return true;
    }

    fn knowledge(self: *const Ecology, now: u64, belief: people.Belief, provenance: people.Provenance) people.Knowledge {
        return .{ .topic = .livestock, .belief = belief, .provenance = provenance, .confidence = 96, .source_id = self.owner_id, .witness_id = self.owner_id, .subject_id = self.owner_id, .event_id = 0x500000 + self.event_serial, .observed_at = now, .evidence_count = self.animals, .evidence_losses = @intCast(self.losses) };
    }

    fn publish(self: *Ecology, social: *Social, now: u64, belief: people.Belief) void {
        self.event_serial +|= 1;
        social.observeLivestock(self.owner_id, self.knowledge(now, belief, .witnessed));
        self.informed_mask |= @as(u32, 1) << @intCast(self.owner_id);
    }
};

fn near(x: f32, z: f32, point: Point, radius: f32) bool {
    const dx = x - point.x;
    const dz = z - point.z;
    return dx * dx + dz * dz <= radius * radius;
}
fn mix(h: u64, value: anytype) u64 {
    const number: u64 = if (@TypeOf(value) == bool) @intFromBool(value) else @intCast(value);
    return mix64(h ^ number);
}
fn mix64(input: u64) u64 {
    var x = input;
    x = (x ^ (x >> 30)) *% 0xbf58476d1ce4e5b9;
    x = (x ^ (x >> 27)) *% 0x94d049bb133111eb;
    return x ^ (x >> 31);
}

fn fixtureSim() Sim {
    var sim = Sim{ .resident_count = 2, .household_count = 1, .food_stock_capacity_milli = 1_000_000 };
    sim.economy = .{ .food_stock_milli = 100_000, .initial_food_milli = 100_000, .goods_stock_milli = 10_000, .initial_goods_milli = 10_000 };
    sim.households[0] = .{ .home_building = 0, .first_resident = 0, .resident_count = 2 };
    sim.residents[0] = .{ .id = 0, .age_years = 36, .appearance_seed = 1, .household = 0, .home_building = 0, .public_building = 1, .workplace = 0, .job = .farmer, .employed = true, .activity = .working, .position = .{ .x = -17, .y = 0, .z = 0 } };
    sim.residents[1] = .{ .id = 1, .age_years = 34, .appearance_seed = 2, .household = 0, .home_building = 0, .public_building = 1, .workplace = 1, .job = .keeper, .employed = true, .activity = .resting, .position = .{ .x = -17, .y = 0, .z = 0 } };
    return sim;
}

fn fixtureVillage() Village {
    var village = Village{ .terrain_ref = undefined, .building_count = 2 };
    village.buildings[0] = .{ .x = 0, .z = 0, .y = 0, .width = 34, .depth = 28, .height = 0, .kind = .farm, .seed = 41 };
    village.entry_points[0] = .{ .x = -17, .z = 0 };
    village.buildings[1] = .{ .x = 20, .z = 20, .y = 0, .width = 3, .depth = 3, .height = 1, .kind = .well, .seed = 41 };
    village.entry_points[1] = .{ .x = 20, .z = 20 };
    return village;
}

fn fixtureTick(ecology: *Ecology, sim: *Sim, social: *Social, village: *const Village, hours: usize) void {
    for (0..hours) |_| {
        sim.elapsed_seconds += 3600;
        ecology.tick(sim, social, village);
        social.tick(sim);
    }
}

test "predation changes actual flock and provisioning without player or quest state" {
    const village = fixtureVillage();
    var vulnerable = fixtureSim();
    var safe = vulnerable;
    var social = Social.init(&vulnerable, 41);
    var safe_social = Social.init(&safe, 41);
    var ecology = Ecology.init(&village, &vulnerable, 41);
    ecology.fence = 0;
    ecology.pressure = 100;
    ecology.hunger = 200;
    // Absent local labor cannot magically maintain a pen from elsewhere.
    vulnerable.residents[0].position.x = -100;
    safe.residents[0].position.x = -100;
    var no_predators = ecology;
    no_predators.predators = 0;
    fixtureTick(&ecology, &vulnerable, &social, &village, 24 * 14);
    fixtureTick(&no_predators, &safe, &safe_social, &village, 24 * 14);
    try ecology.validate(&vulnerable);
    try no_predators.validate(&safe);
    try std.testing.expect(ecology.losses > 0);
    try std.testing.expectEqual(@as(u32, 0), no_predators.losses);
    try std.testing.expect(vulnerable.economy.livestock_food_lost_milli > 0);
    try std.testing.expect(safe.economy.livestock_food_produced_milli > vulnerable.economy.livestock_food_produced_milli);
    try std.testing.expectEqual(@as(u32, 0), ecology.repaired);
    try std.testing.expect(social.knowledgeAbout(0, .livestock) == null);
    try std.testing.expectEqual(vulnerable.economy.initial_food_milli + vulnerable.economy.livestock_food_produced_milli, vulnerable.economy.food_stock_milli + vulnerable.economy.livestock_food_lost_milli + vulnerable.economy.food_discarded_milli);
}

test "owner inspection notice and repair depend on presence labor and goods" {
    const village = fixtureVillage();
    var sim = fixtureSim();
    var social = Social.init(&sim, 41);
    var ecology = Ecology.init(&village, &sim, 41);
    ecology.hunger = 100;
    fixtureTick(&ecology, &sim, &social, &village, 1);
    try std.testing.expect(ecology.notice);
    const posted = ecology.noticeKnowledge().?;
    try std.testing.expectEqual(people.Provenance.notice, posted.provenance);
    try std.testing.expectEqual(ecology.owner_id, posted.subject_id);
    try std.testing.expect(!ecology.volunteer(23));
    const before = sim.economy.goods_stock_milli;
    fixtureTick(&ecology, &sim, &social, &village, 2);
    try std.testing.expectEqual(@as(u32, 1), ecology.repaired);
    try std.testing.expectEqual(before - repair_goods_milli, sim.economy.goods_stock_milli);
    try std.testing.expect(!ecology.notice);
    try std.testing.expectEqual(@as(i8, 0), social.trust(ecology.owner_id));
    try std.testing.expectEqual(people.Belief.livestock_protected, social.knowledgeAbout(0, .livestock).?.belief);
    try ecology.validate(&sim);
}

test "player repair spends real goods and one earned trust action with partition independent timestamp" {
    const village = fixtureVillage();
    var whole = fixtureSim();
    var social = Social.init(&whole, 41);
    var ecology = Ecology.init(&village, &whole, 41);
    ecology.hunger = 100;
    fixtureTick(&ecology, &whole, &social, &village, 1);
    try std.testing.expect(ecology.volunteer(0));
    var chunks = whole;
    var chunks_social = social;
    var chunks_ecology = ecology;
    try std.testing.expect(!ecology.playerWork(&whole, &social, &village, 100, 100, repair_seconds));
    try std.testing.expectEqual(@as(u64, 0), ecology.player_work_seconds);
    whole.elapsed_seconds += repair_seconds;
    try std.testing.expect(ecology.playerWork(&whole, &social, &village, ecology.pen.x, ecology.pen.z, repair_seconds));
    const parts = [_]u64{ 7, 193, 401, 999, 200 };
    for (parts) |part| {
        chunks.elapsed_seconds += part;
        _ = chunks_ecology.playerWork(&chunks, &chunks_social, &village, ecology.pen.x, ecology.pen.z, part);
    }
    try std.testing.expectEqual(ecology.fingerprint(), chunks_ecology.fingerprint());
    try std.testing.expectEqual(social.fingerprint(), chunks_social.fingerprint());
    try std.testing.expectEqual(whole.fingerprint(), chunks.fingerprint());
    try std.testing.expectEqual(@as(i8, 0), social.trust(0));
    whole.elapsed_seconds = 2 * 3600;
    ecology.tick(&whole, &social, &village);
    try std.testing.expectEqual(@as(i8, 8), social.trust(0));
    try std.testing.expectEqual(repair_goods_milli, whole.economy.repair_goods_consumed_milli);
    try std.testing.expect(!ecology.playerWork(&whole, &social, &village, ecology.pen.x, ecology.pen.z, repair_seconds));
    try ecology.validate(&whole);
}

test "material shortage prevents both autonomous and player repair" {
    const village = fixtureVillage();
    var sim = fixtureSim();
    sim.economy.goods_stock_milli = 0;
    sim.economy.initial_goods_milli = 0;
    var social = Social.init(&sim, 41);
    var ecology = Ecology.init(&village, &sim, 41);
    ecology.hunger = 100;
    fixtureTick(&ecology, &sim, &social, &village, 3);
    try std.testing.expect(ecology.notice);
    try std.testing.expect(ecology.volunteer(0));
    try std.testing.expect(!ecology.playerWork(&sim, &social, &village, ecology.pen.x, ecology.pen.z, repair_seconds));
    try std.testing.expectEqual(@as(u32, 0), ecology.repaired);
    try std.testing.expectEqual(@as(i8, 0), social.trust(0));
}

test "physical guarding deters real attack and expires when player leaves" {
    const village = fixtureVillage();
    var sim = fixtureSim();
    sim.elapsed_seconds = 19 * 3600;
    var social = Social.init(&sim, 41);
    var ecology = Ecology.init(&village, &sim, 41);
    ecology.pressure = 100;
    ecology.hunger = 200;
    ecology.fence = 0;
    sim.residents[0].activity = .sleeping;
    const before = ecology.animals;
    sim.elapsed_seconds += 3600;
    _ = ecology.playerWork(&sim, &social, &village, ecology.pen.x, ecology.pen.z, 3600);
    ecology.tick(&sim, &social, &village);
    social.tick(&sim);
    try std.testing.expectEqual(before, ecology.animals);
    try std.testing.expectEqual(@as(u32, 1), ecology.guard_defenses);
    // A sleeping owner has not yet witnessed the successful watch.
    try std.testing.expectEqual(@as(i8, 0), social.trust(0));
    fixtureTick(&ecology, &sim, &social, &village, 1);
    try std.testing.expect(ecology.animals < before);
    sim.residents[0].activity = .working;
    fixtureTick(&ecology, &sim, &social, &village, 1);
    try std.testing.expectEqual(@as(i8, 8), social.trust(0));
    try ecology.validate(&sim);
}

test "informed nearby coworker can repair but remote labor cannot" {
    const village = fixtureVillage();
    var sim = fixtureSim();
    sim.residents[1].job = .farmer;
    sim.residents[1].activity = .working;
    var social = Social.init(&sim, 41);
    var ecology = Ecology.init(&village, &sim, 41);
    ecology.hunger = 100;
    fixtureTick(&ecology, &sim, &social, &village, 1);
    try std.testing.expect(social.knowledgeAbout(1, .livestock) != null);
    sim.residents[0].position.x = -100;
    fixtureTick(&ecology, &sim, &social, &village, 2);
    try std.testing.expectEqual(@as(u32, 1), ecology.neighbor_repairs);
    try std.testing.expectEqual(@as(u8, 1), ecology.npc_responder_id);
    try std.testing.expectEqual(@as(u32, 0), ecology.player_repaired);
    try ecology.validate(&sim);
}

test "real clock working integration gives same consequences under arbitrary chunks" {
    const clock = @import("world_clock.zig");
    const terrain_mod = @import("terrain.zig");
    var terrain = try terrain_mod.Terrain.init(std.testing.allocator, terrain_mod.default_seed);
    defer terrain.deinit();
    const village = try Village.init(&terrain);
    var whole = Sim.init(&village, terrain.seed);
    var social = Social.init(&whole, terrain.seed);
    var ecology = Ecology.init(&village, &whole, terrain.seed);
    clock.advanceWithEcology(&whole, &social, &village, &ecology, 9 * 3600);
    try std.testing.expect(ecology.notice);
    try std.testing.expect(ecology.volunteer(ecology.owner_id));
    var chunks = whole;
    var chunks_social = social;
    var chunks_ecology = ecology;
    clock.advanceWorking(&whole, &social, &village, &ecology, ecology.pen.x, ecology.pen.z, 2 * 3600 + 317);
    var remaining: u64 = 2 * 3600 + 317;
    while (remaining != 0) {
        const part = @min(remaining, 137);
        clock.advanceWorking(&chunks, &chunks_social, &village, &chunks_ecology, ecology.pen.x, ecology.pen.z, part);
        remaining -= part;
    }
    try std.testing.expectEqual(whole.fingerprint(), chunks.fingerprint());
    try std.testing.expectEqual(social.fingerprint(), chunks_social.fingerprint());
    try std.testing.expectEqual(ecology.fingerprint(), chunks_ecology.fingerprint());
    try std.testing.expectEqual(@as(u32, 1), ecology.player_repaired);
    try std.testing.expectEqual(@as(i8, 8), social.trust(ecology.owner_id));
    try whole.validate(&village);
    try social.validate(&whole);
    try ecology.validate(&whole);
}
