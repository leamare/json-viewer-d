module tests.gui_canvas;

import gui.font;
import gui.raster;
import gui.canvas;

unittest {
  auto c = new Canvas;

  c.resize(20, 10);
  c.fill(Rect(0, 0, 20, 10), 0xFFFFFF);
  c.fill(Rect(5, 5, 100, 100), 0x000000);
  assert(c.pixels[9 * 20 + 19] == 0 && c.pixels[0] == 0xFFFFFF);
  c.pushClip(Rect(0, 0, 2, 2));
  c.fill(Rect(0, 0, 20, 10), 0xFF0000);
  c.popClip();
  assert(c.pixels[1 * 20 + 1] == 0xFF0000 && c.pixels[1 * 20 + 2] == 0xFFFFFF);
  assert(mix(0x000000, 0xFFFFFF, 0.5) == 0x7F7F7F);
}
