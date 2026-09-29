const std = @import("std");

pub const c = @cImport({
    @cInclude("native.h");
});

pub const TextEvent = union(enum) {
    character: u8,
    backspace,
    submit,
    cancel,
};

const text_event_capacity = 128;

/// The Wayland state must stay at a stable address from `init` through
/// `deinit`: Wayland listener user data points back to this value.
pub const Platform = struct {
    display: ?*c.wl_display = null,
    surface: ?*c.wl_surface = null,
    width: u32 = 1920,
    height: u32 = 1080,
    configured: bool = false,
    running: bool = true,
    resized: bool = false,
    paused: bool = false,
    key_events: u64 = 0,
    pointer_events: u64 = 0,

    /// Linux evdev key state, indexed by key code. Entries are updated on
    /// both press and release, including the keys in keyboard-enter events.
    keys_down: [768]bool = [_]bool{false} ** 768,
    keys_pressed: [768]bool = [_]bool{false} ** 768,
    text_keys_down: [768]bool = [_]bool{false} ** 768,
    text_mode: bool = false,
    text_events: [text_event_capacity]TextEvent = undefined,
    text_event_count: usize = 0,
    right_mouse: bool = false,
    look_dx: f32 = 0,
    look_dy: f32 = 0,
    pointer_x: f64 = 0,
    pointer_y: f64 = 0,
    suspended: bool = false,

    registry: ?*c.wl_registry = null,
    compositor: ?*c.wl_compositor = null,
    wm_base: ?*c.xdg_wm_base = null,
    xdg_surface: ?*c.xdg_surface = null,
    toplevel: ?*c.xdg_toplevel = null,
    seat: ?*c.wl_seat = null,
    keyboard: ?*c.wl_keyboard = null,
    pointer: ?*c.wl_pointer = null,
    user_paused: bool = false,
    fullscreen: bool = false,
    pending_width: u32 = 1920,
    pending_height: u32 = 1080,
    pending_suspended: bool = false,
    registry_failed: bool = false,
    xkb_context: @TypeOf(c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS)) = null,
    xkb_keymap: @TypeOf(c.xkb_keymap_new_from_string(null, null, c.XKB_KEYMAP_FORMAT_TEXT_V1, c.XKB_KEYMAP_COMPILE_NO_FLAGS)) = null,
    xkb_state: @TypeOf(c.xkb_state_new(null)) = null,

    pub fn init(self: *Platform) !void {
        const width = self.width;
        const height = self.height;
        self.* = .{ .width = width, .height = height, .pending_width = width, .pending_height = height };

        self.xkb_context = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS) orelse return error.XkbContextFailed;
        errdefer self.deinit();

        self.display = c.wl_display_connect(null) orelse return error.WaylandConnectFailed;

        const display = self.display.?;
        self.registry = c.wl_display_get_registry(display) orelse return error.WaylandRegistryFailed;
        if (c.wl_registry_add_listener(self.registry.?, &registry_listener, self) != 0) {
            return error.WaylandListenerFailed;
        }
        if (c.wl_display_roundtrip(display) < 0) return error.WaylandRoundtripFailed;
        if (self.registry_failed) return error.WaylandGlobalBindFailed;

        if (self.compositor == null or self.wm_base == null) return error.WaylandGlobalsUnavailable;

        const surface = c.wl_compositor_create_surface(self.compositor.?) orelse return error.WaylandSurfaceFailed;
        self.surface = surface;
        self.xdg_surface = c.xdg_wm_base_get_xdg_surface(self.wm_base.?, surface) orelse return error.XdgSurfaceFailed;
        if (c.xdg_surface_add_listener(self.xdg_surface.?, &xdg_surface_listener, self) != 0) {
            return error.WaylandListenerFailed;
        }

        self.toplevel = c.xdg_surface_get_toplevel(self.xdg_surface.?) orelse return error.XdgToplevelFailed;
        if (c.xdg_toplevel_add_listener(self.toplevel.?, &toplevel_listener, self) != 0) {
            return error.WaylandListenerFailed;
        }
        c.xdg_toplevel_set_title(self.toplevel.?, "ASCII-Life");
        c.xdg_toplevel_set_app_id(self.toplevel.?, "ascii-life");
        c.xdg_toplevel_set_min_size(self.toplevel.?, 320, 240);

        // The compositor must see the role before it can send the initial
        // configure. Rendering starts only after that configure is acked.
        c.wl_surface_commit(surface);
        if (c.wl_display_roundtrip(display) < 0) return error.WaylandRoundtripFailed;
        if (c.wl_display_get_error(display) != 0) return error.WaylandConnectionFailed;
    }

    pub fn clearInput(self: *Platform) void {
        self.keys_down = [_]bool{false} ** 768;
        self.keys_pressed = [_]bool{false} ** 768;
        self.text_keys_down = [_]bool{false} ** 768;
        self.text_event_count = 0;
        self.look_dx = 0;
        self.look_dy = 0;
        self.right_mouse = false;
    }

    /// Enable layout-aware ASCII text input while preserving the normal game
    /// controls outside this mode. Transitions discard held movement keys and
    /// pending text so an opening/closing key cannot leak into gameplay/UI.
    pub fn setTextMode(self: *Platform, enabled: bool) void {
        if (self.text_mode == enabled) return;
        self.text_mode = enabled;
        self.keys_down = [_]bool{false} ** 768;
        self.keys_pressed = [_]bool{false} ** 768;
        self.text_keys_down = [_]bool{false} ** 768;
        self.text_event_count = 0;
        self.look_dx = 0;
        self.look_dy = 0;
        self.right_mouse = false;
    }

    /// Return key events in compositor order, then empty the bounded queue.
    /// The returned slice stays valid until this Platform records more events.
    pub fn takeTextEvents(self: *Platform) []const TextEvent {
        const events = self.text_events[0..self.text_event_count];
        self.text_event_count = 0;
        return events;
    }

    pub fn takePressed(self: *Platform, key: usize) bool {
        const pressed = self.keys_pressed[key];
        self.keys_pressed[key] = false;
        return pressed;
    }

    pub fn deinit(self: *Platform) void {
        if (self.pointer) |pointer| c.wl_pointer_destroy(pointer);
        self.pointer = null;
        if (self.keyboard) |keyboard| c.wl_keyboard_destroy(keyboard);
        self.keyboard = null;
        if (self.seat) |seat| c.wl_seat_destroy(seat);
        self.seat = null;
        if (self.toplevel) |toplevel| c.xdg_toplevel_destroy(toplevel);
        self.toplevel = null;
        if (self.xdg_surface) |xdg_surface| c.xdg_surface_destroy(xdg_surface);
        self.xdg_surface = null;
        if (self.surface) |surface| c.wl_surface_destroy(surface);
        self.surface = null;
        if (self.wm_base) |wm_base| c.xdg_wm_base_destroy(wm_base);
        self.wm_base = null;
        if (self.compositor) |compositor| c.wl_compositor_destroy(compositor);
        self.compositor = null;
        if (self.registry) |registry| c.wl_registry_destroy(registry);
        self.registry = null;
        if (self.display) |display| c.wl_display_disconnect(display);
        self.display = null;
        self.releaseXkbKeymap();
        if (self.xkb_context) |context| c.xkb_context_unref(context);
        self.xkb_context = null;
        self.running = false;
    }

    /// Dispatch available events without waiting for new input.
    pub fn pump(self: *Platform) !void {
        try self.pollEvents(0);
    }

    /// Dispatch events, waiting up to `timeout_ms`. A negative timeout waits
    /// indefinitely, matching poll(2).
    pub fn wait(self: *Platform, timeout_ms: i32) !void {
        try self.pollEvents(timeout_ms);
    }

    fn pollEvents(self: *Platform, timeout_ms: i32) !void {
        const display = self.display orelse return error.WaylandNotInitialized;

        // prepare_read only succeeds when the pending queue is empty. If it
        // reports work, dispatch it and retry before polling the socket.
        while (c.wl_display_prepare_read(display) != 0) {
            if (c.wl_display_dispatch_pending(display) < 0) return error.WaylandDispatchFailed;
        }

        const flush_result = c.wl_display_flush(display);
        if (flush_result < 0 and c.wl_display_get_error(display) != 0) {
            c.wl_display_cancel_read(display);
            return error.WaylandFlushFailed;
        }

        var fd = c.pollfd{
            .fd = c.wl_display_get_fd(display),
            .events = @intCast(c.POLLIN | (if (flush_result < 0) c.POLLOUT else 0)),
            .revents = 0,
        };
        const poll_result = c.poll(&fd, 1, timeout_ms);
        if (poll_result < 0) {
            const poll_errno = c.ascii_life_errno();
            c.wl_display_cancel_read(display);
            if (poll_errno == c.EINTR) return;
            return error.WaylandPollFailed;
        }

        if (poll_result == 0) {
            c.wl_display_cancel_read(display);
            return;
        }

        if ((fd.revents & c.POLLNVAL) != 0) {
            c.wl_display_cancel_read(display);
            return error.WaylandSocketInvalid;
        }

        if ((fd.revents & c.POLLIN) != 0) {
            if (c.wl_display_read_events(display) < 0) return error.WaylandReadFailed;
        } else {
            c.wl_display_cancel_read(display);
        }

        if ((fd.revents & c.POLLOUT) != 0) {
            if (c.wl_display_flush(display) < 0 and c.wl_display_get_error(display) != 0) {
                return error.WaylandFlushFailed;
            }
        }
        if ((fd.revents & (c.POLLERR | c.POLLHUP)) != 0 and c.wl_display_get_error(display) != 0) {
            return error.WaylandConnectionFailed;
        }
        if (c.wl_display_dispatch_pending(display) < 0) return error.WaylandDispatchFailed;
    }

    fn fromUserData(data: ?*anyopaque) *Platform {
        return @ptrCast(@alignCast(data.?));
    }

    fn updatePaused(self: *Platform) void {
        self.paused = self.user_paused or self.suspended;
    }

    fn countKeyEvent(self: *Platform) void {
        self.key_events +%= 1;
    }

    fn countPointerEvent(self: *Platform) void {
        self.pointer_events +%= 1;
    }

    fn queueTextEvent(self: *Platform, event: TextEvent) void {
        if (self.text_event_count == self.text_events.len) return;
        self.text_events[self.text_event_count] = event;
        self.text_event_count += 1;
    }

    fn releaseXkbKeymap(self: *Platform) void {
        if (self.xkb_state) |state| c.xkb_state_unref(state);
        self.xkb_state = null;
        if (self.xkb_keymap) |keymap| c.xkb_keymap_unref(keymap);
        self.xkb_keymap = null;
    }

    fn resetXkbModifiers(self: *Platform) void {
        if (self.xkb_state) |state| {
            _ = c.xkb_state_update_mask(state, 0, 0, 0, 0, 0, 0);
        }
    }
};

