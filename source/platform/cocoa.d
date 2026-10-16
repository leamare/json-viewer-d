/// macOS window through the Objective-C runtime. AppKit is loaded at runtime like the
/// Wayland libraries, so building needs no SDK, only libSystem.
module platform.cocoa;

version (OSX):

import core.stdc.string : strlen;
import core.sys.posix.dlfcn : dlopen, dlsym, RTLD_NOW, RTLD_GLOBAL;

import platform.window;

private alias id = void*;
private alias SEL = void*;
private alias Class = void*;

private struct NSPoint {
  double x = 0, y = 0;
}

private struct NSSize {
  double width = 0, height = 0;
}

private struct NSRect {
  NSPoint origin;
  NSSize size;
}

private struct NSRange {
  ulong location, length;
}

private enum : ulong {
  flagShift = 1 << 17,
  flagControl = 1 << 18,
  flagOption = 1 << 19,
  flagCommand = 1 << 20,
}

private enum notFound = long.max;

private alias GetClassFn = extern (C) Class function(const(char)*) nothrow @nogc;
private alias SelFn = extern (C) SEL function(const(char)*) nothrow @nogc;
private alias AllocClassFn = extern (C) Class function(Class, const(char)*, size_t) nothrow @nogc;
private alias RegisterClassFn = extern (C) void function(Class) nothrow @nogc;
private alias AddMethodFn = extern (C) bool function(Class, SEL, void*, const(char)*) nothrow @nogc;
private alias GetProtocolFn = extern (C) void* function(const(char)*) nothrow @nogc;
private alias AddProtocolFn = extern (C) bool function(Class, void*) nothrow @nogc;
private alias PoolPushFn = extern (C) void* function() nothrow @nogc;
private alias PoolPopFn = extern (C) void function(void*) nothrow @nogc;
private alias DataCreateFn = extern (C) void* function(void*, const(void)*, long) nothrow @nogc;
private alias ReleaseFn = extern (C) void function(void*) nothrow @nogc;
private alias ProviderFn = extern (C) void* function(void*) nothrow @nogc;
private alias ColorSpaceFn = extern (C) void* function() nothrow @nogc;
private alias ImageCreateFn = extern (C) void* function(size_t, size_t, size_t, size_t, size_t, void*, uint,
  void*, const(double)*, bool, int) nothrow @nogc;

private struct Runtime {
  void* msgSend;
  GetClassFn getClass;
  SelFn sel;
  AllocClassFn allocateClassPair;
  RegisterClassFn registerClassPair;
  AddMethodFn addMethod;
  GetProtocolFn getProtocol;
  AddProtocolFn addProtocol;
  PoolPushFn poolPush;
  PoolPopFn poolPop;

  DataCreateFn dataCreate;
  ReleaseFn release;
  ProviderFn providerFromData;
  ReleaseFn providerRelease;
  ColorSpaceFn deviceRgb;
  ImageCreateFn imageCreate;
  ReleaseFn imageRelease;

  void* colorSpace;
  id defaultMode;
}

private __gshared Runtime rt;
private __gshared Class viewClass, delegateClass;
private __gshared CocoaWindow instance;

