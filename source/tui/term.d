module tui.term;

import std.utf : decode, UTFException;

enum Key {
  none,
  character,
  up,
  down,
  left,
  right,
  home,
  end,
  pageUp,
  pageDown,
  insert,
  del,
  backspace,
  enter,
  tab,
  backTab,
  escape,
  f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12,
  mouse,
  resize,
  paste,
}

enum MouseAction { press, release, move, wheelUp, wheelDown }

struct KeyEvent {
  Key key;
  dchar ch;
  bool ctrl;
  bool alt;
  bool shift;

  MouseAction action;
  int button;
  int x, y;

  string text;
}

final class Terminal {
  int width = 80;
  int height = 24;

  private ubyte[] pending;
  private char[] outBuf;
  private bool active;

  void open() {
    platformOpen();
    active = true;
    write("\x1b[?1049h\x1b[?25l\x1b[?1002h\x1b[?1006h\x1b[?2004h");
    flush();
    updateSize();
  }

  void close() {
    if (!active) {
      return;
    }

    write("\x1b[?2004l\x1b[?1006l\x1b[?1002l\x1b[0m\x1b[?25h\x1b[?1049l");
    flush();
    platformClose();
    active = false;
  }

  void suspend() {
    write("\x1b[?2004l\x1b[?1006l\x1b[?1002l\x1b[0m\x1b[?25h\x1b[?1049l");
    flush();
    platformClose();
  }

  void resume() {
    platformOpen();
    write("\x1b[?1049h\x1b[?25l\x1b[?1002h\x1b[?1006h\x1b[?2004h");
    flush();
    updateSize();
  }

  void write(const(char)[] s) { outBuf ~= s; }

  void flush() {
    if (!outBuf.length) {
      return;
    }

    platformWrite(outBuf);
    outBuf.length = 0;
    outBuf.assumeSafeAppend();
  }

  bool updateSize() {
    int w, h;

    if (!platformSize(w, h) || w <= 0 || h <= 0) {
      return false;
    }

    bool changed = w != width || h != height;

    width = w;
    height = h;

    return changed;
  }

  bool read(out KeyEvent ev, int timeoutMs) {
    if (!pending.length) {
      if (resized) {
        resized = false;
        if (updateSize()) {
          ev.key = Key.resize;

          return true;
        }
      }

      if (!platformRead(pending, timeoutMs)) {
        if (updateSize()) {
          ev.key = Key.resize;

          return true;
        }

        return false;
      }
    }

    if (!pending.length) {
      return false;
    }

    // lone ESC may be a start of a sequence that is still on its way
    if (pending.length == 1 && pending[0] == 0x1b) {
      platformRead(pending, 30);
    }

    size_t used = parse(pending, ev);

    for (int attempt = 0; !used && attempt < 20; attempt++) {
      if (!platformRead(pending, 50)) {
        continue;
      }

      ev = KeyEvent.init;
      used = parse(pending, ev);
    }

    if (!used) {
      ev = KeyEvent.init;
      used = 1;
    }

    pending = pending[used .. $].dup;

    return ev.key != Key.none;
  }

  private static size_t parse(const(ubyte)[] b, ref KeyEvent ev) {
    ubyte c = b[0];

    if (c == 0x1b) {
      if (b.length == 1) {
        ev.key = Key.escape;

        return 1;
      }

      if (b[1] == '[') {
        return parseCsi(b, ev);
      }

      if (b[1] == 'O' && b.length >= 3) {
        return parseSs3(b[2], ev);
      }

      auto used = parse(b[1 .. $], ev);

      ev.alt = true;

      return used + 1;
    }

    if (c == '\r' || c == '\n') {
      ev.key = Key.enter;

      return 1;
    }

    if (c == '\t') {
      ev.key = Key.tab;

      return 1;
    }

    if (c == 0x7f || c == 0x08) {
      ev.key = Key.backspace;

      return 1;
    }

    if (c < 0x20) {
      ev.key = Key.character;
      ev.ctrl = true;
      ev.ch = c == 0 ? ' ' : cast(dchar)('a' + c - 1);

      return 1;
    }

    size_t len = c < 0x80 ? 1 : c < 0xE0 ? 2 : c < 0xF0 ? 3 : 4;

    if (b.length < len) {
      return 0;
    }

    size_t idx = 0;

    try {
      ev.ch = decode(cast(const(char)[])b[0 .. len], idx);
    } catch (UTFException) {
      ev.ch = '�';
    }

    ev.key = Key.character;

    return len;
  }

