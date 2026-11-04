// Renders every clock design (firmware/ESP32_Display/clock_faces.h) at a fixed time to PNG
// files with the real Adafruit GFX library, to look at them without the board.
#include "Adafruit_GFX.h"
#include "clock_faces.h"
#include <string>
int main(int argc, char **argv) {
  std::string out = argc > 1 ? argv[1] : ".";
  ClockTime t = {10, 9, 37, 0.4f, 4, 11, 3, true};   // Wed 4 Nov, 10:09:37
  if (argc > 2) sscanf(argv[2], "%d:%d:%d", &t.h, &t.m, &t.s);
  static unsigned char sheet[480 * 1200 * 3];   // all designs, 5 per row
  for (int style = 0; style < CLOCK_STYLES; style++) {
    GFXcanvas16 g(240, 240);
    g.fillScreen(0);
    drawClockStyle(g, style, t);
    uint16_t *px = g.getBuffer();
    std::string path = out + "/clock" + std::to_string(style) + ".ppm";
    FILE *f = fopen(path.c_str(), "wb");
    fprintf(f, "P6 240 240 255\n");
    for (int i = 0; i < 240 * 240; i++) {
      int dx = i % 240 - 120, dy = i / 240 - 120;
      uint16_t c = dx * dx + dy * dy <= 120 * 120 ? px[i] : 0x2104;   // outside the round screen: gray
      unsigned char rgb[3] = {(unsigned char)((c >> 11) << 3), (unsigned char)(((c >> 5) & 63) << 2), (unsigned char)((c & 31) << 3)};
      fwrite(rgb, 1, 3, f);
      memcpy(sheet + (((style / 5) * 240 + i / 240) * 1200 + (style % 5) * 240 + i % 240) * 3, rgb, 3);
    }
    fclose(f);
  }
  FILE *f = fopen((out + "/sheet.ppm").c_str(), "wb");
  fprintf(f, "P6 1200 480 255\n"); fwrite(sheet, 1, sizeof sheet, f); fclose(f);
  return 0;
}
