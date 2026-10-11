module platform.wayland;

version (linux):

import core.stdc.string : memcpy;
import core.sys.linux.dlfcn : dlopen, dlsym, RTLD_NOW, RTLD_LOCAL;
import core.sys.posix.poll;
import core.sys.posix.sys.mman : mmap, munmap, PROT_READ, PROT_WRITE, MAP_SHARED, MAP_FAILED, MAP_PRIVATE;
import core.sys.posix.unistd : posixClose = close, ftruncate, pipe, read, write;
import core.thread : Thread;
import core.time : MonoTime, msecs;
import std.string : toStringz, fromStringz;

import platform.window;
import platform.x11 : parseUriList;

private extern (C) {
  struct wl_proxy;
  struct wl_display;

  struct wl_message {
    const(char)* name;
    const(char)* signature;
    const(wl_interface*)* types;
  }

  struct wl_interface {
    const(char)* name;
    int version_;
    int methodCount;

    const(wl_message)* methods;
    int eventCount;

    const(wl_message)* events;
  }

  struct wl_array {
    size_t size;
    size_t alloc;
    void* data;
  }

  int memfd_create(const(char)*, uint);
}

private alias wl_display_connect_fn = extern (C) wl_display* function(const(char)*);
private alias wl_display_disconnect_fn = extern (C) void function(wl_display*);
private alias wl_display_get_fd_fn = extern (C) int function(wl_display*);
private alias wl_display_dispatch_pending_fn = extern (C) int function(wl_display*);
private alias wl_display_flush_fn = extern (C) int function(wl_display*);
private alias wl_display_roundtrip_fn = extern (C) int function(wl_display*);
private alias wl_display_prepare_read_fn = extern (C) int function(wl_display*);
private alias wl_display_read_events_fn = extern (C) int function(wl_display*);
private alias wl_display_cancel_read_fn = extern (C) void function(wl_display*);

private alias wl_proxy_marshal_flags_fn = extern (C) wl_proxy* function(wl_proxy*, uint,
  const(wl_interface)*, uint, uint, ...);
private alias wl_proxy_add_listener_fn = extern (C) int function(wl_proxy*, void*, void*);
private alias wl_proxy_get_version_fn = extern (C) uint function(wl_proxy*);
private alias wl_proxy_destroy_fn = extern (C) void function(wl_proxy*);
private alias xkb_context_new_fn = extern (C) void* function(int);
private alias xkb_keymap_new_from_string_fn = extern (C) void* function(void*, const(char)*, int, int);
private alias xkb_keymap_unref_fn = extern (C) void function(void*);
private alias xkb_state_new_fn = extern (C) void* function(void*);
private alias xkb_state_unref_fn = extern (C) void function(void*);
private alias xkb_state_update_mask_fn = extern (C) int function(void*, uint, uint, uint, uint, uint, uint);
private alias xkb_state_key_get_one_sym_fn = extern (C) uint function(void*, uint);
private alias xkb_state_key_get_utf8_fn = extern (C) int function(void*, uint, char*, size_t);
private alias xkb_state_mod_name_is_active_fn = extern (C) int function(void*, const(char)*, int);
private alias xkb_keymap_key_repeats_fn = extern (C) int function(void*, uint);

private alias xkb_keymap_key_get_syms_by_level_fn = extern (C) int function(void*, uint, uint, uint,
  const(uint)**);

// pointers have D linkage on purpose: with C names they would replace the
// library's own functions for the library itself
private __gshared {
  wl_display_connect_fn wl_display_connect;
  wl_display_disconnect_fn wl_display_disconnect;
  wl_display_get_fd_fn wl_display_get_fd;
  wl_display_dispatch_pending_fn wl_display_dispatch_pending;
  wl_display_flush_fn wl_display_flush;
  wl_display_roundtrip_fn wl_display_roundtrip;
  wl_display_prepare_read_fn wl_display_prepare_read;
  wl_display_read_events_fn wl_display_read_events;
  wl_display_cancel_read_fn wl_display_cancel_read;
  wl_proxy_marshal_flags_fn wl_proxy_marshal_flags;
  wl_proxy_add_listener_fn wl_proxy_add_listener;
  wl_proxy_get_version_fn wl_proxy_get_version;
  wl_proxy_destroy_fn wl_proxy_destroy;

  const(wl_interface)* registryIface, compositorIface, surfaceIface, shmIface, shmPoolIface, bufferIface,
    seatIface, pointerIface, keyboardIface, callbackIface, regionIface, outputIface,
    dataManagerIface, dataDeviceIface, dataSourceIface, dataOfferIface;

  xkb_context_new_fn xkb_context_new;
  xkb_keymap_new_from_string_fn xkb_keymap_new_from_string;
  xkb_keymap_unref_fn xkb_keymap_unref;
  xkb_state_new_fn xkb_state_new;
  xkb_state_unref_fn xkb_state_unref;
  xkb_state_update_mask_fn xkb_state_update_mask;
  xkb_state_key_get_one_sym_fn xkb_state_key_get_one_sym;
  xkb_state_key_get_utf8_fn xkb_state_key_get_utf8;
  xkb_state_mod_name_is_active_fn xkb_state_mod_name_is_active;
  xkb_keymap_key_repeats_fn xkb_keymap_key_repeats;
  xkb_keymap_key_get_syms_by_level_fn xkb_keymap_key_get_syms_by_level;

  bool loaded;
  bool loadFailed;
}

