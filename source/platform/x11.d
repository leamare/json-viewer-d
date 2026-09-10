module platform.x11;

version (Posix):

import core.stdc.config : c_long, c_ulong;
import core.stdc.locale : setlocale, LC_ALL;
import core.sys.posix.poll;
import core.time : MonoTime, msecs;
import std.string : toStringz, fromStringz, indexOf, strip, splitLines;
import std.conv : to;

import platform.window;

private extern (C) nothrow @nogc {
  struct Display;
  struct Visual;
  struct _XGC;
  struct _XIM;
  struct _XIC;
  alias GC = _XGC*;
  alias XIM = _XIM*;
  alias XIC = _XIC*;
  alias XID = c_ulong;
  alias XWindow = XID;
  alias Atom = c_ulong;
  alias Time = c_ulong;
  alias KeySym = c_ulong;
  alias Bool = int;
  alias Status = int;

  struct XImageFuncs {
    void* createImage;

    int function(XImage*) destroyImage;
    void* getPixel;
    void* putPixel;
    void* subImage;
    void* addPixel;
  }

  struct XImage {
    int width, height;
    int xoffset;
    int format;
    char* data;
    int byteOrder;
    int bitmapUnit;
    int bitmapBitOrder;
    int bitmapPad;
    int depth;
    int bytesPerLine;
    int bitsPerPixel;
    c_ulong redMask, greenMask, blueMask;
    void* obdata;
    XImageFuncs f;
  }

  struct XAnyEvent {
    int type;
    c_ulong serial;
    Bool sendEvent;
    Display* display;
    XWindow window;
  }

  struct XKeyEvent {
    int type;
    c_ulong serial;
    Bool sendEvent;
    Display* display;
    XWindow window, root, subwindow;
    Time time;
    int x, y, xRoot, yRoot;
    uint state;
    uint keycode;
    Bool sameScreen;
  }

  struct XButtonEvent {
    int type;
    c_ulong serial;
    Bool sendEvent;
    Display* display;
    XWindow window, root, subwindow;
    Time time;
    int x, y, xRoot, yRoot;
    uint state;
    uint button;
    Bool sameScreen;
  }

  struct XMotionEvent {
    int type;
    c_ulong serial;
    Bool sendEvent;
    Display* display;
    XWindow window, root, subwindow;
    Time time;
    int x, y, xRoot, yRoot;
    uint state;
    char isHint;
    Bool sameScreen;
  }

  struct XConfigureEvent {
    int type;
    c_ulong serial;
    Bool sendEvent;
    Display* display;
    XWindow event, window;
    int x, y, width, height, borderWidth;
    XWindow above;
    Bool overrideRedirect;
  }

  struct XClientMessageEvent {
    int type;
    c_ulong serial;
    Bool sendEvent;
    Display* display;
    XWindow window;
    Atom messageType;
    int format;
    c_long[5] l;
  }

  struct XSelectionRequestEvent {
    int type;
    c_ulong serial;
    Bool sendEvent;
    Display* display;
    XWindow owner, requestor;
    Atom selection, target, property;
    Time time;
  }

  struct XSelectionEvent {
    int type;
    c_ulong serial;
    Bool sendEvent;
    Display* display;
    XWindow requestor;
    Atom selection, target, property;
    Time time;
  }

  struct XPropertyEvent {
    int type;
    c_ulong serial;
    Bool sendEvent;
    Display* display;
    XWindow window;
    Atom atom;
    Time time;
    int state;
  }

  union XEvent {
    int type;
    XAnyEvent xany;
    XKeyEvent xkey;
    XButtonEvent xbutton;
    XMotionEvent xmotion;
    XConfigureEvent xconfigure;
    XClientMessageEvent xclient;
    XSelectionRequestEvent xselectionrequest;
    XSelectionEvent xselection;
    XPropertyEvent xproperty;
    c_long[24] pad;
  }

  struct XSizeHints {
    c_long flags;
    int x, y, width, height;
    int minWidth, minHeight;
    int maxWidth, maxHeight;
    int widthInc, heightInc;
    int minAspectX, minAspectY, maxAspectX, maxAspectY;
    int baseWidth, baseHeight;
    int winGravity;
  }

  Display* XOpenDisplay(const(char)*);
  int XCloseDisplay(Display*);
  int XDefaultScreen(Display*);
  XWindow XRootWindow(Display*, int);
  Visual* XDefaultVisual(Display*, int);
  int XDefaultDepth(Display*, int);
  GC XDefaultGC(Display*, int);
  XWindow XCreateSimpleWindow(Display*, XWindow, int, int, uint, uint, uint, c_ulong, c_ulong);
  int XDestroyWindow(Display*, XWindow);
  int XSelectInput(Display*, XWindow, c_long);
  int XMapWindow(Display*, XWindow);
  Atom XInternAtom(Display*, const(char)*, Bool);
  Status XSetWMProtocols(Display*, XWindow, Atom*, int);
  int XChangeProperty(Display*, XWindow, Atom, Atom, int, int, const(void)*, int);
  int XDeleteProperty(Display*, XWindow, Atom);
  int XGetWindowProperty(Display*, XWindow, Atom, c_long, c_long, Bool, Atom, Atom*, int*, c_ulong*,
    c_ulong*, ubyte**);
  int XPending(Display*);
  int XNextEvent(Display*, XEvent*);
  Bool XCheckTypedWindowEvent(Display*, XWindow, int, XEvent*);
  int XConnectionNumber(Display*);
  int XFlush(Display*);
  int XPutImage(Display*, XWindow, GC, XImage*, int, int, int, int, uint, uint);
  Status XInitImage(XImage*);
  int XFree(void*);
  c_ulong XCreateFontCursor(Display*, uint);
  int XDefineCursor(Display*, XWindow, c_ulong);
  KeySym XLookupKeysym(XKeyEvent*, int);
  int XLookupString(XKeyEvent*, char*, int, KeySym*, void*);
  char* XSetLocaleModifiers(const(char)*);
  XIM XOpenIM(Display*, void*, char*, char*);
  XIC XCreateIC(XIM, ...);
  void XSetICFocus(XIC);
  void XUnsetICFocus(XIC);
  int Xutf8LookupString(XIC, XKeyEvent*, char*, int, KeySym*, Status*);
  Bool XFilterEvent(XEvent*, XWindow);
  char* XResourceManagerString(Display*);
  int XSetSelectionOwner(Display*, Atom, XWindow, Time);
  XWindow XGetSelectionOwner(Display*, Atom);
  int XConvertSelection(Display*, Atom, Atom, Atom, XWindow, Time);
  Status XSendEvent(Display*, XWindow, Bool, c_long, XEvent*);
  c_long XExtendedMaxRequestSize(Display*);
  c_long XMaxRequestSize(Display*);
  void XSetWMNormalHints(Display*, XWindow, XSizeHints*);
}

