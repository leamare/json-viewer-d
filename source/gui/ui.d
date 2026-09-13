module gui.ui;

import std.algorithm : min, max;
import std.utf : stride, strideBack;

public import gui.canvas;
public import gui.font;
public import gui.theme;
public import platform.window;

final class Ui {
  Window window;
  Canvas canvas;
  Theme theme;
  Fonts fonts;
  float scale = 1;

  Widget focus;
  Widget capture;
  bool dirty = true;
  bool caretOn = true;

  this(Window w) {
    window = w;
    canvas = new Canvas;
    reload();
  }

  void reload() {
    scale = window.scale();
    theme = systemTheme();
    fonts = loadFonts(scale, theme.dark);
    window.setDarkTitleBar(theme.dark);
    dirty = true;
  }

  int px(float v) const { return cast(int)(v * scale + 0.5f); }

  @property int rowHeight() { return fonts.ui.lineHeight + px(5); }

  void invalidate() { dirty = true; }

  void setFocus(Widget w) {
    if (focus is w) {
      return;
    }

    auto old = focus;

    focus = w;
    if (old !is null) {
      old.focusChanged(false);
    }

    if (w !is null) {
      w.focusChanged(true);
    }

    caretOn = true;
    dirty = true;
  }

  void copy(string text) { window.setClipboard(text); }
  string paste() { return window.getClipboard(); }
}

abstract class Widget {
  Ui ui;
  Rect rect;
  bool visible = true;

  this(Ui ui) {
    this.ui = ui;
  }

  void layout(Rect r) { rect = r; }
  void draw(Canvas c) {}

  bool mouseDown(ref const Event e) { return false; }
  void mouseUp(ref const Event e) {}
  void mouseMove(ref const Event e) {}
  void mouseLeave() {}
  bool wheel(ref const Event e) { return false; }
  bool keyDown(ref const Event e) { return false; }
  bool textInput(string text) { return false; }
  void focusChanged(bool on) {}

  bool focusable() { return false; }
  Cursor cursorAt(int x, int y) { return Cursor.arrow; }

  @property bool focused() { return ui.focus is this; }
  bool contains(int x, int y) { return visible && rect.contains(x, y); }
}

struct ScrollBar {
  bool vertical = true;
  Rect rect;
  long total;
  long page;
  long pos;

  private bool dragging;
  private int dragStart;
  private long dragPos;

  @property bool needed() const { return total > page; }
  @property long maxPos() const { return total > page ? total - page : 0; }

  void clamp() {
    if (pos > maxPos) {
      pos = maxPos;
    }

    if (pos < 0) {
      pos = 0;
    }
  }

  Rect thumb() const {
    int length = vertical ? rect.h : rect.w;

    if (!needed || length <= 0) {
      return Rect(0, 0, 0, 0);
    }

    int size = max(cast(int)(cast(double)page / total * length), min(length, 24));
    int at = cast(int)(cast(double)pos / maxPos * (length - size));

    return vertical ? Rect(rect.x, rect.y + at, rect.w, size) : Rect(rect.x + at, rect.y, size, rect.h);
  }

  void draw(Canvas c, ref const Theme t, bool hot) {
    if (!needed) {
      return;
    }

    c.fill(rect, t.view);
    auto th = thumb().shrink(vertical ? 3 : 2, vertical ? 2 : 3);
    auto color = dragging || hot ? mix(t.view, t.text, 0.45) : mix(t.view, t.text, 0.25);

    c.roundRect(th, (vertical ? th.w : th.h) / 2.0f, color);
  }

  bool mouseDown(int x, int y) {
    if (!needed || !rect.contains(x, y)) {
      return false;
    }

    auto th = thumb();
    int v = vertical ? y : x;

    if (th.contains(x, y)) {
      dragging = true;
      dragStart = v;
      dragPos = pos;
    } else {
      int thumbStart = vertical ? th.y : th.x;

      pos += v < thumbStart ? -page : page;
      clamp();
    }

    return true;
  }

