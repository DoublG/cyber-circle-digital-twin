// The start-up sequence on the ring: a quarter turns green for every step the
// tile has taken, the quarter it is waiting for breathes dim white.
//   1/4  the network: a link and an address (DHCP)
//   2/4  connected to the MQTT broker
//   3/4  the control server knows it: device/<mac>/config arrived (its place, or none yet)
// Then it waits for its place (the last quarter breathes). Assigned: the green
// goes away - the ring is the game's again - and the hearts show the place
// number in binary until the technical setup is done (display.cpp: as long as
// the installation is in SETUP).
// A tile without a place stays at 3/4 (its icons still flash when pressed:
// the sensor test; identify still lights it up). The sequence comes back when
// a step is lost for longer than BOOT_LOST_MS (the broker gone, the cable
// out): a tile that cannot reach the game does not look as if it plays.
#pragma once
#include <stdint.h>

namespace boot {

enum Stage { NO_NETWORK = 0, NETWORK = 1, BROKER = 2, CONTROLLER = 3, PLACED = 4 };

// When the sequence shows and how far it has come (no hardware in here: the
// test runs it on the PC - test/test_boot).
struct Sequence {
    bool showing = true;                // from power-up
    int shown = NO_NETWORK;             // the quarters lit: one more per stepMs (steps that come together are still seen)
    uint32_t steppedAt = 0;
    bool losing = false;
    uint32_t lostAt = 0;

    // Every frame, with how far the tile is now; true while the sequence shows.
    bool update(int stage, uint32_t now, uint32_t stepMs, uint32_t lostMs) {
        if (!showing) {
            if (stage >= PLACED) {
                losing = false;
                return false;
            }
            if (!losing) {
                losing = true;
                lostAt = now;
            }
            if (now - lostAt < lostMs) return false;    // (a short hiccup: nothing to see)
            showing = true;
            losing = false;
            shown = stage;
            steppedAt = now;
        }
        if (stage < shown) {                            // a step lost: at once
            shown = stage;
            steppedAt = now;
        } else if (stage > shown && now - steppedAt >= stepMs) {
            shown++;
            steppedAt = now;
        }
        if (shown < PLACED) return true;
        showing = false;                                // its place: the green goes away
        return false;
    }
};

// Every frame, after the display: draws the sequence on the ring while it
// shows (true), else leaves the ring alone.
bool draw(int stage, uint32_t now);

}  // namespace boot