private enum {
  KeyPress = 2, KeyRelease = 3, ButtonPress = 4, ButtonRelease = 5, MotionNotify = 6,
  FocusIn = 9, FocusOut = 10, Expose = 12, ConfigureNotify = 22, PropertyNotify = 28,
  SelectionClear = 29, SelectionRequest = 30, SelectionNotify = 31, ClientMessage = 33,
}

private enum : c_long {
  KeyPressMask = 1 << 0, KeyReleaseMask = 1 << 1, ButtonPressMask = 1 << 2, ButtonReleaseMask = 1 << 3,
  PointerMotionMask = 1 << 6, ExposureMask = 1 << 15, StructureNotifyMask = 1 << 17,
  FocusChangeMask = 1 << 21, PropertyChangeMask = 1 << 22,
}

private enum ZPixmap = 2;
private enum PropModeReplace = 0;
private enum PropModeAppend = 2;
private enum XA_ATOM = 4;
private enum XA_CARDINAL = 6;
private enum XA_STRING = 31;
private enum XA_WM_NAME = 39;
private enum CurrentTime = 0;
private enum PropertyNewValue = 0;
private enum PropertyDelete = 1;
private enum AnyPropertyType = 0;
private enum PMinSize = 1 << 4;
private enum XIMPreeditNothing = 0x0008;
private enum XIMStatusNothing = 0x0400;