bool loadWayland() {
  if (loaded) {
    return true;
  }

  if (loadFailed) {
    return false;
  }

  loadFailed = true;

  auto wl = dlopen("libwayland-client.so.0", RTLD_NOW | RTLD_LOCAL);
  auto xkb = dlopen("libxkbcommon.so.0", RTLD_NOW | RTLD_LOCAL);

  if (wl is null || xkb is null) {
    return false;
  }

  bool ok = true;

  void sym(T)(ref T fn, void* lib, string name) {
    fn = cast(T)dlsym(lib, name.toStringz);
    if (fn is null) {
      ok = false;
    }
  }
  const(wl_interface)* iface(string name) {
    auto p = cast(const(wl_interface)*)dlsym(wl, name.toStringz);

    if (p is null) {
      ok = false;
    }

    return p;
  }

  sym(wl_display_connect, wl, "wl_display_connect");
  sym(wl_display_disconnect, wl, "wl_display_disconnect");
  sym(wl_display_get_fd, wl, "wl_display_get_fd");
  sym(wl_display_dispatch_pending, wl, "wl_display_dispatch_pending");
  sym(wl_display_flush, wl, "wl_display_flush");
  sym(wl_display_roundtrip, wl, "wl_display_roundtrip");
  sym(wl_display_prepare_read, wl, "wl_display_prepare_read");
  sym(wl_display_read_events, wl, "wl_display_read_events");
  sym(wl_display_cancel_read, wl, "wl_display_cancel_read");
  sym(wl_proxy_marshal_flags, wl, "wl_proxy_marshal_flags");
  sym(wl_proxy_add_listener, wl, "wl_proxy_add_listener");
  sym(wl_proxy_get_version, wl, "wl_proxy_get_version");
  sym(wl_proxy_destroy, wl, "wl_proxy_destroy");

  registryIface = iface("wl_registry_interface");
  compositorIface = iface("wl_compositor_interface");
  surfaceIface = iface("wl_surface_interface");
  shmIface = iface("wl_shm_interface");
  shmPoolIface = iface("wl_shm_pool_interface");
  bufferIface = iface("wl_buffer_interface");
  seatIface = iface("wl_seat_interface");
  pointerIface = iface("wl_pointer_interface");
  keyboardIface = iface("wl_keyboard_interface");
  callbackIface = iface("wl_callback_interface");
  regionIface = iface("wl_region_interface");
  outputIface = iface("wl_output_interface");
  dataManagerIface = iface("wl_data_device_manager_interface");
  dataDeviceIface = iface("wl_data_device_interface");
  dataSourceIface = iface("wl_data_source_interface");
  dataOfferIface = iface("wl_data_offer_interface");

  sym(xkb_context_new, xkb, "xkb_context_new");
  sym(xkb_keymap_new_from_string, xkb, "xkb_keymap_new_from_string");
  sym(xkb_keymap_unref, xkb, "xkb_keymap_unref");
  sym(xkb_state_new, xkb, "xkb_state_new");
  sym(xkb_state_unref, xkb, "xkb_state_unref");
  sym(xkb_state_update_mask, xkb, "xkb_state_update_mask");
  sym(xkb_state_key_get_one_sym, xkb, "xkb_state_key_get_one_sym");
  sym(xkb_state_key_get_utf8, xkb, "xkb_state_key_get_utf8");
  sym(xkb_state_mod_name_is_active, xkb, "xkb_state_mod_name_is_active");
  sym(xkb_keymap_key_repeats, xkb, "xkb_keymap_key_repeats");
  sym(xkb_keymap_key_get_syms_by_level, xkb, "xkb_keymap_key_get_syms_by_level");
  if (!ok) {
    return false;
  }

  defineProtocols();
  loaded = true;
  loadFailed = false;

  return true;
}

private __gshared {
  wl_interface xdgWmBase, xdgPositioner, xdgSurface, xdgToplevel, xdgPopup;
  wl_interface decorationManager, toplevelDecoration;
  wl_interface fractionalManager, fractionalScale;
  wl_interface viewporter, viewport;
  wl_interface cursorShapeManager, cursorShapeDevice;
}

private wl_message msg(string name, string signature, const(wl_interface)*[] types...) {
  auto t = types.dup;

  return wl_message(name.toStringz, signature.toStringz, t.length ? t.ptr : null);
}

private void define(ref wl_interface iface, string name, int ver, wl_message[] methods, wl_message[] events) {
  iface.name = name.toStringz;
  iface.version_ = ver;
  iface.methodCount = cast(int)methods.length;
  iface.methods = methods.length ? methods.ptr : null;
  iface.eventCount = cast(int)events.length;
  iface.events = events.length ? events.ptr : null;
}