fn onRegistryGlobal(
    data: ?*anyopaque,
    registry: ?*c.wl_registry,
    name: u32,
    interface: [*c]const u8,
    version: u32,
) callconv(.c) void {
    const self = Platform.fromUserData(data);
    const registry_proxy = registry orelse return;
    if (interface == null) return;
    const interface_name = std.mem.span(@as([*:0]const u8, @ptrCast(interface)));

    if (std.mem.eql(u8, interface_name, "wl_compositor") and self.compositor == null) {
        const bound = c.wl_registry_bind(registry_proxy, name, &c.wl_compositor_interface, @min(version, 4)) orelse {
            self.registry_failed = true;
            return;
        };
        self.compositor = @ptrCast(bound);
    } else if (std.mem.eql(u8, interface_name, "xdg_wm_base") and self.wm_base == null) {
        const bound = c.wl_registry_bind(registry_proxy, name, &c.xdg_wm_base_interface, @min(version, 6)) orelse {
            self.registry_failed = true;
            return;
        };
        self.wm_base = @ptrCast(bound);
        if (c.xdg_wm_base_add_listener(self.wm_base.?, &wm_base_listener, self) != 0) {
            self.registry_failed = true;
        }
    } else if (std.mem.eql(u8, interface_name, "wl_seat") and self.seat == null) {
        const bound = c.wl_registry_bind(registry_proxy, name, &c.wl_seat_interface, @min(version, 4)) orelse {
            self.registry_failed = true;
            return;
        };
        self.seat = @ptrCast(bound);
        if (c.wl_seat_add_listener(self.seat.?, &seat_listener, self) != 0) {
            self.registry_failed = true;
        }
    }
}

