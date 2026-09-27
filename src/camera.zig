const std = @import("std");
const terrain_mod = @import("terrain.zig");
const Terrain = terrain_mod.Terrain;

const eye_height: f32 = 2.5;
const walk_speed: f32 = 12.0;
const sprint_speed: f32 = 50.0;
const max_frame_dt: f32 = 0.1;
const max_pitch: f32 = 0.8;
const third_person_distance: f32 = 10.0;
const third_person_height: f32 = 5.0;
const third_person_focus_height: f32 = 1.0;
const camera_ground_clearance: f32 = 0.75;

pub const Input = struct {
    forward: f32 = 0,
    strafe: f32 = 0,
    vertical: f32 = 0,
    look_x: f32 = 0,
    look_y: f32 = 0,
    fast: bool = false,
    toggle_view: bool = false,
};

pub const View = struct {
    x: f32,
    y: f32,
    z: f32,
    yaw: f32,
    pitch: f32,
    player_x: f32,
    player_y: f32,
    player_z: f32,
    third_person: bool,
};

/// Renderer-independent movement and view state for the M1 landscape.
/// Yaw zero faces toward positive Z; positive yaw turns toward positive X.
pub const Camera = struct {
    player_x: f32,
    player_y: f32,
    player_z: f32,
    yaw: f32,
    pitch: f32 = 0,
    third_person: bool = false,

    pub fn init(terrain: *const Terrain) Camera {
        const x = clampWorld(terrain.start.x);
        const z = clampWorld(terrain.start.z);
        return .{
            .player_x = x,
            .player_y = groundHeight(terrain, x, z),
            .player_z = z,
            .yaw = terrain.start.yaw,
            .pitch = 0.10,
        };
    }

    pub fn update(self: *Camera, terrain: *const Terrain, input: Input, dt: f32) void {
        if (input.toggle_view) self.third_person = !self.third_person;

        self.yaw = wrapAngle(self.yaw + finiteOrZero(input.look_x));
        self.pitch = @max(-max_pitch, @min(max_pitch, self.pitch + finiteOrZero(input.look_y)));

        const frame_dt = if (std.math.isFinite(dt)) @max(0, @min(max_frame_dt, dt)) else 0;
        var forward = finiteOrZero(input.forward);
        var strafe = finiteOrZero(input.strafe);
        var vertical = finiteOrZero(input.vertical);

        // Keep combined forward, strafe, and elevation motion within one unit
        // so diagonal movement does not gain speed.
        const magnitude_squared = forward * forward + strafe * strafe + vertical * vertical;
        if (magnitude_squared > 1) {
            const inverse_magnitude = 1.0 / @sqrt(magnitude_squared);
            forward *= inverse_magnitude;
            strafe *= inverse_magnitude;
            vertical *= inverse_magnitude;
        }

        const speed = if (input.fast) sprint_speed else walk_speed;
        const distance = speed * frame_dt;
        const old_ground = groundHeight(terrain, self.player_x, self.player_z);
        var elevation = @max(0, self.player_y - old_ground);

        const sin_yaw = @sin(self.yaw);
        const cos_yaw = @cos(self.yaw);
        self.player_x += (sin_yaw * forward + cos_yaw * strafe) * distance;
        self.player_z += (cos_yaw * forward - sin_yaw * strafe) * distance;
        self.player_x = clampWorld(self.player_x);
        self.player_z = clampWorld(self.player_z);

        elevation = @max(0, elevation + vertical * distance);
        self.player_y = groundHeight(terrain, self.player_x, self.player_z) + elevation;
    }

    /// Place the camera at an explicit terrain-relative pose for repeatable
    /// development captures. `lift` is the player's feet height above ground.
    pub fn setPose(self: *Camera, terrain: *const Terrain, x: f32, z: f32, yaw: f32, pitch: f32, lift: f32) void {
        self.player_x = clampWorld(finiteOrZero(x));
        self.player_z = clampWorld(finiteOrZero(z));
        self.yaw = wrapAngle(finiteOrZero(yaw));
        self.pitch = @max(-max_pitch, @min(max_pitch, finiteOrZero(pitch)));
        self.player_y = groundHeight(terrain, self.player_x, self.player_z) + @max(0, finiteOrZero(lift));
    }

    pub fn view(self: *const Camera, terrain: *const Terrain) View {
        const eye_y = self.player_y + eye_height;
        if (!self.third_person) {
            return .{
                .x = self.player_x,
                .y = eye_y,
                .z = self.player_z,
                .yaw = self.yaw,
                .pitch = self.pitch,
                .player_x = self.player_x,
                .player_y = self.player_y,
                .player_z = self.player_z,
                .third_person = false,
            };
        }

        const focus_y = self.player_y + third_person_focus_height;
        const sin_yaw = @sin(self.yaw);
        const cos_yaw = @cos(self.yaw);
        const boom_x = -sin_yaw * third_person_distance;
        const boom_z = -cos_yaw * third_person_distance;

        // At neutral look, keep the original 10 m / 5 m framing. Looking up
        // lowers the orbit boom; looking down raises it. This lets third-person
        // pitch move the camera while keeping the explorer in the view center.
        const neutral_pitch = std.math.atan((focus_y - (self.player_y + third_person_height)) / third_person_distance);
        const desired_pitch = @max(-max_pitch, @min(max_pitch, neutral_pitch + self.pitch));
        const desired_y = focus_y - third_person_distance * @sin(desired_pitch) / @cos(desired_pitch);
        const end_x = self.player_x + boom_x;
        const end_z = self.player_z + boom_z;
        const camera_y = @max(desired_y, groundHeight(terrain, end_x, end_z) + camera_ground_clearance);
        const boom_y = camera_y - focus_y;

        // Pull the camera toward the focus if a nearby ridge crosses the boom.
        // Sampling a short segment keeps this cheap on every frame.
        var scale: f32 = 1;
        while (scale >= 0.125) : (scale -= 0.125) {
            if (boomIsClear(terrain, self.player_x, focus_y, self.player_z, boom_x, boom_y, boom_z, scale)) {
                return thirdPersonView(
                    self,
                    self.player_x + boom_x * scale,
                    focus_y + boom_y * scale,
                    self.player_z + boom_z * scale,
                    third_person_distance * scale,
                );
            }
        }

        // A close orbit is the last resort in a narrow cleft. It still aims at
        // the explorer and stays above terrain, though the figure may fill most
        // of the view when terrain blocks every longer boom.
        for ([_]f32{ 3.0, 1.5, 1.25 }) |distance| {
            const fallback_x = -sin_yaw * distance;
            const fallback_z = -cos_yaw * distance;
            const fallback_end_x = self.player_x + fallback_x;
            const fallback_end_z = self.player_z + fallback_z;
            const fallback_y = @max(
                focus_y - distance * @sin(desired_pitch) / @cos(desired_pitch),
                groundHeight(terrain, fallback_end_x, fallback_end_z) + camera_ground_clearance,
            );
            if (boomIsClear(terrain, self.player_x, focus_y, self.player_z, fallback_x, fallback_y - focus_y, fallback_z, 1)) {
                return thirdPersonView(
                    self,
                    fallback_end_x,
                    fallback_y,
                    fallback_end_z,
                    distance,
                );
            }
        }

        const fallback_distance: f32 = 1.25;
        const fallback_x = self.player_x - sin_yaw * fallback_distance;
        const fallback_z = self.player_z - cos_yaw * fallback_distance;
        return thirdPersonView(
            self,
            fallback_x,
            @max(focus_y, groundHeight(terrain, fallback_x, fallback_z) + camera_ground_clearance),
            fallback_z,
            fallback_distance,
        );
    }
};