final class X11Window : Window {
  private Display* dpy;
  private XWindow win;
  private int screen;
  private GC gc;
  private XIM im;
  private XIC ic;
  private Event[] queue;

  private int w, h;
  private float dpiScale = 1;
  private Cursor currentCursor = Cursor.arrow;
  private c_ulong[Cursor] cursors;

  private Time lastClickTime;
  private int lastClickX, lastClickY;
  private uint lastClickButton;
  private int clickCount;

  private string clipboardText;
  private IncrTransfer[] transfers;
  private size_t maxChunk;

  private XWindow dndSource;
  private int dndVersion;

  private Atom wmDelete, wmProtocols, netWmName, netWmIcon, utf8String, clipboard, targets, incr, textAtom,
    textPlain, selectionProp, xdndAware, xdndEnter, xdndPosition, xdndStatus, xdndLeave, xdndDrop,
    xdndFinished, xdndSelection, xdndActionCopy, uriList;

  private static struct IncrTransfer {
    XWindow requestor;
    Atom property;
    Atom target;
    size_t offset;
    bool finished;
  }

  this(string title, int width, int height) {
    setlocale(LC_ALL, "");
    XSetLocaleModifiers("");

    dpy = XOpenDisplay(null);
    if (dpy is null) {
      throw new Exception("Can't connect to X server, use --tui for terminal mode");
    }

    screen = XDefaultScreen(dpy);
    readScale();

    w = cast(int)(width * dpiScale);
    h = cast(int)(height * dpiScale);
    win = XCreateSimpleWindow(dpy, XRootWindow(dpy, screen), 0, 0, w, h, 0, 0, 0);
    gc = XDefaultGC(dpy, screen);
    XSelectInput(dpy, win, KeyPressMask | KeyReleaseMask | ButtonPressMask | ButtonReleaseMask |
      PointerMotionMask | ExposureMask | StructureNotifyMask | FocusChangeMask | PropertyChangeMask);

    internAtoms();
    XSetWMProtocols(dpy, win, &wmDelete, 1);

    auto wmClass = "jsonview\0JSON Viewer\0";

    XChangeProperty(dpy, win, XInternAtom(dpy, "WM_CLASS", 0), XA_STRING, 8, PropModeReplace,
      wmClass.ptr, cast(int)wmClass.length);
    int dndProtocol = 5;

    XChangeProperty(dpy, win, xdndAware, XA_ATOM, 32, PropModeReplace, &dndProtocol, 1);

    XSizeHints hints;

    hints.flags = PMinSize;
    hints.minWidth = cast(int)(480 * dpiScale);
    hints.minHeight = cast(int)(320 * dpiScale);
    XSetWMNormalHints(dpy, win, &hints);

    setTitle(title);

    im = XOpenIM(dpy, null, null, null);
    if (im !is null) {
      ic = XCreateIC(im, "inputStyle".ptr, cast(c_long)(XIMPreeditNothing | XIMStatusNothing),
        "clientWindow".ptr, win, "focusWindow".ptr, win, null);
    }

    auto maxRequest = XExtendedMaxRequestSize(dpy);

    if (!maxRequest) {
      maxRequest = XMaxRequestSize(dpy);
    }

    maxChunk = maxRequest > 0 ? cast(size_t)maxRequest * 4 - 1024 : 64 * 1024;
    if (maxChunk > 1 << 20) {
      maxChunk = 1 << 20;
    }

    XMapWindow(dpy, win);
    XFlush(dpy);
  }