fn onRegistryGlobalRemove(_: ?*anyopaque, _: ?*c.wl_registry, _: u32) callconv(.c) void {}

fn onWmBasePing(data: ?*anyopaque, wm_base: ?*c.xdg_wm_base, serial: u32) callconv(.c) void {
    _ = data;
    if (wm_base) |base| c.xdg_wm_base_pong(base, serial);
}

fn onXdgSurfaceConfigure(data: ?*anyopaque, xdg_surface: ?*c.xdg_surface, serial: u32) callconv(.c) void {
    const self = Platform.fromUserData(data);
    if (xdg_surface) |surface| c.xdg_surface_ack_configure(surface, serial);
    if (!self.configured or self.width != self.pending_width or self.height != self.pending_height) {
        self.resized = true;
    }
    self.width = self.pending_width;
    self.height = self.pending_height;
    self.suspended = self.pending_suspended;
    self.updatePaused();
    self.configured = true;
}

fn onToplevelConfigure(
    data: ?*anyopaque,
    _: ?*c.xdg_toplevel,
    width: i32,
    height: i32,
    states: ?*c.wl_array,
) callconv(.c) void {
    const self = Platform.fromUserData(data);
    self.pending_width = self.width;
    self.pending_height = self.height;
    // Zero dimensions are the compositor's request for the client to choose;
    // retaining our current dimensions follows xdg-shell configure rules.
    if (width > 0) self.pending_width = @intCast(width);
    if (height > 0) self.pending_height = @intCast(height);

    self.pending_suspended = false;
    if (states) |state_array| {
        const size: usize = state_array.size;
        if (size >= @sizeOf(u32)) {
            if (state_array.data) |raw_data| {
                const values: [*]const u32 = @ptrCast(@alignCast(raw_data));
                const count = size / @sizeOf(u32);
                for (values[0..count]) |state| {
                    if (state == c.XDG_TOPLEVEL_STATE_SUSPENDED) self.pending_suspended = true;
                }
            }
        }
    }
}