// Signatures are copied from the protocol XML files (wayland-protocols)
private void defineProtocols() {
  const(wl_interface)* none = null;

  define(xdgWmBase, "xdg_wm_base", 2, [
    msg("destroy", ""),
    msg("create_positioner", "n", &xdgPositioner),
    msg("get_xdg_surface", "no", &xdgSurface, surfaceIface),
    msg("pong", "u", none),
  ], [msg("ping", "u", none)]);

  define(xdgPositioner, "xdg_positioner", 1, [
    msg("destroy", ""),
    msg("set_size", "ii", none, none),
    msg("set_anchor_rect", "iiii", none, none, none, none),
    msg("set_anchor", "u", none),
    msg("set_gravity", "u", none),
    msg("set_constraint_adjustment", "u", none),
    msg("set_offset", "ii", none, none),
  ], null);

  define(xdgSurface, "xdg_surface", 2, [
    msg("destroy", ""),
    msg("get_toplevel", "n", &xdgToplevel),
    msg("get_popup", "n?oo", &xdgPopup, &xdgSurface, &xdgPositioner),
    msg("set_window_geometry", "iiii", none, none, none, none),
    msg("ack_configure", "u", none),
  ], [msg("configure", "u", none)]);

  define(xdgToplevel, "xdg_toplevel", 2, [
    msg("destroy", ""),
    msg("set_parent", "?o", &xdgToplevel),
    msg("set_title", "s", none),
    msg("set_app_id", "s", none),
    msg("show_window_menu", "ouii", seatIface, none, none, none),
    msg("move", "ou", seatIface, none),
    msg("resize", "ouu", seatIface, none, none),
    msg("set_max_size", "ii", none, none),
    msg("set_min_size", "ii", none, none),
    msg("set_maximized", ""),
    msg("unset_maximized", ""),
    msg("set_fullscreen", "?o", outputIface),
    msg("unset_fullscreen", ""),
    msg("set_minimized", ""),
  ], [
    msg("configure", "iia", none, none, none),
    msg("close", ""),
  ]);

  define(xdgPopup, "xdg_popup", 1, [
    msg("destroy", ""),
    msg("grab", "ou", seatIface, none),
  ], [
    msg("configure", "iiii", none, none, none, none),
    msg("popup_done", ""),
  ]);

  define(decorationManager, "zxdg_decoration_manager_v1", 1, [
    msg("destroy", ""),
    msg("get_toplevel_decoration", "no", &toplevelDecoration, &xdgToplevel),
  ], null);

  define(toplevelDecoration, "zxdg_toplevel_decoration_v1", 1, [
    msg("destroy", ""),
    msg("set_mode", "u", none),
    msg("unset_mode", ""),
  ], [msg("configure", "u", none)]);

  define(fractionalManager, "wp_fractional_scale_manager_v1", 1, [
    msg("destroy", ""),
    msg("get_fractional_scale", "no", &fractionalScale, surfaceIface),
  ], null);

  define(fractionalScale, "wp_fractional_scale_v1", 1, [msg("destroy", "")],
    [msg("preferred_scale", "u", none)]);

  define(viewporter, "wp_viewporter", 1, [
    msg("destroy", ""),
    msg("get_viewport", "no", &viewport, surfaceIface),
  ], null);

  define(viewport, "wp_viewport", 1, [
    msg("destroy", ""),
    msg("set_source", "ffff", none, none, none, none),
    msg("set_destination", "ii", none, none),
  ], null);

  define(cursorShapeManager, "wp_cursor_shape_manager_v1", 1, [
    msg("destroy", ""),
    msg("get_pointer", "no", &cursorShapeDevice, pointerIface),
  ], null);

  define(cursorShapeDevice, "wp_cursor_shape_device_v1", 1, [
    msg("destroy", ""),
    msg("set_shape", "uu", none, none),
  ], null);
}

private enum destroyFlag = 1;

private wl_proxy* create(A...)(wl_proxy* p, uint opcode, const(wl_interface)* iface, A args) {
  return wl_proxy_marshal_flags(p, opcode, iface, wl_proxy_get_version(p), 0, args);
}

private void send(A...)(wl_proxy* p, uint opcode, A args) {
  wl_proxy_marshal_flags(p, opcode, null, wl_proxy_get_version(p), 0, args);
}

private void destroyProxy(wl_proxy* p, uint opcode = 0) {
  if (p is null) {
    return;
  }

  wl_proxy_marshal_flags(p, opcode, null, wl_proxy_get_version(p), destroyFlag);
}

private double fixed(int v) { return v / 256.0; }

final class WaylandWindow : Window {
  private wl_display* display;
  private wl_proxy* registry, compositor, shm, seat, wmBase, dataManager;
  private wl_proxy* decorations, fractional, viewporterObj, cursorShapes;
  private wl_proxy* surface, xdgSurf, toplevel, decoration, scaleObj, viewportObj;
  private wl_proxy* pointer, keyboard, cursorDevice, dataDevice;
  private uint compositorVersion;

  private Event[] queue;
  private int logicalW, logicalH;
  private int pendingW, pendingH;
  private bool configured;
  private float scaleFactor = 1;
  private int bufferScale = 1;

  private Buffer[2] buffers;

  private void* xkbContext, keymap, xkbState;
  private uint mods;
  private uint lastSerial;
  private uint pointerSerial;
  private int mouseX, mouseY;
  private float wheelAcc = 0, hwheelAcc = 0;
  private uint lastClickTime;
  private int lastClickX, lastClickY;
  private MouseButton lastClickButton;
  private int clickCount;
  private Cursor cursor = Cursor.arrow;

  private int repeatRate = 25, repeatDelay = 600;
  private uint repeatKey;
  private MonoTime repeatAt;

  private string clipboardText;
  private wl_proxy* clipboardSource;
  private wl_proxy* selectionOffer;
  private wl_proxy* dndOffer;
  private uint dndSerial;

  private string[][wl_proxy*] offerTypes;

  private static struct Buffer {
    wl_proxy* buffer;
    uint* pixels;
    size_t size;
    int width, height;
    bool busy;
  }

