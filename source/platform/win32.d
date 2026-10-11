module platform.win32;

version (Windows):

import core.sys.windows.windows;
import core.sys.windows.shellapi : DragAcceptFiles, DragQueryFileW, DragFinish, HDROP;
import std.utf : toUTF16z, toUTF8, toUTF16;
import std.string : replace;

import platform.window;

private enum WM_DPICHANGED_ = 0x02E0;
private enum WM_MOUSEHWHEEL_ = 0x020E;
private enum DWMWA_USE_IMMERSIVE_DARK_MODE = 20;

private __gshared Win32Window[HWND] windows;

final class Win32Window : Window {
  private HWND hwnd;
  private Event[] queue;
  private int w, h;
  private float dpiScale = 1;

  private const(uint)[] lastPixels;
  private int lastW, lastH;

  private HCURSOR[Cursor] cursors;
  private Cursor currentCursor = Cursor.arrow;
  private wchar highSurrogate;

  private DWORD lastClickTime;
  private int lastClickX, lastClickY;
  private MouseButton lastClickButton;
  private int clickCount;

  private void delegate(int w, int h) onLiveResize;

  this(string title, int width, int height) {
    enableDpiAwareness();

    auto instance = GetModuleHandleW(null);
    WNDCLASSEXW wc;

    wc.cbSize = WNDCLASSEXW.sizeof;
    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = &windowProc;
    wc.hInstance = instance;
    wc.hCursor = LoadCursorW(null, IDC_ARROW);
    wc.hIcon = LoadIconW(instance, cast(LPCWSTR)1);
    wc.lpszClassName = "JsonViewWindow"w.ptr;
    RegisterClassExW(&wc);

    dpiScale = systemScale();
    w = cast(int)(width * dpiScale);
    h = cast(int)(height * dpiScale);
    hwnd = CreateWindowExW(WS_EX_ACCEPTFILES, wc.lpszClassName, title.toUTF16z, WS_OVERLAPPEDWINDOW,
      CW_USEDEFAULT, CW_USEDEFAULT, w, h, null, null, instance, null);
    if (!hwnd) {
      throw new Exception("Can't create window");
    }

    windows[hwnd] = this;

    auto windowScale = windowDpi(hwnd);

    if (windowScale > 0) {
      dpiScale = windowScale;
    }

    RECT rc;

    GetClientRect(hwnd, &rc);
    w = rc.right - rc.left;
    h = rc.bottom - rc.top;
    DragAcceptFiles(hwnd, TRUE);
    ShowWindow(hwnd, SW_SHOWNORMAL);
    UpdateWindow(hwnd);
  }

  @property int width() { return w; }
  @property int height() { return h; }
  float scale() { return dpiScale; }
  ulong nativeHandle() { return cast(ulong)hwnd; }

  void setLiveResize(void delegate(int, int) handler) {
    onLiveResize = handler;
  }

  void setTitle(string title) {
    SetWindowTextW(hwnd, title.toUTF16z);
  }

  void setDarkTitleBar(bool dark) {
    auto lib = LoadLibraryW("dwmapi.dll"w.ptr);

    if (!lib) {
      return;
    }

    alias SetAttr = extern (Windows) HRESULT function(HWND, DWORD, const(void)*, DWORD) nothrow;
    auto fn = cast(SetAttr)GetProcAddress(lib, "DwmSetWindowAttribute");

    if (fn is null) {
      return;
    }

    BOOL value = dark;

    fn(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, &value, value.sizeof);
  }

  void setIcon(const(uint)[] argb, int size) {
    auto andMask = new ubyte[size * size / 8];
    auto icon = CreateIcon(GetModuleHandleW(null), size, size, 1, 32, andMask.ptr, cast(ubyte*)argb.ptr);

    if (!icon) {
      return;
    }

    SendMessageW(hwnd, WM_SETICON, ICON_BIG, cast(LPARAM)icon);
    SendMessageW(hwnd, WM_SETICON, ICON_SMALL, cast(LPARAM)icon);
  }

  void setCursor(Cursor c) {
    currentCursor = c;
    SetCursor(cursorHandle(c));
  }