fn thirdPersonView(self: *const Camera, x: f32, y: f32, z: f32, forward_distance: f32) View {
    const focus_y = self.player_y + third_person_focus_height;
    return .{
        .x = x,
        .y = y,
        .z = z,
        .yaw = self.yaw,
        .pitch = std.math.atan((focus_y - y) / forward_distance),
        .player_x = self.player_x,
        .player_y = self.player_y,
        .player_z = self.player_z,
        .third_person = true,
    };
}

fn finiteOrZero(value: f32) f32 {
    return if (std.math.isFinite(value)) value else 0;
}

fn wrapAngle(angle: f32) f32 {
    const two_pi: f32 = 2.0 * std.math.pi;
    var wrapped = @rem(angle, two_pi);
    if (wrapped > std.math.pi) wrapped -= two_pi;
    if (wrapped < -std.math.pi) wrapped += two_pi;
    return wrapped;
}

fn clampWorld(value: f32) f32 {
    const edge = terrain_mod.size * 0.5 - 16.0;
    return @max(-edge, @min(edge, value));
}

fn groundHeight(terrain: *const Terrain, x: f32, z: f32) f32 {
    return terrain.standingHeight(x, z);
}

fn boomIsClear(
    terrain: *const Terrain,
    origin_x: f32,
    origin_y: f32,
    origin_z: f32,
    boom_x: f32,
    boom_y: f32,
    boom_z: f32,
    scale: f32,
) bool {
    const sample_count: f32 = 8;
    for (1..9) |i| {
        const t = scale * @as(f32, @floatFromInt(i)) / sample_count;
        const x = origin_x + boom_x * t;
        const y = origin_y + boom_y * t;
        const z = origin_z + boom_z * t;
        if (y < groundHeight(terrain, x, z) + 0.75) return false;
    }
    return true;
}