  this(string title, int width, int height) {
    if (!loadWayland()) {
      throw new Exception("Wayland libraries are not available");
    }

    display = wl_display_connect(null);
    if (display is null) {
      throw new Exception("Can't connect to Wayland compositor");
    }

    registry = create(cast(wl_proxy*)display, 1, registryIface, null);
    wl_proxy_add_listener(registry, cast(void*)&registryListener, cast(void*)this);
    wl_display_roundtrip(display);

    if (compositor is null || shm is null || wmBase is null) {
      wl_display_disconnect(display);
      throw new Exception("Compositor lacks required Wayland globals");
    }

    // without server side decorations the window would have no title bar,
    // X11 through XWayland looks better in that case
    if (decorations is null) {
      wl_display_disconnect(display);
      throw new Exception("Compositor doesn't draw window decorations");
    }

    xkbContext = xkb_context_new(0);
    surface = create(compositor, 0, surfaceIface, null);
    wl_proxy_add_listener(surface, cast(void*)&surfaceListener, cast(void*)this);
    if (fractional !is null && viewporterObj !is null) {
      scaleObj = create(fractional, 1, &fractionalScale, null, surface);
      wl_proxy_add_listener(scaleObj, cast(void*)&fractionalListener, cast(void*)this);
      viewportObj = create(viewporterObj, 1, &viewport, null, surface);
    }

    xdgSurf = create(wmBase, 2, &xdgSurface, null, surface);
    wl_proxy_add_listener(xdgSurf, cast(void*)&xdgSurfaceListener, cast(void*)this);
    toplevel = create(xdgSurf, 1, &xdgToplevel, null);
    wl_proxy_add_listener(toplevel, cast(void*)&toplevelListener, cast(void*)this);
    send(toplevel, 3, "jsonview".ptr);
    setTitle(title);
    send(toplevel, 8, 480, 320);

    decoration = create(decorations, 1, &toplevelDecoration, null, toplevel);
    wl_proxy_add_listener(decoration, cast(void*)&decorationListener, cast(void*)this);
    send(decoration, 1, 2u);

    logicalW = width;
    logicalH = height;
    send(surface, 6);
    while (!configured) {
      if (wl_display_roundtrip(display) < 0) {
        throw new Exception("Wayland connection lost");
      }
    }

    applyConfigure();
  }

  @property int width() { return pixelSize(logicalW); }
  @property int height() { return pixelSize(logicalH); }
  float scale() { return scaleFactor; }
  ulong nativeHandle() { return 0; }
  void setDarkTitleBar(bool dark) {}
  void setLiveResize(void delegate(int, int) handler) {}
  void setIcon(const(uint)[] argb, int size) {}

  private int pixelSize(int logical) {
    return cast(int)(logical * scaleFactor + 0.5f);
  }

  void setTitle(string title) {
    send(toplevel, 2, title.toStringz);
    wl_display_flush(display);
  }

  void setCursor(Cursor c) {
    cursor = c;
    applyCursor();
  }

  private void applyCursor() {
    if (cursorDevice is null || !pointerSerial) {
      return;
    }

    uint shape;

    final switch (cursor) {
      case Cursor.arrow: shape = 1; break;
      case Cursor.text: shape = 9; break;
      case Cursor.resizeH: shape = 26; break;
      case Cursor.resizeV: shape = 27; break;
      case Cursor.hand: shape = 4; break;
    }
    send(cursorDevice, 1, pointerSerial, shape);
    wl_display_flush(display);
  }

  void present(const(uint)[] pixels, int w, int h) {
    auto b = freeBuffer(w, h);

    if (b is null) {
      return;
    }

    memcpy(b.pixels, pixels.ptr, cast(size_t)w * h * 4);
    b.busy = true;
    send(surface, 1, b.buffer, 0, 0);
    send(surface, 9, 0, 0, w, h);
    send(surface, 6);
    wl_display_flush(display);
  }

  private Buffer* freeBuffer(int w, int h) {
    foreach (attempt; 0 .. 50) {
      foreach (ref b; buffers) {
        if (b.busy) {
          continue;
        }

        if (b.width != w || b.height != h) {
          releaseBuffer(b);
          if (!makeBuffer(b, w, h)) {
            return null;
          }
        }

        return &b;
      }

      dispatch(5);
    }

    return null;
  }

  private bool makeBuffer(ref Buffer b, int w, int h) {
    auto size = cast(size_t)w * h * 4;
    int fd = memfd_create("jsonview", 1);

    if (fd < 0 || ftruncate(fd, size) != 0) {
      return false;
    }

    auto mem = mmap(null, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);

    if (mem == MAP_FAILED) {
      posixClose(fd);

      return false;
    }

    auto pool = create(shm, 0, shmPoolIface, null, fd, cast(int)size);

    b.buffer = create(pool, 0, bufferIface, null, 0, w, h, w * 4, 1u);
    destroyProxy(pool, 1);
    posixClose(fd);
    wl_proxy_add_listener(b.buffer, cast(void*)&bufferListener, cast(void*)this);
    b.pixels = cast(uint*)mem;
    b.size = size;
    b.width = w;
    b.height = h;
    b.busy = false;

    return true;
  }

  private void releaseBuffer(ref Buffer b) {
    if (b.buffer is null) {
      return;
    }

    destroyProxy(b.buffer);
    munmap(b.pixels, b.size);
    b = Buffer.init;
  }

  bool nextEvent(out Event ev, int timeoutMs) {
    auto deadline = MonoTime.currTime + timeoutMs.msecs;

    while (true) {
      if (queue.length) {
        ev = queue[0];
        queue = queue[1 .. $];

        return true;
      }

      int wait = -1;
      auto now = MonoTime.currTime;

      if (timeoutMs >= 0) {
        auto left = (deadline - now).total!"msecs";

        if (left <= 0) {
          return false;
        }

        wait = cast(int)left;
      }

      if (repeatKey) {
        auto untilRepeat = cast(int)(repeatAt - now).total!"msecs";

        if (untilRepeat <= 0) {
          repeat();
          continue;
        }

        if (wait < 0 || untilRepeat < wait) {
          wait = untilRepeat;
        }
      }

      if (!dispatch(wait) && !repeatKey && timeoutMs >= 0 && MonoTime.currTime >= deadline) {
        return false;
      }
    }
  }