fn onToplevelClose(data: ?*anyopaque, _: ?*c.xdg_toplevel) callconv(.c) void {
    Platform.fromUserData(data).running = false;
}

fn onToplevelConfigureBounds(_: ?*anyopaque, _: ?*c.xdg_toplevel, _: i32, _: i32) callconv(.c) void {}
fn onToplevelWmCapabilities(_: ?*anyopaque, _: ?*c.xdg_toplevel, _: ?*c.wl_array) callconv(.c) void {}

fn onSeatCapabilities(data: ?*anyopaque, seat: ?*c.wl_seat, capabilities: u32) callconv(.c) void {
    const self = Platform.fromUserData(data);
    const seat_proxy = seat orelse return;

    if ((capabilities & c.WL_SEAT_CAPABILITY_KEYBOARD) != 0 and self.keyboard == null) {
        self.keyboard = c.wl_seat_get_keyboard(seat_proxy) orelse return;
        if (c.wl_keyboard_add_listener(self.keyboard.?, &keyboard_listener, self) != 0) {
            c.wl_keyboard_destroy(self.keyboard.?);
            self.keyboard = null;
        }
    } else if ((capabilities & c.WL_SEAT_CAPABILITY_KEYBOARD) == 0) {
        if (self.keyboard) |keyboard| c.wl_keyboard_destroy(keyboard);
        self.keyboard = null;
        self.clearInput();
        self.resetXkbModifiers();
    }

    if ((capabilities & c.WL_SEAT_CAPABILITY_POINTER) != 0 and self.pointer == null) {
        self.pointer = c.wl_seat_get_pointer(seat_proxy) orelse return;
        if (c.wl_pointer_add_listener(self.pointer.?, &pointer_listener, self) != 0) {
            c.wl_pointer_destroy(self.pointer.?);
            self.pointer = null;
        }
    } else if ((capabilities & c.WL_SEAT_CAPABILITY_POINTER) == 0) {
        if (self.pointer) |pointer| c.wl_pointer_destroy(pointer);
        self.pointer = null;
        self.right_mouse = false;
        self.look_dx = 0;
        self.look_dy = 0;
    }
}