  bool mouseMove(int x, int y) {
    if (!dragging) {
      return false;
    }

    auto th = thumb();
    int length = (vertical ? rect.h : rect.w) - (vertical ? th.h : th.w);

    if (length <= 0) {
      return true;
    }

    int delta = (vertical ? y : x) - dragStart;

    pos = dragPos + cast(long)(cast(double)delta / length * maxPos);
    clamp();

    return true;
  }

  void mouseUp() { dragging = false; }
  @property bool isDragging() const { return dragging; }
}

final class LineEdit : Widget {
  string text;
  string placeholder;
  size_t cursor;
  size_t anchor;
  bool frame = true;

  void delegate() onChange;
  void delegate() onEnter;
  void delegate() onEscape;

  private int scrollX;
  private bool selecting;

  this(Ui ui) {
    super(ui);
  }

  override bool focusable() { return true; }
  override Cursor cursorAt(int x, int y) { return Cursor.text; }

  void setText(string s, bool selectAll = false) {
    text = s;
    cursor = s.length;
    anchor = selectAll ? 0 : cursor;
    scrollX = 0;
    ui.invalidate();
  }

  @property bool hasSelection() const { return anchor != cursor; }
  @property size_t selStart() const { return min(anchor, cursor); }
  @property size_t selEnd() const { return max(anchor, cursor); }

  override void draw(Canvas c) {
    auto t = ui.theme;
    auto f = ui.fonts.ui;

    if (frame) {
      c.roundRect(rect, ui.px(3), t.view, focused ? t.accent : t.border);
    }

    auto inner = rect.shrink(ui.px(6), 0);

    c.pushClip(inner);
    int ty = rect.y + (rect.h - f.lineHeight) / 2;

    int caretX = f.measure(text[0 .. cursor]);

    if (caretX - scrollX > inner.w - 2) {
      scrollX = caretX - inner.w + 2;
    }

    if (caretX - scrollX < 0) {
      scrollX = caretX;
    }

    int x0 = inner.x - scrollX;

    if (hasSelection && focused) {
      int a = f.measure(text[0 .. selStart]), b = f.measure(text[0 .. selEnd]);

      c.fill(Rect(x0 + a, ty, b - a, f.lineHeight), mix(t.view, t.selection, 0.45));
    }

    if (!text.length && placeholder.length && !focused) {
      c.text(f, inner.x, ty, placeholder, t.dimText);
    } else {
      c.text(f, x0, ty, text, t.text);
    }

    if (focused && ui.caretOn) {
      c.fill(Rect(x0 + caretX, ty, max(1, ui.px(1)), f.lineHeight), t.text);
    }

    c.popClip();
  }

  override bool mouseDown(ref const Event e) {
    ui.setFocus(this);
    auto pos = hit(e.x);

    if (e.clicks >= 2) {
      anchor = 0;
      cursor = text.length;
    } else {
      cursor = pos;
      if (!e.shift) {
        anchor = pos;
      }

      selecting = true;
    }

    ui.capture = this;
    ui.invalidate();

    return true;
  }

  override void mouseMove(ref const Event e) {
    if (!selecting) {
      return;
    }

    cursor = hit(e.x);
    ui.invalidate();
  }

  override void mouseUp(ref const Event e) { selecting = false; }

  private size_t hit(int x) {
    return ui.fonts.ui.hitTest(text, x - (rect.x + ui.px(6)) + scrollX);
  }

