module gui.tableview;

import std.algorithm : canFind, min, max;
import std.conv : to;
import std.range : assumeSorted;

import doc.document;
import doc.edit : expandEmbedded, stripSlashes;
import gui.menu : MenuItem, separator, toggle, item;
import gui.ui;
import view.actions : containerSummary, describeNode, nodeLabel, valuePreview;
import view.search : ValueFilter, parseValueFilter;
import view.tree : TreeModel;

private enum ColKind {
  path,
  value,
  type,
  label,
}

/// Column of the table. Expanded columns are groups: their children go on the
/// next header level. A group made from an array of objects shows elements as
/// sub-rows, paths of its children start from the element.
private final class Col {
  string title;
  string[] path;
  ColKind kind;
  Col parent;
  Col[] children;
  bool expanded;
  bool asRows;
  bool hidden;
  bool expandable;
  int width;
  string filter;

  int x;
  int w;

  this(string title, string[] path, Col parent = null, ColKind kind = ColKind.path) {
    this.title = title;
    this.path = path;
    this.parent = parent;
    this.kind = kind;
  }

  @property bool isGroup() const { return expanded && children.length > 0; }

  int depth() {
    int d = 0;

    for (Col p = parent; p !is null; p = p.parent) {
      d++;
    }

    return d;
  }

  Col rowsGroup() {
    for (auto p = parent; p !is null; p = p.parent) {
      if (p.asRows) {
        return p;
      }
    }

    return null;
  }

  /// Steps from the row, or from the element of rowsGroup, to the cell
  string[] steps() {
    auto group = rowsGroup;
    string[] res;

    for (Col c = this; c !is null && c !is group; c = c.parent) {
      res = c.path ~ res;
    }

    return res;
  }
}

final class TableView : Widget {
  void delegate(uint) onOpen;
  void delegate(int, int, MenuItem[]) onHeaderMenu;
  void delegate(string, string, string, void delegate(string)) onPrompt;

  private Document doc;
  private TreeModel tree;
  private uint node = noNode;
  private uint[] baseRows;
  private const(uint)[] baseIndices;
  private uint[] rows;
  private uint[] indices;
  private Col labelCol;
  private Col sortCol;
  private int sortDir;
  private Col[] roots;
  private Col[] leaves;
  private int levels = 1;
  private int firstWidth;
  private bool byKeys;
  private string[uint] summaries;
  private Document listening;
  private Layout[string] layouts;
  private string layoutKey;

  private uint[] offsets;
  private bool heightsDirty = true;

  private size_t cursor;
  private long topLine;
  private int scrollX;
  private ScrollBar vbar;
  private ScrollBar hbar = ScrollBar(false);
  private Col resizing;
  private bool resizingFirst;
  private int resizeStart, resizeWidth;
  private bool barHot;

  private static struct Layout {
    Col[] roots;
    int firstWidth;
    bool byKeys;
    Col sortCol;
    int sortDir;
    string labelFilter;
  }

  private enum maxColumns = 100;
  private enum sampleRows = 500;
  private enum prepareRows = 5000;
  private enum maxSubRows = 200;

  this(Ui ui) {
    super(ui);
    labelCol = new Col(null, null, null, ColKind.label);
  }

  override bool focusable() { return true; }

  @property size_t rowCount() const { return rows.length; }
  @property size_t allRows() const { return baseRows.length; }
  @property size_t columnCount() const { return leaves.length + 1; }

  @property int rowH() { return ui.rowHeight; }
  @property int headerH() { return levels * ui.rowHeight + ui.px(2); }
  @property int barSize() { return ui.px(12); }
  @property int visibleLines() { return max(1, (rect.h - headerH - barSize) / rowH); }

