module gui.diffview;

import std.algorithm : min, max;

import doc.document;
import gui.ui;
import view.actions : nodeLabel, valuePreview;
import view.diff;

final class DiffView : Widget {
  Diff diff;
  string nameA, nameB;
  bool onlyChanges = true;
  void delegate() onSelect;

  private Row[] rows;
  private size_t cursor;
  private size_t top;
  private ScrollBar vbar;
  private bool barHot;

  private static struct Row {
    uint entry;
    uint depth;
  }

  this(Ui ui, Diff diff, string nameA, string nameB) {
    super(ui);
    this.diff = diff;
    this.nameA = nameA;
    this.nameB = nameB;
    expandChanged(0);
    rebuild();
  }

  override bool focusable() { return true; }

  @property int rowH() { return ui.rowHeight; }
  @property int headerH() { return ui.rowHeight + ui.px(2); }
  @property int barWidth() { return ui.px(12); }
  @property int visibleRows() { return max(1, (rect.h - headerH) / rowH); }

  @property const(DiffEntry)* selected() {
    return rows.length ? &diff.entries[rows[cursor].entry] : null;
  }

  void setOnlyChanges(bool on) {
    onlyChanges = on;
    rebuild();
  }

  private void expandChanged(uint e) {
    if (diff.entries[e].status != DiffStatus.changed) {
      return;
    }

    diff.entries[e].expanded = true;
    foreach (c; diff.childrenOf(e)) {
      expandChanged(c);
    }
  }

  private void rebuild() {
    auto keep = rows.length ? rows[cursor].entry : 0;

    rows.length = 0;
    collect(0, 0);
    cursor = 0;
    foreach (k, r; rows) {
      if (r.entry == keep) {
        cursor = k;
      }
    }

    ensureVisible();
    ui.invalidate();
  }

  private void collect(uint e, uint depth) {
    rows ~= Row(e, depth);
    if (!diff.entries[e].expanded) {
      return;
    }

    foreach (c; diff.childrenOf(e)) {
      if (onlyChanges && diff.entries[c].status == DiffStatus.same) {
        continue;
      }

      collect(c, depth + 1);
    }
  }

  private bool canExpand(uint e) {
    return diff.childrenOf(e).length > 0;
  }

  private void toggle(size_t r) {
    auto e = rows[r].entry;

    if (!canExpand(e)) {
      return;
    }

    diff.entries[e].expanded = !diff.entries[e].expanded;
    rebuild();
  }

  override void layout(Rect r) {
    rect = r;
    vbar.rect = Rect(r.right - barWidth, r.y + headerH, barWidth, r.h - headerH);
    ensureVisible();
  }

  override void draw(Canvas c) {
    auto t = ui.theme;
    auto f = ui.fonts.ui;
    int w = rect.w - barWidth;
    int colA = rect.x + w * 34 / 100, colB = rect.x + w * 67 / 100;

    c.fill(rect, t.view);

    auto header = Rect(rect.x, rect.y, rect.w, headerH);
    int hy = header.y + (header.h - f.lineHeight) / 2;

    c.fill(header, mix(t.window, t.view, 0.5));
    c.hline(header.x, header.right, header.bottom - 1, t.border);
    c.text(f, rect.x + ui.px(8), hy, "Tag", t.dimText);
    c.textFit(f, colA + ui.px(8), hy, "A: " ~ nameA, t.dimText, colB - colA - ui.px(12));
    c.textFit(f, colB + ui.px(8), hy, "B: " ~ nameB, t.dimText, rect.x + w - colB - ui.px(12));

    auto body = Rect(rect.x, rect.y + headerH, w, rect.h - headerH);

    c.pushClip(body);
    foreach (k; 0 .. visibleRows + 1) {
      auto r = top + k;

      if (r >= rows.length) {
        break;
      }

      drawRow(c, r, Rect(body.x, body.y + k * rowH, body.w, rowH), colA, colB);
    }

    c.vline(colA, body.y, body.bottom, mix(t.view, t.border, 0.45));
    c.vline(colB, body.y, body.bottom, mix(t.view, t.border, 0.45));
    c.popClip();

    vbar.total = rows.length;
    vbar.page = visibleRows;
    vbar.pos = top;
    vbar.draw(c, t, barHot);
  }

  private Color statusColor(DiffStatus s) {
    auto t = ui.theme;

    final switch (s) {
      case DiffStatus.same: return t.text;
      case DiffStatus.changed: return t.dark ? 0xE5C07B : 0xB7791F;
      case DiffStatus.removed: return t.dark ? 0xF47174 : 0xC0392B;
      case DiffStatus.added: return t.dark ? 0x7FD18B : 0x2E8B3E;
    }
  }