  private bool dispatch(int timeoutMs) {
    while (wl_display_prepare_read(display) != 0) {
      wl_display_dispatch_pending(display);
    }

    wl_display_flush(display);
    pollfd p;

    p.fd = wl_display_get_fd(display);
    p.events = POLLIN;
    bool got = poll(&p, 1, timeoutMs) > 0;

    if (got) {
      wl_display_read_events(display);
    } else {
      wl_display_cancel_read(display);
    }

    wl_display_dispatch_pending(display);

    return got;
  }

  void close() {
    if (display is null) {
      return;
    }

    foreach (ref b; buffers) {
      releaseBuffer(b);
    }

    wl_display_disconnect(display);
    display = null;
  }

  void setClipboard(string text) {
    if (dataDevice is null) {
      return;
    }

    clipboardText = text;
    if (clipboardSource !is null) {
      destroyProxy(clipboardSource, 1);
    }

    clipboardSource = create(dataManager, 0, dataSourceIface, null);
    wl_proxy_add_listener(clipboardSource, cast(void*)&dataSourceListener, cast(void*)this);
    foreach (mime; ["text/plain;charset=utf-8", "UTF8_STRING", "text/plain", "TEXT", "STRING"]) {
      send(clipboardSource, 0, mime.toStringz);
    }

    send(dataDevice, 1, clipboardSource, lastSerial);
    wl_display_flush(display);
  }

  string getClipboard() {
    if (clipboardSource !is null) {
      return clipboardText;
    }

    if (selectionOffer is null) {
      return null;
    }

    auto types = offerTypes.get(selectionOffer, null);
    string mime = "text/plain;charset=utf-8";

    foreach (t; types) {
      if (t == "text/plain;charset=utf-8") {
        mime = t;
        break;
      }

      if (t == "UTF8_STRING" || t == "text/plain") {
        mime = t;
      }
    }

    return receive(selectionOffer, mime);
  }

  private string receive(wl_proxy* offer, string mime) {
    int[2] fds;

    if (pipe(fds) != 0) {
      return null;
    }

    send(offer, 1, mime.toStringz, fds[1]);
    wl_display_flush(display);
    posixClose(fds[1]);

    char[] data;
    char[65_536] buf;
    auto deadline = MonoTime.currTime + 3000.msecs;

    while (MonoTime.currTime < deadline) {
      pollfd p;

      p.fd = fds[0];
      p.events = POLLIN;
      if (poll(&p, 1, 50) <= 0) {
        wl_display_dispatch_pending(display);
        wl_display_flush(display);
        continue;
      }

      auto n = read(fds[0], buf.ptr, buf.length);

      if (n <= 0) {
        break;
      }

      data ~= buf[0 .. n];
    }

    posixClose(fds[0]);

    return cast(string)data;
  }

  private void push(Event e) { queue ~= e; }

  private void applyConfigure() {
    bool changed = false;

    if (pendingW > 0 && pendingH > 0 && (pendingW != logicalW || pendingH != logicalH)) {
      logicalW = pendingW;
      logicalH = pendingH;
      changed = true;
    }

    updateViewport();
    Event e;

    e.type = changed ? EventType.resize : EventType.expose;
    e.width = width;
    e.height = height;
    push(e);
  }

  private void updateViewport() {
    if (viewportObj !is null) {
      send(viewportObj, 2, logicalW, logicalH);
    } else if (compositorVersion >= 3) {
      send(surface, 8, bufferScale);
    }
  }

  private void setScale(float s) {
    if (s == scaleFactor) {
      return;
    }

    scaleFactor = s;
    updateViewport();
    Event e;

    e.type = EventType.resize;
    e.width = width;
    e.height = height;
    push(e);
  }

  private void key(uint code, bool pressed) {
    uint xkbKey = code + 8;

    if (!pressed) {
      if (repeatKey == xkbKey) {
        repeatKey = 0;
      }

      return;
    }

    emitKey(xkbKey);
    if (keymap !is null && xkb_keymap_key_repeats(keymap, xkbKey) && repeatRate > 0) {
      repeatKey = xkbKey;
      repeatAt = MonoTime.currTime + repeatDelay.msecs;
    }
  }

  private void repeat() {
    emitKey(repeatKey);
    repeatAt = MonoTime.currTime + (1000 / repeatRate).msecs;
  }

  private void emitKey(uint xkbKey) {
    if (xkbState is null) {
      return;
    }

    Event e;

    e.type = EventType.keyDown;
    e.mods = mods;
    // shortcuts use the first layout, so Ctrl+C works with any keyboard layout
    const(uint)* syms;

    if (xkb_keymap_key_get_syms_by_level(keymap, xkbKey, 0, 0, &syms) > 0) {
      e.key = mapKeysym(syms[0]);
    }

    if (e.key == Key.unknown) {
      e.key = mapKeysym(xkb_state_key_get_one_sym(xkbState, xkbKey));
    }

    e.x = mouseX;
    e.y = mouseY;
    push(e);

    if (mods & (Mod.ctrl | Mod.meta | Mod.alt)) {
      return;
    }

    char[64] buf;
    auto n = xkb_state_key_get_utf8(xkbState, xkbKey, buf.ptr, buf.length);

    if (n > 0 && n < buf.length && cast(ubyte)buf[0] >= 0x20 && buf[0] != 0x7F) {
      Event t;

      t.type = EventType.text;
      t.text = buf[0 .. n].idup;
      push(t);
    }
  }