  override bool keyDown(ref const Event e) {
    bool shift = e.shift;

    switch (e.key) {
      case Key.left:
        if (hasSelection && !shift) {
          cursor = selStart;
        } else if (cursor) {
          cursor = e.ctrl ? wordLeft(cursor) : cursor - strideBack(text, cursor);
        }

        break;
      case Key.right:
        if (hasSelection && !shift) {
          cursor = selEnd;
        } else if (cursor < text.length) {
          cursor = e.ctrl ? wordRight(cursor) : cursor + stride(text, cursor);
        }

        break;
      case Key.home: cursor = 0; break;
      case Key.end: cursor = text.length; break;
      case Key.backspace:
        if (!hasSelection && cursor) {
          anchor = e.ctrl ? wordLeft(cursor) : cursor - strideBack(text, cursor);
        }

        replaceSelection("");

        return true;
      case Key.del:
        if (!hasSelection &&
          cursor < text.length) {
          anchor = e.ctrl ? wordRight(cursor) : cursor + stride(text, cursor);
        }

        replaceSelection("");

        return true;
      case Key.enter:
        if (onEnter) {
          onEnter();
        }

        return true;
      case Key.escape:
        if (onEscape) {
          onEscape();

          return true;
        }

        return false;
      case Key.a:
        if (!e.ctrl) {
          return false;
        }

        anchor = 0;
        cursor = text.length;
        ui.invalidate();

        return true;
      case Key.c:
      case Key.x:
        if (!e.ctrl) {
          return false;
        }

        if (hasSelection) {
          ui.copy(text[selStart .. selEnd]);
          if (e.key == Key.x) {
            replaceSelection("");
          }
        }

        return true;
      case Key.v:
        if (!e.ctrl) {
          return false;
        }

        import std.string : replace;
        replaceSelection(ui.paste().replace("\r", "").replace("\n", " "));

        return true;
      default:
        return false;
    }

    if (!shift) {
      anchor = cursor;
    }

    ui.caretOn = true;
    ui.invalidate();

    return true;
  }

  override bool textInput(string s) {
    replaceSelection(s);

    return true;
  }

  void replaceSelection(string s) {
    auto a = selStart, b = selEnd;

    text = text[0 .. a] ~ s ~ text[b .. $];
    cursor = anchor = a + s.length;
    ui.caretOn = true;
    ui.invalidate();
    if (onChange) {
      onChange();
    }
  }

  private size_t wordLeft(size_t i) {
    while (i > 0 && text[i - 1] == ' ') {
      i--;
    }

    while (i > 0 && text[i - 1] != ' ') {
      i--;
    }

    return i;
  }

  private size_t wordRight(size_t i) {
    while (i < text.length && text[i] != ' ') {
      i++;
    }

    while (i < text.length && text[i] == ' ') {
      i++;
    }

    return i;
  }
}

final class Button : Widget {
  string label;
  bool primary;
  bool enabled = true;

  void delegate() onClick;

  private bool pressed;
  private bool hot;

  this(Ui ui, string label, void delegate() onClick = null) {
    super(ui);
    this.label = label;
    this.onClick = onClick;
  }

  int preferredWidth() {
    return max(ui.px(80), ui.fonts.ui.measure(label) + ui.px(24));
  }

  override void draw(Canvas c) {
    auto t = ui.theme;
    Color bg = primary ? t.accent : t.button;

    if (pressed && hot) {
      bg = mix(bg, t.text, 0.15);
    } else if (hot) {
      bg = mix(bg, t.accent, primary ? 0.0 : 0.15);
    }

    Color fg = primary ? t.selectionText : t.buttonText;

    if (!enabled) {
      bg = mix(t.window, t.button, 0.5);
      fg = t.dimText;
    }

    c.roundRect(rect, ui.px(3), bg, primary ? mix(t.accent, t.text, 0.1) : t.border);
    auto f = ui.fonts.ui;
    int tw = f.measure(label);

    c.text(f, rect.x + (rect.w - tw) / 2, rect.y + (rect.h - f.lineHeight) / 2, label, fg);
  }

  override bool mouseDown(ref const Event e) {
    if (!enabled || e.button != MouseButton.left) {
      return true;
    }

    pressed = true;
    hot = true;
    ui.capture = this;
    ui.invalidate();

    return true;
  }

  override void mouseMove(ref const Event e) {
    bool h = rect.contains(e.x, e.y);

    if (h != hot) {
      hot = h;
      ui.invalidate();
    }
  }

  override void mouseUp(ref const Event e) {
    bool fire = pressed && rect.contains(e.x, e.y);

    pressed = false;
    ui.invalidate();
    if (fire && onClick) {
      onClick();
    }
  }

  override void mouseLeave() {
    if (hot && !pressed) {
      hot = false;
      ui.invalidate();
    }
  }
}
