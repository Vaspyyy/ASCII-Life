const std = @import("std");
const platform = @import("platform.zig");
const Renderer = @import("renderer.zig").Renderer;
const scene = @import("scene.zig");
const terrain_mod = @import("terrain.zig");
const Camera = @import("camera.zig").Camera;
const CameraInput = @import("camera.zig").Input;
const landscape = @import("landscape.zig");
const Village = @import("village.zig").Village;
const Sim = @import("village_sim.zig").Sim;
const Social = @import("people.zig").Social;
const Ecology = @import("ecology.zig").Ecology;
const Dialogue = @import("dialogue.zig").Dialogue;
const interaction = @import("interaction.zig");
const world_clock = @import("world_clock.zig");
const clock = @cImport({
    @cInclude("time.h");
    @cInclude("stdio.h");
});

fn now(clock_id: clock.clockid_t) u64 {
    var ts: clock.struct_timespec = undefined;
    if (clock.clock_gettime(clock_id, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(ts.tv_nsec));
}
fn sleepUntil(deadline: u64) void {
    const t = now(clock.CLOCK_MONOTONIC);
    if (deadline <= t) return;
    const ns = deadline - t;
    var delay = clock.struct_timespec{ .tv_sec = @intCast(ns / 1_000_000_000), .tv_nsec = @intCast(ns % 1_000_000_000) };
    while (clock.nanosleep(&delay, &delay) != 0) {}
}

pub fn main(init: std.process.Init.Minimal) u8 {
    run(init) catch |err| {
        log("ASCII-Life: {s}\n", .{@errorName(err)});
        if (@import("builtin").mode == .Debug) {
            if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
        }
        return 1;
    };
    return 0;
}

// Keep diagnostics bounded and synchronous. The C runtime is already needed by
// Wayland/Vulkan; no general-purpose async I/O backend is needed for these lines.
fn log(comptime format: []const u8, args: anytype) void {
    var buffer: [1024]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, format, args) catch return;
    _ = clock.fwrite(message.ptr, 1, message.len, clock.stderr);
}