private void loadRuntime() {
  if (rt.msgSend !is null) {
    return;
  }

  auto objc = dlopen("/usr/lib/libobjc.A.dylib", RTLD_NOW | RTLD_GLOBAL);
  auto appKit = dlopen("/System/Library/Frameworks/AppKit.framework/AppKit", RTLD_NOW | RTLD_GLOBAL);
  auto graphics = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW | RTLD_GLOBAL);
  auto foundation = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation",
    RTLD_NOW | RTLD_GLOBAL);

  if (objc is null || appKit is null || graphics is null || foundation is null) {
    throw new Exception("Can't load AppKit");
  }

  T find(T)(void* lib, const(char)* name) {
    auto p = dlsym(lib, name);

    if (p is null) {
      throw new Exception("Missing symbol " ~ cast(string)name[0 .. strlen(name)]);
    }

    return cast(T)p;
  }

  rt.msgSend = find!(void*)(objc, "objc_msgSend");
  rt.getClass = find!GetClassFn(objc, "objc_getClass");
  rt.sel = find!SelFn(objc, "sel_registerName");
  rt.allocateClassPair = find!AllocClassFn(objc, "objc_allocateClassPair");
  rt.registerClassPair = find!RegisterClassFn(objc, "objc_registerClassPair");
  rt.addMethod = find!AddMethodFn(objc, "class_addMethod");
  rt.getProtocol = find!GetProtocolFn(objc, "objc_getProtocol");
  rt.addProtocol = find!AddProtocolFn(objc, "class_addProtocol");
  rt.poolPush = find!PoolPushFn(objc, "objc_autoreleasePoolPush");
  rt.poolPop = find!PoolPopFn(objc, "objc_autoreleasePoolPop");

  rt.dataCreate = find!DataCreateFn(foundation, "CFDataCreate");
  rt.release = find!ReleaseFn(foundation, "CFRelease");
  rt.providerFromData = find!ProviderFn(graphics, "CGDataProviderCreateWithCFData");
  rt.providerRelease = find!ReleaseFn(graphics, "CGDataProviderRelease");
  rt.deviceRgb = find!ColorSpaceFn(graphics, "CGColorSpaceCreateDeviceRGB");
  rt.imageCreate = find!ImageCreateFn(graphics, "CGImageCreate");
  rt.imageRelease = find!ReleaseFn(graphics, "CGImageRelease");

  rt.colorSpace = rt.deviceRgb();
  rt.defaultMode = *find!(id*)(foundation, "kCFRunLoopDefaultMode");
}

private R send(R = id, Args...)(id obj, const(char)* name, Args args) {
  alias Fn = extern (C) R function(id, SEL, Args) nothrow @nogc;

  return (cast(Fn)rt.msgSend)(obj, rt.sel(name), args);
}

private id cls(const(char)* name) {
  return rt.getClass(name);
}

private id make(const(char)* name) {
  return send(send(cls(name), "alloc"), "init");
}

private id nsString(string s) {
  auto str = send!id(send(cls("NSString"), "alloc"), "initWithBytes:length:encoding:", cast(const(void)*)s.ptr,
    cast(ulong)s.length, 4UL);

  return send(str, "autorelease");
}

private string dString(id s) {
  if (s is null) {
    return null;
  }

  auto p = send!(const(char)*)(s, "UTF8String");

  return p is null ? null : p[0 .. strlen(p)].idup;
}

/// BGRA pixels as a CGImage, the caller releases it
private void* makeImage(const(uint)[] pixels, int width, int height) {
  auto data = rt.dataCreate(null, pixels.ptr, cast(long)width * height * 4);
  auto provider = rt.providerFromData(data);

  // kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst
  auto image = rt.imageCreate(width, height, 8, 32, width * 4, rt.colorSpace, 0x2006, provider, null, false, 0);

  rt.providerRelease(provider);
  rt.release(data);

  return image;
}