  private static size_t parseSs3(ubyte f, ref KeyEvent ev) {
    switch (f) {
      case 'A': ev.key = Key.up; break;
      case 'B': ev.key = Key.down; break;
      case 'C': ev.key = Key.right; break;
      case 'D': ev.key = Key.left; break;
      case 'H': ev.key = Key.home; break;
      case 'F': ev.key = Key.end; break;
      case 'P': ev.key = Key.f1; break;
      case 'Q': ev.key = Key.f2; break;
      case 'R': ev.key = Key.f3; break;
      case 'S': ev.key = Key.f4; break;
      default: break;
    }

    return 3;
  }

  private static size_t parseCsi(const(ubyte)[] b, ref KeyEvent ev) {
    size_t i = 2;
    bool sgrMouse = i < b.length && b[i] == '<';

    if (sgrMouse) {
      i++;
    }

    int[4] params;
    int count = 0;
    bool any = false;

    while (i < b.length && ((b[i] >= '0' && b[i] <= '9') || b[i] == ';')) {
      if (b[i] == ';') {
        if (count < 3) {
          count++;
        }
      } else {
        params[count] = params[count] * 10 + (b[i] - '0');
        any = true;
      }

      i++;
    }

    if (i >= b.length) {
      return 0;
    }

    ubyte f = b[i];
    size_t used = i + 1;

    if (any) {
      count++;
    }

    if (sgrMouse) {
      int code = params[0];

      ev.key = Key.mouse;
      ev.x = params[1] - 1;
      ev.y = params[2] - 1;
      ev.shift = (code & 4) != 0;
      ev.alt = (code & 8) != 0;
      ev.ctrl = (code & 16) != 0;
      if (code & 64) {
        ev.action = (code & 1) ? MouseAction.wheelDown : MouseAction.wheelUp;
      } else if (code & 32) {
        ev.action = MouseAction.move;
        ev.button = code & 3;
      } else {
        ev.action = f == 'M' ? MouseAction.press : MouseAction.release;
        ev.button = code & 3;
      }

      return used;
    }

    // modifiers come as the second parameter: 1 + shift(1) + alt(2) + ctrl(4)
    int mods = count >= 2 ? params[1] - 1 : 0;

    ev.shift = (mods & 1) != 0;
    ev.alt = (mods & 2) != 0;
    ev.ctrl = (mods & 4) != 0;

    switch (f) {
      case 'A': ev.key = Key.up; break;
      case 'B': ev.key = Key.down; break;
      case 'C': ev.key = Key.right; break;
      case 'D': ev.key = Key.left; break;
      case 'H': ev.key = Key.home; break;
      case 'F': ev.key = Key.end; break;
      case 'Z': ev.key = Key.backTab; break;
      case 'P': ev.key = Key.f1; break;
      case 'Q': ev.key = Key.f2; break;
      case 'R': ev.key = Key.f3; break;
      case 'S': ev.key = Key.f4; break;
      case '~':
        switch (params[0]) {
          case 1: case 7: ev.key = Key.home; break;
          case 2: ev.key = Key.insert; break;
          case 3: ev.key = Key.del; break;
          case 4: case 8: ev.key = Key.end; break;
          case 5: ev.key = Key.pageUp; break;
          case 6: ev.key = Key.pageDown; break;
          case 11: ev.key = Key.f1; break;
          case 12: ev.key = Key.f2; break;
          case 13: ev.key = Key.f3; break;
          case 14: ev.key = Key.f4; break;
          case 15: ev.key = Key.f5; break;
          case 17: ev.key = Key.f6; break;
          case 18: ev.key = Key.f7; break;
          case 19: ev.key = Key.f8; break;
          case 20: ev.key = Key.f9; break;
          case 21: ev.key = Key.f10; break;
          case 23: ev.key = Key.f11; break;
          case 24: ev.key = Key.f12; break;
          case 200:
            return parsePaste(b, used, ev);
          default: break;
        }

        break;
      default:
        break;
    }

    return used;
  }

