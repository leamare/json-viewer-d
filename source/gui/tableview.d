module gui.tableview;

import std.algorithm : canFind, min, max, startsWith;
import std.conv : to;

import doc.document;
import doc.edit : expandEmbedded, stripSlashes;
import gui.ui;
import view.actions : containerSummary, describeNode, nodeLabel, valuePreview;
import view.tree : TreeModel;

final class TableView : Widget {
  void delegate(uint) onOpen;

  private Document doc;
  private TreeModel tree;
  private uint node = noNode;
  private uint[] rows;
  private const(uint)[] indices;
  private Column[] columns;
  private Column[] originals;
  private bool byKeys;
  private string[uint] summaries;
  private Document listening;

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
    string[] path;
    int width;
    bool expandable;
    int origin = -1;
  }

  private enum maxColumns = 100;
  private enum sampleRows = 500;
  private enum prepareRows = 5000;

  this(Ui ui) {
    super(ui);
  }

  override bool focusable() { return true; }

  @property size_t rowCount() const { return rows.length; }
  @property size_t columnCount() const { return columns.length; }

  @property int rowH() { return ui.rowHeight; }
  @property int headerH() { return ui.rowHeight + ui.px(2); }
  @property int barSize() { return ui.px(12); }
  @property int visibleRows() { return max(1, (rect.h - headerH - barSize) / rowH); }

  void setNode(Document d, TreeModel t, uint n, const(uint)[] children, const(uint)[] childIndices) {
    bool same = d is doc && n == node && columns.length;

    doc = d;
    tree = t;
    node = n;
    rows = children.dup;
    indices = childIndices;
    summaries = null;
    if (listening !is d) {
      d.onShift ~= &shifted;
      listening = d;
    }

    if (!same) {
      cursor = 0;
      top = 0;
      scrollX = 0;
      buildColumns();
    } else {
      markExpandable();
    }

    cursor = min(cursor, rows.length ? rows.length - 1 : 0);
    ui.invalidate();
  }

  private void shifted(uint start, uint oldEnd, long delta) {
    if (doc !is listening) {
      return;
    }

    foreach (ref r; rows) {
      if (r >= oldEnd) {
        r = cast(uint)(r + delta);
      }
    }

    summaries = null;
  }

  private void buildColumns() {
    columns.length = 0;
    originals.length = 0;

    size_t objects;
    auto sample = rows[0 .. min(rows.length, sampleRows)];

    foreach (c; sample) {
      if (doc.nodes[c].type == NodeType.object) {
        objects++;
      }
    }

    byKeys = sample.length && objects * 10 >= sample.length * 6;

    auto first = doc.nodes[node].type == NodeType.array ? "#" : "Key";

    columns ~= Column(first);
    if (byKeys) {
      foreach (key; keysOf(sample)) {
        columns ~= Column(key, [key]);
      }
    } else {
      columns ~= Column("Value");
      columns ~= Column("Type");
    }

    markExpandable();
    foreach (ci; 0 .. columns.length) {
      fitWidth(ci);
    }
  }

  private string[] keysOf(const(uint)[] list) {
    string[] keys;
    bool[string] seen;

    foreach (c; list) {
      if (c == noNode || doc.nodes[c].type != NodeType.object) {
        continue;
      }

      foreach (k; doc.children(c)) {
        auto key = doc.key(k);

        if (key in seen || keys.length >= maxColumns) {
          continue;
        }

        seen[key] = true;
        keys ~= key;
      }
    }

    return keys;
  }

  private void fitWidth(size_t ci) {
    auto f = ui.fonts.ui;
    int buttons = (columns[ci].expandable ? 1 : 0) + (columns[ci].origin >= 0 ? 1 : 0);
    int w = f.measure(columns[ci].title) + ui.px(20 + buttons * 20);

    foreach (r; 0 .. min(rows.length, 50)) {
      w = max(w, f.measure(cellText(r, ci, 120)) + ui.px(16));
    }

    columns[ci].width = min(max(w, ui.px(48)), ui.px(ci == 0 ? 160 : 320));
  }

  private void markExpandable() {
    foreach (ci, ref col; columns) {
      col.expandable = false;
      if (!col.path.length) {
        continue;
      }

      foreach (r; 0 .. min(rows.length, 100)) {
        auto n = cellNode(r, ci);

        if (n != noNode && (doc.nodes[n].isContainer || tree.holdsDocument(n))) {
          col.expandable = true;
          break;
        }
      }
    }
  }

  private uint cellNode(size_t r, size_t ci) {
    auto cur = rows[r];

    if (!byKeys || ci == 0) {
      return cur;
    }

    foreach (step; columns[ci].path) {
      cur = child(cur, step);
      if (cur == noNode) {
        return noNode;
      }
    }

    return cur;
  }

  private uint child(uint parent, string step) {
    auto p = &doc.nodes[parent];

    if (p.type == NodeType.array && step.length > 2 && step[0] == '[') {
      try {
        return doc.childAt(parent, step[1 .. $ - 1].to!size_t);
      } catch (Exception) {
        return noNode;
      }
    }

    if (p.type != NodeType.object) {
      return noNode;
    }

    foreach (k; doc.children(parent)) {
      if (doc.key(k) == step) {
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
      return ci == 1 ? valueText(row, maxLen) : describeNode(doc, row);
    }

    auto n = cellNode(r, ci);

    return n == noNode ? null : valueText(n, maxLen);
  }

  private string valueText(uint n, size_t maxLen) {
    if (doc.nodes[n].isContainer) {
      return containerSummary(doc, n, maxLen);
    }

    if (tree.holdsDocument(n)) {
      return blobSummary(n, maxLen);
    }

    return valuePreview(doc, n, maxLen);
  }

  private string blobSummary(uint n, size_t maxLen) {
    import formats : documentFromText;

    if (auto s = n in summaries) {
      return *s;
    }

    string res;

    try {
      auto text = doc.value(n);
      auto inner = documentFromText(text);

      if (inner.error.length && text.canFind(`\"`)) {
        inner = documentFromText(stripSlashes(text));
      }

      res = inner.error.length ? valuePreview(doc, n, maxLen) : containerSummary(inner, 0, maxLen);
    } catch (Exception) {
      res = valuePreview(doc, n, maxLen);
    }

    summaries[n] = res;

    return res;
  }

  void expandColumn(size_t ci) {
    auto path = columns[ci].path;
    uint[] cells;

    foreach (r; 0 .. min(rows.length, prepareRows)) {
      auto n = cellNode(r, ci);

      // opening keeps the node id, so the cell is the same node after it
      if (n != noNode && tree.holdsDocument(n)) {
        expandEmbedded(doc, n);
      }

      if (r < sampleRows && n != noNode) {
        cells ~= n;
      }
    }

    string[] steps = keysOf(cells);

    if (!steps.length) {
      size_t longest = 0;

      foreach (c; cells) {
        if (doc.nodes[c].type == NodeType.array) {
          longest = max(longest, doc.nodes[c].len);
        }
      }

      foreach (k; 0 .. min(longest, 20)) {
        steps ~= "[" ~ k.to!string ~ "]";
      }
    }

    if (!steps.length) {
      return;
    }

    auto origin = cast(int)originals.length;
    Column[] fresh;

    originals ~= columns[ci];
    foreach (step; steps) {
      auto title = columns[ci].title ~ (step[0] == '[' ? step : "." ~ step);

      fresh ~= Column(title, path ~ step, 0, false, origin);
    }

    columns = columns[0 .. ci] ~ fresh ~ columns[ci + 1 .. $];
    markExpandable();
    foreach (k; ci .. ci + fresh.length) {
      fitWidth(k);
    }

    ui.invalidate();
  }

  void collapseColumn(size_t ci) {
    if (columns[ci].origin < 0) {
      return;
    }

    auto restored = originals[columns[ci].origin];
    auto group = restored.path;
    size_t first = ci, last = ci;

    bool inside(size_t k) {
      return columns[k].path.length > group.length && columns[k].path.startsWith(group);
    }

    while (first > 0 && inside(first - 1)) {
      first--;
    }

    while (last + 1 < columns.length && inside(last + 1)) {
      last++;
    }

    columns = columns[0 .. first] ~ restored ~ columns[last + 1 .. $];
    markExpandable();
    ui.invalidate();
  }

  bool prepareVisible() {
    if (doc is null || !byKeys) {
      return false;
    }

    bool changed = false;

    foreach (ref col; columns) {
      if (col.path.length < 2) {
        continue;
      }

      foreach (k; 0 .. visibleRows + 1) {
        auto r = top + k;

        if (r >= rows.length) {
          break;
        }

        auto cur = rows[r];

        foreach (step; col.path[0 .. $ - 1]) {
          cur = child(cur, step);
          if (cur == noNode) {
            break;
          }

          if (tree.holdsDocument(cur) && !expandEmbedded(doc, cur).length) {
            changed = true;
          }
        }
      }
    }

    return changed;
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

    foreach (ci, ref col; columns) {
      int buttons = (col.expandable ? 1 : 0) + (col.origin >= 0 ? 1 : 0);
      int textW = col.width - ui.px(12 + buttons * 20);

      c.textFit(f, x + ui.px(8), header.y + (header.h - f.lineHeight) / 2, col.title, t.dimText, textW);
      if (col.expandable) {
        drawHeaderButton(c, buttonRect(x, col.width, 0), true);
      }

      if (col.origin >= 0) {
        drawHeaderButton(c, buttonRect(x, col.width, col.expandable ? 1 : 0), false);
      }

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
      Color bg = (r & 1) ? t.alternate : t.view;

      if (selected) {
        bg = focused ? t.selection : mix(t.view, t.selection, 0.35);
      }

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

  private Rect buttonRect(int x, int width, int place) {
    int s = ui.px(16);

    return Rect(x + width - (s + ui.px(4)) * (place + 1) - ui.px(2), rect.y + (headerH - s) / 2, s, s);
  }

  private void drawHeaderButton(Canvas c, Rect r, bool plus) {
    auto t = ui.theme;
    float cx = r.x + r.w / 2.0f, cy = r.y + r.h / 2.0f, d = ui.px(3.5);

    c.roundRect(r, ui.px(3), t.button, t.border);
    c.line(cx - d, cy, cx + d, cy, ui.px(1.3), t.text);
    if (plus) {
      c.line(cx, cy - d, cx, cy + d, ui.px(1.3), t.text);
    }
  }

  private void drawCell(Canvas c, size_t r, size_t ci, Rect cell, bool inverted) {
    auto t = ui.theme;
    auto f = ui.fonts.ui;
    bool label = ci == 0 || (!byKeys && ci == 2);
    auto n = label ? noNode : cellNode(r, ci);
    auto text = cellText(r, ci);
    Color color = t.text;

    if (label) {
      color = t.dimText;
    } else if (n != noNode) {
      bool summary = doc.nodes[n].isContainer || tree.holdsDocument(n);

      color = summary ? t.dimText : valueColor(doc.nodes[n].type);
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

  private int columnStart(size_t ci) {
    int at = rect.x - scrollX;

    foreach (k; 0 .. ci) {
      at += columns[k].width;
    }

    return at;
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
      headerClick(e);

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

  private void headerClick(ref const Event e) {
    auto ci = columnAt(e.x);
    auto col = columns[ci];
    auto x = columnStart(ci);

    if (col.expandable && buttonRect(x, col.width, 0).contains(e.x, e.y)) {
      return expandColumn(ci);
    }

    if (col.origin >= 0 && buttonRect(x, col.width, col.expandable ? 1 : 0).contains(e.x, e.y)) {
      return collapseColumn(ci);
    }

    resizing = columnEdgeAt(e.x);
    if (resizing >= 0) {
      resizeStart = e.x;
      resizeWidth = columns[resizing].width;
    }
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