private void registerClasses() {
  if (viewClass !is null) {
    return;
  }

  void method(Class c, const(char)* name, void* imp, const(char)* types) {
    rt.addMethod(c, rt.sel(name), imp, types);
  }

  enum range = "{_NSRange=QQ}";
  enum rect = "{CGRect={CGPoint=dd}{CGSize=dd}}";

  viewClass = rt.allocateClassPair(cls("NSView"), "JsonViewContentView", 0);
  method(viewClass, "acceptsFirstResponder", &viewYes, "B@:");
  method(viewClass, "acceptsFirstMouse:", &viewYesFor, "B@:@");
  method(viewClass, "keyDown:", &viewKeyDown, "v@:@");
  method(viewClass, "keyUp:", &viewIgnore, "v@:@");
  method(viewClass, "flagsChanged:", &viewIgnore, "v@:@");

  foreach (name; ["mouseDown:", "mouseUp:", "rightMouseDown:", "rightMouseUp:", "otherMouseDown:",
    "otherMouseUp:", "mouseMoved:", "mouseDragged:", "rightMouseDragged:", "otherMouseDragged:"]) {
    method(viewClass, name.ptr, &viewMouse, "v@:@");
  }

  method(viewClass, "scrollWheel:", &viewScroll, "v@:@");

  method(viewClass, "insertText:replacementRange:", &viewInsertText, "v@:@" ~ range);
  method(viewClass, "doCommandBySelector:", &viewCommand, "v@::");
  method(viewClass, "setMarkedText:selectedRange:replacementRange:", &viewSetMarked, "v@:@" ~ range ~ range);
  method(viewClass, "unmarkText", &viewUnmark, "v@:");
  method(viewClass, "hasMarkedText", &viewHasMarked, "B@:");
  method(viewClass, "markedRange", &viewNoRange, range ~ "@:");
  method(viewClass, "selectedRange", &viewNoRange, range ~ "@:");
  method(viewClass, "validAttributesForMarkedText", &viewNoAttributes, "@@:");
  method(viewClass, "attributedSubstringForProposedRange:actualRange:", &viewNoSubstring,
    "@@:" ~ range ~ "^" ~ range);
  method(viewClass, "characterIndexForPoint:", &viewCharIndex, "Q@:{CGPoint=dd}");
  method(viewClass, "firstRectForCharacterRange:actualRange:", &viewFirstRect, rect ~ "@:" ~ range ~ "^" ~ range);
  rt.addProtocol(viewClass, rt.getProtocol("NSTextInputClient"));

  method(viewClass, "draggingEntered:", &viewDragEntered, "Q@:@");
  method(viewClass, "performDragOperation:", &viewDrop, "B@:@");
  rt.registerClassPair(viewClass);

  delegateClass = rt.allocateClassPair(cls("NSObject"), "JsonViewDelegate", 0);
  method(delegateClass, "windowShouldClose:", &delegateShouldClose, "B@:@");
  method(delegateClass, "windowDidResize:", &delegateResized, "v@:@");
  method(delegateClass, "windowDidChangeBackingProperties:", &delegateResized, "v@:@");
  method(delegateClass, "windowDidBecomeKey:", &delegateFocusIn, "v@:@");
  method(delegateClass, "windowDidResignKey:", &delegateFocusOut, "v@:@");
  method(delegateClass, "applicationShouldTerminate:", &delegateShouldTerminate, "Q@:@");
  method(delegateClass, "application:openURLs:", &delegateOpenUrls, "v@:@@");
  method(delegateClass, "requestQuit:", &delegateQuit, "v@:@");
  rt.registerClassPair(delegateClass);
}

final class CocoaWindow : Window {
  private id app, window, view, layer, delegate_;
  private Event[] queue;
  private int w, h;
  private float scaleFactor = 1;
  private float wheelAcc = 0, hwheelAcc = 0;
  private bool marked;

  private id[Cursor] cursors;
  private void delegate(int w, int h) onLiveResize;

  this(string title, int width, int height) {
    loadRuntime();
    registerClasses();
    instance = this;

    auto pool = rt.poolPush();

    scope (exit) rt.poolPop(pool);

    app = send(cls("NSApplication"), "sharedApplication");
    delegate_ = make("JsonViewDelegate");
    send!void(app, "setActivationPolicy:", 0L);
    send!void(app, "setDelegate:", delegate_);
    buildMenu();
    send!void(app, "finishLaunching");

    auto frame = NSRect(NSPoint(0, 0), NSSize(width, height));

    // titled, closable, miniaturizable, resizable; buffered backing
    window = send!id(send(cls("NSWindow"), "alloc"), "initWithContentRect:styleMask:backing:defer:", frame, 15UL,
      2UL, false);
    if (window is null) {
      throw new Exception("Can't create window");
    }

    send!void(window, "setReleasedWhenClosed:", false);
    send!void(window, "setTitle:", nsString(title));
    send!void(window, "setDelegate:", delegate_);
    send!void(window, "setAcceptsMouseMovedEvents:", true);
    send!void(window, "setContentMinSize:", NSSize(480, 320));

    view = send!id(send(viewClass, "alloc"), "initWithFrame:", frame);
    send!void(view, "setWantsLayer:", true);
    send!void(view, "setLayerContentsRedrawPolicy:", 0L);
    layer = send(view, "layer");
    send!void(layer, "setContentsGravity:", nsString("topLeft"));
    send!void(view, "registerForDraggedTypes:", send!id(cls("NSArray"), "arrayWithObject:",
      nsString("public.file-url")));
    send!void(window, "setContentView:", view);
    send!void(window, "makeFirstResponder:", view);
    send!void(window, "center");
    send!void(window, "makeKeyAndOrderFront:", cast(id)null);
    send!void(app, "activateIgnoringOtherApps:", true);
    updateSize();
  }