  private void internAtoms() {
    Atom atom(string name) { return XInternAtom(dpy, name.toStringz, 0); }
    wmDelete = atom("WM_DELETE_WINDOW");
    wmProtocols = atom("WM_PROTOCOLS");
    netWmName = atom("_NET_WM_NAME");
    netWmIcon = atom("_NET_WM_ICON");
    utf8String = atom("UTF8_STRING");
    clipboard = atom("CLIPBOARD");
    targets = atom("TARGETS");
    incr = atom("INCR");
    textAtom = atom("TEXT");
    textPlain = atom("text/plain;charset=utf-8");
    selectionProp = atom("JSONVIEW_SELECTION");
    xdndAware = atom("XdndAware");
    xdndEnter = atom("XdndEnter");
    xdndPosition = atom("XdndPosition");
    xdndStatus = atom("XdndStatus");
    xdndLeave = atom("XdndLeave");
    xdndDrop = atom("XdndDrop");
    xdndFinished = atom("XdndFinished");
    xdndSelection = atom("XdndSelection");
    xdndActionCopy = atom("XdndActionCopy");
    uriList = atom("text/uri-list");
  }

  /// KDE and other desktops publish their scaling through Xft.dpi
  private void readScale() {
    auto res = XResourceManagerString(dpy);

    if (res is null) {
      return;
    }

    foreach (line; res.fromStringz.idup.splitLines) {
      auto colon = line.indexOf(':');

      if (colon < 0 || line[0 .. colon].strip != "Xft.dpi") {
        continue;
      }

      try {
        auto dpi = line[colon + 1 .. $].strip.to!float;

        if (dpi >= 48 && dpi <= 480) {
          dpiScale = dpi / 96;
        }
      } catch (Exception) {
      }
    }
  }

  @property int width() { return w; }
  @property int height() { return h; }
  float scale() { return dpiScale; }
  ulong nativeHandle() { return win; }

  void setDarkTitleBar(bool dark) {}
  void setLiveResize(void delegate(int, int) handler) {}

  void setTitle(string title) {
    XChangeProperty(dpy, win, netWmName, utf8String, 8, PropModeReplace, title.ptr, cast(int)title.length);
    XChangeProperty(dpy, win, XA_WM_NAME, utf8String, 8, PropModeReplace, title.ptr, cast(int)title.length);
  }

  void setIcon(const(uint)[] argb, int size) {
    // format 32 properties are arrays of longs in Xlib, whatever the long size is
    auto data = new c_ulong[2 + argb.length];

    data[0] = size;
    data[1] = size;
    foreach (k, p; argb) {
      data[2 + k] = p;
    }

    XChangeProperty(dpy, win, netWmIcon, XA_CARDINAL, 32, PropModeReplace, data.ptr, cast(int)data.length);
  }

  void setCursor(Cursor c) {
    if (c == currentCursor) {
      return;
    }

    currentCursor = c;
    if (c !in cursors) {
      uint shape;

      final switch (c) {
        case Cursor.arrow: shape = 68; break;
        case Cursor.text: shape = 152; break;
        case Cursor.resizeH: shape = 108; break;
        case Cursor.resizeV: shape = 116; break;
        case Cursor.hand: shape = 60; break;
      }
      cursors[c] = XCreateFontCursor(dpy, shape);
    }

    XDefineCursor(dpy, win, cursors[c]);
    XFlush(dpy);
  }

  void present(const(uint)[] pixels, int width, int height) {
    XImage img;

    img.width = width;
    img.height = height;
    img.format = ZPixmap;
    img.data = cast(char*)pixels.ptr;
    img.byteOrder = 0;
    img.bitmapUnit = 32;
    img.bitmapBitOrder = 0;
    img.bitmapPad = 32;
    img.depth = XDefaultDepth(dpy, screen);
    img.bytesPerLine = width * 4;
    img.bitsPerPixel = 32;
    img.redMask = 0xFF0000;
    img.greenMask = 0xFF00;
    img.blueMask = 0xFF;
    XInitImage(&img);
    XPutImage(dpy, win, gc, &img, 0, 0, 0, 0, width, height);
    XFlush(dpy);
  }