  private HCURSOR cursorHandle(Cursor c) {
    if (auto h = c in cursors) {
      return *h;
    }

    LPCWSTR id;

    final switch (c) {
      case Cursor.arrow: id = IDC_ARROW; break;
      case Cursor.text: id = IDC_IBEAM; break;
      case Cursor.resizeH: id = IDC_SIZEWE; break;
      case Cursor.resizeV: id = IDC_SIZENS; break;
      case Cursor.hand: id = IDC_HAND; break;
    }
    auto handle = LoadCursorW(null, id);

    cursors[c] = handle;

    return handle;
  }

  void present(const(uint)[] pixels, int width, int height) {
    lastPixels = pixels;
    lastW = width;
    lastH = height;
    auto dc = GetDC(hwnd);

    blit(dc);
    ReleaseDC(hwnd, dc);
  }

  private void blit(HDC dc) {
    if (!lastPixels.length) {
      return;
    }

    BITMAPINFO bi;

    bi.bmiHeader.biSize = BITMAPINFOHEADER.sizeof;
    bi.bmiHeader.biWidth = lastW;
    bi.bmiHeader.biHeight = -lastH;
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    bi.bmiHeader.biCompression = BI_RGB;
    SetDIBitsToDevice(dc, 0, 0, lastW, lastH, 0, 0, 0, lastH, lastPixels.ptr, &bi, DIB_RGB_COLORS);
  }