  private void buildMenu() {
    auto bar = make("NSMenu");
    auto appItem = make("NSMenuItem");
    auto appMenu = make("NSMenu");
    auto quit = send!id(send(cls("NSMenuItem"), "alloc"), "initWithTitle:action:keyEquivalent:",
      nsString("Quit JSON Viewer"), rt.sel("requestQuit:"), nsString("q"));

    send!void(quit, "setTarget:", delegate_);
    send!void(appMenu, "addItem:", quit);
    send!void(appItem, "setSubmenu:", appMenu);
    send!void(bar, "addItem:", appItem);
    send!void(app, "setMainMenu:", bar);
  }

  private void updateSize() {
    auto bounds = send!NSRect(view, "bounds");

    scaleFactor = cast(float)send!double(window, "backingScaleFactor");
    w = cast(int)(bounds.size.width * scaleFactor + 0.5);
    h = cast(int)(bounds.size.height * scaleFactor + 0.5);
    send!void(layer, "setContentsScale:", cast(double)scaleFactor);
  }

  @property int width() { return w; }
  @property int height() { return h; }
  float scale() { return scaleFactor; }
  ulong nativeHandle() { return cast(ulong)window; }

  void setLiveResize(void delegate(int, int) handler) {
    onLiveResize = handler;
  }

  void setTitle(string title) {
    auto pool = rt.poolPush();

    send!void(window, "setTitle:", nsString(title));
    rt.poolPop(pool);
  }

  void setDarkTitleBar(bool dark) {
    auto pool = rt.poolPush();
    auto name = nsString(dark ? "NSAppearanceNameDarkAqua" : "NSAppearanceNameAqua");

    send!void(window, "setAppearance:", send!id(cls("NSAppearance"), "appearanceNamed:", name));
    rt.poolPop(pool);
  }

  void setIcon(const(uint)[] argb, int size) {
    auto pool = rt.poolPush();
    auto image = makeImage(argb, size, size);
    auto icon = send!id(send(cls("NSImage"), "alloc"), "initWithCGImage:size:", image, NSSize(size, size));

    send!void(app, "setApplicationIconImage:", icon);
    send!void(icon, "release");
    rt.imageRelease(image);
    rt.poolPop(pool);
  }

  void setCursor(Cursor c) {
    if (auto p = c in cursors) {
      send!void(*p, "set");

      return;
    }

    const(char)* name;

    final switch (c) {
      case Cursor.arrow: name = "arrowCursor"; break;
      case Cursor.text: name = "IBeamCursor"; break;
      case Cursor.resizeH: name = "resizeLeftRightCursor"; break;
      case Cursor.resizeV: name = "resizeUpDownCursor"; break;
      case Cursor.hand: name = "pointingHandCursor"; break;
    }
    auto cursor = send(cls("NSCursor"), name);

    cursors[c] = cursor;
    send!void(cursor, "set");
  }

  void present(const(uint)[] pixels, int width, int height) {
    if (!pixels.length || width <= 0 || height <= 0) {
      return;
    }

    auto pool = rt.poolPush();
    auto image = makeImage(pixels, width, height);

    send!void(layer, "setContents:", image);
    rt.imageRelease(image);
    send!void(cls("CATransaction"), "flush");
    rt.poolPop(pool);
  }

