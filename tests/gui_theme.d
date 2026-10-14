module tests.gui_theme;

import gui.font;
import gui.theme;

unittest {
  auto ini = parseIni("[General]\nfont=Noto Sans,9,-1,5,400\n[Colors:View]\nBackgroundNormal=30,35,42\n");

  assert(ini["General"]["font"] == "Noto Sans,9,-1,5,400");
  assert(ini["Colors:View"]["BackgroundNormal"] == "30,35,42");
  assert(parseQtFont("Hack,9,-1,5,400,0", FontChoice("x", 10)) == FontChoice("Hack", 9));
}