  bool nextEvent(out Event ev, int timeoutMs) {
    while (true) {
      MSG msg;

      while (!queue.length && PeekMessageW(&msg, null, 0, 0, PM_REMOVE)) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
      }

      if (queue.length) {
        ev = queue[0];
        queue = queue[1 .. $];

        return true;
      }

      auto r = MsgWaitForMultipleObjects(0, null, FALSE, timeoutMs < 0 ? INFINITE : timeoutMs, QS_ALLINPUT);

      if (r == WAIT_TIMEOUT) {
        return false;
      }
    }
  }

  void close() {
    if (!hwnd) {
      return;
    }

    windows.remove(hwnd);
    DestroyWindow(hwnd);
    hwnd = null;
  }

  void setClipboard(string text) {
    auto wide = text.replace("\r\n", "\n").replace("\n", "\r\n").toUTF16;

    if (!OpenClipboard(hwnd)) {
      return;
    }

    scope (exit) CloseClipboard();

    EmptyClipboard();
    auto mem = GlobalAlloc(GMEM_MOVEABLE, (wide.length + 1) * wchar.sizeof);

    if (!mem) {
      return;
    }

    auto p = cast(wchar*)GlobalLock(mem);

    p[0 .. wide.length] = wide[];
    p[wide.length] = 0;
    GlobalUnlock(mem);
    SetClipboardData(CF_UNICODETEXT, mem);
  }

  string getClipboard() {
    if (!OpenClipboard(hwnd)) {
      return null;
    }

    scope (exit) CloseClipboard();

    auto mem = GetClipboardData(CF_UNICODETEXT);

    if (!mem) {
      return null;
    }

    auto p = cast(const(wchar)*)GlobalLock(mem);

    if (!p) {
      return null;
    }

    scope (exit) GlobalUnlock(mem);

    size_t n = 0;

    while (p[n]) {
      n++;
    }

    return p[0 .. n].toUTF8.replace("\r\n", "\n");
  }

  private void push(Event e) { queue ~= e; }

  private LRESULT handle(UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
      case WM_CLOSE:
        push(Event(EventType.close));

        return 0;
      case WM_ERASEBKGND:
        return 1;
      case WM_PAINT: {
        PAINTSTRUCT ps;
        auto dc = BeginPaint(hwnd, &ps);

        blit(dc);
        EndPaint(hwnd, &ps);

        return 0;
      }
      case WM_SIZE: {
        int nw = LOWORD(lp), nh = HIWORD(lp);

        if (nw && nh && (nw != w || nh != h)) {
          w = nw;
          h = nh;
          if (onLiveResize !is null) {
            onLiveResize(w, h);
          } else {
            Event e;

            e.type = EventType.resize;
            e.width = w;
            e.height = h;
            push(e);
          }
        }

        return 0;
      }
      case WM_DPICHANGED_: {
        dpiScale = HIWORD(wp) / 96.0f;
        auto rc = cast(RECT*)lp;

        SetWindowPos(hwnd, null, rc.left, rc.top, rc.right - rc.left, rc.bottom - rc.top,
          SWP_NOZORDER | SWP_NOACTIVATE);
        Event e;

        e.type = EventType.resize;
        e.width = w;
        e.height = h;
        push(e);

        return 0;
      }
      case WM_GETMINMAXINFO: {
        auto info = cast(MINMAXINFO*)lp;

        info.ptMinTrackSize.x = cast(int)(480 * dpiScale);
        info.ptMinTrackSize.y = cast(int)(320 * dpiScale);

        return 0;
      }
      case WM_SETCURSOR:
        if (LOWORD(lp) == HTCLIENT) {
          SetCursor(cursorHandle(currentCursor));

          return TRUE;
        }

        break;
      case WM_SETFOCUS:
        push(Event(EventType.focusIn));

        return 0;
      case WM_KILLFOCUS:
        push(Event(EventType.focusOut));

        return 0;
      case WM_KEYDOWN:
      case WM_SYSKEYDOWN: {
        Event e;

        e.type = EventType.keyDown;
        e.key = mapKey(cast(uint)wp);
        e.mods = currentMods();
        push(e);
        // Alt+F4 and the system menu still need default handling
        if (msg == WM_SYSKEYDOWN && (wp == VK_F4 || wp == VK_SPACE)) {
          break;
        }

        return 0;
      }
      case WM_SYSCHAR:
        return 0;
      case WM_CHAR:
        charMessage(cast(wchar)wp);

        return 0;
      case WM_LBUTTONDOWN: mouseButton(MouseButton.left, true, lp); return 0;
      case WM_LBUTTONUP: mouseButton(MouseButton.left, false, lp); return 0;
      case WM_RBUTTONDOWN: mouseButton(MouseButton.right, true, lp); return 0;
      case WM_RBUTTONUP: mouseButton(MouseButton.right, false, lp); return 0;
      case WM_MBUTTONDOWN: mouseButton(MouseButton.middle, true, lp); return 0;
      case WM_MBUTTONUP: mouseButton(MouseButton.middle, false, lp); return 0;
      case WM_MOUSEMOVE: {
        Event e;

        e.type = EventType.mouseMove;
        e.x = cast(short)LOWORD(lp);
        e.y = cast(short)HIWORD(lp);
        e.mods = currentMods();
        if (queue.length && queue[$ - 1].type == EventType.mouseMove) {
          queue[$ - 1] = e;
        } else {
          push(e);
        }

        return 0;
      }
      case WM_MOUSEWHEEL:
      case WM_MOUSEHWHEEL_: {
        POINT pt = POINT(cast(short)LOWORD(lp), cast(short)HIWORD(lp));

        ScreenToClient(hwnd, &pt);
        Event e;

        e.type = EventType.wheel;
        e.x = pt.x;
        e.y = pt.y;
        e.mods = currentMods();
        float delta = cast(short)HIWORD(wp) / 120.0f;

        if (msg == WM_MOUSEWHEEL && !e.shift) {
          e.wheelY = delta;
        } else {
          e.wheelX = msg == WM_MOUSEWHEEL ? delta : -delta;
        }

        push(e);

        return 0;
      }
      case WM_DROPFILES: {
        auto drop = cast(HDROP)wp;
        Event e;

        e.type = EventType.drop;
        auto count = DragQueryFileW(drop, 0xFFFFFFFF, null, 0);

        foreach (k; 0 .. count) {
          auto len = DragQueryFileW(drop, k, null, 0);
          auto buf = new wchar[len + 1];

          DragQueryFileW(drop, k, buf.ptr, len + 1);
          e.files ~= buf[0 .. len].toUTF8;
        }

        DragFinish(drop);
        push(e);

        return 0;
      }
      default:
        break;
    }

    return DefWindowProcW(hwnd, msg, wp, lp);
  }

  private void charMessage(wchar c) {
    if (c >= 0xD800 && c < 0xDC00) {
      highSurrogate = c;

      return;
    }

    if (c < 0x20 || c == 0x7F) {
      return;
    }

    if (currentMods() & Mod.ctrl && !(GetKeyState(VK_MENU) < 0)) {
      return;
    }

    wchar[2] pair = [highSurrogate, c];
    auto text = c >= 0xDC00 && c < 0xE000 && highSurrogate ? pair[].toUTF8 : [c].toUTF8;

    highSurrogate = 0;
    Event e;

    e.type = EventType.text;
    e.text = text;
    push(e);
  }

  private void mouseButton(MouseButton b, bool down, LPARAM lp) {
    Event e;

    e.type = down ? EventType.mouseDown : EventType.mouseUp;
    e.button = b;
    e.x = cast(short)LOWORD(lp);
    e.y = cast(short)HIWORD(lp);
    e.mods = currentMods();
    if (down) {
      import std.math : abs;

      SetCapture(hwnd);
      auto time = GetMessageTime();
      bool near = abs(e.x - lastClickX) < 5 && abs(e.y - lastClickY) < 5;

      if (b == lastClickButton && near && time - lastClickTime <= GetDoubleClickTime()) {
        clickCount++;
      } else {
        clickCount = 1;
      }

      lastClickTime = time;
      lastClickX = e.x;
      lastClickY = e.y;
      lastClickButton = b;
    } else {
      ReleaseCapture();
    }

    e.clicks = clickCount;
    push(e);
  }

  private static uint currentMods() {
    uint m;

    if (GetKeyState(VK_SHIFT) < 0) {
      m |= Mod.shift;
    }

    if (GetKeyState(VK_CONTROL) < 0) {
      m |= Mod.ctrl;
    }

    if (GetKeyState(VK_MENU) < 0) {
      m |= Mod.alt;
    }

    if (GetKeyState(VK_LWIN) < 0 || GetKeyState(VK_RWIN) < 0) {
      m |= Mod.meta;
    }

    return m;
  }

  private static Key mapKey(uint vk) {
    if (vk >= 'A' && vk <= 'Z') {
      return cast(Key)(Key.a + (vk - 'A'));
    }

    if (vk >= '0' && vk <= '9') {
      return cast(Key)(Key.num0 + (vk - '0'));
    }

    if (vk >= VK_F1 && vk <= VK_F12) {
      return cast(Key)(Key.f1 + (vk - VK_F1));
    }

    switch (vk) {
      case VK_ESCAPE: return Key.escape;
      case VK_RETURN: return Key.enter;
      case VK_TAB: return Key.tab;
      case VK_BACK: return Key.backspace;
      case VK_DELETE: return Key.del;
      case VK_INSERT: return Key.insert;
      case VK_LEFT: return Key.left;
      case VK_RIGHT: return Key.right;
      case VK_UP: return Key.up;
      case VK_DOWN: return Key.down;
      case VK_HOME: return Key.home;
      case VK_END: return Key.end;
      case VK_PRIOR: return Key.pageUp;
      case VK_NEXT: return Key.pageDown;
      case VK_SPACE: return Key.space;
      case VK_APPS: return Key.menu;
      case VK_OEM_MINUS: case VK_SUBTRACT: return Key.minus;
      case VK_OEM_PLUS: case VK_ADD: return Key.plus;
      default: return Key.unknown;
    }
  }
}