fn onSeatName(_: ?*anyopaque, _: ?*c.wl_seat, _: [*c]const u8) callconv(.c) void {}

fn onKeyboardKeymap(data: ?*anyopaque, _: ?*c.wl_keyboard, format: u32, fd: i32, size: u32) callconv(.c) void {
    const self = Platform.fromUserData(data);
    if (format != c.WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1 or fd < 0) {
        if (fd >= 0) _ = c.close(fd);
        self.releaseXkbKeymap();
        return;
    }

    const mapping = c.ascii_life_map_keymap(fd, size) orelse {
        self.releaseXkbKeymap();
        return;
    };
    defer c.ascii_life_unmap_keymap(mapping, size);

    const map_size: usize = @intCast(size);
    if (map_size == 0) {
        self.releaseXkbKeymap();
        return;
    }
    const bytes: [*]const u8 = @ptrCast(mapping);
    if (bytes[map_size - 1] != 0) {
        self.releaseXkbKeymap();
        return;
    }

    const context = self.xkb_context orelse return;
    const keymap = c.xkb_keymap_new_from_string(
        context,
        mapping,
        c.XKB_KEYMAP_FORMAT_TEXT_V1,
        c.XKB_KEYMAP_COMPILE_NO_FLAGS,
    ) orelse {
        self.releaseXkbKeymap();
        return;
    };
    const state = c.xkb_state_new(keymap) orelse {
        c.xkb_keymap_unref(keymap);
        self.releaseXkbKeymap();
        return;
    };

    self.releaseXkbKeymap();
    self.xkb_keymap = keymap;
    self.xkb_state = state;
}

fn onKeyboardEnter(data: ?*anyopaque, _: ?*c.wl_keyboard, _: u32, _: ?*c.wl_surface, keys: ?*c.wl_array) callconv(.c) void {
    const self = Platform.fromUserData(data);
    self.clearInput();
    if (keys) |key_array| {
        const size: usize = key_array.size;
        if (size >= @sizeOf(u32)) {
            if (key_array.data) |raw_data| {
                const values: [*]const u32 = @ptrCast(@alignCast(raw_data));
                const count = size / @sizeOf(u32);
                for (values[0..count]) |key| {
                    if (key < self.keys_down.len) {
                        if (self.text_mode) {
                            self.text_keys_down[key] = true;
                        } else {
                            self.keys_down[key] = true;
                        }
                    }
                }
            }
        }
    }
}

