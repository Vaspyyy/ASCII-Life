#ifndef ASCII_LIFE_NATIVE_H
#define ASCII_LIFE_NATIVE_H

#define VK_USE_PLATFORM_WAYLAND_KHR

#include <errno.h>
#include <poll.h>
#include <time.h>
#include <unistd.h>

#include <wayland-client.h>
#include <xdg-shell-client-protocol.h>
#include <vulkan/vulkan.h>

/* Keep errno access behind tiny C helpers so Zig does not depend on libc's
 * platform-specific errno macro expansion. */
static inline int ascii_life_errno(void) {
    return errno;
}

#endif