  void setNode(Document d, TreeModel t, uint n, const(uint)[] children, const(uint)[] childIndices) {
    bool same = d is doc && n == node && roots.length;

    doc = d;
    tree = t;
    node = n;
    baseRows = children.dup;
    baseIndices = childIndices;
    rows = baseRows.dup;
    indices = null;
    summaries = null;
    heightsDirty = true;
    if (listening !is d) {
      d.onShift ~= &shifted;
      listening = d;
      layouts = null;
    }

    if (!same) {
      cursor = 0;
      topLine = 0;
      scrollX = 0;

      auto key = d.pathOf(n);

      layoutKey = key;
      if (auto saved = key in layouts) {
        roots = saved.roots;
        firstWidth = saved.firstWidth;
        byKeys = saved.byKeys;
        sortCol = saved.sortCol;
        sortDir = saved.sortDir;
        labelCol.filter = saved.labelFilter;
        markExpandable();
        placeColumns();
      } else {
        sortCol = null;
        sortDir = 0;
        labelCol.filter = null;
        buildColumns();
        saveLayout();
      }
    } else {
      markExpandable();
    }

    applyView();

    cursor = min(cursor, rows.length ? rows.length - 1 : 0);
    ui.invalidate();
  }

  private void shifted(uint start, uint oldEnd, long delta) {
    if (doc !is listening) {
      return;
    }

    foreach (list; [baseRows, rows]) {
      foreach (ref r; list) {
        if (r >= oldEnd) {
          r = cast(uint)(r + delta);
        }
      }
    }

    summaries = null;
    heightsDirty = true;
  }

