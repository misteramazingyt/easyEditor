#ifndef NTSC_BRIDGE_H
#define NTSC_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>

/// Handle to a configured ntsc-rs effect. Opaque on this side.
typedef struct Bridge NtscBridge;

/// Build an effect from ntsc-rs preset JSON (pass NULL for the defaults).
NtscBridge *ntsc_bridge_create(const char *json);

/// Apply the effect in place to a packed RGBA8 buffer.
bool ntsc_bridge_process(NtscBridge *handle, unsigned char *pixels,
                         size_t width, size_t height, size_t frame, float scale);

void ntsc_bridge_destroy(NtscBridge *handle);

#endif /* NTSC_BRIDGE_H */
