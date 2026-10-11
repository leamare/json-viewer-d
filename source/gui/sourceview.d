module gui.sourceview;

import core.stdc.string : memchr;
import std.algorithm : min, max;
import std.conv : to;
import std.range : assumeSorted;

import gui.ui;

final class SourceView : Widget {
  private const(char)[] text;
  private ulong[] lineStarts;
  private ulong[] rowStarts;
  private size_t wrapWidth;
  private long scrollY;
  private ulong mark = ulong.max;
  private ScrollBar vbar;
  private bool barHot;

  this(Ui ui) {
    super(ui);
  }

  override bool focusable() { return true; }

  void setText(const(char)[] t) {
    if (t.ptr is text.ptr && t.length == text.length) {
      return;
    }

    text = t;
    lineStarts = null;
    rowStarts = null;
    wrapWidth = 0;
    scrollY = 0;
    mark = ulong.max;
    ui.invalidate();
  }

  @property Font font() { return ui.fonts.mono; }
  @property int lineH() { return font.lineHeight + ui.px(1); }
  @property int barSize() { return ui.px(12); }
  @property int gutterW() { return font.measure((lineStarts.length + 1).to!string) + ui.px(18); }
  @property int visibleRows() { return max(1, rect.h / lineH); }

  void goTo(ulong offset) {
    mark = offset;
    ensureIndex();
    auto row = rowOf(offset);

    scrollY = max(0, cast(long)row - visibleRows / 3);
    ui.invalidate();
  }

  override void layout(Rect r) {
    rect = r;
    vbar.rect = Rect(r.right - barSize, r.y, barSize, r.h);
  }

  private void ensureIndex() {
    if (!lineStarts.length) {
      lineStarts ~= 0;
      const(char)* p = text.ptr, end = text.ptr + text.length;

      while (p < end) {
        auto nl = cast(const(char)*)memchr(p, '\n', end - p);

        if (nl is null) {
          break;
        }

        lineStarts ~= nl - text.ptr + 1;
        p = nl + 1;
      }
    }

    auto charW = max(1, font.measure("0"));
    auto width = cast(size_t)max(20, (rect.w - gutterW - barSize - ui.px(8)) / charW);

    if (width == wrapWidth && rowStarts.length) {
      return;
    }

    wrapWidth = width;

    rowStarts.length = 0;
    rowStarts.reserve(lineStarts.length);
    foreach (i, start; lineStarts) {
      auto end = i + 1 < lineStarts.length ? lineStarts[i + 1] : text.length;

      rowStarts ~= start;
      auto at = start + width;

      while (at < end) {
        while (at > start && (text[cast(size_t)at] & 0xC0) == 0x80) {
          at--;
        }

        rowStarts ~= at;
        at += width;
      }
    }
  }

  private size_t rowOf(ulong offset) {
    auto idx = rowStarts.assumeSorted.lowerBound(offset + 1).length;

    return idx ? idx - 1 : 0;
  }

  private size_t lineOf(ulong offset) {
    auto idx = lineStarts.assumeSorted.lowerBound(offset + 1).length;

    return idx ? idx - 1 : 0;
  }

  override void draw(Canvas c) {
    auto t = ui.theme;
    auto f = font;

    c.fill(rect, t.view);
    if (!text.length) {
      c.text(ui.fonts.ui, rect.x + ui.px(12), rect.y + ui.px(10),
        "Source is not available for this document", t.dimText);

      return;
    }

    ensureIndex();
    scrollY = max(0, min(scrollY, cast(long)rowStarts.length - visibleRows));

    auto gw = gutterW;
    auto gutter = Rect(rect.x, rect.y, gw, rect.h);

    c.fill(gutter, mix(t.view, t.window, 0.6));
    c.vline(gutter.right - 1, rect.y, rect.bottom, mix(t.view, t.border, 0.5));
    auto area = Rect(gutter.right, rect.y, rect.w - gw - barSize, rect.h);

    foreach (k; 0 .. visibleRows + 1) {
      auto row = cast(size_t)(scrollY + k);

      if (row >= rowStarts.length) {
        break;
      }

      int y = rect.y + k * lineH;
      auto start = rowStarts[row];
      auto end = row + 1 < rowStarts.length ? rowStarts[row + 1] : text.length;
      auto line = text[cast(size_t)start .. cast(size_t)end];

      if (line.length && line[$ - 1] == '\n') {
        line = line[0 .. $ - 1];
      }

      if (line.length && line[$ - 1] == '\r') {
        line = line[0 .. $ - 1];
      }

      auto li = lineOf(start);

      if (lineStarts[li] == start) {
        auto num = (li + 1).to!string;

        c.text(f, gutter.right - ui.px(8) - f.measure(num), y, num, t.dimText);
      }

      c.pushClip(area);
      int x0 = area.x + ui.px(4);

      if (mark != ulong.max && mark >= start && mark < end) {
        c.fill(Rect(area.x, y, area.w, lineH), mix(t.view, t.selection, 0.18));
        int mx = x0 + f.measure(line[0 .. cast(size_t)min(mark - start, line.length)]);

        c.fill(Rect(mx, y, max(ui.px(2), f.measure("0")), lineH), mix(t.view, t.selection, 0.6));
      }

      c.text(f, x0, y, line, t.text, area.right);
      c.popClip();
    }

    vbar.total = rowStarts.length;
    vbar.page = visibleRows;
    vbar.pos = scrollY;
    vbar.draw(c, t, barHot);
  }

  override bool keyDown(ref const Event e) {
    long page = visibleRows - 1;

    switch (e.key) {
      case Key.up: scrollY--; break;
      case Key.down: scrollY++; break;
      case Key.pageUp: scrollY -= page; break;
      case Key.pageDown: scrollY += page; break;
      case Key.home: scrollY = 0; break;
      case Key.end: scrollY = long.max / 2; break;
      default: return false;
    }

    ui.invalidate();

    return true;
  }

  override bool mouseDown(ref const Event e) {
    ui.setFocus(this);
    ui.capture = this;
    if (vbar.mouseDown(e.x, e.y)) {
      scrollY = vbar.pos;
      ui.invalidate();
    }

    return true;
  }

  override void mouseMove(ref const Event e) {
    if (vbar.mouseMove(e.x, e.y)) {
      scrollY = vbar.pos;
      ui.invalidate();

      return;
    }

    bool hot = vbar.rect.contains(e.x, e.y);

    if (hot != barHot) {
      barHot = hot;
      ui.invalidate();
    }
  }

  override void mouseUp(ref const Event e) { vbar.mouseUp(); }

  override bool wheel(ref const Event e) {
    scrollY -= cast(long)(e.wheelY * 3);
    ui.invalidate();

    return true;
  }
}
