module tui.screen;

import std.conv : to;
import std.utf : decode, UTFException;

import tui.term;

enum Color : ubyte {
  none,
  black, red, green, yellow, blue, magenta, cyan, white,
  gray, brightRed, brightGreen, brightYellow, brightBlue, brightMagenta, brightCyan, brightWhite,
}

enum Attr : ubyte {
  none = 0,
  bold = 1,
  dim = 2,
  italic = 4,
  underline = 8,
  reverse = 16,
}

struct Style {
  Color fg;
  Color bg;
  ubyte attr;
}

struct Cell {
  dchar ch = ' ';
  Style style;
}

final class Screen {
  int width, height;
  int cursorX = -1, cursorY = -1;

  private Cell[] cells;
  private Cell[] shown;
  private bool fullRedraw = true;

  void resize(int w, int h) {
    if (w == width && h == height) {
      return;
    }

    width = w;
    height = h;
    cells = new Cell[w * h];
    shown = new Cell[w * h];
    fullRedraw = true;
  }

  void invalidate() { fullRedraw = true; }

  void clear(Style st = Style.init) {
    cells[] = Cell(' ', st);
    cursorX = cursorY = -1;
  }

  void fill(int x, int y, int w, dchar ch, Style st) {
    if (y < 0 || y >= height) {
      return;
    }

    foreach (cx; (x < 0 ? 0 : x) .. (x + w > width ? width : x + w)) {
      cells[y * width + cx] = Cell(ch, st);
    }
  }

  int put(int x, int y, const(char)[] text, Style st, int maxX = int.max) {
    if (y < 0 || y >= height) {
      return x;
    }

    if (maxX > width) {
      maxX = width;
    }

    size_t i = 0;

    while (i < text.length && x < maxX) {
      dchar c;

      try {
        c = decode(text, i);
      } catch (UTFException) {
        c = '�';
        i++;
      }

      if (c == '\t' || c == '\n' || c == '\r') {
        c = ' ';
      } else if (c < 0x20 || c == 0x7F) {
        c = '·';
      }

      int w = charWidth(c);

      if (w == 0) {
        continue;
      }

      if (x + w > maxX) {
        break;
      }

      if (x >= 0) {
        cells[y * width + x] = Cell(c, st);
        if (w == 2) {
          cells[y * width + x + 1] = Cell(0, st);
        }
      }

      x += w;
    }

    return x;
  }

  void addAttr(int x, int y, int w, ubyte attr) {
    if (y < 0 || y >= height) {
      return;
    }

    foreach (cx; (x < 0 ? 0 : x) .. (x + w > width ? width : x + w)) {
      cells[y * width + cx].style.attr |= attr;
    }
  }

  void render(Terminal term) {
    char[] o;

    o ~= "\x1b[?25l";
    Style current;
    bool styleKnown = false;

    foreach (y; 0 .. height) {
      int x = 0;

      while (x < width) {
        auto at = y * width + x;

        if (!fullRedraw && cells[at] == shown[at]) {
          x++;
          continue;
        }

        o ~= "\x1b[" ~ (y + 1).to!string ~ ";" ~ (x + 1).to!string ~ "H";
        while (x < width) {
          at = y * width + x;
          if (!fullRedraw && cells[at] == shown[at]) {
            break;
          }

          auto c = cells[at];

          if (!styleKnown || c.style != current) {
            o ~= sgr(c.style);
            current = c.style;
            styleKnown = true;
          }

          if (c.ch != 0) {
            char[4] buf;

            import std.utf : encode;
            o ~= buf[0 .. encode(buf, c.ch)];
          }

          shown[at] = c;
          x++;
        }
      }
    }

    o ~= "\x1b[0m";
    if (cursorX >= 0 && cursorY >= 0) {
      o ~= "\x1b[" ~ (cursorY + 1).to!string ~ ";" ~ (cursorX + 1).to!string ~ "H\x1b[?25h";
    }

    fullRedraw = false;
    term.write(o);
    term.flush();
  }

  private static string sgr(Style st) {
    string s = "\x1b[0";

    if (st.attr & Attr.bold) {
      s ~= ";1";
    }

    if (st.attr & Attr.dim) {
      s ~= ";2";
    }

    if (st.attr & Attr.italic) {
      s ~= ";3";
    }

    if (st.attr & Attr.underline) {
      s ~= ";4";
    }

    if (st.attr & Attr.reverse) {
      s ~= ";7";
    }

    if (st.fg != Color.none) {
      s ~= ";" ~ colorCode(st.fg, 30).to!string;
    }

    if (st.bg != Color.none) {
      s ~= ";" ~ colorCode(st.bg, 40).to!string;
    }

    return s ~ "m";
  }

  private static int colorCode(Color c, int base) {
    int idx = c - 1;

    return idx < 8 ? base + idx : base + 60 + idx - 8;
  }
}

int textWidth(const(char)[] text) {
  int w = 0;
  size_t i = 0;

  while (i < text.length) {
    dchar c;

    try {
      c = decode(text, i);
    } catch (UTFException) {
      i++;
      c = '?';
    }

    w += c < 0x20 ? 1 : charWidth(c);
  }

  return w;
}