  private void buildColumns() {
    roots.length = 0;

    size_t objects;
    auto sample = rows[0 .. min(rows.length, sampleRows)];

    foreach (c; sample) {
      if (doc.nodes[c].type == NodeType.object) {
        objects++;
      }
    }

    byKeys = sample.length && objects * 10 >= sample.length * 6;
    if (byKeys) {
      foreach (key; keysOf(sample)) {
        roots ~= new Col(key, [key]);
      }
    } else {
      roots ~= new Col("Value", null, null, ColKind.value);
      roots ~= new Col("Type", null, null, ColKind.type);
    }

    auto f = ui.fonts.ui;
    auto title = doc.nodes[node].type == NodeType.array ? "#" : "Key";

    firstWidth = f.measure(title) + ui.px(24);
    foreach (r; 0 .. min(rows.length, 50)) {
      firstWidth = max(firstWidth, f.measure(rowLabel(r)) + ui.px(16));
    }

    firstWidth = min(firstWidth, ui.px(160));
    markExpandable();
    foreach (c; roots) {
      fitWidth(c);
    }

    placeColumns();
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

  private void eachColumn(void delegate(Col) fn, Col[] list = null) {
    foreach (c; list is null ? roots : list) {
      fn(c);
      if (c.expanded && c.children.length) {
        eachColumn(fn, c.children);
      }
    }
  }

  private void markExpandable() {
    eachColumn((c) {
      c.expandable = false;
      if (c.kind != ColKind.path || c.expanded) {
        return;
      }

      foreach (n; sampleCells(c, 100)) {
        if (doc.nodes[n].isContainer || tree.holdsDocument(n)) {
          c.expandable = true;
          break;
        }
      }
    });
  }

  private void fitWidth(Col c) {
    auto f = ui.fonts.ui;
    int w = f.measure(c.title) + ui.px(40);

    foreach (n; sampleCells(c, 50)) {
      w = max(w, f.measure(valueText(n, 120)) + ui.px(16));
    }

    c.width = min(max(w, ui.px(48)), ui.px(320));
  }

  private void placeColumns() {
    leaves.length = 0;
    levels = 1;

    int x = firstWidth;

    foreach (c; roots) {
      place(c, 0, x);
    }

    heightsDirty = true;
  }

  private void place(Col c, int depth, ref int x) {
    if (c.hidden) {
      c.w = 0;

      return;
    }

    c.x = x;
    if (c.isGroup) {
      foreach (k; c.children) {
        place(k, depth + 1, x);
      }

      c.w = x - c.x;
      if (c.w) {
        levels = max(levels, depth + 2);

        int need = ui.fonts.ui.measure(c.title) + ui.px(40);

        if (c.w < need) {
          leaves[$ - 1].w += need - c.w;
          x += need - c.w;
          c.w = need;
        }
      }

      return;
    }

    levels = max(levels, depth + 1);
    c.w = c.width;
    leaves ~= c;
    x += c.width;
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

  private uint resolve(uint from, const(string)[] steps, bool open = false) {
    auto cur = from;

    foreach (step; steps) {
      if (open && tree.holdsDocument(cur)) {
        expandEmbedded(doc, cur);
      }

      cur = child(cur, step);
      if (cur == noNode) {
        return noNode;
      }
    }

    if (open && tree.holdsDocument(cur)) {
      expandEmbedded(doc, cur);
    }

    return cur;
  }

  private uint groupArray(size_t r, Col g, bool open = false) {
    return groupArrayAt(rows[r], g, open);
  }

  private uint groupArrayAt(uint row, Col g, bool open = false) {
    auto n = resolve(row, g.steps, open);

    return n != noNode && doc.nodes[n].type == NodeType.array ? n : noNode;
  }

  private uint[] cellsOf(size_t r, Col c, bool open = false) {
    return cellsAt(rows[r], c, open);
  }

  private uint[] cellsAt(uint row, Col c, bool open = false) {
    auto g = c.rowsGroup;

    if (g is null) {
      auto n = resolve(row, c.steps, open);

      return n == noNode ? null : [n];
    }

    auto arr = groupArrayAt(row, g, open);

    if (arr == noNode) {
      return null;
    }

    uint[] res;
    size_t k = 0;

    foreach (el; doc.children(arr)) {
      if (k++ >= maxSubRows) {
        break;
      }

      res ~= c is g ? el : resolve(el, c.steps, open);
    }

    return res;
  }

  private uint[] sampleCells(Col c, size_t count, bool open = false) {
    uint[] res;

    foreach (r; 0 .. min(rows.length, count)) {
      foreach (n; cellsOf(r, c, open)) {
        if (n != noNode) {
          res ~= n;
        }
      }
    }

    return res;
  }

  private string rowLabel(size_t r) {
    return nodeLabel(doc, rows[r], 200, indices.length > r ? indices[r] : size_t.max);
  }

  private void saveLayout() {
    layouts[layoutKey] = Layout(roots, firstWidth, byKeys, sortCol, sortDir, labelCol.filter);
  }

  private void applyView() {
    Col[] filtered;

    if (labelCol.filter.length) {
      filtered ~= labelCol;
    }

    eachColumn((c) {
      if (c.filter.length && !c.isGroup) {
        filtered ~= c;
      }
    });

    ValueFilter[] tests;

    foreach (c; filtered) {
      tests ~= parseValueFilter(c.filter);
    }

    rows.length = 0;
    indices.length = 0;
    foreach (k, row; baseRows) {
      uint index = k < baseIndices.length ? baseIndices[k] : cast(uint)k;
      bool ok = true;

      foreach (f, c; filtered) {
        if (!passes(row, index, c, tests[f])) {
          ok = false;
          break;
        }
      }

      if (ok) {
        rows ~= row;
        indices ~= index;
      }
    }

    if (sortCol !is null && sortDir) {
      sortRows();
    }

    cursor = min(cursor, rows.length ? rows.length - 1 : 0);
    heightsDirty = true;
    saveLayout();
    ui.invalidate();
  }

  private string[] textsOf(uint row, uint index, Col c) {
    final switch (c.kind) {
      case ColKind.label:
        return [nodeLabel(doc, row, 200, index)];
      case ColKind.value:
        return [cellValue(row)];
      case ColKind.type:
        return [describeNode(doc, row)];
      case ColKind.path:
        string[] res;

        foreach (n; cellsAt(row, c)) {
          res ~= n == noNode ? null : cellValue(n);
        }

        return res;
    }
  }

  private string cellValue(uint n) {
    return doc.nodes[n].isContainer || tree.holdsDocument(n) ? valueText(n, 200) : doc.value(n, 1000);
  }

  private bool passes(uint row, uint index, Col c, ref const ValueFilter f) {
    auto texts = textsOf(row, index, c);

    if (f.negate) {
      foreach (t; texts) {
        if (f.matches(t)) {
          return false;
        }
      }

      return true;
    }

    foreach (t; texts) {
      if (f.matches(t)) {
        return true;
      }
    }

    return false;
  }

  private void sortRows() {
    import std.algorithm : sort, SwapStrategy;
    import std.uni : icmp;

    // kind is 0 for numbers, 1 for text, 2 for empty cells
    static struct SortKey {
      int kind;
      double number;
      string text;
    }

    auto keys = new SortKey[rows.length];

    foreach (k, row; rows) {
      auto texts = textsOf(row, indices[k], sortCol);
      auto text = texts.length ? texts[0] : null;

      if (sortCol.kind == ColKind.label && doc.nodes[node].type == NodeType.array) {
        keys[k] = SortKey(0, indices[k]);
      } else if (!text.length) {
        keys[k] = SortKey(2);
      } else {
        try {
          keys[k] = SortKey(0, text.to!double);
        } catch (Exception) {
          keys[k] = SortKey(1, 0, text);
        }
      }
    }

    auto order = new size_t[rows.length];

    foreach (k; 0 .. order.length) {
      order[k] = k;
    }

    int dir = sortDir;

    bool less(size_t a, size_t b) {
      auto x = &keys[a], y = &keys[b];

      // empty cells stay at the end whatever the direction
      if (x.kind != y.kind) {
        return x.kind == 2 || y.kind == 2 ? y.kind == 2 : (dir > 0) == (x.kind < y.kind);
      }

      if (x.kind == 2) {
        return false;
      }

      int cmp = x.kind == 0 ? (x.number < y.number ? -1 : x.number > y.number) : icmp(x.text, y.text);

      return dir > 0 ? cmp < 0 : cmp > 0;
    }

    sort!(less, SwapStrategy.stable)(order);

    auto sortedRows = new uint[rows.length];
    auto sortedIndices = new uint[rows.length];

    foreach (k, from; order) {
      sortedRows[k] = rows[from];
      sortedIndices[k] = indices[from];
    }

    rows = sortedRows;
    indices = sortedIndices;
  }

  private void cycleSort(Col c) {
    if (sortCol !is c) {
      sortCol = c;
      sortDir = 1;
    } else if (sortDir == 1) {
      sortDir = -1;
    } else {
      sortCol = null;
      sortDir = 0;
    }

    applyView();
  }

  private void setSort(Col c, int dir) {
    sortCol = dir ? c : null;
    sortDir = dir;
    applyView();
  }

  private void askFilter(Col c) {
    if (onPrompt is null) {
      return;
    }

    auto name = c is labelCol ? indexTitle : c.title;

    onPrompt("Filter " ~ name, "Text to look for. =text matches the whole value, !text excludes, " ~
      ">10 and <10 compare numbers.", c.filter, (text) {
        c.filter = text;
        applyView();
      });
  }

  private bool anyFilter() {
    bool any = labelCol.filter.length > 0;

    eachColumn((c) {
      any = any || c.filter.length > 0;
    });

    return any;
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

  private Col[] rowGroups() {
    Col[] res;

    eachColumn((c) {
      if (c.asRows && c.isGroup && c.w > 0) {
        res ~= c;
      }
    });

    return res;
  }

  private uint linesOf(size_t r, Col[] groups) {
    uint lines = 1;

    foreach (g; groups) {
      auto arr = groupArray(r, g);

      if (arr != noNode) {
        lines = max(lines, min(doc.nodes[arr].len, maxSubRows));
      }
    }

    return lines;
  }

  private void updateHeights() {
    if (!heightsDirty) {
      return;
    }

    heightsDirty = false;

    auto groups = rowGroups();

    offsets.length = rows.length + 1;
    offsets[0] = 0;
    foreach (r; 0 .. rows.length) {
      offsets[r + 1] = offsets[r] + (groups.length ? linesOf(r, groups) : 1);
    }
  }

  @property private long totalLines() { return offsets.length ? offsets[$ - 1] : 0; }

  private size_t rowAtLine(long line) {
    auto idx = offsets[0 .. rows.length].assumeSorted.lowerBound(cast(uint)line + 1).length;

    return idx ? idx - 1 : 0;
  }

  void expandColumn(Col c) {
    sampleCells(c, prepareRows, true);

    auto cells = sampleCells(c, sampleRows);

    string[] keys = keysOf(cells);
    bool arrays = false;
    uint[] elements;

    if (!keys.length) {
      foreach (n; cells) {
        if (doc.nodes[n].type == NodeType.array) {
          arrays = true;
          foreach (el; doc.children(n)) {
            elements ~= el;
          }
        }
      }
    }

    c.children.length = 0;
    if (keys.length) {
      foreach (k; keys) {
        c.children ~= new Col(k, [k], c);
      }
    } else if (arrays && c.rowsGroup is null) {
      // elements become sub-rows, their keys are the columns
      c.asRows = true;
      foreach (k; keysOf(elements)) {
        c.children ~= new Col(k, [k], c);
      }

      if (!c.children.length) {
        c.children ~= new Col("value", null, c);
      }
    } else if (arrays) {
      size_t longest = 0;

      foreach (n; cells) {
        longest = max(longest, doc.nodes[n].len);
      }

      foreach (k; 0 .. min(longest, 20)) {
        auto step = "[" ~ k.to!string ~ "]";

        c.children ~= new Col(step, [step], c);
      }
    }

    if (!c.children.length) {
      return;
    }

    c.expanded = true;
    markExpandable();
    foreach (k; c.children) {
      fitWidth(k);
    }

    placeColumns();
    ui.invalidate();
  }

  void collapseColumn(Col c) {
    c.expanded = false;
    c.asRows = false;
    c.children.length = 0;
    markExpandable();
    fitWidth(c);
    placeColumns();
    ui.invalidate();
  }

  private void setHidden(Col c, bool hidden) {
    c.hidden = hidden;
    placeColumns();
    ui.invalidate();
  }

  private MenuItem[] columnsMenu(Col clicked) {
    MenuItem[] items;

    if (clicked !is null && !clicked.isGroup) {
      items ~= item("Sort ascending", null, () { setSort(clicked, 1); });
      items ~= item("Sort descending", null, () { setSort(clicked, -1); });
      if (sortCol !is null) {
        items ~= item("Original order", null, () { setSort(null, 0); });
      }

      items ~= item("Filter by value\u2026", null, () { askFilter(clicked); });
      if (clicked.filter.length) {
        items ~= item("Clear filter", null, () {
          clicked.filter = null;
          applyView();
        });
      }

      items ~= separator();
    }

    if (anyFilter()) {
      items ~= item("Clear all filters", null, () {
        labelCol.filter = null;
        eachColumn((c) { c.filter = null; });
        applyView();
      });
      items ~= separator();
    }

    if (clicked !is null && clicked.expanded) {
      items ~= item("Collapse " ~ clicked.title, null, () { collapseColumn(clicked); });
      items ~= separator();
    } else if (clicked !is null && clicked.expandable) {
      items ~= item("Expand " ~ clicked.title, null, () { expandColumn(clicked); });
      items ~= separator();
    }

    eachColumn((c) {
      string indent;

      foreach (_; 0 .. c.depth) {
        indent ~= "    ";
      }

      auto col = c;

      items ~= toggle(indent ~ c.title, !c.hidden, () { setHidden(col, !col.hidden); });
    });
    items ~= separator();
    items ~= item("Show all columns", null, () {
      eachColumn((c) { c.hidden = false; });
      placeColumns();
      ui.invalidate();
    });

    return items;
  }

  bool prepareVisible() {
    if (doc is null || !byKeys || !rows.length) {
      return false;
    }

    updateHeights();

    auto revision = doc.revision;
    auto first = rowAtLine(topLine);
    auto last = rowAtLine(topLine + visibleLines);

    eachColumn((c) {
      if (c.isGroup) {
        foreach (r; first .. min(last + 1, rows.length)) {
          cellsOf(r, c, true);
        }
      }
    });

    return doc.revision != revision;
  }

  override void layout(Rect r) {
    rect = r;
    vbar.rect = Rect(r.right - barSize, r.y + headerH, barSize, r.h - headerH - barSize);
    hbar.rect = Rect(r.x, r.bottom - barSize, r.w - barSize, barSize);
  }

  override void draw(Canvas c) {
    auto t = ui.theme;

    c.fill(rect, t.view);
    if (doc is null) {
      return;
    }

    layout(rect);
    updateHeights();

    auto body = Rect(rect.x, rect.y + headerH, rect.w - barSize, rect.h - headerH - barSize);
    int totalW = leaves.length ? leaves[$ - 1].x + leaves[$ - 1].w : firstWidth;

    scrollX = max(0, min(scrollX, totalW - body.w));
    topLine = max(0, min(topLine, totalLines - visibleLines));
    drawHeader(c, body);
    drawRows(c, body);

    vbar.total = totalLines;
    vbar.page = visibleLines;
    vbar.pos = topLine;
    vbar.draw(c, t, barHot);
    hbar.total = totalW > body.w ? totalW : 0;
    hbar.page = body.w;
    hbar.pos = scrollX;
    if (hbar.needed) {
      hbar.draw(c, t, barHot);
    }
  }

  private void drawHeader(Canvas c, Rect body) {
    auto t = ui.theme;
    auto f = ui.fonts.ui;
    auto header = Rect(rect.x, rect.y, rect.w, headerH);

    c.fill(header, mix(t.window, t.view, 0.5));
    c.pushClip(Rect(rect.x, rect.y, body.w, headerH));
    headerCell(c, Rect(rect.x - scrollX, rect.y, firstWidth, headerH), indexTitle, false, false, labelCol);
    eachColumn((col) {
      if (col.w <= 0 || !visibleColumn(col)) {
        return;
      }

      headerCell(c, headerRect(col), col.title, col.expandable, col.isGroup, col);
    });
    c.popClip();
    c.hline(header.x, header.right, header.bottom - 1, t.border);
  }

  @property private string indexTitle() {
    return doc.nodes[node].type == NodeType.array ? "#" : "Key";
  }

  private bool visibleColumn(Col col) {
    for (auto p = col; p !is null; p = p.parent) {
      if (p.hidden) {
        return false;
      }
    }

    return true;
  }

  private Rect headerRect(Col col) {
    int y = rect.y + col.depth * rowH;
    int h = col.isGroup ? rowH : headerH - (y - rect.y);

    return Rect(rect.x - scrollX + col.x, y, col.w, h);
  }

  private Rect visiblePart(Rect r) {
    int left = max(r.x, rect.x + firstWidth), right = min(r.right, rect.right - barSize);

    return right - left > ui.px(40) ? Rect(left, r.y, right - left, r.h) : r;
  }

  private void headerCell(Canvas c, Rect r, string title, bool plus, bool minus, Col col) {
    auto t = ui.theme;
    auto f = ui.fonts.ui;
    bool button = plus || minus;
    bool sorted = sortCol is col && sortDir;
    auto shown = visiblePart(r);
    int ty = r.y + min(r.h, rowH) / 2 - f.lineHeight / 2 + (r.h > rowH ? (r.h - rowH) / 2 : 0);
    int room = shown.w - ui.px(12 + (button ? 20 : 0) + (sorted ? 14 : 0));
    auto color = col.filter.length ? t.accent : t.dimText;
    int end = c.textFit(f, shown.x + ui.px(8), ty, title, color, room);

    if (sorted) {
      c.arrow(end + ui.px(8), ty + f.lineHeight / 2, ui.px(8), sortDir > 0 ? 3 : 1, t.text);
    }

    if (button) {
      drawHeaderButton(c, buttonRect(shown), plus);
    }

    c.vline(r.right - 1, r.y + ui.px(3), r.bottom - ui.px(3), t.border);
    c.hline(r.x, r.right, r.bottom - 1, mix(t.window, t.border, 0.6));
  }

  private Rect buttonRect(Rect cell) {
    int s = ui.px(16);
    int y = cell.y + (min(cell.h, rowH) - s) / 2 + (cell.h > rowH ? (cell.h - rowH) / 2 : 0);

    return Rect(cell.right - s - ui.px(6), y, s, s);
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

  private void drawRows(Canvas c, Rect body) {
    auto t = ui.theme;
    auto lineColor = mix(t.view, t.border, 0.45);

    if (!rows.length) {
      return;
    }

    c.pushClip(body);
    for (auto r = rowAtLine(topLine); r < rows.length; r++) {
      int y = body.y + cast(int)(offsets[r] - topLine) * rowH;
      int h = cast(int)(offsets[r + 1] - offsets[r]) * rowH;

      if (y >= body.bottom) {
        break;
      }

      bool selected = r == cursor;
      bool inverted = selected && focused;
      Color bg = (r & 1) ? t.alternate : t.view;

      if (selected) {
        bg = focused ? t.selection : mix(t.view, t.selection, 0.35);
      }

      c.fill(Rect(body.x, y, body.w, h), bg);

      int x0 = body.x - scrollX;

      drawText(c, Rect(x0, y, firstWidth, rowH), rowLabel(r), inverted ? t.selectionText : t.dimText);
      c.vline(x0 + firstWidth - 1, y, y + h, mix(t.view, t.border, 0.35));
      foreach (leaf; leaves) {
        auto cell = Rect(x0 + leaf.x, y, leaf.w, h);

        if (cell.right < body.x || cell.x > body.right) {
          continue;
        }

        drawColumn(c, r, leaf, cell, inverted);
      }

      c.hline(body.x, body.right, y + h - 1, lineColor);
    }

    c.popClip();
  }

  private void drawColumn(Canvas c, size_t r, Col leaf, Rect cell, bool inverted) {
    auto t = ui.theme;
    auto subLine = mix(t.view, t.border, 0.25);

    final switch (leaf.kind) {
      case ColKind.label:
        break;
      case ColKind.value:
        drawValue(c, rows[r], Rect(cell.x, cell.y, cell.w, rowH), inverted);
        break;
      case ColKind.type:
        auto color = inverted ? t.selectionText : t.dimText;

        drawText(c, Rect(cell.x, cell.y, cell.w, rowH), describeNode(doc, rows[r]), color);
        break;
      case ColKind.path:
        auto nodes = cellsOf(r, leaf);
        bool sub = leaf.rowsGroup !is null;

        foreach (k, n; nodes) {
          auto line = Rect(cell.x, cell.y + cast(int)k * rowH, cell.w, rowH);

          if (n != noNode) {
            drawValue(c, n, line, inverted);
          }

          if (sub && k + 1 < nodes.length) {
            c.hline(line.x, line.right, line.bottom - 1, subLine);
          }
        }

        break;
    }

    c.vline(cell.right - 1, cell.y, cell.bottom, mix(t.view, t.border, 0.35));
  }

  private void drawValue(Canvas c, uint n, Rect line, bool inverted) {
    auto t = ui.theme;
    Color color = t.dimText;

    if (!doc.nodes[n].isContainer && !tree.holdsDocument(n)) {
      color = valueColor(doc.nodes[n].type);
    }

    drawText(c, line, valueText(n, 300), inverted ? t.selectionText : color);
  }

  private void drawText(Canvas c, Rect line, string text, Color color) {
    auto f = ui.fonts.ui;

    c.textFit(f, line.x + ui.px(8), line.y + (line.h - f.lineHeight) / 2, text, color, line.w - ui.px(12));
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
    updateHeights();

    auto first = cast(long)offsets[cursor], last = cast(long)offsets[cursor + 1];

    if (first < topLine) {
      topLine = first;
    }

    if (last > topLine + visibleLines) {
      topLine = max(first, last - visibleLines);
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
    long page = max(1, visibleLines - 1);

    switch (e.key) {
      case Key.up: select(cast(long)cursor - 1); break;
      case Key.down: select(cast(long)cursor + 1); break;
      case Key.pageUp: select(rowAtLine(max(0, cast(long)offsets[cursor] - page))); break;
      case Key.pageDown: select(rowAtLine(offsets[cursor] + page)); break;
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

  private Col headerColumnAt(int x, int y) {
    Col found;
    int px = x - rect.x + scrollX;
    int level = (y - rect.y) / rowH;

    eachColumn((col) {
      if (col.w <= 0 || !visibleColumn(col) || px < col.x || px >= col.x + col.w) {
        return;
      }

      if (col.isGroup ? col.depth == level : col.depth <= level) {
        found = col;
      }
    });

    return found;
  }

  private Col edgeAt(int x) {
    int px = x - rect.x + scrollX;

    foreach (leaf; leaves) {
      int edge = leaf.x + leaf.w;

      if (px >= edge - ui.px(4) && px <= edge + ui.px(4)) {
        return leaf;
      }
    }

    return null;
  }

  override Cursor cursorAt(int x, int y) {
    bool firstEdge = abs(x - rect.x + scrollX - firstWidth) <= ui.px(4);

    if (resizing !is null || resizingFirst || (y < rect.y + headerH && (edgeAt(x) !is null || firstEdge))) {
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
      topLine = vbar.pos;
      ui.invalidate();

      return true;
    }

    if (hbar.mouseDown(e.x, e.y)) {
      scrollX = cast(int)hbar.pos;
      ui.invalidate();

      return true;
    }

    if (!rows.length) {
      return true;
    }

    updateHeights();

    auto line = topLine + (e.y - rect.y - headerH) / rowH;

    if (line >= totalLines) {
      return true;
    }

    auto r = rowAtLine(line);

    select(r);
    if (e.button == MouseButton.right && onHeaderMenu) {
      onHeaderMenu(e.x, e.y, columnsMenu(null));
    } else if (e.clicks == 2 && onOpen) {
      onOpen(cellAt(r, cast(size_t)(line - offsets[r]), e.x));
    }

    return true;
  }

  private uint cellAt(size_t r, size_t sub, int x) {
    int px = x - rect.x + scrollX;

    foreach (leaf; leaves) {
      if (px < leaf.x || px >= leaf.x + leaf.w || leaf.kind != ColKind.path) {
        continue;
      }

      auto nodes = cellsOf(r, leaf);
      auto k = leaf.rowsGroup is null ? 0 : sub;

      if (k < nodes.length && nodes[k] != noNode) {
        return nodes[k];
      }
    }

    return rows[r];
  }

  private void headerClick(ref const Event e) {
    if (abs(e.x - rect.x + scrollX - firstWidth) <= ui.px(4)) {
      resizingFirst = true;
      resizeStart = e.x;
      resizeWidth = firstWidth;

      return;
    }

    auto col = headerColumnAt(e.x, e.y);

    if (col is null && e.x < rect.x - scrollX + firstWidth) {
      col = labelCol;
    }

    if (e.button == MouseButton.right) {
      if (onHeaderMenu) {
        onHeaderMenu(e.x, e.y, columnsMenu(col));
      }

      return;
    }

    if (col !is null && col !is labelCol) {
      auto cell = visiblePart(headerRect(col));

      if ((col.expandable || col.isGroup) && buttonRect(cell).contains(e.x, e.y)) {
        if (col.isGroup) {
          collapseColumn(col);
        } else {
          expandColumn(col);
        }

        return;
      }
    }

    resizing = edgeAt(e.x);
    if (resizing !is null) {
      resizeStart = e.x;
      resizeWidth = resizing.width;

      return;
    }

    if (col !is null && !col.isGroup && e.button == MouseButton.left) {
      cycleSort(col);
    }
  }

  override void mouseMove(ref const Event e) {
    if (resizingFirst) {
      firstWidth = max(ui.px(30), resizeWidth + e.x - resizeStart);
      placeColumns();
      ui.invalidate();

      return;
    }

    if (resizing !is null) {
      resizing.width = max(ui.px(30), resizeWidth + e.x - resizeStart);
      placeColumns();
      ui.invalidate();

      return;
    }

    if (vbar.mouseMove(e.x, e.y)) {
      topLine = vbar.pos;
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
    if (resizingFirst) {
      if (auto saved = layoutKey in layouts) {
        saved.firstWidth = firstWidth;
      }
    }

    resizing = null;
    resizingFirst = false;
    vbar.mouseUp();
    hbar.mouseUp();
  }

  override bool wheel(ref const Event e) {
    if (e.wheelY != 0) {
      topLine = max(0, min(topLine - cast(long)(e.wheelY * 3), totalLines - visibleLines));
    }

    if (e.wheelX != 0) {
      scrollX = max(0, scrollX - cast(int)(e.wheelX * ui.px(60)));
    }

    ui.invalidate();

    return true;
  }
}

private int abs(int v) { return v < 0 ? -v : v; }