  bool nextEvent(out Event ev, int timeoutMs) {
    while (!queue.length) {
      auto pool = rt.poolPush();

      scope (exit) rt.poolPop(pool);

      auto date = timeoutMs < 0 ? send(cls("NSDate"), "distantFuture")
        : send!id(cls("NSDate"), "dateWithTimeIntervalSinceNow:", timeoutMs / 1000.0);
      auto e = send!id(app, "nextEventMatchingMask:untilDate:inMode:dequeue:", ulong.max, date, rt.defaultMode,
        true);

      if (e is null) {
        return false;
      }

      while (e !is null) {
        send!void(app, "sendEvent:", e);
        e = send!id(app, "nextEventMatchingMask:untilDate:inMode:dequeue:", ulong.max, cast(id)null,
          rt.defaultMode, true);
      }

      send!void(app, "updateWindows");
    }

    ev = queue[0];
    queue = queue[1 .. $];

    return true;
  }

  void close() {
    if (window is null) {
      return;
    }

    send!void(window, "orderOut:", cast(id)null);
    send!void(window, "close");
    window = null;
  }

  void setClipboard(string text) {
    auto pool = rt.poolPush();
    auto board = send(cls("NSPasteboard"), "generalPasteboard");

    send!long(board, "clearContents");
    send!bool(board, "setString:forType:", nsString(text), nsString("public.utf8-plain-text"));
    rt.poolPop(pool);
  }

  string getClipboard() {
    auto pool = rt.poolPush();

    scope (exit) rt.poolPop(pool);

    auto board = send(cls("NSPasteboard"), "generalPasteboard");

    return dString(send!id(board, "stringForType:", nsString("public.utf8-plain-text")));
  }

  private void push(Event e) {
    queue ~= e;
  }

  private void pushResize() {
    updateSize();
    if (onLiveResize !is null) {
      onLiveResize(w, h);

      return;
    }

    Event e;

    e.type = EventType.resize;
    e.width = w;
    e.height = h;
    push(e);
  }

  private static uint modsOf(ulong flags) {
    uint m;

    if (flags & flagShift) {
      m |= Mod.shift;
    }

    if (flags & (flagCommand | flagControl)) {
      m |= Mod.ctrl;
    }

    if (flags & flagOption) {
      m |= Mod.alt;
    }

    return m;
  }

  private void position(id event, ref Event e) {
    auto p = send!NSPoint(view, "convertPoint:fromView:", send!NSPoint(event, "locationInWindow"), cast(id)null);
    auto bounds = send!NSRect(view, "bounds");

    e.x = cast(int)(p.x * scaleFactor);
    e.y = cast(int)((bounds.size.height - p.y) * scaleFactor);
  }

  private void keyDown(id event) {
    auto flags = send!ulong(event, "modifierFlags");

    if (!marked) {
      Event e;

      e.type = EventType.keyDown;
      e.key = mapKey(event, send!ushort(event, "keyCode"));
      e.mods = modsOf(flags);
      push(e);
    }

    if (!(flags & (flagCommand | flagControl))) {
      send!void(view, "interpretKeyEvents:", send!id(cls("NSArray"), "arrayWithObject:", event));
    }
  }

  private void insertText(id text) {
    if (send!bool(text, "isKindOfClass:", cls("NSAttributedString"))) {
      text = send(text, "string");
    }

    marked = false;

    auto s = dString(text);

    if (!s.length || s[0] < 0x20 || s[0] == 0x7F) {
      return;
    }

    Event e;

    e.type = EventType.text;
    e.text = s;
    push(e);
  }

  private void mouse(id event) {
    // NSEventType: 1/2 left down/up, 3/4 right, 5 moved, 6/7/27 dragged, 25/26 other down/up
    auto type = send!ulong(event, "type");
    auto flags = send!ulong(event, "modifierFlags");
    Event e;

    position(event, e);
    e.mods = modsOf(flags);
    switch (type) {
      case 1, 2:
        e.button = flags & flagControl ? MouseButton.right : MouseButton.left;
        e.type = type == 1 ? EventType.mouseDown : EventType.mouseUp;
        break;
      case 3, 4:
        e.button = MouseButton.right;
        e.type = type == 3 ? EventType.mouseDown : EventType.mouseUp;
        break;
      case 25, 26:
        e.button = MouseButton.middle;
        e.type = type == 25 ? EventType.mouseDown : EventType.mouseUp;
        break;
      default:
        e.type = EventType.mouseMove;
        if (queue.length && queue[$ - 1].type == EventType.mouseMove) {
          queue[$ - 1] = e;

          return;
        }

        break;
    }

    if (e.type != EventType.mouseMove) {
      e.clicks = cast(int)send!long(event, "clickCount");
    }

    push(e);
  }