fn run(init: std.process.Init.Minimal) !void {
    const started = now(clock.CLOCK_MONOTONIC);
    var args = init.args.iterate();
    _ = args.skip();
    var limit: u32 = 0;
    var metrics = false;
    var frozen = false;
    var capture_path: ?[:0]const u8 = null;
    var seed: u64 = terrain_mod.default_seed;
    var time_of_day: f32 = 0.36;
    var show_hud = true;
    var third_person = false;
    var tour = false;
    var atlas = false;
    var world_report = false;
    var village_report = false;
    var people_report = false;
    var ecology_report = false;
    var pen_view = false;
    var notice_view = false;
    var practice_work: u64 = 0;
    var talk_to: ?usize = null;
    var journal = false;
    var lines: [16][]const u8 = undefined;
    var line_count: usize = 0;
    var simulate_days: u64 = 0;
    var overview = false;
    var width: u32 = 2560;
    var height: u32 = 1440;
    var pose: ?[5]f32 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--metrics")) metrics = true else if (std.mem.eql(u8, arg, "--static")) frozen = true else if (std.mem.eql(u8, arg, "--capture")) {
            capture_path = args.next() orelse return error.MissingCapturePath;
            frozen = true;
        } else if (std.mem.eql(u8, arg, "--frames")) {
            limit = try std.fmt.parseInt(u32, args.next() orelse return error.MissingFrameCount, 10);
            if (limit == 0) return error.InvalidFrameCount;
        } else if (std.mem.eql(u8, arg, "--seed")) {
            seed = try std.fmt.parseInt(u64, args.next() orelse return error.MissingSeed, 0);
        } else if (std.mem.eql(u8, arg, "--time")) {
            time_of_day = try finiteFloat(args.next() orelse return error.MissingTime);
            if (time_of_day < 0 or time_of_day >= 1) return error.TimeOutsideDay;
        } else if (std.mem.eql(u8, arg, "--third-person")) {
            third_person = true;
        } else if (std.mem.eql(u8, arg, "--hide-hud")) {
            show_hud = false;
        } else if (std.mem.eql(u8, arg, "--atlas")) {
            atlas = true;
        } else if (std.mem.eql(u8, arg, "--world-report")) {
            world_report = true;
        } else if (std.mem.eql(u8, arg, "--village-report")) {
            village_report = true;
        } else if (std.mem.eql(u8, arg, "--ecology-report")) {
            ecology_report = true;
        } else if (std.mem.eql(u8, arg, "--pen-view")) {
            pen_view = true;
        } else if (std.mem.eql(u8, arg, "--notice")) {
            notice_view = true;
        } else if (std.mem.eql(u8, arg, "--work-seconds")) {
            practice_work = try std.fmt.parseInt(u64, args.next() orelse return error.MissingWorkSeconds, 10);
            if (practice_work > 86400) return error.InvalidWorkSeconds;
        } else if (std.mem.eql(u8, arg, "--people-report")) {
            people_report = true;
        } else if (std.mem.eql(u8, arg, "--talk-to")) {
            talk_to = try std.fmt.parseInt(usize, args.next() orelse return error.MissingResident, 10);
        } else if (std.mem.eql(u8, arg, "--say")) {
            if (line_count == lines.len) return error.TooManyDialogueLines;
            const line = args.next() orelse return error.MissingDialogueLine;
            if (line.len > @import("dialogue.zig").input_capacity) return error.DialogueLineTooLong;
            for (line) |ch| if (ch < 0x20 or ch > 0x7e) return error.NonAsciiDialogueLine;
            lines[line_count] = line;
            line_count += 1;
        } else if (std.mem.eql(u8, arg, "--journal")) {
            journal = true;
        } else if (std.mem.eql(u8, arg, "--elapsed-days")) {
            simulate_days = try std.fmt.parseInt(u64, args.next() orelse return error.MissingDayCount, 10);
            if (simulate_days > 3650) return error.InvalidDayCount;
        } else if (std.mem.eql(u8, arg, "--simulate-days")) {
            simulate_days = try std.fmt.parseInt(u64, args.next() orelse return error.MissingDayCount, 10);
            if (simulate_days > 3650) return error.InvalidDayCount;
            village_report = true;
        } else if (std.mem.eql(u8, arg, "--village-overview")) {
            overview = true;
        } else if (std.mem.eql(u8, arg, "--tour")) {
            tour = true;
        } else if (std.mem.eql(u8, arg, "--size")) {
            var dims = std.mem.splitScalar(u8, args.next() orelse return error.MissingSize, 'x');
            width = try std.fmt.parseInt(u32, dims.next() orelse return error.InvalidSize, 10);
            height = try std.fmt.parseInt(u32, dims.next() orelse return error.InvalidSize, 10);
            if (dims.next() != null or width < 320 or width > 3840 or height < 240 or height > 2160) return error.InvalidSize;
        } else if (std.mem.eql(u8, arg, "--view")) {
            var values = std.mem.splitScalar(u8, args.next() orelse return error.MissingView, ',');
            var v: [5]f32 = undefined;
            for (&v) |*value| value.* = try finiteFloat(values.next() orelse return error.InvalidView);
            if (values.next() != null or @abs(v[0]) > 4096 or @abs(v[1]) > 4096 or @abs(v[2]) > 100 or @abs(v[3]) > 2 or v[4] < 0 or v[4] > 1500) return error.InvalidView;
            pose = v;
        } else if (std.mem.eql(u8, arg, "--help")) {
            log("ASCII-Life / Milestone 5\n--atlas        Developer geography overview\n--world-report Headless geography validation and peak scan\n--seed N       Reproducible regional seed (decimal or 0x hex)\n--time F       Day fraction [0,1), default 0.36\n--third-person Start behind the explorer\n--hide-hud     Hide labels and controls\n--view X,Z,YAW,PITCH,HEIGHT  Set a development viewpoint (radians/metres)\n--size WxH     Initial window pixels (320x240 to 3840x2160)\n--metrics      Report generation, CPU/GPU timing, and final viewpoint\n--static       Freeze simulation and animation\n--tour         Fixed-step movement benchmark (600 frames by default)\n--frames N     Exit after N presentations\n--capture PATH Save first Vulkan frame as PPM and exit\nWASD move / arrows or right-drag look / Q,E altitude / Shift fast\nC camera / R reset / T step clock (dev) / H HUD / Space pause time\nF11 fullscreen / Esc close\n", .{});
            log("--village-report  Headless layout and residents report\n--simulate-days N Advance unattended village for QA (headless)\n--village-overview Elevated development view of the village\n", .{});
            log("F speak with nearby villager / J journal / Enter submit / Esc leave\nConversation understands: hello, name, work, family, news, plans,\nask about food, help, thanks, sorry, goodbye. Time pauses while reading.\n--people-report Headless social validation (including private QA state)\n--talk-to N     Developer conversation with resident index N\n--say TEXT      Submit a line (repeat up to 16 times; requires --talk-to)\n--journal       Open learned-information journal\n", .{});
            log("G hold near livestock pen to repair/guard (world time continues)\n--ecology-report Headless livestock/predator/accounting validation\n--pen-view      Developer viewpoint beside livestock\n--notice        Read public notice for QA if one exists\n--work-seconds N Perform N seconds of physical pen work for QA\n--elapsed-days N Advance days before native play/capture (QA)\n", .{});
            return;
        } else return error.UnknownArgument;
    }
    if (tour and capture_path != null) return error.TourCaptureConflict;
    if (line_count != 0 and talk_to == null) return error.DialogueNeedsSpeaker;
    if (tour and (talk_to != null or journal)) return error.TourDialogueConflict;
    if (tour and limit == 0) limit = 600;
    const generation_start = now(clock.CLOCK_MONOTONIC);
    var terrain = try terrain_mod.Terrain.init(std.heap.page_allocator, seed);
    defer terrain.deinit();
    if (world_report) {
        try reportWorld(&terrain);
        return;
    }
    const terrain_elapsed = now(clock.CLOCK_MONOTONIC) - generation_start;
    const village_started = now(clock.CLOCK_MONOTONIC);
    const village = try Village.init(&terrain);
    var sim = Sim.init(&village, seed);
    var social = Social.init(&sim, seed);
    var ecology = Ecology.init(&village, &sim, seed);
    world_clock.advanceWithEcology(&sim, &social, &village, &ecology, @intFromFloat(time_of_day * 86400));
    world_clock.advanceWithEcology(&sim, &social, &village, &ecology, simulate_days * 86400);
    var dialogue: Dialogue = .{};
    if (talk_to) |speaker| {
        if (speaker >= sim.resident_count) return error.InvalidResident;
        dialogue.open(speaker, &social, &sim);
        for (lines[0..line_count]) |line| {
            if (!dialogue.active) return error.ConversationEnded;
            for (line) |ch| dialogue.addChar(ch);
            dialogue.submitWithEcology(&social, &sim, &ecology);
            if (people_report) log("said={s}\nreply={s}\n", .{ line, dialogue.reply[0..dialogue.reply_len] });
        }
    }
    if (practice_work != 0) {
        _ = ecology.volunteer(ecology.owner_id);
        var left = practice_work;
        while (left != 0) {
            const step = @min(left, 3600 - sim.elapsed_seconds % 3600);
            world_clock.advanceWorking(&sim, &social, &village, &ecology, ecology.pen.x, ecology.pen.z, step);
            left -= step;
        }
    }
    if (notice_view) dialogue.openNotice(&ecology, &social, &sim);
    if (journal) dialogue.toggleJournal();
    if (village_report or people_report or ecology_report) {
        try reportVillage(&village, &sim);
        if (people_report or ecology_report) try reportPeople(&sim, &social, &dialogue);
        if (ecology_report) try reportEcology(&ecology, &sim);
        return;
    }
    terrain.start = village.arrival;
    var camera = Camera.init(&terrain);
    if (overview) camera.setPose(&terrain, village.center.x - 85, village.center.z - 100, 0.65, -0.32, 60);
    camera.third_person = third_person;
    if (pose) |v| camera.setPose(&terrain, v[0], v[1], v[2], v[3], v[4]);
    if (talk_to) |speaker| try approachSpeaker(&camera, &terrain, &village, &sim, speaker);
    if (pen_view) camera.setPose(&terrain, ecology.pen.x, ecology.pen.z - 13, 0, -0.13, 0);
    const starting_camera = camera;
    if (metrics) log("seed={d} terrain_generation_ms={d:.3}\n", .{ seed, @as(f64, @floatFromInt(terrain_elapsed)) / 1e6 });
    if (metrics) log("village_generation_ms={d:.3}\n", .{@as(f64, @floatFromInt(now(clock.CLOCK_MONOTONIC) - village_started)) / 1e6});
    var window: platform.Platform = .{ .width = width, .height = height };
    try window.init();
    defer window.deinit();
    window.setTextMode(dialogue.active or dialogue.journal_open);
    while (!window.configured and window.running) try window.wait(100);
    if (!window.running) return;
    var renderer: Renderer = .{};
    try renderer.init(window.display, window.surface, window.width, window.height);
    defer renderer.deinit();
    if (capture_path != null) try renderer.requestCapture();
    window.resized = false; // init consumed the acknowledged initial dimensions.
    var cells: [scene.cols * scene.rows]scene.Cell = undefined;
    var frames: u32 = 0;
    var animation_seconds: f32 = 0;
    var previous_time = now(clock.CLOCK_MONOTONIC);
    var cpu_ns: u64 = 0;
    var wall_ns: u64 = 0;
    var resize_count: u32 = 0;
    var gpu_ns: u64 = 0;
    var gpu_samples: u64 = 0;
    var attempts: u64 = 0;
    var sim_fraction_ns: u64 = 0;
    var tour_changed_view = false;
    var tour_step_pending = false;
    while (window.running) {
        const frame_start = now(clock.CLOCK_MONOTONIC);
        const cpu_start = now(clock.CLOCK_THREAD_CPUTIME_ID);
        try window.pump();
        if (!window.running) break;
        if (window.resized) {
            try renderer.resize(window.width, window.height);
            resize_count += 1;
            if (metrics) log("resize={d}x{d}\n", .{ window.width, window.height });
            window.resized = false;
        }
        if (window.suspended) {
            window.clearInput();
            try window.wait(100);
            previous_time = now(clock.CLOCK_MONOTONIC);
            continue;
        }
        const dt: f32 = if (tour) 1.0 / 60.0 else @min(0.1, @as(f32, @floatFromInt(frame_start - previous_time)) / 1e9);
        previous_time = frame_start;
        var input: CameraInput = .{};
        if (capture_path == null and !tour and !dialogue.active and !dialogue.journal_open) {
            if (window.takePressed(33)) {
                if (interaction.target(&sim, &village, &camera)) |speaker| {
                    dialogue.open(speaker, &social, &sim);
                } else if (nearNotice(&village, &camera) and ecology.notice) dialogue.openNotice(&ecology, &social, &sim);
            }
            if (window.takePressed(36)) dialogue.toggleJournal();
            window.setTextMode(dialogue.active or dialogue.journal_open);
            input = .{
                .forward = axis(&window, 17, 31),
                .strafe = axis(&window, 32, 30),
                .vertical = axis(&window, 18, 16),
                .fast = window.keys_down[42] or window.keys_down[54],
                .look_x = axis(&window, 106, 105) * dt * 1.3 + window.look_dx * 0.004,
                .look_y = axis(&window, 103, 108) * dt * 1.1 - window.look_dy * 0.004,
                .toggle_view = window.takePressed(46),
            };
            if (window.takePressed(35)) show_hud = !show_hud;
            if (window.takePressed(19)) camera = starting_camera;
            if (window.takePressed(20)) world_clock.advanceWithEcology(&sim, &social, &village, &ecology, 10800); // Development clock step, not unlocked player rest.
        }
        for (window.takeTextEvents()) |event| {
            switch (event) {
                .character => |ch| {
                    if (dialogue.journal_open) {
                        switch (std.ascii.toLower(ch)) {
                            'j' => dialogue.toggleJournal(),
                            'n' => dialogue.pageJournal(1),
                            'p' => dialogue.pageJournal(-1),
                            else => {},
                        }
                    } else dialogue.addChar(ch);
                },
                .backspace => dialogue.backspace(),
                .submit => dialogue.submitWithEcology(&social, &sim, &ecology),
                .cancel => if (dialogue.journal_open) dialogue.toggleJournal() else dialogue.close(),
            }
        }
        window.setTextMode(dialogue.active or dialogue.journal_open);
        if (tour and !tour_step_pending) {
            const toggle = frames >= limit / 2 and !tour_changed_view;
            if (toggle) tour_changed_view = true;
            input = .{ .forward = 0.65, .look_x = 0.0015, .fast = true, .toggle_view = toggle };
        }
        const advance = !tour or !tour_step_pending;
        window.look_dx = 0;
        window.look_dy = 0;
        camera.updateInVillage(&terrain, &village, input, if (capture_path != null or !advance) 0 else dt);
        if (advance and !frozen and !dialogue.active and !dialogue.journal_open and (tour or !window.paused)) {
            animation_seconds = @mod(animation_seconds + dt, 86400);
            const work_seconds: u64 = if (tour) 1 else blk: {
                sim_fraction_ns += @as(u64, @intFromFloat(dt * 1e9)) * 60;
                const seconds = sim_fraction_ns / 1_000_000_000;
                sim_fraction_ns %= 1_000_000_000;
                break :blk seconds;
            };
            const repairs_before = ecology.player_repaired;
            const guards_before = ecology.guard_defenses;
            if (window.keys_down[34] and @abs(camera.player_y - village.surfaceY(camera.player_x, camera.player_z)) < 1) {
                world_clock.advanceWorking(&sim, &social, &village, &ecology, camera.player_x, camera.player_z, work_seconds);
            } else world_clock.advanceWithEcology(&sim, &social, &village, &ecology, work_seconds);
            if (ecology.player_repaired > repairs_before) dialogue.recordLearnedWithContext(@import("people.zig").player_id, "You", "I finished mending the sheep pen with village materials.", @intCast(sim.day()), .witnessed, @import("people.zig").player_id, "You");
            if (ecology.guard_defenses > guards_before) dialogue.recordLearnedWithContext(@import("people.zig").player_id, "You", "I drove a hungry wolf away from the sheep pen while keeping watch.", @intCast(sim.day()), .witnessed, @import("people.zig").player_id, "You");
        }
        time_of_day = sim.timeOfDay();
        if (tour) tour_step_pending = true;
        if (atlas) landscape.fillAtlas(&cells, &terrain, camera.view(&terrain)) else landscape.fillVillageWithEcology(&cells, &terrain, camera.villageView(&terrain, &village), time_of_day, animation_seconds, show_hud and !dialogue.active and !dialogue.journal_open, &village, &sim, &ecology);
        if (show_hud and !atlas and !dialogue.active and !dialogue.journal_open) {
            scene.label(&cells, 4, scene.rows - 8, "J JOURNAL", scene.rgb(207, 222, 216));
            const px = camera.player_x - ecology.pen.x;
            const pz = camera.player_z - ecology.pen.z;
            if (px * px + pz * pz <= 81 and @abs(camera.player_y - village.surfaceY(camera.player_x, camera.player_z)) < 1) scene.label(&cells, 4, scene.rows - 10, if (ecology.player_volunteered) "HOLD G: MEND FENCE / KEEP WATCH" else "HOLD G: KEEP WATCH", scene.rgb(255, 225, 159));
            if (interaction.target(&sim, &village, &camera) != null) {
                scene.label(&cells, scene.cols / 2 - 12, scene.rows - 12, "F SPEAK WITH VILLAGER", scene.rgb(255, 225, 159));
            } else if (ecology.notice and nearNotice(&village, &camera)) scene.label(&cells, 4, scene.rows - 12, "F READ NOTICE AT WELL", scene.rgb(255, 225, 159));
        }
        dialogue.paint(&cells);
        try renderer.draw(&cells, scene.cols, scene.rows);
        cpu_ns += now(clock.CLOCK_THREAD_CPUTIME_ID) - cpu_start;
        wall_ns += now(clock.CLOCK_MONOTONIC) - frame_start;
        attempts += 1;
        if (renderer.gpu_sample_count != gpu_samples) {
            gpu_ns += renderer.last_gpu_frame_ns;
            gpu_samples = renderer.gpu_sample_count;
        }
        if (renderer.presented_frames == frames) {
            sleepUntil(frame_start + 16_666_667);
            continue;
        }
        frames = @intCast(renderer.presented_frames);
        tour_step_pending = false;
        if (frames == 1 and metrics) log("startup_to_first_present_ms={d:.3}\n", .{@as(f64, @floatFromInt(now(clock.CLOCK_MONOTONIC) - started)) / 1e6});
        if (capture_path) |path| {
            if (renderer.capture_pixels.len > 0) {
                try saveCapture(path, &renderer);
                break;
            }
        }
        if (limit != 0 and frames >= limit) break;
        // FIFO provides presentation pacing. This caps work on high-refresh displays
        // and when the compositor cannot present (e.g. a hidden window).
        sleepUntil(frame_start + 16_666_667);
    }
    if (metrics and frames > 0) {
        const n: f64 = @floatFromInt(attempts);
        log("frames={d} draw_attempts={d} frame_thread_cpu_ms={d:.4} frame_work_wall_ms={d:.4} elapsed_ms={d:.2} key_events={d} pointer_events={d} resizes={d}\n", .{ frames, attempts, @as(f64, @floatFromInt(cpu_ns)) / n / 1e6, @as(f64, @floatFromInt(wall_ns)) / n / 1e6, @as(f64, @floatFromInt(now(clock.CLOCK_MONOTONIC) - started)) / 1e6, window.key_events, window.pointer_events, resize_count });
    }
    if (metrics) {
        try reportVillage(&village, &sim);
        try reportPeople(&sim, &social, &dialogue);
        try reportEcology(&ecology, &sim);
        const cache_stats = terrain.cache.stats();
        log("output={d}x{d} grid={d}x{d} tile_hits={d} tile_misses={d} tile_evictions={d}\n", .{ window.width, window.height, scene.cols, scene.rows, cache_stats.hits, cache_stats.misses, cache_stats.evictions });
        log("view={d:.2},{d:.2},{d:.3},{d:.3},{d:.2} third_person={} time={d:.4}\n", .{ camera.player_x, camera.player_z, camera.yaw, camera.pitch, camera.player_y - terrain.standingHeight(camera.player_x, camera.player_z), camera.third_person, time_of_day });
        if (gpu_samples > 0) log("frame_gpu_ms={d:.4} gpu_samples={d}\n", .{ @as(f64, @floatFromInt(gpu_ns)) / @as(f64, @floatFromInt(gpu_samples)) / 1e6, gpu_samples }) else log("frame_gpu_ms=unavailable\n", .{});
    }
}