test "movement, turning, and pitch are frame independent and bounded" {
    var terrain = try Terrain.init(std.testing.allocator, 17);
    defer terrain.deinit();

    var camera = Camera.init(&terrain);
    camera.yaw = 0;
    const start_x = camera.player_x;
    const start_z = camera.player_z;

    camera.update(&terrain, .{ .forward = 1, .strafe = 1 }, 0.1);
    const dx = camera.player_x - start_x;
    const dz = camera.player_z - start_z;
    try std.testing.expect(dx > 0);
    try std.testing.expect(dz > 0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.2), @sqrt(dx * dx + dz * dz), 0.001);

    var partition_a = Camera.init(&terrain);
    var partition_b = Camera.init(&terrain);
    partition_a.setPose(&terrain, 0, 0, 0, 0, 0);
    partition_b.setPose(&terrain, 0, 0, 0, 0, 0);
    const diagonal = Input{ .forward = 0.6, .strafe = 0.8 };
    for (0..10) |_| partition_a.update(&terrain, diagonal, 0.1);
    for (0..60) |_| partition_b.update(&terrain, diagonal, 1.0 / 60.0);
    try std.testing.expectApproxEqAbs(partition_a.player_x, partition_b.player_x, 0.0005);
    try std.testing.expectApproxEqAbs(partition_a.player_z, partition_b.player_z, 0.0005);

    camera.update(&terrain, .{ .look_x = 0.5, .look_y = 4.0 }, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), camera.yaw, 0.0001);
    try std.testing.expectApproxEqAbs(max_pitch, camera.pitch, 0.0001);
    camera.update(&terrain, .{ .look_y = -4.0 }, 0);
    try std.testing.expectApproxEqAbs(-max_pitch, camera.pitch, 0.0001);

    const before_spike_x = camera.player_x;
    const before_spike_z = camera.player_z;
    camera.update(&terrain, .{ .forward = 1, .fast = true }, 10);
    const spike_dx = camera.player_x - before_spike_x;
    const spike_dz = camera.player_z - before_spike_z;
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), @sqrt(spike_dx * spike_dx + spike_dz * spike_dz), 0.001);
}

test "view toggle preserves the player and third person stays above terrain" {
    var terrain = try Terrain.init(std.testing.allocator, 23);
    defer terrain.deinit();

    var camera = Camera.init(&terrain);
    camera.update(&terrain, .{ .vertical = 1 }, 0.1);
    const player_x = camera.player_x;
    const player_y = camera.player_y;
    const player_z = camera.player_z;

    camera.update(&terrain, .{ .toggle_view = true }, 0);
    const view = camera.view(&terrain);
    try std.testing.expect(view.third_person);
    try std.testing.expectApproxEqAbs(player_x, view.player_x, 0.0001);
    try std.testing.expectApproxEqAbs(player_y, view.player_y, 0.0001);
    try std.testing.expectApproxEqAbs(player_z, view.player_z, 0.0001);
    try std.testing.expect(view.y >= @max(terrain_mod.sea_level, terrain.height(view.x, view.z)));
    try std.testing.expect(view.y > player_y);
}

test "third person frames a grounded explorer at default and pitch limits" {
    var terrain = try Terrain.init(std.testing.allocator, 17);
    defer terrain.deinit();

    var camera = Camera.init(&terrain);
    camera.third_person = true;
    camera.pitch = 0;
    try std.testing.expectApproxEqAbs(
        groundHeight(&terrain, camera.player_x, camera.player_z),
        camera.player_y,
        0.001,
    );

    for ([_]f32{ 0, max_pitch, -max_pitch }) |look_pitch| {
        camera.pitch = look_pitch;
        const view = camera.view(&terrain);
        try std.testing.expect(view.third_person);
        try std.testing.expect(view.y >= groundHeight(&terrain, view.x, view.z) + camera_ground_clearance - 0.001);

        // The M1 landscape projects with horizon = center + tan(pitch) * focal.
        // The orbit aims its one-metre focus point at the center under that rule.
        const forward = (camera.player_x - view.x) * @sin(view.yaw) +
            (camera.player_z - view.z) * @cos(view.yaw);
        try std.testing.expect(forward > 1.2);
        const rows: f32 = 135;
        const focal = rows * 0.82;
        const horizon = rows * 0.5 + @tan(view.pitch) * focal;
        const focus_row = horizon -
            (camera.player_y + third_person_focus_height - view.y) * focal / forward;
        try std.testing.expectApproxEqAbs(rows * 0.5, focus_row, 0.01);

        const head_row = horizon - (camera.player_y + 1.76 - view.y) * focal / forward;
        const feet_row = horizon - (camera.player_y - view.y) * focal / forward;
        try std.testing.expect(head_row >= 0);
        try std.testing.expect(feet_row < rows);
    }
}
