const std = @import("std");
const sim_mod = @import("village_sim.zig");
const people = @import("people.zig");
const village_mod = @import("village.zig");
const Sim = sim_mod.Sim;
const Social = people.Social;
const Village = village_mod.Village;

pub const days_per_year: u64 = 360;
pub const days_per_season: u64 = 90;
pub const seconds_per_year: u64 = days_per_year * sim_mod.seconds_per_day;
pub const daily_work_limit: u64 = 6 * 3600;
pub const Season = enum(u8) { spring, summer, autumn, winter };

pub fn season(seconds: u64) Season {
    return @enumFromInt((seconds / sim_mod.seconds_per_day / days_per_season) % 4);
}

/// Player life stores earned changes. Routine is an explicit instruction to
/// carry on a household's ordinary work, shopping and rest through the clock.
pub const Life = struct {
    coins: u32 = 10,
    food_milli: u64 = 3_000,
    hunger: u16 = 0,
    fatigue: u16 = 0,
    age_years: u16 = 15,
    employer_id: ?u8 = null,
    home_household: ?u8 = null,
    home_building: ?u8 = null,
    work_seconds: u64 = 0,
    paid_hours: u64 = 0,
    skill: u16 = 0,
    routine: bool = false,
    arrived_at: u64 = 0,
    last_tick_seconds: u64 = 0,
    last_work_at: u64 = 0,
    work_day: u64 = 0,
    day_work_seconds: u32 = 0,
    work_remainder_seconds: u16 = 0,
    production_remainder: u64 = 0,
    need_remainder: u32 = 0,
    food_consumed_milli: u64 = 0,
    food_shortage_milli: u64 = 0,
    aged_years: u16 = 0,
    rent_paid_until_day: u64 = 0,
    rent_arrears_days: u16 = 0,

    pub fn init(sim: *const Sim) Life {
        return .{ .arrived_at = sim.elapsed_seconds, .last_tick_seconds = sim.elapsed_seconds, .last_work_at = sim.elapsed_seconds, .work_day = sim.day() };
    }

    pub fn hire(self: *Life, speaker: u8, sim: *const Sim, social: *Social) bool {
        if (self.employer_id) |current| if (current != speaker) return false;
        if (speaker >= sim.resident_count or social.trust(speaker) < -20) return false;
        const resident = sim.residents[speaker];
        if (resident.job != .farmer or !resident.employed or resident.age_years < 18) return false;
        self.employer_id = speaker;
        social.meet(speaker, sim.elapsed_seconds);
        return true;
    }

    pub fn buyFood(self: *Life, speaker: u8, sim: *Sim, social: *Social) bool {
        if (speaker >= sim.resident_count or sim.residents[speaker].job != .keeper or !sim.residents[speaker].employed or social.trust(speaker) < -20) return false;
        if (!self.purchase(sim)) return false;
        social.meet(speaker, sim.elapsed_seconds);
        return true;
    }

    pub fn rentHome(self: *Life, speaker: u8, sim: *Sim, social: *Social) bool {
        if (speaker >= sim.resident_count or self.home_household != null or self.coins < 7) return false;
        const resident = sim.residents[speaker];
        if (!resident.employed or resident.age_years < 18 or social.trust(speaker) < 0) return false;
        const worked_for_household = if (self.employer_id) |employer| self.paid_hours >= 4 and sim.residents[employer].household == resident.household else false;
        if (!worked_for_household and social.trust(speaker) < 8) return false;
        self.coins -= 7;
        sim.economy.player_rent_payments += 7;
        self.home_household = resident.household;
        self.home_building = @intCast(resident.home_building);
        self.rent_paid_until_day = sim.day() + 7;
        self.rent_arrears_days = 0;
        social.meet(speaker, sim.elapsed_seconds);
        return true;
    }

    pub fn atHome(self: *const Life, village: *const Village, x: f32, z: f32) bool {
        const home = self.home_building orelse return false;
        if (home >= village.building_count) return false;
        const door = village.doorPoint(home);
        return near(x, z, door.x, door.z, 9);
    }

    pub fn canSkip(self: *const Life, sim: *const Sim, village: *const Village, x: f32, z: f32) bool {
        return self.home_household != null and self.rent_arrears_days < 7 and self.hunger < 950 and self.fatigue < 950 and self.atHome(village, x, z) and sim.day() < std.math.maxInt(u64) / sim_mod.seconds_per_day;
    }

    pub fn fieldPoint(self: *const Life, sim: *const Sim, village: *const Village) ?village_mod.Point {
        const employer = self.employer_id orelse return null;
        if (employer >= sim.resident_count) return null;
        const resident = sim.residents[employer];
        if (resident.workplace >= village.building_count or village.buildings[resident.workplace].kind != .farm) return null;
        return village.entryPoint(resident.workplace);
    }

    pub fn workReady(self: *const Life, sim: *const Sim, village: *const Village) bool {
        const point = self.fieldPoint(sim, village) orelse return false;
        const resident = sim.residents[self.employer_id.?];
        const second = (sim.elapsed_seconds -| 1) % sim_mod.seconds_per_day;
        return resident.employed and resident.age_years >= 18 and resident.job == .farmer and near(resident.position.x, resident.position.z, point.x, point.z, 8) and workingTime(second) and self.hunger < 950 and self.fatigue < 950 and (self.work_day != sim.day() or self.day_work_seconds < daily_work_limit);
    }

    pub fn workPeriodRemaining(self: *const Life) u64 {
        return 3600 - self.work_remainder_seconds;
    }

    /// Pay only a fresh elapsed interval, physically at the farmer's actual
    /// cultivated plot, while the adult farmer is present during work hours.
    pub fn work(self: *Life, sim: *Sim, social: *Social, village: *const Village, x: f32, z: f32, seconds: u64) void {
        const end = sim.elapsed_seconds;
        var start = @max(end -| seconds, self.last_work_at);
        self.last_work_at = @max(self.last_work_at, end);
        if (start >= end or self.hunger >= 950 or self.fatigue >= 950) return;
        const point = self.fieldPoint(sim, village) orelse return;
        const employer = self.employer_id.?;
        const farmer = sim.residents[employer];
        if (!farmer.employed or farmer.age_years < 18 or farmer.job != .farmer or !near(x, z, point.x, point.z, 9) or !near(farmer.position.x, farmer.position.z, point.x, point.z, 8)) return;
        // Arrival may occur within this interval. Do not credit the earlier
        // time when a farmer was still travelling toward the field.
        if (farmer.target_building == farmer.workplace and farmer.route_started <= end) start = @max(start, @min(end, farmer.route_arrives));
        while (start < end) {
            const day = start / sim_mod.seconds_per_day;
            const boundary = @min(end, (start / 3600 + 1) * 3600);
            if (self.work_day != day) {
                self.work_day = day;
                self.day_work_seconds = 0;
            }
            if (workingTime(start % sim_mod.seconds_per_day)) {
                const credited = @min(boundary - start, daily_work_limit - self.day_work_seconds);
                self.creditWork(sim, social, employer, credited, boundary);
            }
            start = boundary;
        }
    }

    /// The shared world clock calls this once per absolute hour after ecology.
    pub fn tick(self: *Life, sim: *Sim, social: *Social, village: *const Village) void {
        _ = village;
        sim.seasonal_farming = true;
        if (sim.elapsed_seconds <= self.last_tick_seconds) return;
        const elapsed = sim.elapsed_seconds - self.last_tick_seconds;
        self.last_tick_seconds = sim.elapsed_seconds;
        if (self.routine and self.home_household != null and self.employer_id != null and self.food_milli < 1000) {
            for (sim.residents[0..sim.resident_count]) |resident| {
                if (resident.job == .keeper and resident.employed) {
                    _ = self.buyFood(resident.id, sim, social);
                    break;
                }
            }
        }
        const demand_numerator = elapsed * 1000 + self.need_remainder;
        const demand = demand_numerator / sim_mod.seconds_per_day;
        self.need_remainder = @intCast(demand_numerator % sim_mod.seconds_per_day);
        const meal = @min(demand, self.food_milli);
        self.food_milli -= meal;
        self.food_consumed_milli += meal;
        self.food_shortage_milli += demand - meal;
        self.hunger = @intCast(@min(1000, @as(u64, self.hunger) + demand - meal) -| @min(@as(u64, self.hunger), meal));
        const hour = (sim.elapsed_seconds / 3600) % 24;
        const recovery: u64 = if (hour <= 5 or hour >= 21) 60 else 12;
        self.fatigue -|= @intCast(@min(@as(u64, self.fatigue), elapsed * recovery / 3600));
        self.payRent(sim, social);
        const years = @min((sim.elapsed_seconds -| self.arrived_at) / seconds_per_year, std.math.maxInt(u16) - 15);
        if (years > self.aged_years) {
            const delta: u8 = @intCast(@min(255, years - self.aged_years));
            self.age_years = @intCast(15 + years);
            self.aged_years = @intCast(years);
            for (sim.residents[0..sim.resident_count], 0..) |*resident, index| {
                resident.age_years +|= delta;
                if (!resident.employed and resident.age_years >= 18) {
                    // The child joins an existing household trade. No new
                    // workplace or unstable global assignment is invented.
                    const household = sim.households[resident.household];
                    const mentor = sim.residents[household.first_resident];
                    if (mentor.employed) {
                        resident.employed = true;
                        resident.workplace = mentor.workplace;
                        resident.job = mentor.job;
                        resident.work_remainder = 0;
                        social.persons[index].goal = .{ .kind = switch (resident.job) {
                            .farmer => .tend_fields,
                            .keeper => .maintain_supplies,
                            .craftsperson => .craft_better_tools,
                            .water_carrier => .carry_water,
                            .child => .learn_village_trades,
                        }, .target_hours = 36 };
                    }
                }
                social.persons[index].age_years = resident.age_years;
                social.persons[index].job = resident.job;
            }
        }
    }

    fn creditWork(self: *Life, sim: *Sim, social: *Social, employer: u8, seconds: u64, now: u64) void {
        if (seconds == 0) return;
        self.day_work_seconds += @intCast(seconds);
        self.work_seconds += seconds;
        const numerator = seconds * sim_mod.seasonalFarmRate(now - 1) + self.production_remainder;
        const produced = numerator / (9 * 3600);
        self.production_remainder = numerator % (9 * 3600);
        sim.addFood(produced);
        sim.economy.player_food_produced_milli += produced;
        const completed = (@as(u64, self.work_remainder_seconds) + seconds) / 3600;
        self.work_remainder_seconds = @intCast((@as(u64, self.work_remainder_seconds) + seconds) % 3600);
        if (completed == 0) return;
        self.paid_hours += completed;
        self.coins += @intCast(completed * 2);
        sim.economy.player_wages_paid += completed * 2;
        self.skill = @intCast(@min(1000, self.paid_hours / 12));
        self.fatigue = @intCast(@min(1000, @as(u64, self.fatigue) + completed * 40));
        const ration = @min(sim.economy.food_stock_milli, completed * 250);
        sim.economy.food_stock_milli -= ration;
        sim.economy.player_food_provisioned_milli += ration;
        self.food_milli += ration;
        social.recordPlayerAction(employer, .helpful_work, now);
    }

    fn purchase(self: *Life, sim: *Sim) bool {
        if (self.coins < 3 or sim.economy.food_stock_milli < 2000) return false;
        self.coins -= 3;
        self.food_milli += 2000;
        sim.economy.food_stock_milli -= 2000;
        sim.economy.player_food_provisioned_milli += 2000;
        sim.economy.player_food_payments += 3;
        return true;
    }

    fn payRent(self: *Life, sim: *Sim, social: *Social) void {
        const household_id = self.home_household orelse return;
        while (self.rent_paid_until_day <= sim.day()) {
            self.rent_paid_until_day += 1;
            if (self.coins > 0) {
                self.coins -= 1;
                sim.economy.player_rent_payments += 1;
                self.rent_arrears_days = 0;
                const host: u8 = @intCast(sim.households[household_id].first_resident);
                social.recordPlayerAction(host, .kept_promise, sim.elapsed_seconds);
            } else {
                self.rent_arrears_days +|= 1;
            }
        }
        if (self.rent_arrears_days >= 7) {
            self.home_household = null;
            self.home_building = null;
            self.routine = false;
        }
    }

    pub fn fingerprint(self: *const Life) u64 {
        var h: u64 = 0x6c696665;
        inline for (std.meta.fields(Life)) |field| {
            const value = @field(self, field.name);
            const n: u64 = switch (@typeInfo(field.type)) {
                .bool => @intFromBool(value),
                .optional => if (value) |present| @as(u64, present) + 1 else 0,
                else => @intCast(value),
            };
            h = mix64(h ^ n);
        }
        return h;
    }

    pub fn validate(self: *const Life, sim: *const Sim) error{InvalidState}!void {
        if (self.hunger > 1000 or self.fatigue > 1000 or self.skill > 1000 or self.age_years < 15 or self.day_work_seconds > daily_work_limit or self.work_remainder_seconds >= 3600 or self.production_remainder >= 9 * 3600 or self.need_remainder >= sim_mod.seconds_per_day) return error.InvalidState;
        if (self.last_tick_seconds > sim.elapsed_seconds or self.last_work_at > sim.elapsed_seconds or self.arrived_at > sim.elapsed_seconds or self.work_day > sim.day()) return error.InvalidState;
        if (self.arrived_at > self.last_tick_seconds or self.aged_years != @min((self.last_tick_seconds - self.arrived_at) / seconds_per_year, std.math.maxInt(u16) - 15)) return error.InvalidState;
        if (self.age_years != 15 + self.aged_years or self.paid_hours != self.work_seconds / 3600 or self.work_remainder_seconds != self.work_seconds % 3600 or self.skill != @min(1000, self.paid_hours / 12)) return error.InvalidState;
        if (self.employer_id) |id| {
            if (id >= sim.resident_count or sim.residents[id].job != .farmer or !sim.residents[id].employed) return error.InvalidState;
        }
        if (self.home_household) |id| {
            if (id >= sim.household_count or self.home_building == null or self.home_building.? != sim.households[id].home_building) return error.InvalidState;
        } else if (self.home_building != null) return error.InvalidState;
        if (3000 + sim.economy.player_food_provisioned_milli != self.food_milli + self.food_consumed_milli) return error.InvalidState;
        if (10 + sim.economy.player_wages_paid != @as(u64, self.coins) + sim.economy.player_food_payments + sim.economy.player_rent_payments) return error.InvalidState;
    }
};