private extern (Windows) LRESULT windowProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) nothrow {
  try {
    if (auto w = hwnd in windows) {
      return (*w).handle(msg, wp, lp);
    }
  } catch (Throwable) {
  }

  return DefWindowProcW(hwnd, msg, wp, lp);
}

// per-monitor DPI functions only exist on Windows 10, so they are looked up at runtime
private void enableDpiAwareness() {
  auto user32 = GetModuleHandleW("user32.dll"w.ptr);
  alias SetContext = extern (Windows) BOOL function(HANDLE) nothrow;
  auto fn = cast(SetContext)GetProcAddress(user32, "SetProcessDpiAwarenessContext");

  if (fn !is null) {
    fn(cast(HANDLE)-4);

    return;
  }

  alias SetAware = extern (Windows) BOOL function() nothrow;
  auto old = cast(SetAware)GetProcAddress(user32, "SetProcessDPIAware");

  if (old !is null) {
    old();
  }
}

private float windowDpi(HWND hwnd) {
  alias GetDpi = extern (Windows) UINT function(HWND) nothrow;
  auto fn = cast(GetDpi)GetProcAddress(GetModuleHandleW("user32.dll"w.ptr), "GetDpiForWindow");

  if (fn is null) {
    return 0;
  }

  auto dpi = fn(hwnd);

  return dpi ? dpi / 96.0f : 0;
}

private float systemScale() {
  auto dc = GetDC(null);
  auto dpi = GetDeviceCaps(dc, LOGPIXELSX);

  ReleaseDC(null, dc);

  return dpi > 0 ? dpi / 96.0f : 1;
}