fn saveCapture(path: [:0]const u8, renderer: *Renderer) !void {
    const file = clock.fopen(path.ptr, "wb") orelse return error.CaptureOpenFailed;
    defer _ = clock.fclose(file);
    var header: [80]u8 = undefined;
    const text = try std.fmt.bufPrint(&header, "P6\n{d} {d}\n255\n", .{ renderer.capture_width, renderer.capture_height });
    if (clock.fwrite(text.ptr, 1, text.len, file) != text.len) return error.CaptureWriteFailed;
    const row = try std.heap.page_allocator.alloc(u8, @as(usize, renderer.capture_width) * 3);
    defer std.heap.page_allocator.free(row);
    for (0..renderer.capture_height) |y| {
        for (0..renderer.capture_width) |x| {
            const pixel = renderer.capture_pixels[(y * renderer.capture_width + x) * 4 ..][0..4];
            row[x * 3] = pixel[if (renderer.capture_bgra) 2 else 0];
            row[x * 3 + 1] = pixel[1];
            row[x * 3 + 2] = pixel[if (renderer.capture_bgra) 0 else 2];
        }
        if (clock.fwrite(row.ptr, 1, row.len, file) != row.len) return error.CaptureWriteFailed;
    }
    if (clock.fflush(file) != 0) return error.CaptureWriteFailed;
    log("capture={s} size={d}x{d}\n", .{ path, renderer.capture_width, renderer.capture_height });
}