fn workingTime(second: u64) bool {
    return (second >= 5 * 3600 and second < 12 * 3600) or (second >= 13 * 3600 and second < 17 * 3600);
}
fn near(x: f32, z: f32, tx: f32, tz: f32, radius: f32) bool {
    const dx = x - tx;
    const dz = z - tz;
    return dx * dx + dz * dz <= radius * radius;
}
fn mix64(input: u64) u64 {
    var n = input;
    n = (n ^ (n >> 30)) *% 0xbf58476d1ce4e5b9;
    n = (n ^ (n >> 27)) *% 0x94d049bb133111eb;
    return n ^ (n >> 31);
}

fn testAdvance(sim: *Sim, social: *Social, village: *const Village, life: *Life, seconds: u64, chunk: u64, routine: bool) void {
    var left = seconds;
    sim.seasonal_farming = true;
    while (left > 0) {
        const step = @min(@min(left, chunk), @min(3600 - sim.elapsed_seconds % 3600, life.workPeriodRemaining()));
        sim.advance(step, village);
        if (routine and life.workReady(sim, village)) {
            const field = life.fieldPoint(sim, village).?;
            life.work(sim, social, village, field.x, field.z, step);
        }
        if (sim.elapsed_seconds % 3600 == 0) {
            life.tick(sim, social, village);
            social.tick(sim);
        }
        left -= step;
    }
}

