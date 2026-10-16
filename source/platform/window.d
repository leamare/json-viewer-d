module platform.window;

enum EventType {
  none,
  keyDown,
  text,
  mouseDown,
  mouseUp,
  mouseMove,
  wheel,
  resize,
  expose,
  close,
  focusIn,
  focusOut,
  drop,
}

enum Key {
  unknown,
  escape, enter, tab, backspace, del, insert,
  left, right, up, down, home, end, pageUp, pageDown,
  f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12,
  a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p, q, r, s, t, u, v, w, x, y, z,
  num0, num1, num2, num3, num4, num5, num6, num7, num8, num9,
  space, minus, plus, menu,
}

enum Mod : uint {
  none = 0,
  shift = 1,
  ctrl = 2,
  alt = 4,
  meta = 8,
}

enum MouseButton {
  none,
  left,
  middle,
  right,
}

enum Cursor {
  arrow,
  text,
  resizeH,
  resizeV,
  hand,
}

struct Event {
  EventType type;
  Key key;
  uint mods;
  string text;
  string[] files;
  MouseButton button;
  int clicks;
  int x, y;
  float wheelX = 0, wheelY = 0;
  int width, height;

  bool ctrl() const { return (mods & Mod.ctrl) != 0; }
  bool shift() const { return (mods & Mod.shift) != 0; }
  bool alt() const { return (mods & Mod.alt) != 0; }
}

interface Window {
  bool nextEvent(out Event ev, int timeoutMs);

  void present(const(uint)[] pixels, int width, int height);

  void setTitle(string title);
  void setCursor(Cursor c);
  void setIcon(const(uint)[] argb, int size);

  float scale();

  void setClipboard(string text);
  string getClipboard();

  @property int width();
  @property int height();

  ulong nativeHandle();

  void setDarkTitleBar(bool dark);

  void setLiveResize(void delegate(int width, int height) handler);

  void close();
}

Window createWindow(string title, int width, int height) {
  version (Windows) {
    import platform.win32 : Win32Window;

    return new Win32Window(title, width, height);
  } else version (OSX) {
    throw new Exception("There is no GUI for macOS yet, use --tui");
  } else {
    import platform.x11 : X11Window;
    import std.process : environment;

    version (linux) {
      if (environment.get("WAYLAND_DISPLAY").length && !environment.get("JSONVIEW_X11").length) {
        import platform.wayland : WaylandWindow;
        try {
          return new WaylandWindow(title, width, height);
        } catch (Exception) {
        }
      }
    }

    return new X11Window(title, width, height);
  }
}
