const std = @import("std");
const platform = @import("platform.zig");
const Renderer = @import("renderer.zig").Renderer;
const scene = @import("scene.zig");
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
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--metrics")) metrics = true else if (std.mem.eql(u8, arg, "--static")) frozen = true else if (std.mem.eql(u8, arg, "--capture")) {
            capture_path = args.next() orelse return error.MissingCapturePath;
            frozen = true;
        } else if (std.mem.eql(u8, arg, "--frames")) {
            limit = try std.fmt.parseInt(u32, args.next() orelse return error.MissingFrameCount, 10);
            if (limit == 0) return error.InvalidFrameCount;
        } else if (std.mem.eql(u8, arg, "--help")) {
            log("ASCII-Life / Milestone 0\n--metrics  Report startup and frame CPU cost\n--static   Freeze the deterministic scene at tick zero\n--frames N Exit cleanly after N frames\n--capture PATH Save the first rendered frame as PPM and exit\nSpace pauses animation; F11 toggles fullscreen; Escape closes.\n", .{});
            return;
        } else return error.UnknownArgument;
    }
    var window: platform.Platform = .{};
    try window.init();
    defer window.deinit();
    while (!window.configured and window.running) try window.wait(100);
    if (!window.running) return;
    var renderer: Renderer = .{};
    try renderer.init(window.display, window.surface, window.width, window.height);
    defer renderer.deinit();
    if (capture_path != null) try renderer.requestCapture();
    window.resized = false; // init consumed the acknowledged initial dimensions.
    var cells: [scene.cols * scene.rows]scene.Cell = undefined;
    var frames: u32 = 0;
    var tick: u32 = 0;
    var cpu_ns: u64 = 0;
    var wall_ns: u64 = 0;
    var resize_count: u32 = 0;
    var gpu_ns: u64 = 0;
    var gpu_samples: u64 = 0;
    var attempts: u64 = 0;
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
            try window.wait(100);
            continue;
        }
        scene.fill(&cells, tick, window.paused);
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
        if (frames == 1 and metrics) log("startup_to_first_present_ms={d:.3}\n", .{@as(f64, @floatFromInt(now(clock.CLOCK_MONOTONIC) - started)) / 1e6});
        if (capture_path) |path| {
            if (renderer.capture_pixels.len > 0) {
                try saveCapture(path, &renderer);
                break;
            }
        }
        if (!window.paused and !frozen) tick +%= 1;
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
