module tests.gui_font;

import gui.raster;
import gui.font;

unittest {
  import std.algorithm : canFind;

  // only runs where Noto Sans is installed, it's the default KDE font
  auto face = FontFace.load("/usr/share/fonts/noto/NotoSans-Regular.ttf");

  if (face is null) {
    return;
  }

  auto font = new Font(face, 16);

  assert(font.glyphId('A') != 0);
  assert(font.glyphId('Ж') != 0);
  auto g = font.glyph('A', 0);

  assert(g.width > 5 && g.height > 8);
  assert(g.alpha.canFind(255));
  assert(font.measure("Hello") > 30 && font.measure("Hello") < 50);
  assert(font.hitTest("Hello", 0) == 0 && font.hitTest("Hello", 1000) == 5);
}