  bool nextEvent(out Event ev, int timeoutMs) {
    auto deadline = MonoTime.currTime + timeoutMs.msecs;

    while (true) {
      while (!queue.length && XPending(dpy)) {
        XEvent xe;

        XNextEvent(dpy, &xe);
        if (XFilterEvent(&xe, 0)) {
          continue;
        }

        translate(xe);
      }

      if (queue.length) {
        ev = queue[0];
        queue = queue[1 .. $];

        return true;
      }

      XFlush(dpy);
      int wait = -1;

      if (timeoutMs >= 0) {
        auto left = (deadline - MonoTime.currTime).total!"msecs";

        if (left <= 0) {
          return false;
        }

        wait = cast(int)left;
      }

      pollfd p;

      p.fd = XConnectionNumber(dpy);
      p.events = POLLIN;
      if (poll(&p, 1, wait) <= 0 && timeoutMs >= 0) {
        return false;
      }
    }
  }

  void close() {
    if (dpy is null) {
      return;
    }

    XDestroyWindow(dpy, win);
    XCloseDisplay(dpy);
    dpy = null;
  }

  void setClipboard(string text) {
    clipboardText = text;
    XSetSelectionOwner(dpy, clipboard, win, CurrentTime);
    XFlush(dpy);
  }

  string getClipboard() {
    auto owner = XGetSelectionOwner(dpy, clipboard);

    if (owner == win) {
      return clipboardText;
    }

    if (!owner) {
      return null;
    }

    XDeleteProperty(dpy, win, selectionProp);
    XConvertSelection(dpy, clipboard, utf8String, selectionProp, win, CurrentTime);
    XFlush(dpy);

    XEvent xe;

    if (!waitFor(SelectionNotify, xe, 2000)) {
      return null;
    }

    if (xe.xselection.property == 0) {
      return null;
    }

    return readSelection(selectionProp);
  }

  private bool waitFor(int type, ref XEvent xe, int timeoutMs) {
    auto deadline = MonoTime.currTime + timeoutMs.msecs;

    while (MonoTime.currTime < deadline) {
      if (XCheckTypedWindowEvent(dpy, win, type, &xe)) {
        return true;
      }

      XEvent other;

      if (XCheckTypedWindowEvent(dpy, win, SelectionRequest, &other)) {
        translate(other);
      }

      pollfd p;

      p.fd = XConnectionNumber(dpy);
      p.events = POLLIN;
      poll(&p, 1, 10);
    }

    return false;
  }

  private string readSelection(Atom property) {
    Atom type;
    int format;
    c_ulong count, remaining;
    ubyte* data;

    XGetWindowProperty(dpy, win, property, 0, c_long.max / 4, 1, AnyPropertyType, &type, &format,
      &count, &remaining, &data);
    if (type == incr) {
      if (data) {
        XFree(data);
      }

      return readIncremental(property);
    }

    string res = data ? (cast(char*)data)[0 .. count].idup : null;

    if (data) {
      XFree(data);
    }

    return res;
  }

  // INCR: the owner sends the data in chunks, each time we delete the property
  private string readIncremental(Atom property) {
    char[] res;

    while (true) {
      XEvent xe;
      bool got = false;
      auto deadline = MonoTime.currTime + 2000.msecs;

      while (MonoTime.currTime < deadline) {
        if (XCheckTypedWindowEvent(dpy, win, PropertyNotify, &xe) &&
          xe.xproperty.atom == property && xe.xproperty.state == PropertyNewValue) {
          got = true;
          break;
        }
        pollfd p;

        p.fd = XConnectionNumber(dpy);
        p.events = POLLIN;
        poll(&p, 1, 10);
      }

      if (!got) {
        break;
      }

      Atom type;
      int format;
      c_ulong count, remaining;
      ubyte* data;

      XGetWindowProperty(dpy, win, property, 0, c_long.max / 4, 1, AnyPropertyType, &type, &format,
        &count, &remaining, &data);
      if (data) {
        res ~= (cast(char*)data)[0 .. count];
        XFree(data);
      }

      XFlush(dpy);
      if (!count) {
        break;
      }
    }

    return cast(string)res;
  }

