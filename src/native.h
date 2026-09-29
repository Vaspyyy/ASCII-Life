#ifndef ASCII_LIFE_NATIVE_H
#define ASCII_LIFE_NATIVE_H

#define VK_USE_PLATFORM_WAYLAND_KHR

#include <errno.h>
#include <poll.h>
#include <stdint.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#include <wayland-client.h>
#include <xdg-shell-client-protocol.h>
#include <xkbcommon/xkbcommon.h>
#include <xkbcommon/xkbcommon-keysyms.h>
#include <vulkan/vulkan.h>

/* Keep errno access behind tiny C helpers so Zig does not depend on libc's
 * platform-specific errno macro expansion. */
static inline int ascii_life_errno(void) {
    return errno;
}

/* wl_keyboard.keymap transfers a read-only, NUL-terminated XKB map by fd.
 * Mapping it avoids an extra allocation/copy; the callback unmaps it after
 * libxkbcommon has compiled the map. The fd is consumed on every path. */
static inline const char *ascii_life_map_keymap(int fd, uint32_t size) {
    if (size == 0) {
        close(fd);
        return NULL;
    }
    void *mapping = mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if ((intptr_t)mapping == -1) return NULL;
    return (const char *)mapping;
}

static inline void ascii_life_unmap_keymap(const char *mapping, uint32_t size) {
    if (mapping != NULL && size != 0) munmap((void *)mapping, size);
}

#endif
