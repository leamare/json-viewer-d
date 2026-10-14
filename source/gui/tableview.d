module gui.tableview;

import std.algorithm : min, max;

import doc.document;
import gui.ui;
import view.actions : describeNode, nodeLabel, valuePreview;

final class TableView : Widget {
  void delegate(uint) onOpen;

  private Document doc;
  private uint node = noNode;
  private const(uint)[] rows;
  private const(uint)[] indices;
  private Column[] columns;
  private bool byKeys;

  private size_t cursor;
  private size_t top;
  private int scrollX;
  private ScrollBar vbar;
  private ScrollBar hbar = ScrollBar(false);
  private int resizing = -1;
  private int resizeStart, resizeWidth;
  private bool barHot;

  private static struct Column {
    string title;
    string key;
    int width;
  }

  private enum maxColumns = 100;
  private enum sampleRows = 500;

  this(Ui ui) {
    super(ui);
  }

  override bool focusable() { return true; }

  @property size_t rowCount() const { return rows.length; }
  @property size_t columnCount() const { return columns.length; }
  @property bool keyColumns() const { return byKeys; }

  @property int rowH() { return ui.rowHeight; }
  @property int headerH() { return ui.rowHeight + ui.px(2); }
  @property int barSize() { return ui.px(12); }
  @property int visibleRows() { return max(1, (rect.h - headerH - barSize) / rowH); }

  void setNode(Document d, uint n, const(uint)[] children, const(uint)[] childIndices) {
    bool same = d is doc && n == node;

    doc = d;
    node = n;
    rows = children;
    indices = childIndices;
    if (!same) {
      cursor = 0;
      top = 0;
      scrollX = 0;
    }

    cursor = min(cursor, rows.length ? rows.length - 1 : 0);
    buildColumns();
    ui.invalidate();
  }

  private void buildColumns() {
    columns.length = 0;

    auto f = ui.fonts.ui;
    size_t objects;
    auto sample = rows[0 .. min(rows.length, sampleRows)];

    foreach (c; sample) {
      if (doc.nodes[c].type == NodeType.object) {
        objects++;
      }
    }

    byKeys = sample.length && objects * 10 >= sample.length * 6;

    auto first = doc.nodes[node].type == NodeType.array ? "#" : "Key";

    columns ~= Column(first, null, f.measure(first) + ui.px(24));
    if (byKeys) {
      bool[string] seen;

      foreach (c; sample) {
        if (doc.nodes[c].type != NodeType.object) {
          continue;
        }

        foreach (k; doc.children(c)) {
          auto key = doc.key(k);

          if (key in seen || columns.length > maxColumns) {
            continue;
          }

          seen[key] = true;
          columns ~= Column(key, key, 0);
        }
      }
    } else {
      columns ~= Column("Value", null, 0);
      columns ~= Column("Type", null, 0);
    }

    foreach (ci, ref col; columns) {
      int w = f.measure(col.title) + ui.px(20);

      foreach (r; 0 .. min(rows.length, 50)) {
        w = max(w, f.measure(cellText(r, ci, 120)) + ui.px(16));
      }

      col.width = min(max(w, ui.px(48)), ui.px(ci == 0 ? 160 : 320));
    }
  }

  private uint cellNode(size_t r, size_t ci) {
    auto row = rows[r];

    if (!byKeys || ci == 0) {
      return row;
    }

    if (doc.nodes[row].type != NodeType.object) {
      return ci == 1 ? row : noNode;
    }

    auto key = columns[ci].key;

    foreach (k; doc.children(row)) {
      if (doc.key(k) == key) {
        return k;
      }
    }

    return noNode;
  }

  private string cellText(size_t r, size_t ci, size_t maxLen = 300) {
    auto row = rows[r];

    if (ci == 0) {
      return nodeLabel(doc, row, maxLen, indices.length > r ? indices[r] : size_t.max);
    }

    if (!byKeys) {
      return ci == 1 ? valuePreview(doc, row, maxLen) : describeNode(doc, row);
    }

    auto n = cellNode(r, ci);

    return n == noNode ? null : valuePreview(doc, n, maxLen);
  }