fn finiteFloat(text: []const u8) !f32 {
    const value = try std.fmt.parseFloat(f32, text);
    if (!std.math.isFinite(value)) return error.NonFiniteArgument;
    return value;
}

fn approachSpeaker(camera: *Camera, terrain: *const terrain_mod.Terrain, village: *const Village, sim: *const Sim, speaker: usize) !void {
    const p = sim.residents[speaker].position;
    for (0..16) |i| {
        const angle = @as(f32, @floatFromInt(i)) * std.math.tau / 16;
        const x = p.x + @sin(angle) * 3.5;
        const z = p.z + @cos(angle) * 3.5;
        if (village.blocked(x, z, 0.5)) continue;
        camera.setPose(terrain, x, z, angle + std.math.pi, -0.12, 0);
        camera.pitch = std.math.atan((p.y + 1.1 - (camera.player_y + 2.5)) / 3.5);
        if (interaction.target(sim, village, camera) == speaker) return;
    }
    return error.ResidentNotReachable;
}

fn reportPeople(sim: *const Sim, social: *const Social, dialogue: *const Dialogue) !void {
    try social.validate(sim);
    log("people={d} social_fingerprint={x} social_validation_ok=1 journal_entries={d} conversation_active={}\n", .{ sim.resident_count, social.fingerprint(), dialogue.journal_count, dialogue.active });
    log("dialogue_speaker={d} journal_open={} history_turns={d} dialogue_reply={s}\n", .{ dialogue.speaker_id, dialogue.journal_open, dialogue.history_count, dialogue.reply[0..dialogue.reply_len] });
    for (0..dialogue.history_count) |i| {
        const turn = dialogue.history[(dialogue.history_start + i) % @import("dialogue.zig").max_history];
        log("dialogue_typed={s}\ndialogue_answer={s}\n", .{ turn.player_line[0..turn.player_len], turn.reply[0..turn.reply_len] });
    }
    for (social.persons[0..social.count], 0..) |person, id| {
        log("person={d} name={s} job={s} family_links={d} memories={d} trust={d} goal={s} goal_hours={d}/{d}\n", .{ id, person.nameSlice(), @tagName(person.job), person.family_count, person.memory_count, person.player.trust, @tagName(person.goal.kind), person.goal.progress_hours, person.goal.target_hours });
        for (person.knowledge[0..person.knowledge_count]) |knowledge| {
            log("belief_person={d} topic={s} belief={s} provenance={s} source={d} witness={d} event={d} confidence={d} evidence_days={d}\n", .{ id, @tagName(knowledge.topic), @tagName(knowledge.belief), @tagName(knowledge.provenance), knowledge.source_id, knowledge.witness_id, knowledge.event_id, knowledge.confidence, knowledge.evidence_days });
        }
    }
    for (0..dialogue.journal_count) |i| {
        const entry = dialogue.journal[(dialogue.journal_start + i) % @import("dialogue.zig").max_journal_entries];
        log("journal_source={d} learned_day={d} journal={s}\n", .{ entry.source_id, entry.learned_day, entry.text[0..entry.text_len] });
    }
}
fn axis(window: *const platform.Platform, positive: usize, negative: usize) f32 {
    return @as(f32, @floatFromInt(@intFromBool(window.keys_down[positive]))) - @as(f32, @floatFromInt(@intFromBool(window.keys_down[negative])));
}