  private void answerSelectionRequest(ref XSelectionRequestEvent req) {
    XEvent reply;

    reply.xselection.type = SelectionNotify;
    reply.xselection.requestor = req.requestor;
    reply.xselection.selection = req.selection;
    reply.xselection.target = req.target;
    reply.xselection.time = req.time;
    auto property = req.property ? req.property : req.target;

    reply.xselection.property = property;

    if (req.target == targets) {
      Atom[5] list = [targets, utf8String, XA_STRING, textAtom, textPlain];

      XChangeProperty(dpy, req.requestor, property, XA_ATOM, 32, PropModeReplace, list.ptr, list.length);
    } else if (req.target == utf8String || req.target == XA_STRING ||
      req.target == textAtom || req.target == textPlain) {
      if (clipboardText.length <= maxChunk) {
        XChangeProperty(dpy, req.requestor, property, req.target, 8, PropModeReplace,
          clipboardText.ptr, cast(int)clipboardText.length);
      } else {
        XSelectInput(dpy, req.requestor, PropertyChangeMask);
        c_ulong size = clipboardText.length;

        XChangeProperty(dpy, req.requestor, property, incr, 32, PropModeReplace, &size, 1);
        transfers ~= IncrTransfer(req.requestor, property, req.target, 0);
      }
    } else {
      reply.xselection.property = 0;
    }

    XSendEvent(dpy, req.requestor, 0, 0, &reply);
    XFlush(dpy);
  }

  private void continueTransfer(ref XPropertyEvent pe) {
    foreach (ref t; transfers) {
      if (t.finished || t.requestor != pe.window || t.property != pe.atom || pe.state != PropertyDelete) {
        continue;
      }

      auto left = clipboardText.length - t.offset;
      auto n = left < maxChunk ? left : maxChunk;

      XChangeProperty(dpy, t.requestor, t.property, t.target, 8, PropModeReplace,
        clipboardText.ptr + t.offset, cast(int)n);
      t.offset += n;
      if (n == 0) {
        t.finished = true;
      }

      XFlush(dpy);
    }

    import std.algorithm : remove;
    transfers = transfers.remove!(t => t.finished);
  }

  private void dndMessage(ref XClientMessageEvent cm) {
    if (cm.messageType == xdndEnter) {
      dndSource = cast(XWindow)cm.l[0];
      dndVersion = cast(int)(cm.l[1] >> 24);
    } else if (cm.messageType == xdndPosition) {
      XEvent reply;

      reply.xclient.type = ClientMessage;
      reply.xclient.window = cast(XWindow)cm.l[0];
      reply.xclient.messageType = xdndStatus;
      reply.xclient.format = 32;
      reply.xclient.l[0] = cast(c_long)win;
      reply.xclient.l[1] = 1;
      reply.xclient.l[4] = cast(c_long)xdndActionCopy;
      XSendEvent(dpy, cast(XWindow)cm.l[0], 0, 0, &reply);
      XFlush(dpy);
    } else if (cm.messageType == xdndDrop) {
      Time time = dndVersion >= 1 ? cast(Time)cm.l[2] : CurrentTime;

      XConvertSelection(dpy, xdndSelection, uriList, selectionProp, win, time);
      XFlush(dpy);
    } else if (cm.messageType == xdndLeave) {
      dndSource = 0;
    }
  }

