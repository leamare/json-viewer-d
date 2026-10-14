module tests.tui_term;

import tui.term;

unittest {
  KeyEvent ev;

  assert(Terminal.parse(cast(ubyte[])"\x1b[A", ev) == 3 && ev.key == Key.up);
  ev = KeyEvent.init;
  assert(Terminal.parse(cast(ubyte[])"\x1b[1;5C", ev) == 6 && ev.key == Key.right && ev.ctrl);
  ev = KeyEvent.init;
  assert(Terminal.parse(cast(ubyte[])"\x1b[5~", ev) == 4 && ev.key == Key.pageUp);
  ev = KeyEvent.init;
  assert(Terminal.parse(cast(ubyte[])"\x1b[<0;10;5M", ev) == 10);
  assert(ev.key == Key.mouse && ev.x == 9 && ev.y == 4);
  ev = KeyEvent.init;
  assert(Terminal.parse(cast(ubyte[])"\x1b[<65;1;1M", ev) && ev.action == MouseAction.wheelDown);
  ev = KeyEvent.init;
  assert(Terminal.parse(cast(ubyte[])"ж", ev) == 2 && ev.ch == 'ж');
  ev = KeyEvent.init;
  assert(Terminal.parse(cast(ubyte[])"\x13", ev) == 1 && ev.ctrl && ev.ch == 's');
  ev = KeyEvent.init;
  assert(Terminal.parse(cast(ubyte[])"\x1bx", ev) == 2 && ev.alt && ev.ch == 'x');
  ev = KeyEvent.init;
  assert(Terminal.parse(cast(ubyte[])"\x1b[200~a\nb\x1b[201~", ev) == 15);
  assert(ev.key == Key.paste && ev.text == "a\nb");
  ev = KeyEvent.init;
  assert(Terminal.parse(cast(ubyte[])"\x1b[200~abc", ev) == 0);
  assert(Terminal.parse(cast(ubyte[])"\x1b[1;", ev) == 0);
}