  private void updateMods(uint depressed, uint latched, uint locked, uint group) {
    if (xkbState is null) {
      return;
    }

    xkb_state_update_mask(xkbState, depressed, latched, locked, 0, 0, group);
    enum effective = 8;

    mods = 0;
    if (xkb_state_mod_name_is_active(xkbState, "Shift", effective) > 0) {
      mods |= Mod.shift;
    }

    if (xkb_state_mod_name_is_active(xkbState, "Control", effective) > 0) {
      mods |= Mod.ctrl;
    }

    if (xkb_state_mod_name_is_active(xkbState, "Mod1", effective) > 0) {
      mods |= Mod.alt;
    }

    if (xkb_state_mod_name_is_active(xkbState, "Mod4", effective) > 0) {
      mods |= Mod.meta;
    }
  }

  private void loadKeymap(int fd, uint size) {
    auto mem = mmap(null, size, PROT_READ, MAP_PRIVATE, fd, 0);

    posixClose(fd);
    if (mem == MAP_FAILED) {
      return;
    }

    auto km = xkb_keymap_new_from_string(xkbContext, cast(const(char)*)mem, 1, 0);

    munmap(mem, size);
    if (km is null) {
      return;
    }

    if (xkbState !is null) {
      xkb_state_unref(xkbState);
    }

    if (keymap !is null) {
      xkb_keymap_unref(keymap);
    }

    keymap = km;
    xkbState = xkb_state_new(km);
  }

  private void button(uint time, uint code, bool pressed) {
    Event e;

    e.x = mouseX;
    e.y = mouseY;
    e.mods = mods;
    switch (code) {
      case 0x110: e.button = MouseButton.left; break;
      case 0x111: e.button = MouseButton.right; break;
      case 0x112: e.button = MouseButton.middle; break;
      default: return;
    }

    e.type = pressed ? EventType.mouseDown : EventType.mouseUp;
    if (pressed) {
      import std.math : abs;
      bool near = abs(e.x - lastClickX) < 6 && abs(e.y - lastClickY) < 6;

      if (e.button == lastClickButton && near && time - lastClickTime < 400) {
        clickCount++;
      } else {
        clickCount = 1;
      }

      lastClickTime = time;
      lastClickX = e.x;
      lastClickY = e.y;
      lastClickButton = e.button;
    }

    e.clicks = clickCount;
    push(e);
  }

  private void axis(uint which, double value) {
    // one wheel notch is 15 units on most compositors, touchpads send small steps
    float* acc = which == 0 ? &wheelAcc : &hwheelAcc;

    *acc += value / 15;
    int lines = cast(int)*acc;

    if (!lines) {
      return;
    }

    *acc -= lines;
    Event e;

    e.type = EventType.wheel;
    e.x = mouseX;
    e.y = mouseY;
    e.mods = mods;
    if (which == 0 && !(mods & Mod.shift)) {
      e.wheelY = -lines;
    } else {
      e.wheelX = -lines;
    }

    push(e);
  }

  private void offerDrop() {
    if (dndOffer is null) {
      return;
    }

    auto text = receive(dndOffer, "text/uri-list");

    if (wl_proxy_get_version(dndOffer) >= 3) {
      send(dndOffer, 3);
    }

    auto files = parseUriList(text);

    if (files.length) {
      Event e;

      e.type = EventType.drop;
      e.files = files;
      push(e);
    }
  }

  private static WaylandWindow self(void* data) { return cast(WaylandWindow)data; }