  private void dndFinished(bool ok) {
    if (!dndSource) {
      return;
    }

    XEvent reply;

    reply.xclient.type = ClientMessage;
    reply.xclient.window = dndSource;
    reply.xclient.messageType = xdndFinished;
    reply.xclient.format = 32;
    reply.xclient.l[0] = cast(c_long)win;
    reply.xclient.l[1] = ok ? 1 : 0;
    reply.xclient.l[2] = ok ? cast(c_long)xdndActionCopy : 0;
    XSendEvent(dpy, dndSource, 0, 0, &reply);
    XFlush(dpy);
    dndSource = 0;
  }

  private void push(Event e) { queue ~= e; }

  private void translate(ref XEvent xe) {
    switch (xe.type) {
      case KeyPress:
        keyPress(xe.xkey);
        break;
      case ButtonPress:
      case ButtonRelease:
        button(xe.xbutton, xe.type == ButtonPress);
        break;
      case MotionNotify: {
        Event e;

        e.type = EventType.mouseMove;
        e.x = xe.xmotion.x;
        e.y = xe.xmotion.y;
        e.mods = mods(xe.xmotion.state);
        if (queue.length && queue[$ - 1].type == EventType.mouseMove) {
          queue[$ - 1] = e;
        } else {
          push(e);
        }

        break;
      }
      case ConfigureNotify:
        if (xe.xconfigure.width != w || xe.xconfigure.height != h) {
          w = xe.xconfigure.width;
          h = xe.xconfigure.height;
          Event e;

          e.type = EventType.resize;
          e.width = w;
          e.height = h;
          push(e);
        }

        break;
      case Expose:
        if (!queue.length || queue[$ - 1].type != EventType.expose) {
          push(Event(EventType.expose));
        }

        break;
      case FocusIn:
        if (ic) {
          XSetICFocus(ic);
        }

        push(Event(EventType.focusIn));
        break;
      case FocusOut:
        if (ic) {
          XUnsetICFocus(ic);
        }

        push(Event(EventType.focusOut));
        break;
      case ClientMessage:
        if (xe.xclient.messageType == wmProtocols && cast(Atom)xe.xclient.l[0] == wmDelete) {
          push(Event(EventType.close));
        } else {
          dndMessage(xe.xclient);
        }

        break;
      case SelectionRequest:
        answerSelectionRequest(xe.xselectionrequest);
        break;
      case SelectionClear:
        clipboardText = null;
        break;
      case SelectionNotify:
        if (xe.xselection.target == uriList) {
          auto files = parseUriList(xe.xselection.property ? readSelection(selectionProp) : null);

          dndFinished(files.length > 0);
          if (files.length) {
            Event e;

            e.type = EventType.drop;
            e.files = files;
            push(e);
          }
        }

        break;
      case PropertyNotify:
        if (transfers.length) {
          continueTransfer(xe.xproperty);
        }

        break;
      default:
        break;
    }
  }

  private void keyPress(ref XKeyEvent ke) {
    char[64] buf;
    KeySym sym;
    Status status;
    int len;

    if (ic) {
      len = Xutf8LookupString(ic, &ke, buf.ptr, buf.length, &sym, &status);
    } else {
      len = XLookupString(&ke, buf.ptr, buf.length, &sym, null);
    }

    Event e;

    e.type = EventType.keyDown;
    e.mods = mods(ke.state);
    // shortcuts should work with any keyboard layout, so letters come from the first group
    e.key = mapKey(XLookupKeysym(&ke, 0));
    if (e.key == Key.unknown) {
      e.key = mapKey(sym);
    }

    e.x = ke.x;
    e.y = ke.y;
    push(e);

    if (len > 0 && !(e.mods & (Mod.ctrl | Mod.meta)) && !(e.mods & Mod.alt && len == 1)) {
      auto text = buf[0 .. len].idup;

      if (text[0] >= 0x20 && text[0] != 0x7F) {
        Event t;

        t.type = EventType.text;
        t.text = text;
        push(t);
      }
    }
  }