  private static size_t parsePaste(const(ubyte)[] b, size_t start, ref KeyEvent ev) {
    import std.string : indexOf;

    enum endMark = "\x1b[201~";
    auto rest = cast(const(char)[])b[start .. $];
    auto at = rest.indexOf(endMark);

    if (at < 0) {
      return 0;
    }

    ev.key = Key.paste;
    ev.text = rest[0 .. at].idup;

    return start + at + endMark.length;
  }

  private shared static bool resized;

  version (Posix) {
    import core.sys.posix.termios;
    import core.sys.posix.unistd : posixRead = read, posixWrite = write, STDIN_FILENO, STDOUT_FILENO;
    import core.sys.posix.poll;
    import core.sys.posix.signal;
    import core.sys.posix.sys.ioctl;

    private termios saved;
    private enum SIGWINCH = 28;

    private void platformOpen() {
      tcgetattr(STDIN_FILENO, &saved);
      termios raw = saved;

      raw.c_iflag &= ~(BRKINT | ICRNL | INPCK | ISTRIP | IXON);
      raw.c_oflag &= ~OPOST;
      raw.c_cflag |= CS8;
      raw.c_lflag &= ~(ECHO | ICANON | IEXTEN | ISIG);
      raw.c_cc[VMIN] = 0;
      raw.c_cc[VTIME] = 0;
      tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw);

      sigaction_t sa;

      sa.sa_handler = &onResize;
      sigaction(SIGWINCH, &sa, null);
    }

    private void platformClose() {
      tcsetattr(STDIN_FILENO, TCSAFLUSH, &saved);
    }

    extern (C) private static void onResize(int) nothrow @nogc {
      resized = true;
    }

    private void platformWrite(const(char)[] s) {
      while (s.length) {
        auto n = posixWrite(STDOUT_FILENO, s.ptr, s.length);

        if (n <= 0) {
          break;
        }

        s = s[n .. $];
      }
    }