  extern (C) static {
    void onGlobal(void* data, wl_proxy* reg, uint name, const(char)* iface, uint ver) {
      auto w = self(data);

      wl_proxy* bind(const(wl_interface)* i, uint want) {
        auto v = ver < want ? ver : want;

        return wl_proxy_marshal_flags(reg, 0, i, v, 0, name, i.name, v, null);
      }
      auto n = iface.fromStringz;

      switch (n) {
        case "wl_compositor":
          w.compositorVersion = ver < 6 ? ver : 6;
          w.compositor = bind(compositorIface, 6);
          break;
        case "wl_shm": w.shm = bind(shmIface, 1); break;
        case "xdg_wm_base":
          w.wmBase = bind(&xdgWmBase, 2);
          wl_proxy_add_listener(w.wmBase, cast(void*)&wmBaseListener, data);
          break;
        case "wl_seat":
          w.seat = bind(seatIface, 5);
          wl_proxy_add_listener(w.seat, cast(void*)&seatListener, data);
          break;
        case "zxdg_decoration_manager_v1": w.decorations = bind(&decorationManager, 1); break;
        case "wp_fractional_scale_manager_v1": w.fractional = bind(&fractionalManager, 1); break;
        case "wp_viewporter": w.viewporterObj = bind(&viewporter, 1); break;
        case "wp_cursor_shape_manager_v1": w.cursorShapes = bind(&cursorShapeManager, 1); break;
        case "wl_data_device_manager": w.dataManager = bind(dataManagerIface, 3); break;
        default: break;
      }

      if (w.seat !is null && w.dataManager !is null && w.dataDevice is null) {
        w.dataDevice = create(w.dataManager, 1, dataDeviceIface, null, w.seat);
        wl_proxy_add_listener(w.dataDevice, cast(void*)&dataDeviceListener, data);
      }
    }
    void onGlobalRemove(void*, wl_proxy*, uint) {}

    void onPing(void*, wl_proxy* base, uint serial) { send(base, 3, serial); }

    void onSurfaceEnter(void*, wl_proxy*, wl_proxy*) {}
    void onSurfaceLeave(void*, wl_proxy*, wl_proxy*) {}
    void onPreferredBufferScale(void* data, wl_proxy*, int s) {
      auto w = self(data);

      if (w.viewportObj !is null || s < 1) {
        return;
      }

      w.bufferScale = s;
      w.setScale(s);
    }
    void onPreferredTransform(void*, wl_proxy*, uint) {}

    void onFractionalScale(void* data, wl_proxy*, uint scale120) {
      self(data).setScale(scale120 / 120.0f);
    }

    void onXdgSurfaceConfigure(void* data, wl_proxy* s, uint serial) {
      auto w = self(data);

      send(s, 4, serial);
      if (w.configured) {
        w.applyConfigure();
      }

      w.configured = true;
    }

    void onToplevelConfigure(void* data, wl_proxy*, int width, int height, wl_array*) {
      auto w = self(data);

      w.pendingW = width;
      w.pendingH = height;
    }
    void onToplevelClose(void* data, wl_proxy*) { self(data).push(Event(EventType.close)); }

    void onDecorationConfigure(void*, wl_proxy*, uint) {}

    void onBufferRelease(void* data, wl_proxy* buf) {
      foreach (ref b; self(data).buffers) {
        if (b.buffer is buf) {
          b.busy = false;
        }
      }
    }

    void onSeatCapabilities(void* data, wl_proxy* seat, uint caps) {
      auto w = self(data);

      if ((caps & 1) && w.pointer is null) {
        w.pointer = create(seat, 0, pointerIface, null);
        wl_proxy_add_listener(w.pointer, cast(void*)&pointerListener, data);
        if (w.cursorShapes !is null) {
          w.cursorDevice = create(w.cursorShapes, 1, &cursorShapeDevice, null, w.pointer);
        }
      }

      if ((caps & 2) && w.keyboard is null) {
        w.keyboard = create(seat, 1, keyboardIface, null);
        wl_proxy_add_listener(w.keyboard, cast(void*)&keyboardListener, data);
      }
    }
    void onSeatName(void*, wl_proxy*, const(char)*) {}

    void onPointerEnter(void* data, wl_proxy*, uint serial, wl_proxy*, int x, int y) {
      auto w = self(data);

      w.pointerSerial = serial;
      w.mouseX = cast(int)(fixed(x) * w.scaleFactor);
      w.mouseY = cast(int)(fixed(y) * w.scaleFactor);
      w.applyCursor();
    }
    void onPointerLeave(void*, wl_proxy*, uint, wl_proxy*) {}
    void onPointerMotion(void* data, wl_proxy*, uint, int x, int y) {
      auto w = self(data);

      w.mouseX = cast(int)(fixed(x) * w.scaleFactor);
      w.mouseY = cast(int)(fixed(y) * w.scaleFactor);
      Event e;

      e.type = EventType.mouseMove;
      e.x = w.mouseX;
      e.y = w.mouseY;
      e.mods = w.mods;
      if (w.queue.length && w.queue[$ - 1].type == EventType.mouseMove) {
        w.queue[$ - 1] = e;
      } else {
        w.push(e);
      }
    }
    void onPointerButton(void* data, wl_proxy*, uint serial, uint time, uint button, uint state) {
      auto w = self(data);

      w.lastSerial = serial;
      w.button(time, button, state == 1);
    }
    void onPointerAxis(void* data, wl_proxy*, uint, uint which, int value) {
      self(data).axis(which, fixed(value));
    }
    void onPointerFrame(void*, wl_proxy*) {}
    void onPointerAxisSource(void*, wl_proxy*, uint) {}
    void onPointerAxisStop(void*, wl_proxy*, uint, uint) {}
    void onPointerAxisDiscrete(void*, wl_proxy*, uint, int) {}

    void onKeymap(void* data, wl_proxy*, uint format, int fd, uint size) {
      if (format != 1) {
        posixClose(fd);

        return;
      }

      self(data).loadKeymap(fd, size);
    }
    void onKeyboardEnter(void* data, wl_proxy*, uint serial, wl_proxy*, wl_array*) {
      auto w = self(data);

      w.lastSerial = serial;
      w.push(Event(EventType.focusIn));
    }
    void onKeyboardLeave(void* data, wl_proxy*, uint, wl_proxy*) {
      auto w = self(data);

      w.repeatKey = 0;
      w.push(Event(EventType.focusOut));
    }
    void onKey(void* data, wl_proxy*, uint serial, uint, uint key, uint state) {
      auto w = self(data);

      w.lastSerial = serial;
      w.key(key, state == 1);
    }
    void onModifiers(void* data, wl_proxy*, uint, uint depressed, uint latched, uint locked, uint group) {
      self(data).updateMods(depressed, latched, locked, group);
    }
    void onRepeatInfo(void* data, wl_proxy*, int rate, int delay) {
      auto w = self(data);

      w.repeatRate = rate;
      w.repeatDelay = delay;
    }

    void onDataOffer(void* data, wl_proxy*, wl_proxy* offer) {
      wl_proxy_add_listener(offer, cast(void*)&dataOfferListener, data);
      self(data).offerTypes[offer] = null;
    }
    void onDataEnter(void* data, wl_proxy*, uint serial, wl_proxy*, int, int, wl_proxy* offer) {
      auto w = self(data);

      w.dndOffer = offer;
      w.dndSerial = serial;
      if (offer is null) {
        return;
      }

      bool files = false;

      foreach (t; w.offerTypes.get(offer, null)) {
        if (t == "text/uri-list") {
          files = true;
        }
      }

      send(offer, 0, serial, files ? "text/uri-list".ptr : null);
      if (wl_proxy_get_version(offer) >= 3) {
        send(offer, 4, 1u, 1u);
      }
    }
    void onDataLeave(void* data, wl_proxy*) {
      auto w = self(data);

      if (w.dndOffer !is null) {
        forgetOffer(w, w.dndOffer);
      }

      w.dndOffer = null;
    }
    void onDataMotion(void*, wl_proxy*, uint, int, int) {}
    void onDataDrop(void* data, wl_proxy*) {
      auto w = self(data);

      w.offerDrop();
      if (w.dndOffer !is null) {
        forgetOffer(w, w.dndOffer);
      }

      w.dndOffer = null;
    }
    void onSelection(void* data, wl_proxy*, wl_proxy* offer) {
      auto w = self(data);

      if (w.selectionOffer !is null && w.selectionOffer !is offer) {
        forgetOffer(w, w.selectionOffer);
      }

      w.selectionOffer = offer;
    }

    void onOffer(void* data, wl_proxy* offer, const(char)* mime) {
      auto w = self(data);

      w.offerTypes[offer] ~= mime.fromStringz.idup;
    }
    void onSourceActions(void*, wl_proxy*, uint) {}
    void onAction(void*, wl_proxy*, uint) {}

    void onSourceTarget(void*, wl_proxy*, const(char)*) {}
    void onSourceSend(void* data, wl_proxy*, const(char)*, int fd) {
      // writing happens in a thread, a big copy must not block the window
      auto text = self(data).clipboardText;

      auto t = new Thread(() {
        size_t at = 0;

        while (at < text.length) {
          auto n = write(fd, text.ptr + at, text.length - at);

          if (n <= 0) {
            break;
          }

          at += n;
        }

        posixClose(fd);
      });
      t.isDaemon = true;
      t.start();
    }
    void onSourceCancelled(void* data, wl_proxy* source) {
      auto w = self(data);

      if (w.clipboardSource is source) {
        w.clipboardSource = null;
      }

      destroyProxy(source, 1);
    }
    void onSourceDndDropPerformed(void*, wl_proxy*) {}
    void onSourceDndFinished(void*, wl_proxy*) {}
    void onSourceAction(void*, wl_proxy*, uint) {}
  }

