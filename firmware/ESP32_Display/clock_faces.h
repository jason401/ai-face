// Clock designs for the 240x240 round screen, chosen in the app (Settings → General → Clock).
// Each draws the whole screen into any Adafruit_GFX target (the board sends it in one piece).
// tools/clock_preview renders these same functions to PNGs on the Mac.
#pragma once
#include <Fonts/FreeSansBold9pt7b.h>
#include <Fonts/FreeSans9pt7b.h>
#include <Fonts/FreeSansBold12pt7b.h>
#include <Fonts/FreeSansBold18pt7b.h>
#include <Fonts/FreeSansBold24pt7b.h>
#include <Fonts/FreeSerifBold9pt7b.h>
#include <Fonts/FreeMonoBold9pt7b.h>
#include "hangul_grid.h"

struct ClockTime { int h, m, s; float frac; int day, month, wday; bool date; };   // wday 0 = Sunday
const int CLOCK_STYLES = 10;
enum { CS_CLASSIC, CS_MINIMAL, CS_RAILWAY, CS_ROMAN, CS_NUMBERS, CS_CHRONO, CS_RINGS, CS_DIGITAL, CS_RADAR, CS_WORDS };

static inline uint16_t cc(int r, int g, int b) { return ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3); }
static inline uint16_t ccScale(int r, int g, int b, float k) { return cc(r * k, g * k, b * k); }
const int CC = 120;   // centre

// Angle in degrees clockwise from 12 o'clock -> point at radius r.
static inline float cpx(float deg, float r) { return CC + sinf(deg * PI / 180.0f) * r; }
static inline float cpy(float deg, float r) { return CC - cosf(deg * PI / 180.0f) * r; }

static void thickLine(Adafruit_GFX &g, float x0, float y0, float x1, float y1, float w, uint16_t c, bool round) {
  float dx = x1 - x0, dy = y1 - y0, l = sqrtf(dx * dx + dy * dy);
  if (l < 0.5f) return;
  float nx = -dy / l * w / 2, ny = dx / l * w / 2;
  g.fillTriangle(x0 + nx, y0 + ny, x1 + nx, y1 + ny, x1 - nx, y1 - ny, c);
  g.fillTriangle(x0 + nx, y0 + ny, x0 - nx, y0 - ny, x1 - nx, y1 - ny, c);
  if (round) { g.fillCircle(x0, y0, w / 2, c); g.fillCircle(x1, y1, w / 2, c); }
}
// A hand from `back` behind the centre to `len` in front of it.
static void hand(Adafruit_GFX &g, float deg, float back, float len, float w, uint16_t c, bool round = true) {
  thickLine(g, cpx(deg + 180, back), cpy(deg + 180, back), cpx(deg, len), cpy(deg, len), w, c, round);
}
// A pointed hand: widest at 30% of its length.
static void diamondHand(Adafruit_GFX &g, float deg, float len, float w, uint16_t c) {
  float bx = cpx(deg, len * 0.3f), by = cpy(deg, len * 0.3f);
  float sx = cpx(deg + 90, w), sy = cpy(deg + 90, w), ox = sx - CC, oy = sy - CC;
  g.fillTriangle(CC, CC, bx + ox, by + oy, cpx(deg, len), cpy(deg, len), c);
  g.fillTriangle(CC, CC, bx - ox, by - oy, cpx(deg, len), cpy(deg, len), c);
}
// A whole ring (two discs: much faster than arc()). Draw rings outermost first, before
// whatever goes inside them: the inner disc paints the background over the centre.
static void disc2(Adafruit_GFX &g, float r0, float r1, uint16_t c, uint16_t bg = 0) {
  g.fillCircle(CC, CC, r1, c); g.fillCircle(CC, CC, r0, bg);
}
// A ring segment from a0 to a1 degrees, between radii r0 and r1.
static void arc(Adafruit_GFX &g, float a0, float a1, float r0, float r1, uint16_t c) {
  for (float a = a0; a < a1; a += 2.5f) {
    float b = fminf(a + 2.5f, a1) + 0.3f;
    g.fillTriangle(cpx(a, r0), cpy(a, r0), cpx(a, r1), cpy(a, r1), cpx(b, r1), cpy(b, r1), c);
    g.fillTriangle(cpx(a, r0), cpy(a, r0), cpx(b, r0), cpy(b, r0), cpx(b, r1), cpy(b, r1), c);
  }
}
static void text(Adafruit_GFX &g, const char *s, float x, float y, const GFXfont *f, uint16_t c) {
  int16_t bx, by; uint16_t w, h;
  g.setFont(f); g.setTextSize(1); g.setTextColor(c);
  g.getTextBounds(s, 0, 0, &bx, &by, &w, &h);
  g.setCursor((int)roundf(x - w / 2.0f - bx), (int)roundf(y - h / 2.0f - by));
  g.print(s);
  g.setFont(nullptr);
}