  private void scroll(id event) {
    double dx = send!double(event, "scrollingDeltaX"), dy = send!double(event, "scrollingDeltaY");

    // touchpads report points, wheels report lines
    if (send!bool(event, "hasPreciseScrollingDeltas")) {
      dx /= 12;
      dy /= 12;
    }

    wheelAcc += dy;
    hwheelAcc += dx;

    int lines = cast(int)wheelAcc, columns = cast(int)hwheelAcc;

    if (!lines && !columns) {
      return;
    }

    wheelAcc -= lines;
    hwheelAcc -= columns;

    Event e;

    e.type = EventType.wheel;
    position(event, e);
    e.mods = modsOf(send!ulong(event, "modifierFlags"));
    e.wheelY = lines;
    e.wheelX = columns;
    push(e);
  }

  private bool drop(id info) {
    auto board = send(info, "draggingPasteboard");
    auto classes = send!id(cls("NSArray"), "arrayWithObject:", cls("NSURL"));
    auto urls = send!id(board, "readObjectsForClasses:options:", classes, cast(id)null);
    Event e;

    e.type = EventType.drop;
    openUrls(urls, e);

    auto p = send!NSPoint(view, "convertPoint:fromView:", send!NSPoint(info, "draggingLocation"), cast(id)null);
    auto bounds = send!NSRect(view, "bounds");

    e.x = cast(int)(p.x * scaleFactor);
    e.y = cast(int)((bounds.size.height - p.y) * scaleFactor);
    push(e);

    return e.files.length > 0;
  }

  private void openUrls(id urls, ref Event e) {
    if (urls is null) {
      return;
    }

    auto count = send!ulong(urls, "count");

    foreach (k; 0 .. count) {
      auto url = send!id(urls, "objectAtIndex:", k);

      if (send!bool(url, "isFileURL")) {
        e.files ~= dString(send(url, "path"));
      }
    }
  }

  private static Key mapKey(id event, ushort code) {
    auto chars = dString(send(event, "charactersIgnoringModifiers"));

    // letters follow the layout when it is latin, the key position otherwise
    if (chars.length == 1) {
      char c = chars[0];

      if (c >= 'A' && c <= 'Z') {
        c += 32;
      }

      if (c >= 'a' && c <= 'z') {
        return cast(Key)(Key.a + (c - 'a'));
      }
    }

    // ANSI key codes 0 .. 46
    enum letters = "asdfhgzxcv bqweryt123465 97 80 ou ip lj k    nm";

    if (code < letters.length) {
      char c = letters[code];

      if (c >= 'a' && c <= 'z') {
        return cast(Key)(Key.a + (c - 'a'));
      }

      if (c >= '0' && c <= '9') {
        return cast(Key)(Key.num0 + (c - '0'));
      }
    }

    switch (code) {
      case 36, 76: return Key.enter;
      case 48: return Key.tab;
      case 49: return Key.space;
      case 51: return Key.backspace;
      case 53: return Key.escape;
      case 117: return Key.del;
      case 114: return Key.insert;
      case 123: return Key.left;
      case 124: return Key.right;
      case 125: return Key.down;
      case 126: return Key.up;
      case 115: return Key.home;
      case 119: return Key.end;
      case 116: return Key.pageUp;
      case 121: return Key.pageDown;
      case 27, 78: return Key.minus;
      case 24, 69: return Key.plus;
      case 110: return Key.menu;
      case 122: return Key.f1;
      case 120: return Key.f2;
      case 99: return Key.f3;
      case 118: return Key.f4;
      case 96: return Key.f5;
      case 97: return Key.f6;
      case 98: return Key.f7;
      case 100: return Key.f8;
      case 101: return Key.f9;
      case 109: return Key.f10;
      case 103: return Key.f11;
      case 111: return Key.f12;
      default: return Key.unknown;
    }
  }
}