  private static void forgetOffer(WaylandWindow w, wl_proxy* offer) {
    w.offerTypes.remove(offer);
    destroyProxy(offer, 2);
  }
}

// Listener tables, in the same order as events in the protocol
private alias W = WaylandWindow;

private __gshared {
  void*[2] registryListener = [
    cast(void*)&W.onGlobal,
    cast(void*)&W.onGlobalRemove,
  ];
  void*[1] wmBaseListener = [
    cast(void*)&W.onPing,
  ];
  void*[4] surfaceListener = [
    cast(void*)&W.onSurfaceEnter,
    cast(void*)&W.onSurfaceLeave,
    cast(void*)&W.onPreferredBufferScale,
    cast(void*)&W.onPreferredTransform,
  ];
  void*[1] fractionalListener = [
    cast(void*)&W.onFractionalScale,
  ];
  void*[1] xdgSurfaceListener = [
    cast(void*)&W.onXdgSurfaceConfigure,
  ];
  void*[2] toplevelListener = [
    cast(void*)&W.onToplevelConfigure,
    cast(void*)&W.onToplevelClose,
  ];
  void*[1] decorationListener = [
    cast(void*)&W.onDecorationConfigure,
  ];
  void*[1] bufferListener = [
    cast(void*)&W.onBufferRelease,
  ];
  void*[2] seatListener = [
    cast(void*)&W.onSeatCapabilities,
    cast(void*)&W.onSeatName,
  ];
  void*[9] pointerListener = [
    cast(void*)&W.onPointerEnter,
    cast(void*)&W.onPointerLeave,
    cast(void*)&W.onPointerMotion,
    cast(void*)&W.onPointerButton,
    cast(void*)&W.onPointerAxis,
    cast(void*)&W.onPointerFrame,
    cast(void*)&W.onPointerAxisSource,
    cast(void*)&W.onPointerAxisStop,
    cast(void*)&W.onPointerAxisDiscrete,
  ];
  void*[6] keyboardListener = [
    cast(void*)&W.onKeymap,
    cast(void*)&W.onKeyboardEnter,
    cast(void*)&W.onKeyboardLeave,
    cast(void*)&W.onKey,
    cast(void*)&W.onModifiers,
    cast(void*)&W.onRepeatInfo,
  ];
  void*[6] dataDeviceListener = [
    cast(void*)&W.onDataOffer,
    cast(void*)&W.onDataEnter,
    cast(void*)&W.onDataLeave,
    cast(void*)&W.onDataMotion,
    cast(void*)&W.onDataDrop,
    cast(void*)&W.onSelection,
  ];
  void*[3] dataOfferListener = [
    cast(void*)&W.onOffer,
    cast(void*)&W.onSourceActions,
    cast(void*)&W.onAction,
  ];
  void*[6] dataSourceListener = [
    cast(void*)&W.onSourceTarget,
    cast(void*)&W.onSourceSend,
    cast(void*)&W.onSourceCancelled,
    cast(void*)&W.onSourceDndDropPerformed,
    cast(void*)&W.onSourceDndFinished,
    cast(void*)&W.onSourceAction,
  ];
}

private Key mapKeysym(uint s) {
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