fn onKeyboardLeave(data: ?*anyopaque, _: ?*c.wl_keyboard, _: u32, _: ?*c.wl_surface) callconv(.c) void {
    const self = Platform.fromUserData(data);
    self.clearInput();
    self.resetXkbModifiers();
}

fn onKeyboardKey(data: ?*anyopaque, _: ?*c.wl_keyboard, _: u32, _: u32, key: u32, state: u32) callconv(.c) void {
    const self = Platform.fromUserData(data);
    const pressed = state == c.WL_KEYBOARD_KEY_STATE_PRESSED;
    const key_index: ?usize = if (key < self.keys_down.len) @intCast(key) else null;
    const was_down = if (key_index) |index|
        (if (self.text_mode) self.text_keys_down[index] else self.keys_down[index])
    else
        false;
    if (key_index) |index| {
        if (self.text_mode) {
            self.text_keys_down[index] = pressed;
            self.keys_down[index] = false;
        } else {
            self.keys_down[index] = pressed;
            self.text_keys_down[index] = false;
        }
    }
    self.countKeyEvent();

    // Function keys stay global while reading; presses already held are ignored
    // so compositor repeat cannot save/reload or toggle fullscreen repeatedly.
    if (pressed and !was_down) {
        if (key == 63 or key == 67) self.keys_pressed[key] = true;
        if (key == 87) {
            self.fullscreen = !self.fullscreen;
            if (self.toplevel) |toplevel| {
                if (self.fullscreen) c.xdg_toplevel_set_fullscreen(toplevel, null) else c.xdg_toplevel_unset_fullscreen(toplevel);
            }
        }

        if (self.text_mode) {
            handleTextKey(self, key);
            return;
        }

        if (key_index) |index| self.keys_pressed[index] = true;
        if (key == 1) self.running = false;
        if (key == 57) {
            self.user_paused = !self.user_paused;
            self.updatePaused();
        }
    }
}

fn onKeyboardModifiers(data: ?*anyopaque, _: ?*c.wl_keyboard, _: u32, depressed: u32, latched: u32, locked: u32, group: u32) callconv(.c) void {
    const self = Platform.fromUserData(data);
    if (self.xkb_state) |state| {
        _ = c.xkb_state_update_mask(state, depressed, latched, locked, 0, 0, group);
    }
}
fn onKeyboardRepeatInfo(_: ?*anyopaque, _: ?*c.wl_keyboard, _: i32, _: i32) callconv(.c) void {}

fn handleTextKey(self: *Platform, key: u32) void {
    if (key >= self.keys_down.len) return;
    const state = self.xkb_state orelse return;
    const keycode = key + 8; // Wayland supplies evdev codes; XKB adds 8.
    const keysym = c.xkb_state_key_get_one_sym(state, keycode);
    if (keysym == c.XKB_KEY_Escape) {
        self.keys_pressed[1] = true;
        self.queueTextEvent(.cancel);
    } else if (keysym == c.XKB_KEY_Return or keysym == c.XKB_KEY_KP_Enter) {
        self.queueTextEvent(.submit);
    } else if (keysym == c.XKB_KEY_BackSpace) {
        self.queueTextEvent(.backspace);
    } else {
        const codepoint = c.xkb_state_key_get_utf32(state, keycode);
        if (codepoint >= 0x20 and codepoint <= 0x7e) {
            self.queueTextEvent(.{ .character = @intCast(codepoint) });
        }
    }
}

fn onPointerEnter(data: ?*anyopaque, _: ?*c.wl_pointer, _: u32, _: ?*c.wl_surface, x: c.wl_fixed_t, y: c.wl_fixed_t) callconv(.c) void {
    const self = Platform.fromUserData(data);
    self.countPointerEvent();
    self.pointer_x = c.wl_fixed_to_double(x);
    self.pointer_y = c.wl_fixed_to_double(y);
}