/// Modal open or save panel, null when cancelled
string filePanel(string title, string path, bool save) {
  import std.path : dirName, baseName;

  loadRuntime();

  auto pool = rt.poolPush();

  scope (exit) rt.poolPop(pool);

  auto panel = save ? send(cls("NSSavePanel"), "savePanel") : send(cls("NSOpenPanel"), "openPanel");

  send!void(panel, "setTitle:", nsString(title));
  send!void(panel, "setMessage:", nsString(title));
  if (path.length) {
    auto dir = save ? path.dirName : path;

    send!void(panel, "setDirectoryURL:", send!id(cls("NSURL"), "fileURLWithPath:", nsString(dir)));
    if (save) {
      send!void(panel, "setNameFieldStringValue:", nsString(path.baseName));
    }
  }

  if (send!long(panel, "runModal") != 1) {
    return null;
  }

  return dString(send(send(panel, "URL"), "path"));
}

private extern (C) bool viewYes(id, SEL) {
  return true;
}

private extern (C) bool viewYesFor(id, SEL, id) {
  return true;
}

private extern (C) void viewIgnore(id, SEL, id) {
}

private extern (C) void viewKeyDown(id, SEL, id event) {
  try {
    instance.keyDown(event);
  } catch (Throwable) {
  }
}

private extern (C) void viewMouse(id, SEL, id event) {
  try {
    instance.mouse(event);
  } catch (Throwable) {
  }
}

private extern (C) void viewScroll(id, SEL, id event) {
  try {
    instance.scroll(event);
  } catch (Throwable) {
  }
}

private extern (C) void viewInsertText(id, SEL, id text, NSRange) {
  try {
    instance.insertText(text);
  } catch (Throwable) {
  }
}

private extern (C) void viewCommand(id, SEL, SEL) {
}

private extern (C) void viewSetMarked(id, SEL, id text, NSRange, NSRange) {
  try {
    if (send!bool(text, "isKindOfClass:", cls("NSAttributedString"))) {
      text = send(text, "string");
    }

    instance.marked = send!ulong(text, "length") > 0;
  } catch (Throwable) {
  }
}

private extern (C) void viewUnmark(id, SEL) {
  instance.marked = false;
}

private extern (C) bool viewHasMarked(id, SEL) {
  return instance.marked;
}

private extern (C) NSRange viewNoRange(id, SEL) {
  return NSRange(notFound, 0);
}

private extern (C) id viewNoAttributes(id, SEL) {
  return send(cls("NSArray"), "array");
}

private extern (C) id viewNoSubstring(id, SEL, NSRange, NSRange*) {
  return null;
}

private extern (C) ulong viewCharIndex(id, SEL, NSPoint) {
  return notFound;
}

private extern (C) NSRect viewFirstRect(id, SEL, NSRange, NSRange*) {
  auto frame = send!NSRect(instance.window, "frame");

  return NSRect(frame.origin, NSSize(0, 0));
}

private extern (C) ulong viewDragEntered(id, SEL, id) {
  return 1;
}

private extern (C) bool viewDrop(id, SEL, id info) {
  try {
    return instance.drop(info);
  } catch (Throwable) {
    return false;
  }
}

private extern (C) bool delegateShouldClose(id, SEL, id) {
  instance.push(Event(EventType.close));

  return false;
}

private extern (C) void delegateResized(id, SEL, id) {
  try {
    instance.pushResize();
  } catch (Throwable) {
  }
}

private extern (C) void delegateFocusIn(id, SEL, id) {
  instance.push(Event(EventType.focusIn));
}

private extern (C) void delegateFocusOut(id, SEL, id) {
  instance.push(Event(EventType.focusOut));
}

private extern (C) ulong delegateShouldTerminate(id, SEL, id) {
  instance.push(Event(EventType.close));

  return 0;
}

private extern (C) void delegateOpenUrls(id, SEL, id, id urls) {
  try {
    Event e;

    e.type = EventType.drop;
    instance.openUrls(urls, e);
    if (e.files.length) {
      instance.push(e);
    }
  } catch (Throwable) {
  }
}

private extern (C) void delegateQuit(id, SEL, id) {
  instance.push(Event(EventType.close));
}