fn reportWorld(terrain: *terrain_mod.Terrain) !void {
    var river_nodes: usize = 0;
    var lake_nodes: usize = 0;
    var biomes = [_]u32{0} ** @typeInfo(terrain_mod.climate_mod.Biome).@"enum".fields.len;
    var rain_min: u16 = std.math.maxInt(u16);
    var rain_max: u16 = 0;
    var fingerprint: u64 = 0xcbf29ce484222325;
    for (terrain.samples, 0..) |height, i| {
        const x = -4096 + @as(f32, @floatFromInt(i % 257)) * 32;
        const z = -4096 + @as(f32, @floatFromInt(i / 257)) * 32;
        const water = terrain.water(x, z);
        if (water.kind == .river) river_nodes += 1;
        if (water.kind == .lake) lake_nodes += 1;
        const geo = terrain.geography(x, z, water);
        biomes[@intFromEnum(geo.biome)] += 1;
        rain_min = @min(rain_min, geo.rainfall_mm);
        rain_max = @max(rain_max, geo.rainfall_mm);
        fingerprint = (fingerprint ^ height) *% 0x100000001b3;
    }
    if (river_nodes == 0) return error.NoRivers;
    const peak = terrain.peak();
    log("seed={d} generation_seed={d} repaired={} macro_fingerprint={x}\n", .{ terrain.seed, terrain.generation_seed, terrain.repaired, fingerprint });
    log("region_m=8192x8192 grid={d}x{d} peak_world_y={d:.2} peak_above_sea_m={d:.2}\n", .{ scene.cols, scene.rows, peak, peak - terrain_mod.sea_level });
    log("river_nodes={d} lake_nodes={d} rainfall_mm={d}..{d}\n", .{ river_nodes, lake_nodes, rain_min, rain_max });
    log("start={d:.2},{d:.2},{d:.3} settlement_candidate={d:.2},{d:.2} suitability={d}\n", .{ terrain.start.x, terrain.start.z, terrain.start.yaw, terrain.settlement.x, terrain.settlement.z, terrain.settlement.score });
    inline for (@typeInfo(terrain_mod.climate_mod.Biome).@"enum".fields) |field| {
        log("biome_{s}={d}\n", .{ field.name, biomes[field.value] });
    }
    const st = terrain.cache.stats();
    log("stream_hits={d} misses={d} evictions={d}\n", .{ st.hits, st.misses, st.evictions });
}