static float hourDeg(const ClockTime &t) { return ((t.h % 12) + t.m / 60.0f + t.s / 3600.0f) * 30.0f; }
static float minDeg(const ClockTime &t) { return (t.m + t.s / 60.0f) * 6.0f; }
static float secDeg(const ClockTime &t) { return (t.s + t.frac) * 6.0f; }

static void clockClassic(Adafruit_GFX &g, const ClockTime &t) {
  const uint16_t W = 0xFFFF, R = cc(255, 0, 0);
  g.drawCircle(CC, CC, 110, W);
  for (int i = 0; i < 60; i++) g.drawLine(cpx(i * 6, i % 5 ? 102 : 94), cpy(i * 6, i % 5 ? 102 : 94), cpx(i * 6, 108), cpy(i * 6, 108), W);
  g.drawLine(CC, CC, cpx(hourDeg(t), 50), cpy(hourDeg(t), 50), W);
  g.drawLine(CC, CC, cpx(minDeg(t), 72), cpy(minDeg(t), 72), W);
  g.drawLine(CC, CC, cpx(secDeg(t), 90), cpy(secDeg(t), 90), R);
  g.fillCircle(CC, CC, 4, R);
}

static void clockMinimal(Adafruit_GFX &g, const ClockTime &t) {
  const uint16_t W = cc(235, 235, 230), O = cc(255, 140, 40);
  for (int i = 0; i < 12; i++) g.fillCircle(cpx(i * 30, 104), cpy(i * 30, 104), i ? 3 : 5, i ? cc(130, 130, 130) : O);
  hand(g, hourDeg(t), 0, 58, 8, W);
  hand(g, minDeg(t), 0, 92, 6, W);
  hand(g, secDeg(t), 18, 100, 2, O);
  g.fillCircle(CC, CC, 6, O); g.fillCircle(CC, CC, 2, 0);
}

static void clockRailway(Adafruit_GFX &g, const ClockTime &t) {
  const uint16_t K = 0, R = cc(220, 30, 30);
  g.fillCircle(CC, CC, 119, cc(245, 245, 242));
  for (int i = 0; i < 60; i++)
    if (i % 5) thickLine(g, cpx(i * 6, 106), cpy(i * 6, 106), cpx(i * 6, 115), cpy(i * 6, 115), 2, K, false);
    else thickLine(g, cpx(i * 6, 86), cpy(i * 6, 86), cpx(i * 6, 115), cpy(i * 6, 115), 7, K, false);
  hand(g, hourDeg(t), 16, 62, 10, K, false);
  hand(g, minDeg(t), 18, 100, 8, K, false);
  hand(g, secDeg(t), 26, 70, 3, R, false);
  g.fillCircle(cpx(secDeg(t), 70), cpy(secDeg(t), 70), 9, R);
  g.fillCircle(CC, CC, 4, R);
}

static void clockRoman(Adafruit_GFX &g, const ClockTime &t) {
  const uint16_t G = cc(214, 178, 96), R = cc(200, 50, 40);
  g.fillCircle(CC, CC, 119, cc(14, 16, 32));
  g.drawCircle(CC, CC, 116, G); g.drawCircle(CC, CC, 112, G);
  for (int i = 0; i < 60; i++) if (i % 5) g.fillCircle(cpx(i * 6, 106), cpy(i * 6, 106), 1, G);
  static const char *const N[12] = {"XII", "I", "II", "III", "IIII", "V", "VI", "VII", "VIII", "IX", "X", "XI"};
  for (int i = 0; i < 12; i++) text(g, N[i], cpx(i * 30, 89), cpy(i * 30, 89), &FreeSerifBold9pt7b, G);
  diamondHand(g, hourDeg(t), 56, 6, G);
  diamondHand(g, minDeg(t), 84, 5, G);
  hand(g, secDeg(t), 16, 96, 2, R);
  g.fillCircle(CC, CC, 5, G); g.fillCircle(CC, CC, 2, R);
}