  override void layout(Rect r) {
    rect = r;
    vbar.rect = Rect(r.right - barSize, r.y + headerH, barSize, r.h - headerH - barSize);
    hbar.rect = Rect(r.x, r.bottom - barSize, r.w - barSize, barSize);
  }

  override void draw(Canvas c) {
    auto t = ui.theme;
    auto f = ui.fonts.ui;

    c.fill(rect, t.view);
    if (doc is null) {
      return;
    }

    auto body = Rect(rect.x, rect.y + headerH, rect.w - barSize, rect.h - headerH - barSize);
    int totalW = 0;

    foreach (ref col; columns) {
      totalW += col.width;
    }

    scrollX = max(0, min(scrollX, totalW - body.w));

    auto header = Rect(rect.x, rect.y, rect.w, headerH);

    c.fill(header, mix(t.window, t.view, 0.5));
    c.hline(header.x, header.right, header.bottom - 1, t.border);
    c.pushClip(Rect(rect.x, rect.y, body.w, rect.h));
    int x = rect.x - scrollX;

    foreach (ref col; columns) {
      c.textFit(f, x + ui.px(8), header.y + (header.h - f.lineHeight) / 2, col.title, t.dimText, col.width - ui.px(12));
      c.vline(x + col.width - 1, header.y + ui.px(4), header.bottom - ui.px(4), t.border);
      x += col.width;
    }

    c.popClip();

    c.pushClip(body);
    auto lineColor = mix(t.view, t.border, 0.45);

    foreach (k; 0 .. visibleRows + 1) {
      auto r = top + k;

      if (r >= rows.length) {
        break;
      }

      int y = body.y + k * rowH;
      bool selected = r == cursor;
      Color bg = selected ? (focused ? t.selection : mix(t.view, t.selection, 0.35)) : (r & 1) ? t.alternate : t.view;

      c.fill(Rect(body.x, y, body.w, rowH), bg);
      x = body.x - scrollX;
      foreach (ci, ref col; columns) {
        if (x + col.width >= body.x && x < body.right) {
          drawCell(c, r, ci, Rect(x, y, col.width, rowH), selected && focused);
        }

        x += col.width;
      }

      c.hline(body.x, body.right, y + rowH - 1, lineColor);
    }

    c.popClip();

    vbar.total = rows.length;
    vbar.page = visibleRows;
    vbar.pos = top;
    vbar.draw(c, t, barHot);
    hbar.total = totalW > body.w ? totalW : 0;
    hbar.page = body.w;
    hbar.pos = scrollX;
    if (hbar.needed) {
      hbar.draw(c, t, barHot);
    }
  }

  private void drawCell(Canvas c, size_t r, size_t ci, Rect cell, bool inverted) {
    auto t = ui.theme;
    auto f = ui.fonts.ui;
    auto n = ci == 0 || (!byKeys && ci == 2) ? noNode : cellNode(r, ci);
    auto text = cellText(r, ci);
    Color color = t.text;

    if (ci == 0 || (!byKeys && ci == 2)) {
      color = t.dimText;
    } else if (n != noNode) {
      color = valueColor(doc.nodes[n].type);
    }

    if (inverted) {
      color = t.selectionText;
    }

    int ty = cell.y + (cell.h - f.lineHeight) / 2;

    c.textFit(f, cell.x + ui.px(8), ty, text, color, cell.w - ui.px(12));
    c.vline(cell.right - 1, cell.y, cell.bottom, mix(t.view, t.border, 0.35));
  }

  private Color valueColor(NodeType type) {
    auto t = ui.theme;

    final switch (type) {
      case NodeType.string: return t.str;
      case NodeType.number: return t.number;
      case NodeType.boolean: return t.boolean;
      case NodeType.null_: return t.nil;
      case NodeType.object:
      case NodeType.array: return t.dimText;
    }
  }