fn reportVillage(village: *const Village, sim: *const Sim) !void {
    try village.validate();
    try sim.validate(village);
    var homes: usize = 0;
    var farms: usize = 0;
    for (village.buildingsSlice()) |b| {
        if (b.kind == .home) homes += 1;
        if (b.kind == .farm) farms += 1;
    }
    log("layout_fingerprint={x}\n", .{village.layoutFingerprint()});
    log("village_seed={d} center={d:.2},{d:.2} arrival={d:.2},{d:.2},{d:.3}\n", .{ village.seed, village.center.x, village.center.z, village.arrival.x, village.arrival.z, village.arrival.yaw });
    log("buildings={d} homes={d} farms={d} paths={d} residents={d} households={d} unassigned_adults=0 validation_ok=1\n", .{ village.building_count, homes, farms, village.path_count, sim.resident_count, sim.household_count });
    log("simulation_seconds={d} day={d} simulation_fingerprint={x}\n", .{ sim.elapsed_seconds, sim.day(), sim.fingerprint() });
    var walking: usize = 0;
    var working: usize = 0;
    var sleeping: usize = 0;
    for (sim.residents[0..sim.resident_count]) |r| {
        switch (r.activity) {
            .walking => walking += 1,
            .working => working += 1,
            .sleeping => sleeping += 1,
            else => {},
        }
    }
    log("walking={d} working={d} sleeping={d}\n", .{ walking, working, sleeping });
    const e = sim.economy;
    log("food_stock={d} food_produced={d} food_consumed={d} food_shortage={d} work_seconds={d}\n", .{ e.food_stock_milli, e.food_produced_milli, e.food_consumed_milli, e.food_shortage_milli, e.work_seconds });
    log("goods_stock={d} goods_produced={d} goods_consumed={d} goods_shortage={d}\n", .{ e.goods_stock_milli, e.goods_produced_milli, e.goods_consumed_milli, e.goods_shortage_milli });
    log("water_stock={d} water_produced={d} water_consumed={d} water_shortage={d}\n", .{ e.water_stock_milli, e.water_produced_milli, e.water_consumed_milli, e.water_shortage_milli });
}

