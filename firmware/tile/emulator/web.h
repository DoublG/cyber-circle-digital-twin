// The tile emulator's web view (--web PORT): the tile's top (tile_top.svg)
// live in the browser, click / hold an icon = stand on it.
#pragma once
#include <deque>
#include <string>
struct CRGB;

bool webStart(int port);
// answer what's waiting; held[i] = an icon held down in the browser
void webPoll(const CRGB *leds, int count, const std::string &mac, const std::deque<std::string> &log, bool held[4]);
