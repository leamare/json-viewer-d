module tests.tui_screen;

import tui.term;
import tui.screen;

unittest {
  auto s = new Screen;

  s.resize(10, 2);
  s.clear();
  assert(s.put(0, 0, "ab日c", Style.init) == 5);
  assert(s.put(8, 1, "日本", Style.init, 10) == 10);
  assert(s.put(9, 1, "日", Style.init) == 9);
  assert(textWidth("aж日") == 4);
}