  private void drawRow(Canvas c, size_t r, Rect row, int colA, int colB) {
    auto t = ui.theme;
    auto f = ui.fonts.ui;
    auto info = rows[r];
    auto e = &diff.entries[info.entry];
    bool selected = r == cursor;
    auto accent = statusColor(e.status);

    Color bg = (r & 1) ? t.alternate : t.view;

    if (e.status != DiffStatus.same) {
      bg = mix(bg, accent, 0.12);
    }

    if (selected) {
      bg = focused ? t.selection : mix(t.view, t.selection, 0.35);
    }

    c.fill(row, bg);

    Color fg = selected && focused ? t.selectionText : t.text;
    int ty = row.y + (row.h - f.lineHeight) / 2;
    int indent = row.x + ui.px(4) + cast(int)info.depth * ui.px(16);

    if (canExpand(info.entry)) {
      c.arrow(indent + ui.px(6), row.y + row.h / 2, ui.px(8), e.expanded ? 1 : 0, selected ? fg : t.dimText);
    }

    static immutable marks = [" ", "~", "−", "+"];

    c.text(ui.fonts.bold, indent + ui.px(16), ty, marks[e.status], selected && focused ? fg : accent);

    auto docSide = e.a != noNode ? diff.a : diff.b;
    auto node = e.a != noNode ? e.a : e.b;
    auto label = info.entry == 0 ? "<root>" : nodeLabel(docSide, node, 200, e.index);

    c.pushClip(Rect(row.x, row.y, colA - row.x - ui.px(2), row.h));
    c.textFit(f, indent + ui.px(30), ty, label, fg, colA - indent - ui.px(36));
    c.popClip();

    if (e.a != noNode) {
      c.textFit(f, colA + ui.px(8), ty, valuePreview(diff.a, e.a, 300), sideColor(e, true, fg), colB - colA - ui.px(14));
    }

    if (e.b != noNode) {
      c.textFit(f, colB + ui.px(8), ty, valuePreview(diff.b, e.b, 300), sideColor(e, false, fg), row.right - colB - ui.px(14));
    }

    c.hline(row.x, row.right, row.bottom - 1, mix(t.view, t.border, 0.45));
  }

  private Color sideColor(const DiffEntry* e, bool sideA, Color fg) {
    if (e.status == DiffStatus.same || fg == ui.theme.selectionText) {
      return fg;
    }

    if (e.status == DiffStatus.changed) {
      return statusColor(sideA ? DiffStatus.removed : DiffStatus.added);
    }

    return statusColor(e.status);
  }

  private void ensureVisible() {
    auto page = visibleRows;

    if (cursor < top) {
      top = cursor;
    }

    if (cursor >= top + page) {
      top = cursor - page + 1;
    }
  }

  private void select(long r) {
    if (!rows.length) {
      return;
    }

    cursor = cast(size_t)max(0, min(r, cast(long)rows.length - 1));
    ensureVisible();
    ui.invalidate();
    if (onSelect) {
      onSelect();
    }
  }

  void nextDifference(bool backwards) {
    auto r = cast(long)cursor;

    foreach (_; 0 .. rows.length) {
      r += backwards ? -1 : 1;
      if (r < 0 || r >= cast(long)rows.length) {
        return;
      }

      auto e = &diff.entries[rows[cast(size_t)r].entry];
      bool leaf = e.status != DiffStatus.changed || !diff.childrenOf(rows[cast(size_t)r].entry).length;

      if (e.status != DiffStatus.same && leaf) {
        select(r);

        return;
      }
    }
  }

  override bool keyDown(ref const Event e) {
    long page = visibleRows - 1;

    switch (e.key) {
      case Key.up: select(cast(long)cursor - 1); break;
      case Key.down: select(cast(long)cursor + 1); break;
      case Key.pageUp: select(cast(long)cursor - page); break;
      case Key.pageDown: select(cast(long)cursor + page); break;
      case Key.home: select(0); break;
      case Key.end: select(cast(long)rows.length - 1); break;
      case Key.enter:
      case Key.space:
        toggle(cursor);
        break;
      case Key.right:
        if (!diff.entries[rows[cursor].entry].expanded) {
          toggle(cursor);
        } else {
          select(cast(long)cursor + 1);
        }

        break;
      case Key.left:
        if (diff.entries[rows[cursor].entry].expanded) {
          toggle(cursor);
        } else {
          selectParent();
        }

        break;
      case Key.f7:
      case Key.n:
        nextDifference(e.shift);
        break;
      default:
        return false;
    }

    return true;
  }

  private void selectParent() {
    auto depth = rows[cursor].depth;

    foreach_reverse (k; 0 .. cursor) {
      if (rows[k].depth < depth) {
        select(k);

        return;
      }
    }
  }

  override bool mouseDown(ref const Event e) {
    ui.setFocus(this);
    ui.capture = this;
    if (vbar.mouseDown(e.x, e.y)) {
      top = cast(size_t)vbar.pos;
      ui.invalidate();

      return true;
    }

    auto r = top + (e.y - rect.y - headerH) / rowH;

    if (e.y < rect.y + headerH || r >= rows.length) {
      return true;
    }

    select(r);

    int indent = rect.x + ui.px(4) + cast(int)rows[r].depth * ui.px(16);
    bool onArrow = e.x >= indent - ui.px(2) && e.x < indent + ui.px(15);

    if (onArrow || e.clicks == 2) {
      toggle(r);
    }

    return true;
  }

  override void mouseMove(ref const Event e) {
    if (vbar.mouseMove(e.x, e.y)) {
      top = cast(size_t)vbar.pos;
      ui.invalidate();

      return;
    }

    bool hot = vbar.rect.contains(e.x, e.y);

    if (hot != barHot) {
      barHot = hot;
      ui.invalidate();
    }
  }

  override void mouseUp(ref const Event e) {
    vbar.mouseUp();
  }

  override bool wheel(ref const Event e) {
    long t = cast(long)top - cast(long)(e.wheelY * 3);

    top = cast(size_t)max(0, min(t, cast(long)rows.length - visibleRows));
    ui.invalidate();

    return true;
  }
}
