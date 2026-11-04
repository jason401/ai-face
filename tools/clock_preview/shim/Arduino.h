// Just enough Arduino for Adafruit GFX's canvas and fonts on the Mac (clock previews only).
#pragma once
#include <cstdint>
#include <cstring>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <algorithm>
#include <initializer_list>
#ifndef ARDUINO
#define ARDUINO 100
#endif
#define PROGMEM
#define PI 3.14159265358979f
typedef bool boolean;
typedef uint8_t byte;
#define pgm_read_byte(a) (*(const uint8_t *)(a))
#define pgm_read_word(a) (*(const uint16_t *)(a))
#define pgm_read_dword(a) (*(const uint32_t *)(a))
#define pgm_read_pointer(a) (*(void *const *)(a))
#include <string>
class __FlashStringHelper;
struct String : std::string { using std::string::string; String(const std::string &s) : std::string(s) {} };
static inline float radians(float d) { return d * PI / 180.0f; }
#include "Print.h"