fn nearNotice(village: *const Village, camera: *const Camera) bool {
    if (@abs(camera.player_y - village.surfaceY(camera.player_x, camera.player_z)) > 1) return false;
    for (village.buildingsSlice()) |building| {
        if (building.kind != .well) continue;
        const dx = camera.player_x - building.x;
        const dz = camera.player_z - building.z;
        return dx * dx + dz * dz < 49;
    }
    return false;
}

fn reportEcology(ecology: *const Ecology, sim: *const Sim) !void {
    try ecology.validate(sim);
    log("ecology_validation_ok=1 ecology_fingerprint={x} livestock_owner={d} pen={d:.2},{d:.2} animals={d} initial_animals={d} losses={d} attacks={d} defenses={d} repairs={d} fence={d} guard_defenses={d} player_repairs={d} npc_assists={d} neighbor_repairs={d} notice={} volunteered={} player_work_seconds={d}\n", .{ ecology.fingerprint(), ecology.owner_id, ecology.pen.x, ecology.pen.z, ecology.animals, ecology.initial_animals, ecology.losses, ecology.attacks, ecology.defenses, ecology.repaired, ecology.fence, ecology.guard_defenses, ecology.player_repaired, ecology.npc_assists, ecology.neighbor_repairs, ecology.notice, ecology.player_volunteered, ecology.player_work_seconds });
    log("livestock_food_produced={d} livestock_food_lost={d} repair_goods_consumed={d}\n", .{ sim.economy.livestock_food_produced_milli, sim.economy.livestock_food_lost_milli, sim.economy.repair_goods_consumed_milli });
}
