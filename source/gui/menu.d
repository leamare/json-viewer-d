module gui.menu;

import std.algorithm : max, min;

import gui.ui;

struct MenuItem {
  string label;
  string shortcut;

  void delegate() action;
  bool enabled = true;
  bool checked;
  bool checkable;
  bool separator;
  bool keepOpen;
}

MenuItem item(string label, string shortcut, void delegate() action, bool enabled = true) {
  return MenuItem(label, shortcut, action, enabled);
}

MenuItem check(string label, string shortcut, bool checked, void delegate() action) {
  auto m = MenuItem(label, shortcut, action, true, checked, true);

  return m;
}

MenuItem toggle(string label, bool checked, void delegate() action) {
  auto m = MenuItem(label, null, action, true, checked, true);

  m.keepOpen = true;

  return m;
}

MenuItem separator() {
  MenuItem m;

  m.separator = true;

  return m;
}

final class PopupMenu : Widget {
  MenuItem[] items;

  void delegate() onClose;
  void delegate(int) onSideKey;

  private int hover = -1;
  private int scroll;
  private int contentH;

  this(Ui ui) {
    super(ui);
  }

  void open(int x, int y, MenuItem[] items) {
    this.items = items;
    hover = -1;
    auto f = ui.fonts.ui;
    int labelW = 0, shortcutW = 0, h = ui.px(4) * 2;

    foreach (ref m; items) {
      if (m.separator) {
        h += ui.px(9);
        continue;
      }

      labelW = max(labelW, f.measure(m.label));
      shortcutW = max(shortcutW, f.measure(m.shortcut));
      h += itemHeight;
    }

    int w = ui.px(30) + labelW + (shortcutW ? ui.px(32) + shortcutW : 0) + ui.px(16);

    w = max(w, ui.px(160));
    if (x + w > ui.canvas.width) {
      x = max(0, ui.canvas.width - w);
    }

    contentH = h;
    scroll = 0;
    h = min(h, ui.canvas.height - ui.px(16));
    if (y + h > ui.canvas.height) {
      y = max(0, ui.canvas.height - h);
    }

    rect = Rect(x, y, w, h);
    visible = true;
    ui.invalidate();
  }

  void close() {
    if (!visible) {
      return;
    }

    visible = false;
    ui.invalidate();
    if (onClose) {
      onClose();
    }
  }

  @property int itemHeight() { return ui.fonts.ui.lineHeight + ui.px(8); }

  override void draw(Canvas c) {
    auto t = ui.theme;
    auto f = ui.fonts.ui;

    foreach (k; 1 .. 4) {
      c.blend(Rect(rect.x + k, rect.y + k, rect.w, rect.h), 0x000000, 18);
    }

    c.roundRect(rect, ui.px(4), t.window, t.border);
    c.pushClip(rect.shrink(1));

    int y = rect.y + ui.px(4) - scroll;

    foreach (i, ref m; items) {
      if (m.separator) {
        c.hline(rect.x + ui.px(8), rect.right - ui.px(8), y + ui.px(4), t.border);
        y += ui.px(9);
        continue;
      }

      auto row = Rect(rect.x + ui.px(4), y, rect.w - ui.px(8), itemHeight);
      bool hot = i == hover && m.enabled;

      if (hot) {
        c.roundRect(row, ui.px(3), t.selection);
      }

      Color fg = !m.enabled ? t.dimText : hot ? t.selectionText : t.text;
      int ty = y + (itemHeight - f.lineHeight) / 2;

      if (m.checkable && m.checked) {
        int cx = rect.x + ui.px(14), cy = y + itemHeight / 2;

        c.line(cx - ui.px(4), cy, cx - ui.px(1), cy + ui.px(3), ui.px(1.6), fg);
        c.line(cx - ui.px(1), cy + ui.px(3), cx + ui.px(5), cy - ui.px(4), ui.px(1.6), fg);
      }

      c.text(f, rect.x + ui.px(28), ty, m.label, fg);
      if (m.shortcut.length) {
        int sw = f.measure(m.shortcut);

        c.text(f, rect.right - ui.px(14) - sw, ty, m.shortcut, hot ? fg : t.dimText);
      }

      y += itemHeight;
    }

    c.popClip();
  }

  private int itemAt(int x, int y) {
    if (!rect.contains(x, y)) {
      return -1;
    }

    int at = rect.y + ui.px(4) - scroll;

    foreach (i, ref m; items) {
      int h = m.separator ? ui.px(9) : itemHeight;

      if (y >= at && y < at + h) {
        return m.separator ? -1 : cast(int)i;
      }

      at += h;
    }

    return -1;
  }