  private void button(ref XButtonEvent be, bool pressed) {
    Event e;

    e.x = be.x;
    e.y = be.y;
    e.mods = mods(be.state);
    switch (be.button) {
      case 4: case 5: case 6: case 7:
        if (!pressed) {
          return;
        }

        e.type = EventType.wheel;
        if (be.button == 4) {
          e.wheelY = 1;
        } else if (be.button == 5) {
          e.wheelY = -1;
        } else if (be.button == 6) {
          e.wheelX = 1;
        } else {
          e.wheelX = -1;
        }

        if (e.shift && e.wheelY != 0) {
          e.wheelX = e.wheelY;
          e.wheelY = 0;
        }

        push(e);

        return;
      case 1: e.button = MouseButton.left; break;
      case 2: e.button = MouseButton.middle; break;
      case 3: e.button = MouseButton.right; break;
      default: return;
    }

    e.type = pressed ? EventType.mouseDown : EventType.mouseUp;
    if (pressed) {
      import std.math : abs;
      bool near = abs(be.x - lastClickX) < 5 && abs(be.y - lastClickY) < 5;

      if (be.button == lastClickButton && near && be.time - lastClickTime < 400) {
        clickCount++;
      } else {
        clickCount = 1;
      }

      lastClickTime = be.time;
      lastClickX = be.x;
      lastClickY = be.y;
      lastClickButton = be.button;
    }

    e.clicks = clickCount;
    push(e);
  }

  private static uint mods(uint state) {
    uint m;

    if (state & 1) {
      m |= Mod.shift;
    }

    if (state & 4) {
      m |= Mod.ctrl;
    }

    if (state & 8) {
      m |= Mod.alt;
    }

    if (state & 64) {
      m |= Mod.meta;
    }

    return m;
  }

  private static Key mapKey(KeySym s) {
    if (s >= 'a' && s <= 'z') {
      return cast(Key)(Key.a + (s - 'a'));
    }

    if (s >= 'A' && s <= 'Z') {
      return cast(Key)(Key.a + (s - 'A'));
    }

    if (s >= '0' && s <= '9') {
      return cast(Key)(Key.num0 + (s - '0'));
    }

    if (s >= 0xFFBE && s <= 0xFFC9) {
      return cast(Key)(Key.f1 + (s - 0xFFBE));
    }

    switch (s) {
      case 0xFF1B: return Key.escape;
      case 0xFF0D: case 0xFF8D: return Key.enter;
      case 0xFF09: case 0xFE20: return Key.tab;
      case 0xFF08: return Key.backspace;
      case 0xFFFF: case 0xFF9F: return Key.del;
      case 0xFF63: case 0xFF9E: return Key.insert;
      case 0xFF51: case 0xFF96: return Key.left;
      case 0xFF52: case 0xFF97: return Key.up;
      case 0xFF53: case 0xFF98: return Key.right;
      case 0xFF54: case 0xFF99: return Key.down;
      case 0xFF50: case 0xFF95: return Key.home;
      case 0xFF57: case 0xFF9C: return Key.end;
      case 0xFF55: case 0xFF9A: return Key.pageUp;
      case 0xFF56: case 0xFF9B: return Key.pageDown;
      case 0xFF67: return Key.menu;
      case 0x20: return Key.space;
      case 0x2D: case 0xFFAD: return Key.minus;
      case 0x2B: case 0x3D: case 0xFFAB: return Key.plus;
      default: return Key.unknown;
    }
  }
}

string[] parseUriList(string list) {
  import std.uri : decodeComponent;

  string[] files;

  foreach (line; list.splitLines) {
    line = line.strip;
    if (!line.length || line[0] == '#') {
      continue;
    }

    if (line.length > 7 && line[0 .. 7] == "file://") {
      auto rest = line[7 .. $];
      auto slash = rest.indexOf('/');

      if (slash < 0) {
        continue;
      }

      try {
        files ~= decodeComponent(rest[slash .. $]);
      } catch (Exception) {
        files ~= rest[slash .. $];
      }
    }
  }

  return files;
}