test "farm wages need physical labor and conserve food, coins and daily limits" {
    const terrain_mod = @import("terrain.zig");
    var terrain = try terrain_mod.Terrain.init(std.testing.allocator, terrain_mod.default_seed);
    defer terrain.deinit();
    const village = try Village.init(&terrain);
    var sim = Sim.init(&village, terrain.seed);
    var social = Social.init(&sim, terrain.seed);
    var life = Life.init(&sim);
    var farmer: ?u8 = null;
    var keeper: ?u8 = null;
    for (sim.residents[0..sim.resident_count]) |resident| {
        if (resident.job == .farmer and farmer == null) farmer = resident.id;
        if (resident.job == .keeper) keeper = resident.id;
    }
    try std.testing.expectEqual(@as(u16, 15), life.age_years);
    try std.testing.expect(!life.canSkip(&sim, &village, village.arrival.x, village.arrival.z));
    try std.testing.expect(life.hire(farmer.?, &sim, &social));
    testAdvance(&sim, &social, &village, &life, 8 * 3600, 3600, false);
    sim.advance(3600, &village);
    life.work(&sim, &social, &village, 100000, 100000, 3600);
    try std.testing.expectEqual(@as(u64, 0), life.paid_hours);
    const field = life.fieldPoint(&sim, &village).?;
    // The same elapsed hour cannot be replayed later from the field.
    life.work(&sim, &social, &village, field.x, field.z, 3600);
    try std.testing.expectEqual(@as(u64, 0), life.paid_hours);
    life.tick(&sim, &social, &village);
    testAdvance(&sim, &social, &village, &life, 8 * 3600, 137, true);
    try std.testing.expect(life.paid_hours > 0 and life.paid_hours <= 6);
    try std.testing.expect(sim.economy.player_food_produced_milli > 0);
    try std.testing.expect(social.trust(farmer.?) > 0);
    try std.testing.expect(life.buyFood(keeper.?, &sim, &social));
    try std.testing.expect(life.rentHome(farmer.?, &sim, &social));
    const door = village.doorPoint(life.home_building.?);
    try std.testing.expect(life.canSkip(&sim, &village, door.x, door.z));
    try life.validate(&sim);
    try sim.validate(&village);
}