    private bool platformSize(out int w, out int h) {
      winsize ws;

      if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) != 0) {
        return false;
      }

      w = ws.ws_col;
      h = ws.ws_row;

      return true;
    }

    private bool platformRead(ref ubyte[] buf, int timeoutMs) {
      pollfd p;

      p.fd = STDIN_FILENO;
      p.events = POLLIN;
      if (poll(&p, 1, timeoutMs) <= 0) {
        return false;
      }

      ubyte[4096] tmp;
      auto n = posixRead(STDIN_FILENO, tmp.ptr, tmp.length);

      if (n <= 0) {
        return false;
      }

      buf ~= tmp[0 .. n];

      return true;
    }
  }

  version (Windows) {
    import core.sys.windows.windows;

    private enum ENABLE_VIRTUAL_TERMINAL_INPUT = 0x0200;
    private enum ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004;
    private enum DISABLE_NEWLINE_AUTO_RETURN = 0x0008;

    private HANDLE input, output;
    private DWORD savedIn, savedOut;
    private UINT savedCp, savedOutCp;

    private void platformOpen() {
      input = GetStdHandle(STD_INPUT_HANDLE);
      output = GetStdHandle(STD_OUTPUT_HANDLE);
      GetConsoleMode(input, &savedIn);
      GetConsoleMode(output, &savedOut);
      savedCp = GetConsoleCP();
      savedOutCp = GetConsoleOutputCP();
      SetConsoleCP(65001);
      SetConsoleOutputCP(65001);
      SetConsoleMode(input, ENABLE_VIRTUAL_TERMINAL_INPUT | ENABLE_WINDOW_INPUT | ENABLE_EXTENDED_FLAGS);
      SetConsoleMode(output,
        ENABLE_PROCESSED_OUTPUT | ENABLE_VIRTUAL_TERMINAL_PROCESSING | DISABLE_NEWLINE_AUTO_RETURN);
    }

    private void platformClose() {
      SetConsoleMode(input, savedIn);
      SetConsoleMode(output, savedOut);
      SetConsoleCP(savedCp);
      SetConsoleOutputCP(savedOutCp);
    }

    private void platformWrite(const(char)[] s) {
      DWORD written;

      WriteFile(output, s.ptr, cast(DWORD)s.length, &written, null);
    }

    private bool platformSize(out int w, out int h) {
      CONSOLE_SCREEN_BUFFER_INFO info;

      if (!GetConsoleScreenBufferInfo(output, &info)) {
        return false;
      }

      w = info.srWindow.Right - info.srWindow.Left + 1;
      h = info.srWindow.Bottom - info.srWindow.Top + 1;

      return true;
    }

    private bool platformRead(ref ubyte[] buf, int timeoutMs) {
      import std.utf : encode;

      if (WaitForSingleObject(input, timeoutMs) != WAIT_OBJECT_0) {
        return false;
      }

      INPUT_RECORD[64] records;
      DWORD count;

      if (!ReadConsoleInputW(input, records.ptr, records.length, &count)) {
        return false;
      }

      bool any;
      wchar high;

      foreach (ref r; records[0 .. count]) {
        if (r.EventType == WINDOW_BUFFER_SIZE_EVENT) {
          resized = true;
          any = true;
          continue;
        }

        if (r.EventType != KEY_EVENT || !r.KeyEvent.bKeyDown) {
          continue;
        }

        wchar wc = r.KeyEvent.UnicodeChar;

        if (!wc) {
          continue;
        }

        dchar c = wc;

        if (wc >= 0xD800 && wc < 0xDC00) {
          high = wc;
          continue;
        }

        if (wc >= 0xDC00 && wc < 0xE000 && high) {
          c = 0x10000 + ((high - 0xD800) << 10) + (wc - 0xDC00);
          high = 0;
        }

        char[4] tmp;

        foreach (_; 0 .. r.KeyEvent.wRepeatCount ? r.KeyEvent.wRepeatCount : 1) {
          buf ~= cast(ubyte[])tmp[0 .. encode(tmp, c)];
        }

        any = true;
      }

      return any;
    }
  }
}

int charWidth(dchar c) {
  if (c < 0x300) {
    return c < 0x20 ? 0 : 1;
  }

  if ((c >= 0x300 && c < 0x370) || (c >= 0x200B && c <= 0x200F) || (c >= 0xFE00 && c <= 0xFE0F)) {
    return 0;
  }

  if ((c >= 0x1100 && c <= 0x115F) || (c >= 0x2E80 && c <= 0xA4CF && c != 0x303F) ||
    (c >= 0xAC00 && c <= 0xD7A3) || (c >= 0xF900 && c <= 0xFAFF) || (c >= 0xFE30 && c <= 0xFE4F) ||
    (c >= 0xFF00 && c <= 0xFF60) || (c >= 0xFFE0 && c <= 0xFFE6) ||
    (c >= 0x1F300 && c <= 0x1F64F) || (c >= 0x1F900 && c <= 0x1F9FF) || (c >= 0x20000 && c <= 0x3FFFD)) {
    return 2;
  }

  return 1;
}
