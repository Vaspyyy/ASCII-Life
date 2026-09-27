const std = @import("std");
const village_mod = @import("village.zig");

const Village = village_mod.Village;
const Point = village_mod.Point;

pub const seconds_per_day: u64 = 24 * 60 * 60;
pub const max_residents: usize = 24;
pub const max_households: usize = 8;
const max_paths: usize = 64;
const max_route_points: usize = max_paths * 2 + 2;
const max_route_edges: usize = max_paths + 5;
const no_building: usize = std.math.maxInt(usize);
const walk_speed: f64 = 0.02; // metres per simulated second (about 1.2 m/minute)
const milli_per_unit: u64 = 1000;
const day_milli: u64 = 1000;

pub const Activity = enum(u8) {
    sleeping,
    resting,
    walking,
    working,
    break_time,
    visiting,
};

pub const Job = enum(u8) {
    child,
    farmer,
    craftsperson,
    keeper,
    water_carrier,
};

pub const Position = struct { x: f32, y: f32, z: f32 };

pub const Household = struct {
    home_building: usize,
    first_resident: usize,
    resident_count: usize,
};

pub const Resident = struct {
    id: u8,
    name: [24]u8 = [_]u8{0} ** 24,
    name_len: u8 = 0,
    age_years: u8,
    appearance_seed: u64,
    household: u8,
    home_building: usize,
    public_building: usize,
    workplace: usize = no_building,
    job: Job = .child,
    position: Position,
    activity: Activity = .resting,
    employed: bool = false,

    route_points: [max_route_points]Point = undefined,
    route_count: u16 = 0,
    route_length: f64 = 0,
    route_started: u64 = 0,
    route_arrives: u64 = 0,
    target_building: usize = no_building,
    target_activity: Activity = .resting,
    at_target: bool = true,
    work_remainder: u64 = 0,

    pub fn nameSlice(self: *const Resident) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const Economy = struct {
    food_stock_milli: u64 = 0,
    goods_stock_milli: u64 = 0,
    water_stock_milli: u64 = 0,
    food_produced_milli: u64 = 0,
    goods_produced_milli: u64 = 0,
    water_produced_milli: u64 = 0,
    food_consumed_milli: u64 = 0,
    goods_consumed_milli: u64 = 0,
    water_consumed_milli: u64 = 0,
    food_demand_milli: u64 = 0,
    goods_demand_milli: u64 = 0,
    water_demand_milli: u64 = 0,
    food_shortage_milli: u64 = 0,
    goods_shortage_milli: u64 = 0,
    water_shortage_milli: u64 = 0,
    food_discarded_milli: u64 = 0,
    goods_discarded_milli: u64 = 0,
    water_discarded_milli: u64 = 0,
    work_seconds: u64 = 0,
    farmer_work_seconds: u64 = 0,
    craft_work_seconds: u64 = 0,
    keeper_work_seconds: u64 = 0,
    water_work_seconds: u64 = 0,
    initial_food_milli: u64 = 0,
    initial_goods_milli: u64 = 0,
    initial_water_milli: u64 = 0,
};

/// Deterministic, event-stepped life and economy for the initial settlement.
/// `elapsed_seconds` begins at midnight; callers may advance to any displayed
/// time before presenting the first frame.
pub const Sim = struct {
    residents: [max_residents]Resident = undefined,
    resident_count: usize = 0,
    households: [max_households]Household = undefined,
    household_count: usize = 0,
    economy: Economy = .{},
    elapsed_seconds: u64 = 0,
    world_seed: u64 = 0,
    food_stock_capacity_milli: u64 = 0,
    goods_stock_capacity_milli: u64 = 0,
    water_stock_capacity_milli: u64 = 0,

    pub fn init(village: *const Village, seed: u64) Sim {
        var self = Sim{ .world_seed = seed };
        var homes: [max_households]usize = undefined;
        var home_count: usize = 0;
        var work_buildings: [max_paths]usize = undefined;
        var work_kinds: [max_paths]village_mod.Kind = undefined;
        var work_count: usize = 0;
        var public_building = no_building;
        var fallback_public = no_building;

        for (village.buildingsSlice(), 0..) |building, index| {
            if (building.kind == .home and home_count < max_households) {
                homes[home_count] = index;
                home_count += 1;
            } else if (building.kind != .home and work_count < max_paths) {
                work_buildings[work_count] = index;
                work_kinds[work_count] = building.kind;
                work_count += 1;
            }
            if (building.kind == .well) public_building = index;
            if (fallback_public == no_building and (building.kind == .granary or building.kind == .workshop)) fallback_public = index;
        }
        if (public_building == no_building) public_building = fallback_public;
        if (public_building == no_building and home_count != 0) public_building = homes[0];

        self.household_count = home_count;
        var assigned_workers: usize = 0;
        for (0..home_count) |household_index| {
            const home_index = homes[household_index];
            const members: usize = 3 + @as(usize, @intCast(hash64(seed ^ (@as(u64, @intCast(household_index)) *% 0x9e3779b97f4a7c15)) & 1));
            const start = self.resident_count;
            self.households[household_index] = .{
                .home_building = home_index,
                .first_resident = start,
                .resident_count = members,
            };
            for (0..members) |member_index| {
                const resident_index = self.resident_count;
                if (resident_index == max_residents) break;
                const resident_seed = hash64(seed ^ (@as(u64, @intCast(resident_index)) *% 0xd6e8feb86659fd93));
                const is_worker = member_index < 2;
                const age: u8 = if (is_worker)
                    25 + @as(u8, @intCast(resident_seed % 34))
                else if (member_index == 2)
                    6 + @as(u8, @intCast(resident_seed % 11))
                else
                    2 + @as(u8, @intCast(resident_seed % 10));
                const home_door = village.doorPoint(home_index);
                var resident = Resident{
                    .id = @intCast(resident_index),
                    .age_years = age,
                    .appearance_seed = hash64(resident_seed ^ 0xa0761d6478bd642f),
                    .household = @intCast(household_index),
                    .home_building = home_index,
                    .public_building = public_building,
                    .position = .{ .x = home_door.x, .y = village.buildingsSlice()[home_index].y, .z = home_door.z },
                };
                makeName(&resident, resident_seed);
                resident.position.y = village.surfaceY(resident.position.x, resident.position.z);
                if (is_worker and work_count != 0) {
                    const work_index = selectWorkIndex(assigned_workers, work_count, work_kinds);
                    resident.workplace = work_buildings[work_index];
                    resident.job = jobFor(work_kinds[work_index]);
                    resident.employed = true;
                    assigned_workers += 1;
                }
                resident.target_building = home_index;
                resident.target_activity = .resting;
                resident.at_target = true;
                resident.position.y = village.surfaceY(resident.position.x, resident.position.z);
                self.residents[resident_index] = resident;
                self.resident_count += 1;
            }
        }

        // A small, visible buffer means the household can eat before its first
        // harvest. All later changes follow actual work and household demand.
        self.economy.food_stock_milli = @as(u64, @intCast(self.resident_count)) * 7 * day_milli;
        self.economy.goods_stock_milli = @as(u64, @intCast(self.household_count)) * 4 * day_milli;
        self.economy.water_stock_milli = @as(u64, @intCast(self.resident_count)) * 7 * day_milli;
        self.economy.initial_food_milli = self.economy.food_stock_milli;
        self.economy.initial_goods_milli = self.economy.goods_stock_milli;
        self.economy.initial_water_milli = self.economy.water_stock_milli;
        self.food_stock_capacity_milli = @max(1, @as(u64, @intCast(self.resident_count)) * 120 * day_milli);
        self.goods_stock_capacity_milli = @max(1, @as(u64, @intCast(self.household_count)) * 90 * day_milli);
        self.water_stock_capacity_milli = @max(1, @as(u64, @intCast(self.resident_count)) * 120 * day_milli);
        self.refreshResidents(village);
        return self;
    }

    /// Advance the local settlement using absolute integer-second event times.
    /// Work, travel arrivals, and household meals split large jumps at the same
    /// boundaries, so calling this with different frame partitions is exact.
    pub fn advance(self: *Sim, seconds: u64, village: *const Village) void {
        const end_time = self.elapsed_seconds +| seconds;
        if (end_time == self.elapsed_seconds) return;
        while (self.elapsed_seconds < end_time) {
            self.refreshResidents(village);
            var next = @min(end_time, nextScheduleBoundary(self.elapsed_seconds));
            if (nextMealBoundary(self.elapsed_seconds)) |meal| next = @min(next, meal);
            for (self.residents[0..self.resident_count]) |resident| {
                if (resident.route_count != 0 and !resident.at_target) next = @min(next, resident.route_arrives);
            }
            if (next <= self.elapsed_seconds) next = self.elapsed_seconds + 1;
            const dt = next - self.elapsed_seconds;
            self.integrate(dt, village);
            self.elapsed_seconds = next;
            for (self.residents[0..self.resident_count]) |*resident| {
                if (!resident.at_target and resident.route_arrives <= self.elapsed_seconds) {
                    const last = resident.route_points[resident.route_count - 1];
                    resident.position = .{ .x = last.x, .y = village.surfaceY(last.x, last.z), .z = last.z };
                    resident.position.y = village.surfaceY(resident.position.x, resident.position.z);
                    resident.at_target = true;
                    resident.route_count = 0;
                    resident.activity = resident.target_activity;
                }
            }
            if (isMealBoundary(self.elapsed_seconds)) self.consumeForHouseholds();
        }
        self.refreshResidents(village);
    }

    pub fn residentPosition(self: *const Sim, index: usize) ?Position {
        if (index >= self.resident_count) return null;
        return self.residents[index].position;
    }

    pub fn day(self: *const Sim) u64 {
        return self.elapsed_seconds / seconds_per_day;
    }

    pub fn timeOfDay(self: *const Sim) f32 {
        return @as(f32, @floatFromInt(self.elapsed_seconds % seconds_per_day)) / @as(f32, @floatFromInt(seconds_per_day));
    }

    pub fn fingerprint(self: *const Sim) u64 {
        var h = hash64(self.world_seed ^ self.elapsed_seconds);
        h = mixHash(h, self.resident_count);
        h = mixHash(h, self.household_count);
        h = mixHash(h, self.economy.food_stock_milli);
        h = mixHash(h, self.economy.goods_stock_milli);
        h = mixHash(h, self.economy.water_stock_milli);
        h = mixHash(h, self.economy.food_produced_milli);
        h = mixHash(h, self.economy.goods_produced_milli);
        h = mixHash(h, self.economy.water_produced_milli);
        h = mixHash(h, self.economy.food_consumed_milli);
        h = mixHash(h, self.economy.goods_consumed_milli);
        h = mixHash(h, self.economy.water_consumed_milli);
        h = mixHash(h, self.economy.food_demand_milli);
        h = mixHash(h, self.economy.goods_demand_milli);
        h = mixHash(h, self.economy.water_demand_milli);
        h = mixHash(h, self.economy.food_shortage_milli);
        h = mixHash(h, self.economy.goods_shortage_milli);
        h = mixHash(h, self.economy.water_shortage_milli);
        h = mixHash(h, self.economy.work_seconds);
        h = mixHash(h, self.economy.farmer_work_seconds);
        h = mixHash(h, self.economy.craft_work_seconds);
        h = mixHash(h, self.economy.keeper_work_seconds);
        h = mixHash(h, self.economy.water_work_seconds);
        for (self.residents[0..self.resident_count]) |resident| {
            h = mixHash(h, resident.id);
            h = mixHash(h, resident.age_years);
            h = mixHash(h, resident.appearance_seed);
            h = mixHash(h, resident.household);
            h = mixHash(h, resident.home_building);
            h = mixHash(h, resident.workplace);
            h = mixHash(h, @intFromEnum(resident.job));
            h = mixHash(h, @intFromEnum(resident.activity));
            h = mixHash(h, quantized(resident.position.x));
            h = mixHash(h, quantized(resident.position.y));
            h = mixHash(h, quantized(resident.position.z));
            h = mixHash(h, resident.at_target);
            h = mixHash(h, resident.route_arrives);
            h = mixHash(h, resident.work_remainder);
            h = mixHash(h, resident.target_building);
            h = mixHash(h, @intFromEnum(resident.target_activity));
            h = mixHash(h, resident.route_count);
            for (resident.route_points[0..resident.route_count]) |point| {
                h = mixHash(h, quantized(point.x));
                h = mixHash(h, quantized(point.z));
            }
        }
        return h;
    }

    pub fn validate(self: *const Sim, village: *const Village) error{InvalidState}!void {
        if (self.resident_count > max_residents or self.household_count > max_households) return error.InvalidState;
        const buildings = village.buildingsSlice();
        for (self.households[0..self.household_count], 0..) |household, household_index| {
            if (household.home_building >= buildings.len or buildings[household.home_building].kind != .home) return error.InvalidState;
            if (household.first_resident + household.resident_count > self.resident_count) return error.InvalidState;
            if (household.resident_count == 0) return error.InvalidState;
            for (self.residents[household.first_resident .. household.first_resident + household.resident_count]) |resident| {
                if (resident.household != household_index or resident.home_building != household.home_building) return error.InvalidState;
            }
        }
        for (self.residents[0..self.resident_count]) |resident| {
            if (resident.home_building >= buildings.len or buildings[resident.home_building].kind != .home) return error.InvalidState;
            if (resident.employed) {
                if (resident.age_years < 18 or resident.workplace >= buildings.len or buildings[resident.workplace].kind == .home) return error.InvalidState;
                if (resident.job != jobFor(buildings[resident.workplace].kind)) return error.InvalidState;
            } else if (resident.age_years >= 18 or resident.job != .child or resident.workplace != no_building) {
                return error.InvalidState;
            }
            if (resident.public_building >= buildings.len or buildings[resident.public_building].kind == .home) return error.InvalidState;
            if (!std.math.isFinite(resident.position.x) or !std.math.isFinite(resident.position.y) or !std.math.isFinite(resident.position.z)) return error.InvalidState;
            if (resident.route_count > max_route_points) return error.InvalidState;
            if (resident.route_count != 0 and resident.at_target) return error.InvalidState;
            if (village.blocked(resident.position.x, resident.position.z, 0.15)) return error.InvalidState;
        }
        if (self.economy.initial_food_milli + self.economy.food_produced_milli != self.economy.food_stock_milli + self.economy.food_consumed_milli + self.economy.food_discarded_milli) return error.InvalidState;
        if (self.economy.initial_goods_milli + self.economy.goods_produced_milli != self.economy.goods_stock_milli + self.economy.goods_consumed_milli + self.economy.goods_discarded_milli) return error.InvalidState;
        if (self.economy.initial_water_milli + self.economy.water_produced_milli != self.economy.water_stock_milli + self.economy.water_consumed_milli + self.economy.water_discarded_milli) return error.InvalidState;
        if (self.economy.work_seconds != self.economy.farmer_work_seconds + self.economy.craft_work_seconds + self.economy.keeper_work_seconds + self.economy.water_work_seconds) return error.InvalidState;
        if (self.economy.food_demand_milli != self.economy.food_consumed_milli + self.economy.food_shortage_milli) return error.InvalidState;
        if (self.economy.goods_demand_milli != self.economy.goods_consumed_milli + self.economy.goods_shortage_milli) return error.InvalidState;
        if (self.economy.water_demand_milli != self.economy.water_consumed_milli + self.economy.water_shortage_milli) return error.InvalidState;
    }

    fn refreshResidents(self: *Sim, village: *const Village) void {
        for (self.residents[0..self.resident_count]) |*resident| {
            const schedule = scheduleFor(self.elapsed_seconds, resident);
            if (resident.target_building != schedule.building or resident.target_activity != schedule.activity) {
                resident.target_activity = schedule.activity;
                if (resident.target_building != schedule.building or resident.at_target) {
                    resident.target_building = schedule.building;
                    self.beginRoute(resident, village, schedule.building);
                } else {
                    resident.target_building = schedule.building;
                }
            }
            if (resident.at_target) {
                resident.activity = resident.target_activity;
            } else {
                resident.activity = .walking;
                if (resident.route_count == 0) self.beginRoute(resident, village, resident.target_building);
            }
        }
    }

    fn beginRoute(self: *Sim, resident: *Resident, village: *const Village, target_building: usize) void {
        const buildings = village.buildingsSlice();
        if (target_building >= buildings.len) return;
        const target_point = personalTarget(village, resident, target_building);
        const target = Position{ .x = target_point.x, .y = village.surfaceY(target_point.x, target_point.z), .z = target_point.z };
        if (resident.at_target and resident.target_building == target_building and distance2(resident.position.x, resident.position.z, target.x, target.z) < 0.25) return;
        var point_count: usize = 0;
        resident.route_points[point_count] = .{ .x = resident.position.x, .z = resident.position.z };
        point_count += 1;
        if (makeRoadRoute(village, resident.position, target, &resident.route_points, &point_count)) {
            // makeRoadRoute includes both endpoints; overwrite its source with
            // the exact current position to avoid a gap after schedule changes.
            resident.route_points[0] = .{ .x = resident.position.x, .z = resident.position.z };
        } else {
            // A missed connection waits at the current safe point. Never make
            // a straight-line shortcut through houses, fields, or water.
            resident.route_count = 0;
            resident.at_target = false;
            resident.activity = .walking;
            return;
        }
        resident.route_count = @intCast(point_count);
        resident.route_length = polylineLength(resident.route_points[0..point_count]);
        if (resident.route_length <= 0.25) {
            resident.position = target;
            resident.position.y = village.surfaceY(target.x, target.z);
            resident.at_target = true;
            resident.route_count = 0;
            resident.activity = resident.target_activity;
            return;
        }
        resident.route_started = self.elapsed_seconds;
        resident.route_arrives = self.elapsed_seconds + @as(u64, @intFromFloat(@ceil(resident.route_length / walk_speed)));
        resident.at_target = false;
        resident.activity = .walking;
    }

    fn integrate(self: *Sim, dt: u64, village: *const Village) void {
        for (self.residents[0..self.resident_count]) |*resident| {
            if (resident.activity != .working or !resident.employed or !resident.at_target) continue;
            self.economy.work_seconds += dt;
            switch (resident.job) {
                .farmer => {
                    self.economy.farmer_work_seconds += dt;
                    const produced = accrueWork(dt, 3_200, &resident.work_remainder);
                    self.addFood(produced);
                },
                .craftsperson => {
                    self.economy.craft_work_seconds += dt;
                    const produced = accrueWork(dt, 1_200, &resident.work_remainder);
                    self.addGoods(produced);
                },
                .keeper => {
                    self.economy.keeper_work_seconds += dt;
                    const produced = accrueWork(dt, 200, &resident.work_remainder);
                    self.addGoods(produced);
                },
                .water_carrier => {
                    self.economy.water_work_seconds += dt;
                    const produced = accrueWork(dt, 30_000, &resident.work_remainder);
                    self.addWater(produced);
                },
                .child => {},
            }
        }
        const now = self.elapsed_seconds + dt;
        for (self.residents[0..self.resident_count]) |*resident| {
            if (resident.at_target or resident.route_count < 2) continue;
            resident.position = positionOnRoute(resident, now);
            resident.position.y = village.surfaceY(resident.position.x, resident.position.z);
        }
    }

    fn consumeForHouseholds(self: *Sim) void {
        const headcount: u64 = @intCast(self.resident_count);
        self.consumeFood(headcount * 1000);
        self.consumeWater(headcount * 1000);
        if ((self.elapsed_seconds / seconds_per_day) % 7 == 6) {
            const households: u64 = @intCast(self.household_count);
            self.consumeGoods(households * 400);
        }
    }

    fn addFood(self: *Sim, amount: u64) void {
        self.economy.food_produced_milli += amount;
        const space = self.food_stock_capacity_milli -| self.economy.food_stock_milli;
        const stored = @min(space, amount);
        self.economy.food_stock_milli += stored;
        self.economy.food_discarded_milli += amount - stored;
    }

    fn addGoods(self: *Sim, amount: u64) void {
        self.economy.goods_produced_milli += amount;
        const space = self.goods_stock_capacity_milli -| self.economy.goods_stock_milli;
        const stored = @min(space, amount);
        self.economy.goods_stock_milli += stored;
        self.economy.goods_discarded_milli += amount - stored;
    }

    fn addWater(self: *Sim, amount: u64) void {
        self.economy.water_produced_milli += amount;
        const space = self.water_stock_capacity_milli -| self.economy.water_stock_milli;
        const stored = @min(space, amount);
        self.economy.water_stock_milli += stored;
        self.economy.water_discarded_milli += amount - stored;
    }

    fn consumeFood(self: *Sim, demand: u64) void {
        self.economy.food_demand_milli += demand;
        const served = @min(self.economy.food_stock_milli, demand);
        self.economy.food_stock_milli -= served;
        self.economy.food_consumed_milli += served;
        self.economy.food_shortage_milli += demand - served;
    }

    fn consumeGoods(self: *Sim, demand: u64) void {
        self.economy.goods_demand_milli += demand;
        const served = @min(self.economy.goods_stock_milli, demand);
        self.economy.goods_stock_milli -= served;
        self.economy.goods_consumed_milli += served;
        self.economy.goods_shortage_milli += demand - served;
    }

    fn consumeWater(self: *Sim, demand: u64) void {
        self.economy.water_demand_milli += demand;
        const served = @min(self.economy.water_stock_milli, demand);
        self.economy.water_stock_milli -= served;
        self.economy.water_consumed_milli += served;
        self.economy.water_shortage_milli += demand - served;
    }
};

const Schedule = struct { building: usize, activity: Activity };

fn scheduleFor(time: u64, resident: *const Resident) Schedule {
    const seconds = time % seconds_per_day;
    if (!resident.employed) {
        if (seconds < 7 * 3600) return .{ .building = resident.home_building, .activity = .sleeping };
        if (seconds < 17 * 3600) return .{ .building = resident.home_building, .activity = .resting };
        if (seconds < 19 * 3600) return .{ .building = publicPlaceFor(resident), .activity = .visiting };
        return .{ .building = resident.home_building, .activity = .resting };
    }
    if (seconds < 5 * 3600) return .{ .building = resident.home_building, .activity = .sleeping };
    if (seconds < 7 * 3600) return .{ .building = resident.workplace, .activity = .working };
    if (seconds < 12 * 3600) return .{ .building = resident.workplace, .activity = .working };
    if (seconds < 13 * 3600) return .{ .building = resident.workplace, .activity = .break_time };
    if (seconds < 17 * 3600) return .{ .building = resident.workplace, .activity = .working };
    if (seconds < 18 * 3600) return .{ .building = publicPlaceFor(resident), .activity = .visiting };
    if (seconds < 19 * 3600) return .{ .building = publicPlaceFor(resident), .activity = .visiting };
    if (seconds < 20 * 3600) return .{ .building = resident.home_building, .activity = .resting };
    return .{ .building = resident.home_building, .activity = .sleeping };
}

fn publicPlaceFor(resident: *const Resident) usize {
    return resident.public_building;
}

fn nextScheduleBoundary(time: u64) u64 {
    const boundaries = [_]u64{ 5, 7, 12, 13, 17, 18, 19, 20 };
    const day_start = time - time % seconds_per_day;
    for (boundaries) |hour| {
        const boundary = day_start + hour * 3600;
        if (boundary > time) return boundary;
    }
    return day_start + seconds_per_day;
}

fn nextMealBoundary(time: u64) ?u64 {
    const day_start = time - time % seconds_per_day;
    const meal = day_start + 20 * 3600;
    if (meal > time) return meal;
    return null;
}

fn isMealBoundary(time: u64) bool {
    return time % seconds_per_day == 20 * 3600;
}

fn accrueWork(seconds: u64, units_per_day: u64, remainder: *u64) u64 {
    // Output is proportional to working time; the carried integer fraction
    // avoids partition-dependent rounding.
    const numerator = seconds * units_per_day + remainder.*;
    const result = numerator / (9 * 3600);
    remainder.* = numerator % (9 * 3600);
    return result;
}

fn selectWorkIndex(index: usize, count: usize, kinds: [max_paths]village_mod.Kind) usize {
    if (count == 0) return 0;
    const preference: [10]village_mod.Kind = .{ .farm, .farm, .farm, .farm, .farm, .farm, .workshop, .workshop, .granary, .well };
    const wanted = preference[index % preference.len];
    var matches: usize = 0;
    for (0..count) |i| if (kinds[i] == wanted) {
        matches += 1;
    };
    if (matches != 0) {
        var selected = index % matches;
        for (0..count) |i| if (kinds[i] == wanted) {
            if (selected == 0) return i;
            selected -= 1;
        };
    }
    return index % count;
}

fn personalTarget(village: *const Village, resident: *const Resident, building_index: usize) Point {
    const entry = village.doorPoint(building_index);
    if (resident.target_activity != .working and resident.target_activity != .visiting) return entry;
    const paths = village.pathsSlice();
    var other: ?Point = null;
    for (paths) |path| {
        if (@abs(path.a.x - entry.x) < 0.01 and @abs(path.a.z - entry.z) < 0.01) {
            other = path.b;
            break;
        }
        if (@abs(path.b.x - entry.x) < 0.01 and @abs(path.b.z - entry.z) < 0.01) {
            other = path.a;
            break;
        }
    }
    const neighbor = other orelse return entry;
    const dx = neighbor.x - entry.x;
    const dz = neighbor.z - entry.z;
    const length = @sqrt(dx * dx + dz * dz);
    if (length < 0.01) return entry;
    const offset_index: u32 = if (resident.target_activity == .visiting) @as(u32, resident.id % 8) else @as(u32, resident.id % 4);
    const offset = if (resident.target_activity == .visiting) 0.35 + @as(f32, @floatFromInt(offset_index)) * 0.40 else 0.30 + @as(f32, @floatFromInt(offset_index)) * 0.42;
    return .{ .x = entry.x + dx / length * offset, .z = entry.z + dz / length * offset };
}

fn jobFor(kind: village_mod.Kind) Job {
    return switch (kind) {
        .farm => .farmer,
        .workshop => .craftsperson,
        .granary => .keeper,
        .well => .water_carrier,
        .home => .child,
    };
}

fn makeRoadRoute(village: *const Village, start: Position, goal: Position, points: *[max_route_points]Point, count: *usize) bool {
    const paths = village.pathsSlice();
    if (paths.len == 0 or paths.len > max_paths) return false;
    var nodes: [max_route_points]Point = undefined;
    var node_count: usize = 0;
    var ends_a: [max_paths]usize = undefined;
    var ends_b: [max_paths]usize = undefined;
    var edges: [max_route_edges]RouteEdge = undefined;
    var edge_count: usize = 0;
    for (paths, 0..) |path, path_index| {
        ends_a[path_index] = nodeIndex(&nodes, &node_count, path.a);
        ends_b[path_index] = nodeIndex(&nodes, &node_count, path.b);
        appendEdge(&edges, &edge_count, ends_a[path_index], ends_b[path_index], pointDistance(path.a, path.b));
    }
    if (node_count == 0) return false;
    const source_projection = closestProjection(paths, start.x, start.z) orelse return false;
    const target_projection = closestProjection(paths, goal.x, goal.z) orelse return false;
    const source = node_count;
    nodes[node_count] = .{ .x = start.x, .z = start.z };
    node_count += 1;
    const target = node_count;
    nodes[node_count] = .{ .x = goal.x, .z = goal.z };
    node_count += 1;

    const source_gap = pointDistance(.{ .x = start.x, .z = start.z }, source_projection.point);
    const target_gap = pointDistance(.{ .x = goal.x, .z = goal.z }, target_projection.point);
    const source_a = ends_a[source_projection.path_index];
    const source_b = ends_b[source_projection.path_index];
    const target_a = ends_a[target_projection.path_index];
    const target_b = ends_b[target_projection.path_index];
    appendEdge(&edges, &edge_count, source, source_a, source_gap + pointDistance(source_projection.point, nodes[source_a]));
    appendEdge(&edges, &edge_count, source, source_b, source_gap + pointDistance(source_projection.point, nodes[source_b]));
    appendEdge(&edges, &edge_count, target, target_a, target_gap + pointDistance(target_projection.point, nodes[target_a]));
    appendEdge(&edges, &edge_count, target, target_b, target_gap + pointDistance(target_projection.point, nodes[target_b]));
    if (source_projection.path_index == target_projection.path_index) {
        appendEdge(&edges, &edge_count, source, target, source_gap + pointDistance(source_projection.point, target_projection.point) + target_gap);
    }

    var distance = [_]f64{std.math.inf(f64)} ** max_route_points;
    var previous = [_]usize{max_route_points} ** max_route_points;
    var visited = [_]bool{false} ** max_route_points;
    distance[source] = 0;
    for (0..node_count) |_| {
        var selected = node_count;
        var best = std.math.inf(f64);
        for (0..node_count) |node| {
            if (!visited[node] and distance[node] < best) {
                selected = node;
                best = distance[node];
            }
        }
        if (selected == node_count or selected == target) break;
        visited[selected] = true;
        for (edges[0..edge_count]) |edge| {
            const other = if (edge.a == selected) edge.b else if (edge.b == selected) edge.a else continue;
            const alternative = distance[selected] + edge.cost;
            if (alternative < distance[other]) {
                distance[other] = alternative;
                previous[other] = selected;
            }
        }
    }
    if (!std.math.isFinite(distance[target])) return false;

    var reverse: [max_paths * 2]usize = undefined;
    var reverse_count: usize = 0;
    var current = target;
    while (current != source and reverse_count < reverse.len) : (reverse_count += 1) {
        reverse[reverse_count] = current;
        current = previous[current];
        if (current >= node_count) return false;
    }
    if (current != source) return false;

    var output_count: usize = 0;
    appendPoint(points, &output_count, .{ .x = start.x, .z = start.z });
    while (reverse_count > 0) {
        reverse_count -= 1;
        appendPoint(points, &output_count, nodes[reverse[reverse_count]]);
    }
    if (!routeOnRoad(village, points[0..output_count])) return false;
    count.* = output_count;
    return output_count >= 2;
}

const RouteEdge = struct { a: usize, b: usize, cost: f64 };
const Projection = struct { path_index: usize, point: Point, distance: f64 };

fn appendEdge(edges: *[max_route_edges]RouteEdge, count: *usize, a: usize, b: usize, cost: f64) void {
    if (count.* < edges.len) {
        edges[count.*] = .{ .a = a, .b = b, .cost = cost };
        count.* += 1;
    }
}

fn closestProjection(paths: []const village_mod.Path, x: f32, z: f32) ?Projection {
    var best: ?Projection = null;
    var best_distance = std.math.inf(f64);
    for (paths, 0..) |path, path_index| {
        const dx: f64 = @floatCast(path.b.x - path.a.x);
        const dz: f64 = @floatCast(path.b.z - path.a.z);
        const px: f64 = @floatCast(x - path.a.x);
        const pz: f64 = @floatCast(z - path.a.z);
        const length_squared = dx * dx + dz * dz;
        const t = if (length_squared > 0) std.math.clamp((px * dx + pz * dz) / length_squared, 0, 1) else 0;
        const projected = Point{ .x = path.a.x + @as(f32, @floatCast(dx * t)), .z = path.a.z + @as(f32, @floatCast(dz * t)) };
        const distance = pointDistance(projected, .{ .x = x, .z = z });
        if (distance < best_distance) {
            best_distance = distance;
            best = .{ .path_index = path_index, .point = projected, .distance = distance };
        }
    }
    return best;
}

fn routeOnRoad(village: *const Village, points: []const Point) bool {
    for (1..points.len) |i| {
        const a = points[i - 1];
        const b = points[i];
        const length = pointDistance(a, b);
        const steps: usize = @max(@as(usize, 1), @as(usize, @intFromFloat(@ceil(length / 0.7))));
        for (0..steps + 1) |step| {
            const t = @as(f32, @floatFromInt(step)) / @as(f32, @floatFromInt(steps));
            const x = a.x + (b.x - a.x) * t;
            const z = a.z + (b.z - a.z) * t;
            if (village.blocked(x, z, 0.12) or village.surfaceAt(x, z) != .path or village.terrain_ref.water(x, z).wet) return false;
        }
    }
    return true;
}

fn nodeIndex(nodes: *[max_route_points]Point, count: *usize, point: Point) usize {
    for (0..count.*) |i| if (@abs(nodes[i].x - point.x) < 0.01 and @abs(nodes[i].z - point.z) < 0.01) return i;
    const result = count.*;
    nodes[result] = point;
    count.* += 1;
    return result;
}

fn nearestNode(nodes: []const Point, x: f32, z: f32) usize {
    var best: usize = 0;
    var best_distance = std.math.inf(f32);
    for (nodes, 0..) |node, i| {
        const distance = distance2(node.x, node.z, x, z);
        if (distance < best_distance) {
            best_distance = distance;
            best = i;
        }
    }
    return best;
}

fn appendPoint(points: *[max_route_points]Point, count: *usize, point: Point) void {
    if (count.* != 0) {
        const previous = points[count.* - 1];
        if (@abs(previous.x - point.x) < 0.01 and @abs(previous.z - point.z) < 0.01) return;
    }
    if (count.* < points.len) {
        points[count.*] = point;
        count.* += 1;
    }
}

fn polylineLength(points: []const Point) f64 {
    var result: f64 = 0;
    for (1..points.len) |i| result += pointDistance(points[i - 1], points[i]);
    return result;
}

fn positionOnRoute(resident: *const Resident, now: u64) Position {
    const elapsed = now - resident.route_started;
    var distance = @min(resident.route_length, @as(f64, @floatFromInt(elapsed)) * walk_speed);
    for (1..resident.route_count) |i| {
        const a = resident.route_points[i - 1];
        const b = resident.route_points[i];
        const leg = pointDistance(a, b);
        if (distance <= leg or i + 1 == resident.route_count) {
            const amount: f32 = if (leg > 0) @floatCast(@min(1.0, distance / leg)) else 1;
            return .{ .x = a.x + (b.x - a.x) * amount, .z = a.z + (b.z - a.z) * amount, .y = 0 };
        }
        distance -= leg;
    }
    const last = resident.route_points[resident.route_count - 1];
    return .{ .x = last.x, .z = last.z, .y = 0 };
}

fn pointDistance(a: Point, b: Point) f64 {
    const dx: f64 = @floatCast(a.x - b.x);
    const dz: f64 = @floatCast(a.z - b.z);
    return @sqrt(dx * dx + dz * dz);
}

fn distance2(ax: f32, az: f32, bx: f32, bz: f32) f32 {
    const dx = ax - bx;
    const dz = az - bz;
    return dx * dx + dz * dz;
}

fn makeName(resident: *Resident, seed: u64) void {
    const onset = [_][]const u8{ "A", "Be", "Ca", "Da", "E", "Fa", "Ga", "I", "Ka", "Le", "Ma", "Na", "O", "Ra", "Sa", "Ta", "Va", "Ye" };
    const middle = [_][]const u8{ "l", "r", "n", "m", "v", "s", "th", "d", "k", "w", "" };
    const endings = [_][]const u8{ "a", "en", "in", "o", "ia", "el", "er", "an", "et", "is", "un", "or", "" };
    const first = hash64(seed ^ 0x243f6a8885a308d3);
    const second = hash64(seed ^ 0x13198a2e03707344);
    const pieces = .{ onset[first % onset.len], middle[(first >> 12) % middle.len], endings[(second >> 8) % endings.len] };
    var cursor: usize = 0;
    inline for (pieces) |piece| for (piece) |ch| {
        if (cursor < resident.name.len) {
            resident.name[cursor] = ch;
            cursor += 1;
        }
    };
    resident.name_len = @intCast(cursor);
    if (cursor == 0) {
        resident.name[0] = 'A';
        resident.name_len = 1;
    }
}

fn quantized(value: f32) i64 {
    return @intFromFloat(@round(@as(f64, value) * 64.0));
}

fn mixHash(seed: u64, value: anytype) u64 {
    const T = @TypeOf(value);
    const as_u64: u64 = switch (@typeInfo(T)) {
        .bool => @intFromBool(value),
        .int => |int_type| if (int_type.signedness == .signed)
            @as(u64, @bitCast(@as(i64, @intCast(value))))
        else
            @as(u64, @intCast(value)),
        .@"enum" => @intFromEnum(value),
        else => 0,
    };
    return hash64(seed ^ as_u64);
}

fn hash64(value: u64) u64 {
    var x = value +% 0x9e3779b97f4a7c15;
    x = (x ^ (x >> 30)) *% 0xbf58476d1ce4e5b9;
    x = (x ^ (x >> 27)) *% 0x94d049bb133111eb;
    return x ^ (x >> 31);
}

test "village schedules and economy are independent of advance partitions" {
    const terrain_mod = @import("terrain.zig");
    var terrain = try terrain_mod.Terrain.init(std.testing.allocator, terrain_mod.default_seed);
    defer terrain.deinit();
    const village = try Village.init(&terrain);

    var whole = Sim.init(&village, 0x51a7e);
    var chunks = Sim.init(&village, 0x51a7e);
    const duration: u64 = 28 * seconds_per_day;
    whole.advance(duration, &village);
    var remaining = duration;
    const chunk_sizes = [_]u64{ 137, 3601, 17, 82_763, 900, 22_207, 43_119 };
    var i: usize = 0;
    while (remaining != 0) : (i += 1) {
        const amount = @min(remaining, chunk_sizes[i % chunk_sizes.len]);
        chunks.advance(amount, &village);
        for (chunks.residents[0..chunks.resident_count]) |resident| {
            try std.testing.expect(!village.blocked(resident.position.x, resident.position.z, 0.12));
            try std.testing.expect(!terrain.water(resident.position.x, resident.position.z).wet);
        }
        remaining -= amount;
    }

    try std.testing.expectEqual(@as(usize, 6), whole.household_count);
    try std.testing.expect(whole.resident_count >= 18 and whole.resident_count <= 24);
    try std.testing.expectEqual(whole.fingerprint(), chunks.fingerprint());
    try std.testing.expectEqual(duration, whole.elapsed_seconds);
    try std.testing.expect(whole.economy.farmer_work_seconds > 0);
    try std.testing.expect(whole.economy.food_produced_milli > 0);
    try std.testing.expect(whole.economy.food_consumed_milli > 0);
    try std.testing.expectEqual(@as(u64, 0), whole.economy.food_shortage_milli);
    try std.testing.expectEqual(@as(u64, 0), whole.economy.water_shortage_milli);
    try std.testing.expectEqual(whole.resident_count, whole.economy.food_consumed_milli / 28_000);
    for (whole.residents[0..whole.resident_count], chunks.residents[0..chunks.resident_count]) |a, b| {
        try std.testing.expectEqualSlices(u8, a.nameSlice(), b.nameSlice());
        try std.testing.expectEqual(a.appearance_seed, b.appearance_seed);
        try std.testing.expect(a.nameSlice().len != 0);
    }
    try whole.validate(&village);
    try chunks.validate(&village);

    var no_farm_labor = Sim.init(&village, 0x51a7e);
    var workshop_index: ?usize = null;
    for (village.buildingsSlice(), 0..) |building, index| if (building.kind == .workshop) {
        workshop_index = index;
        break;
    };
    for (no_farm_labor.residents[0..no_farm_labor.resident_count]) |*resident| {
        if (resident.job == .farmer) {
            resident.workplace = workshop_index.?;
            resident.job = .craftsperson;
            resident.work_remainder = 0;
        }
    }
    no_farm_labor.advance(duration, &village);
    try std.testing.expectEqual(@as(u64, 0), no_farm_labor.economy.farmer_work_seconds);
    try std.testing.expect(no_farm_labor.economy.food_shortage_milli > 0);
    try no_farm_labor.validate(&village);
}