test "ordinary anchored life advances three years with real seasons and maturing children" {
    const terrain_mod = @import("terrain.zig");
    var terrain = try terrain_mod.Terrain.init(std.testing.allocator, terrain_mod.default_seed);
    defer terrain.deinit();
    const village = try Village.init(&terrain);
    var sim = Sim.init(&village, terrain.seed);
    var social = Social.init(&sim, terrain.seed);
    var life = Life.init(&sim);
    var farmer: u8 = 0;
    for (sim.residents[0..sim.resident_count]) |resident| {
        if (resident.job == .farmer) {
            farmer = resident.id;
            break;
        }
    }
    const opening_age = sim.residents[farmer].age_years;
    var adolescent: ?u8 = null;
    for (sim.residents[0..sim.resident_count]) |*resident| {
        if (resident.job == .child) {
            adolescent = resident.id;
            resident.age_years = 17;
            social.persons[resident.id].age_years = 17;
            break;
        }
    }
    try std.testing.expect(life.hire(farmer, &sim, &social));
    testAdvance(&sim, &social, &village, &life, 17 * 3600, 3600, true);
    try std.testing.expect(life.rentHome(farmer, &sim, &social));
    life.routine = true;
    // A pantry initially empty from earlier meals exercises paid routine
    // shopping against the keeper's actual communal stock.
    life.food_consumed_milli += life.food_milli;
    life.food_milli = 0;
    var partitioned_sim = sim;
    var partitioned_social = social;
    var partitioned_life = life;
    testAdvance(&sim, &social, &village, &life, 3 * seconds_per_year, 3600, true);
    testAdvance(&partitioned_sim, &partitioned_social, &village, &partitioned_life, 3 * seconds_per_year, 137, true);
    try std.testing.expectEqual(sim.fingerprint(), partitioned_sim.fingerprint());
    try std.testing.expectEqual(social.fingerprint(), partitioned_social.fingerprint());
    try std.testing.expectEqual(life.fingerprint(), partitioned_life.fingerprint());
    try std.testing.expectEqual(@as(u16, 18), life.age_years);
    try std.testing.expectEqual(opening_age + 3, sim.residents[farmer].age_years);
    try std.testing.expect(sim.residents[adolescent.?].employed);
    try std.testing.expectEqual(@as(u8, 20), sim.residents[adolescent.?].age_years);
    try std.testing.expect(sim.residents[adolescent.?].job != .child);
    try std.testing.expectEqual(sim.residents[adolescent.?].job, social.persons[adolescent.?].job);
    try std.testing.expect(life.home_household != null and life.coins > 10 and life.paid_hours > 3000);
    try std.testing.expectEqual(@as(u16, 0), life.hunger);
    try std.testing.expectEqual(@as(u64, 0), life.food_shortage_milli);
    try std.testing.expect(social.trust(farmer) >= 50);
    try std.testing.expect(sim.economy.player_rent_payments > 1000);
    try std.testing.expect(sim.economy.player_food_payments >= 3);
    try std.testing.expectEqual(Season.spring, season(sim.elapsed_seconds));
    try std.testing.expectEqual(Season.winter, season(270 * sim_mod.seconds_per_day));
    try std.testing.expect(sim_mod.seasonalFarmRate(270 * sim_mod.seconds_per_day) < sim_mod.seasonalFarmRate(180 * sim_mod.seconds_per_day));
    try life.validate(&sim);
    try sim.validate(&village);
    try social.validate(&sim);
}