static void clockNumbers(Adafruit_GFX &g, const ClockTime &t) {
  const uint16_t W = 0xFFFF, Y = cc(255, 204, 0);
  for (int i = 0; i < 60; i++) {
    if (i % 5) g.drawLine(cpx(i * 6, 109), cpy(i * 6, 109), cpx(i * 6, 115), cpy(i * 6, 115), cc(90, 90, 90));
    else thickLine(g, cpx(i * 6, 106), cpy(i * 6, 106), cpx(i * 6, 115), cpy(i * 6, 115), 3, W, false);
  }
  char b[3];
  for (int i = 1; i <= 12; i++) { snprintf(b, sizeof b, "%d", i); text(g, b, cpx(i * 30, 88), cpy(i * 30, 88), &FreeSansBold12pt7b, W); }
  hand(g, hourDeg(t), 0, 52, 9, W);
  hand(g, minDeg(t), 0, 80, 6, W);
  hand(g, secDeg(t), 20, 102, 2, Y);
  g.fillCircle(CC, CC, 5, Y);
}

static void subDial(Adafruit_GFX &g, int x, int y, float deg, const char *label, uint16_t hc) {
  const uint16_t S = cc(170, 175, 185);
  g.fillCircle(x, y, 25, cc(30, 33, 40)); g.drawCircle(x, y, 25, S);
  for (int i = 0; i < 12; i++) {
    float a = i * 30 * PI / 180;
    g.drawLine(x + sinf(a) * 20, y - cosf(a) * 20, x + sinf(a) * 24, y - cosf(a) * 24, S);
  }
  if (label) text(g, label, x, y - 11, &FreeSans9pt7b, cc(120, 125, 135));
  float a = deg * PI / 180;
  thickLine(g, x, y, x + sinf(a) * 21, y - cosf(a) * 21, 2, hc, true);
  g.fillCircle(x, y, 3, hc);
}
static void clockChrono(Adafruit_GFX &g, const ClockTime &t) {
  const uint16_t S = cc(200, 205, 215), O = cc(255, 120, 30);
  g.fillCircle(CC, CC, 119, cc(18, 20, 26));
  for (int i = 0; i < 60; i++) {
    if (i % 5) g.drawLine(cpx(i * 6, 110), cpy(i * 6, 110), cpx(i * 6, 116), cpy(i * 6, 116), cc(110, 112, 120));
    else thickLine(g, cpx(i * 6, 100), cpy(i * 6, 100), cpx(i * 6, 116), cpy(i * 6, 116), 3, S, false);
  }
  text(g, "12", CC, 34, &FreeSansBold12pt7b, S);
  subDial(g, 72, CC, (t.s + t.frac) * 6, nullptr, O);                          // small seconds
  subDial(g, 168, CC, ((t.h % 24) + t.m / 60.0f) * 15, "24", S);                // 24-hour
  if (t.date) {
    g.fillRect(105, 158, 30, 22, cc(235, 235, 230)); g.drawRect(104, 157, 32, 24, S);
    char b[3]; snprintf(b, sizeof b, "%d", t.day); text(g, b, CC, 169, &FreeSansBold9pt7b, 0);
  }
  hand(g, hourDeg(t), 12, 56, 8, S);
  hand(g, minDeg(t), 14, 88, 6, S);
  hand(g, secDeg(t), 22, 108, 2, O);
  g.fillCircle(CC, CC, 5, O);
}

static void clockRings(Adafruit_GFX &g, const ClockTime &t) {
  struct { float r0, r1, p; int rr, gg, bb; } ring[3] = {
    {101, 115, (t.s + t.frac) / 60.0f, 250, 30, 80},
    {84, 98, (t.m + t.s / 60.0f) / 60.0f, 150, 250, 10},
    {67, 81, ((t.h % 12) + t.m / 60.0f) / 12.0f, 0, 210, 255}};
  for (auto &r : ring) {
    disc2(g, r.r0, r.r1, ccScale(r.rr, r.gg, r.bb, 0.22f));
    if (r.p > 0.002f) arc(g, 0, r.p * 360, r.r0, r.r1, cc(r.rr, r.gg, r.bb));
  }
  char b[6]; snprintf(b, sizeof b, "%d:%02d", t.h % 12 ? t.h % 12 : 12, t.m);
  text(g, b, CC, CC, &FreeSansBold18pt7b, 0xFFFF);
}

static void clockDigital(Adafruit_GFX &g, const ClockTime &t) {
  for (int i = 0; i < 60; i++)
    g.fillCircle(cpx(i * 6, 110), cpy(i * 6, 110), i % 5 ? 2 : 3, i <= t.s ? cc(0, 200, 255) : cc(32, 34, 44));
  char b[6]; snprintf(b, sizeof b, "%02d:%02d", t.h, t.m);
  text(g, b, CC, t.date ? 110 : CC, &FreeSansBold24pt7b, 0xFFFF);
  if (t.date) {
    static const char *const D[7] = {"SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"};
    static const char *const M[12] = {"JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"};
    char d[16]; snprintf(d, sizeof d, "%s %d %s", D[t.wday % 7], t.day, M[(t.month + 11) % 12]);
    text(g, d, CC, 152, &FreeSans9pt7b, cc(150, 155, 170));
  }
}

