// The task watchdog (watchdog.cpp): a task that hangs for WATCHDOG_S (config.h)
// restarts the board - and the hello tells why it started last ("reset").
// Shared by the tile and the robot (this library knows neither's config.h:
// what it needs is handed to it).
#pragma once

namespace watchdog {
void begin(int seconds);    // the loop is watched from here on
void watchThisTask();       // ... and the task that calls this (it must feed())
void feed();                // "still alive": after a call that may block for seconds (the network, an update)
const char *resetReason();  // "poweron", "task_wdt", "panic", "brownout", "sw" (an update, a restart) ...
}