  private void ensureVisible() {
    auto page = visibleRows;

    if (cursor < top) {
      top = cursor;
    }

    if (cursor >= top + page) {
      top = cursor - page + 1;
    }

    long maxTop = cast(long)rows.length - page;

    if (cast(long)top > maxTop) {
      top = cast(size_t)max(0, maxTop);
    }
  }

  private void select(long r) {
    if (!rows.length) {
      return;
    }

    cursor = cast(size_t)max(0, min(r, cast(long)rows.length - 1));
    ensureVisible();
    ui.invalidate();
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
      case Key.left: scrollX = max(0, scrollX - ui.px(60)); ui.invalidate(); break;
      case Key.right: scrollX += ui.px(60); ui.invalidate(); break;
      case Key.enter:
        if (rows.length && onOpen) {
          onOpen(rows[cursor]);
        }

        break;
      default:
        return false;
    }

    return true;
  }

  private int columnEdgeAt(int x) {
    int at = rect.x - scrollX;

    foreach (ci, ref col; columns) {
      at += col.width;
      if (x >= at - ui.px(4) && x <= at + ui.px(4)) {
        return cast(int)ci;
      }
    }

    return -1;
  }

  private size_t columnAt(int x) {
    int at = rect.x - scrollX;

    foreach (ci, ref col; columns) {
      if (x >= at && x < at + col.width) {
        return ci;
      }

      at += col.width;
    }

    return 0;
  }

  override Cursor cursorAt(int x, int y) {
    if (resizing >= 0 || (y < rect.y + headerH && columnEdgeAt(x) >= 0)) {
      return Cursor.resizeH;
    }

    return Cursor.arrow;
  }

  override bool mouseDown(ref const Event e) {
    ui.setFocus(this);
    ui.capture = this;
    if (e.y < rect.y + headerH) {
      resizing = columnEdgeAt(e.x);
      if (resizing >= 0) {
        resizeStart = e.x;
        resizeWidth = columns[resizing].width;
      }

      return true;
    }

    if (vbar.mouseDown(e.x, e.y)) {
      top = cast(size_t)vbar.pos;
      ui.invalidate();

      return true;
    }

    if (hbar.mouseDown(e.x, e.y)) {
      scrollX = cast(int)hbar.pos;
      ui.invalidate();

      return true;
    }

    auto r = top + (e.y - rect.y - headerH) / rowH;

    if (r >= rows.length) {
      return true;
    }

    select(r);
    if (e.clicks == 2 && onOpen) {
      auto n = cellNode(r, columnAt(e.x));

      onOpen(n == noNode ? rows[r] : n);
    }

    return true;
  }

  override void mouseMove(ref const Event e) {
    if (resizing >= 0) {
      columns[resizing].width = max(ui.px(30), resizeWidth + e.x - resizeStart);
      ui.invalidate();

      return;
    }

    if (vbar.mouseMove(e.x, e.y)) {
      top = cast(size_t)vbar.pos;
      ui.invalidate();

      return;
    }

    if (hbar.mouseMove(e.x, e.y)) {
      scrollX = cast(int)hbar.pos;
      ui.invalidate();

      return;
    }

    bool hot = vbar.rect.contains(e.x, e.y) || hbar.rect.contains(e.x, e.y);

    if (hot != barHot) {
      barHot = hot;
      ui.invalidate();
    }
  }

  override void mouseUp(ref const Event e) {
    resizing = -1;
    vbar.mouseUp();
    hbar.mouseUp();
  }

  override bool wheel(ref const Event e) {
    if (e.wheelY != 0) {
      long t = cast(long)top - cast(long)(e.wheelY * 3);

      top = cast(size_t)max(0, min(t, cast(long)rows.length - visibleRows));
    }

    if (e.wheelX != 0) {
      scrollX = max(0, scrollX - cast(int)(e.wheelX * ui.px(60)));
    }

    ui.invalidate();

    return true;
  }
}