static void clockRadar(Adafruit_GFX &g, const ClockTime &t) {
  const uint16_t D = cc(0, 80, 36);
  g.fillCircle(CC, CC, 119, cc(0, 16, 8));
  for (int r : {40, 80, 116}) g.drawCircle(CC, CC, r, D);
  g.drawLine(CC, 4, CC, 236, D); g.drawLine(4, CC, 236, CC, D);
  float sw = secDeg(t);
  for (int i = 28; i >= 0; i--) {   // the sweep and its fading trail
    float k = 1.0f - i / 29.0f;
    thickLine(g, CC, CC, cpx(sw - i * 1.6f, 116), cpy(sw - i * 1.6f, 116), 3, ccScale(40, 255, 120, k * k * 0.9f + 0.05f), false);
  }
  struct { float deg, r; int size; } blip[2] = {{hourDeg(t), 52, 7}, {minDeg(t), 96, 5}};
  for (auto &b : blip) {   // brightest right after the sweep passes, then fading
    float since = fmodf(sw - b.deg + 720.0f, 360.0f), k = fmaxf(0.3f, 1.0f - since / 330.0f);
    g.fillCircle(cpx(b.deg, b.r), cpy(b.deg, b.r), b.size, ccScale(120, 255, 160, k));
  }
  char s[6]; snprintf(s, sizeof s, "%02d:%02d", t.h, t.m);
  text(g, s, CC, 196, &FreeMonoBold9pt7b, cc(60, 220, 120));
}

// Hangul word clock: letters of hangul_grid.h light up to spell e.g. "오전 열 시 이십오 분".
static void clockWords(Adafruit_GFX &g, const ClockTime &t) {
  bool on[WORD_ROWS * WORD_COLS] = {};
  auto lit = [&](std::initializer_list<int> cells) { for (int c : cells) on[c] = true; };
  int h12 = t.h % 12 ? t.h % 12 : 12;
  static const uint8_t HOUR[13][2] = {{0, 0}, {1, 1}, {2, 2}, {3, 3}, {4, 4}, {5, 6}, {7, 8}, {9, 10}, {11, 12}, {13, 14}, {0, 0}, {0, 1}, {0, 2}};
  lit({HOUR[h12][0], HOUR[h12][1], 15});                   // ... 시
  if (t.h < 12) lit({24, 25}); else lit({26, 27});        // 오전 / 오후
  int m5 = t.m / 5 * 5;
  if (!m5) lit({23, 28, 29});                              // 정각 ♥
  else {
    static const int TENS[6] = {-1, -1, 16, 17, 18, 19};   // 이 삼 사 오 (십)
    if (m5 >= 10) { lit({20}); if (TENS[m5 / 10] >= 0) lit({TENS[m5 / 10]}); }
    if (m5 % 10) lit({21});                                // 오 (분)
    lit({22});                                             // 분
  }
  disc2(g, 114, 117, cc(40, 34, 26));
  arc(g, 0, (t.s + t.frac) * 6, 114, 117, cc(200, 150, 80));
  const int x0 = CC - WORD_COLS * 30 / 2, y0 = CC - WORD_ROWS * 30 / 2;
  for (int i = 0; i < WORD_ROWS * WORD_COLS; i++)
    g.drawBitmap(x0 + (i % WORD_COLS) * 30 + 3, y0 + (i / WORD_COLS) * 30 + 3, WORD_GLYPHS[i], WORD_PX, WORD_PX,
                 on[i] ? cc(255, 214, 150) : cc(44, 44, 52));
}

void drawClockStyle(Adafruit_GFX &g, int style, const ClockTime &t) {
  switch (style) {
    case CS_MINIMAL: clockMinimal(g, t); break;
    case CS_RAILWAY: clockRailway(g, t); break;
    case CS_ROMAN: clockRoman(g, t); break;
    case CS_NUMBERS: clockNumbers(g, t); break;
    case CS_CHRONO: clockChrono(g, t); break;
    case CS_RINGS: clockRings(g, t); break;
    case CS_DIGITAL: clockDigital(g, t); break;
    case CS_RADAR: clockRadar(g, t); break;
    case CS_WORDS: clockWords(g, t); break;
    default: clockClassic(g, t);
  }
}
