// Stand-in for firmware/ESP32_Display/clock_faces.h in the simulator: the designs themselves are
// checked as pictures by tools/clock_preview; here only which design and time were asked for.
#pragma once
struct ClockTime { int h, m, s; float frac; int day, month, wday; bool date; };
const int CLOCK_STYLES = 10;
inline int lastClockStyle = -1;
inline ClockTime lastClockTime = {};
inline void drawClockStyle(Adafruit_GFX &g, int style, const ClockTime &t) { lastClockStyle = style; lastClockTime = t; g.fillRect(100, 100, 40, 40, 0xFFFF); }