fn onPointerLeave(data: ?*anyopaque, _: ?*c.wl_pointer, _: u32, _: ?*c.wl_surface) callconv(.c) void {
    const self = Platform.fromUserData(data);
    self.right_mouse = false;
    self.countPointerEvent();
}

fn onPointerMotion(data: ?*anyopaque, _: ?*c.wl_pointer, _: u32, x: c.wl_fixed_t, y: c.wl_fixed_t) callconv(.c) void {
    const self = Platform.fromUserData(data);
    const px = c.wl_fixed_to_double(x);
    const py = c.wl_fixed_to_double(y);
    if (self.right_mouse) {
        self.look_dx += @floatCast(px - self.pointer_x);
        self.look_dy += @floatCast(py - self.pointer_y);
    }
    self.countPointerEvent();
    self.pointer_x = px;
    self.pointer_y = py;
}

fn onPointerButton(data: ?*anyopaque, _: ?*c.wl_pointer, _: u32, _: u32, button: u32, state: u32) callconv(.c) void {
    const self = Platform.fromUserData(data);
    self.countPointerEvent();
    if (button == 273) self.right_mouse = state == c.WL_POINTER_BUTTON_STATE_PRESSED;
}

fn onPointerAxis(data: ?*anyopaque, _: ?*c.wl_pointer, _: u32, _: u32, _: c.wl_fixed_t) callconv(.c) void {
    Platform.fromUserData(data).countPointerEvent();
}

fn onPointerFrame(_: ?*anyopaque, _: ?*c.wl_pointer) callconv(.c) void {}
fn onPointerAxisSource(_: ?*anyopaque, _: ?*c.wl_pointer, _: u32) callconv(.c) void {}
fn onPointerAxisStop(_: ?*anyopaque, _: ?*c.wl_pointer, _: u32, _: u32) callconv(.c) void {}
fn onPointerAxisDiscrete(_: ?*anyopaque, _: ?*c.wl_pointer, _: u32, _: i32) callconv(.c) void {}
fn onPointerAxisValue120(_: ?*anyopaque, _: ?*c.wl_pointer, _: u32, _: i32) callconv(.c) void {}
fn onPointerAxisRelativeDirection(_: ?*anyopaque, _: ?*c.wl_pointer, _: u32, _: u32) callconv(.c) void {}

const registry_listener = c.wl_registry_listener{
    .global = onRegistryGlobal,
    .global_remove = onRegistryGlobalRemove,
};

const wm_base_listener = c.xdg_wm_base_listener{
    .ping = onWmBasePing,
};

const xdg_surface_listener = c.xdg_surface_listener{
    .configure = onXdgSurfaceConfigure,
};

const toplevel_listener = c.xdg_toplevel_listener{
    .configure = onToplevelConfigure,
    .close = onToplevelClose,
    .configure_bounds = onToplevelConfigureBounds,
    .wm_capabilities = onToplevelWmCapabilities,
};

const seat_listener = c.wl_seat_listener{
    .capabilities = onSeatCapabilities,
    .name = onSeatName,
};

const keyboard_listener = c.wl_keyboard_listener{
    .keymap = onKeyboardKeymap,
    .enter = onKeyboardEnter,
    .leave = onKeyboardLeave,
    .key = onKeyboardKey,
    .modifiers = onKeyboardModifiers,
    .repeat_info = onKeyboardRepeatInfo,
};

const pointer_listener = c.wl_pointer_listener{
    .enter = onPointerEnter,
    .leave = onPointerLeave,
    .motion = onPointerMotion,
    .button = onPointerButton,
    .axis = onPointerAxis,
    .frame = onPointerFrame,
    .axis_source = onPointerAxisSource,
    .axis_stop = onPointerAxisStop,
    .axis_discrete = onPointerAxisDiscrete,
    .axis_value120 = onPointerAxisValue120,
    .axis_relative_direction = onPointerAxisRelativeDirection,
};