  override void mouseMove(ref const Event e) {
    auto h = itemAt(e.x, e.y);

    if (h != hover) {
      hover = h;
      ui.invalidate();
    }
  }

  override bool mouseDown(ref const Event e) {
    if (!rect.contains(e.x, e.y)) {
      close();

      return false;
    }

    return true;
  }

  override void mouseUp(ref const Event e) {
    auto i = itemAt(e.x, e.y);

    if (i >= 0) {
      activate(i);
    }
  }

  override bool wheel(ref const Event e) {
    scroll = max(0, min(scroll - cast(int)(e.wheelY * itemHeight * 3), contentH - rect.h));
    ui.invalidate();

    return true;
  }

  private void activate(int i) {
    auto m = items[i];

    if (!m.enabled) {
      return;
    }

    if (m.keepOpen) {
      items[i].checked = !items[i].checked;
      ui.invalidate();
      if (m.action) {
        m.action();
      }

      return;
    }

    close();
    if (m.action) {
      m.action();
    }
  }

  override bool keyDown(ref const Event e) {
    switch (e.key) {
      case Key.escape:
        close();

        return true;
      case Key.up:
        moveHover(-1);

        return true;
      case Key.down:
        moveHover(1);

        return true;
      case Key.left:
      case Key.right:
        if (onSideKey) {
          onSideKey(e.key == Key.left ? -1 : 1);
        }

        return true;
      case Key.enter:
      case Key.space:
        if (hover >= 0) {
          activate(hover);
        }

        return true;
      default:
        return true;
    }
  }

  private void moveHover(int dir) {
    if (!items.length) {
      return;
    }

    int h = hover;

    foreach (_; 0 .. items.length) {
      h = cast(int)((h + dir + items.length) % items.length);
      if (!items[h].separator && items[h].enabled) {
        break;
      }
    }

    hover = h;
    ui.invalidate();
  }
}

final class MenuBar : Widget {
  struct Menu {
    string title;

    MenuItem[] delegate() build;
    Rect rect;
  }

  Menu[] menus;
  PopupMenu popup;

  void delegate(PopupMenu) onOpen;

  private int opened = -1;
  private int hover = -1;

  this(Ui ui, PopupMenu popup) {
    super(ui);
    this.popup = popup;
  }

  void add(string title, MenuItem[] delegate() build) {
    menus ~= Menu(title, build);
  }

  @property int preferredHeight() { return ui.fonts.ui.lineHeight + ui.px(10); }
  @property bool isOpen() { return opened >= 0 && popup.visible; }

  override void layout(Rect r) {
    rect = r;
    int x = r.x + ui.px(4);

    foreach (ref m; menus) {
      int w = ui.fonts.ui.measure(m.title) + ui.px(18);

      m.rect = Rect(x, r.y + ui.px(2), w, r.h - ui.px(4));
      x += w;
    }
  }

  override void draw(Canvas c) {
    auto t = ui.theme;
    auto f = ui.fonts.ui;

    c.fill(rect, t.window);
    foreach (i, ref m; menus) {
      bool active = i == opened && popup.visible;

      if (active ||
        i == hover) {
        c.roundRect(m.rect, ui.px(3), active ? t.selection : mix(t.window, t.selection, 0.25));
      }

      c.text(f, m.rect.x + ui.px(9), m.rect.y + (m.rect.h - f.lineHeight) / 2, m.title,
        active ? t.selectionText : t.text);
    }
  }

  private int menuAt(int x, int y) {
    foreach (i, ref m; menus) {
      if (m.rect.contains(x, y)) {
        return cast(int)i;
      }
    }

    return -1;
  }

  override bool mouseDown(ref const Event e) {
    auto i = menuAt(e.x, e.y);

    if (i < 0) {
      return false;
    }

    if (isOpen && i == opened) {
      popup.close();
    } else {
      open(i);
    }

    return true;
  }

  override void mouseMove(ref const Event e) {
    auto i = menuAt(e.x, e.y);

    if (i >= 0 && isOpen && i != opened) {
      open(i);
    }

    if (i != hover) {
      hover = i;
      ui.invalidate();
    }
  }

  override void mouseLeave() {
    if (hover >= 0) {
      hover = -1;
      ui.invalidate();
    }
  }

  void open(int i) {
    opened = i;
    auto m = menus[i];

    popup.onSideKey = (dir) { open(cast(int)((opened + dir + menus.length) % menus.length)); };
    popup.onClose = () { opened = -1; ui.invalidate(); };
    popup.open(m.rect.x, m.rect.bottom + ui.px(2), m.build());
    if (onOpen) {
      onOpen(popup);
    }
  }
}
