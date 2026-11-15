// The start-up sequence on the ring: boot.h.
#include "boot.h"

#include "tile.h"

namespace boot {

static Sequence seq;

bool draw(int stage, uint32_t now) {
    if (!seq.update(stage, now, BOOT_STEP_MS, BOOT_LOST_MS)) return false;
    uint32_t phase = now % 1600;                        // the quarter waited for: breathing
    uint8_t v = 8 + (phase < 800 ? phase : 1600 - phase) * 48 / 800;
    for (int i = 0; i < RING_COUNT; i++) {
        int quarter = i * 4 / RING_COUNT;
        bool gap = (i + 1) * 4 / RING_COUNT != quarter; // (the last LED of a quarter stays dark: they can be counted)
        ring(i) = gap ? CRGB::Black : quarter < seq.shown ? GREEN : quarter == seq.shown ? CRGB(v, v, v) : CRGB::Black;
    }
    return true;
}

}  // namespace boot
