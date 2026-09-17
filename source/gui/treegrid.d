module gui.treegrid;

import std.algorithm : min, max;

import doc.document;
import doc.text : looksLikeJson;
import gui.ui;
import view.actions : embeddedFormatName, nodeLabel, valuePreview;
import view.tree;

final class TreeGrid : Widget {
  TreeModel tree;
  float split = 0.45;

  void delegate() onSelect;
  void delegate(int x, int y) onContextMenu;
  void delegate(uint, string, bool) onEdit;
  void delegate() onActivate;

  LineEdit editor;
  private bool editing;
  private bool editingKey;
  private uint editNode = noNode;

  private ScrollBar vbar;
  private int hoverRow = -1;
  private bool draggingSplit;
  private bool barHot;

  this(Ui ui) {
    super(ui);
    editor = new LineEdit(ui);
    editor.onEnter = () { finishEdit(true); };
    editor.onEscape = () { finishEdit(false); };
  }

  override bool focusable() { return true; }

  void setModel(TreeModel m) {
    cancelEdit();
    tree = m;
    ui.invalidate();
  }

  @property int rowH() { return ui.rowHeight; }
  @property int headerH() { return ui.rowHeight + ui.px(2); }
  @property Rect body() { return Rect(rect.x, rect.y + headerH, rect.w - barWidth, rect.h - headerH); }
  @property int barWidth() { return ui.px(12); }
  @property int visibleRows() { return max(1, body.h / rowH); }
  @property int splitX() { return rect.x + cast(int)((rect.w - barWidth) * split); }

  override void layout(Rect r) {
    rect = r;
    vbar.rect = Rect(r.right - barWidth, r.y + headerH, barWidth, r.h - headerH);
    ensureVisible();
    if (editing) {
      placeEditor();
    }
  }

  override void draw(Canvas c) {
    auto t = ui.theme;

    c.fill(rect, t.view);
    drawHeader(c);
    if (tree is null) {
      return;
    }

    auto b = body;

    c.pushClip(b);
    auto doc = tree.doc;
    int sx = splitX;
    auto lineColor = mix(t.view, t.border, 0.45);
    size_t top = tree.top;

    foreach (k; 0 .. visibleRows + 1) {
      auto r = top + k;

      if (r >= tree.length) {
        break;
      }

      int y = b.y + k * rowH;

      drawRow(c, r, Rect(b.x, y, b.w, rowH), sx);
      c.hline(b.x, b.right, y + rowH - 1, lineColor);
    }

    c.vline(sx, b.y, b.bottom, lineColor);
    c.popClip();

    vbar.total = tree.length;
    vbar.page = visibleRows;
    vbar.pos = tree.top;
    vbar.draw(c, t, barHot);
    if (editing) {
      editor.draw(c);
    }
  }

  private void drawHeader(Canvas c) {
    auto t = ui.theme;
    auto f = ui.fonts.ui;
    auto h = Rect(rect.x, rect.y, rect.w, headerH);

    c.fill(h, mix(t.window, t.view, 0.5));
    c.hline(h.x, h.right, h.bottom - 1, t.border);
    int ty = h.y + (h.h - f.lineHeight) / 2;

    c.text(f, h.x + ui.px(8), ty, "Tag", t.dimText);
    c.vline(splitX, h.y + ui.px(4), h.bottom - ui.px(4), t.border);
    c.text(f, splitX + ui.px(8), ty, "Value", t.dimText);
  }

  private void drawRow(Canvas c, size_t r, Rect row, int sx) {
    auto t = ui.theme;
    auto doc = tree.doc;
    auto f = ui.fonts.ui;
    auto rowInfo = tree.rows[r];
    auto id = rowInfo.node;
    auto n = &doc.nodes[id];
    bool selected = r == tree.cursor;

    Color bg = (r & 1) ? t.alternate : t.view;

    if (selected) {
      bg = focused || editing ? t.selection : mix(t.view, t.selection, 0.35);
    } else if (r == hoverRow) {
      bg = t.hover;
    }

    c.fill(row, bg);

    Color fg = selected && (focused || editing) ? t.selectionText : t.text;
    int ty = row.y + (row.h - f.lineHeight) / 2;
    int cy = row.y + row.h / 2;

    int indent = row.x + ui.px(4) + cast(int)rowInfo.depth * ui.px(16);

    if (n.isContainer && n.len) {
      c.arrow(indent + ui.px(6), cy, ui.px(8), tree.isExpanded(r) ? 1 : 0, selected ? fg : t.dimText);
    }

    int ix = indent + ui.px(16);

    drawIcon(c, ix, cy, *n, selected && focused);

    c.pushClip(Rect(row.x, row.y, sx - row.x - ui.px(2), row.h));
    bool isIndex = !doc.hasKey(id) && n.parent != noNode;
    auto label = nodeLabel(doc, id, 300);
    auto font = n.parent == noNode ? ui.fonts.bold : f;
    int lx = ix + ui.px(18);
    int end = c.textFit(font, lx, ty, label, isIndex && !selected ? t.dimText : fg, sx - lx - ui.px(6));

    if (n.has(NodeFlags.embedded)) {
      import std.uni : toLower;
      pill(c, end + ui.px(6), row, embeddedFormatName(*n).toLower, selected ? fg : t.accent);
    }

    c.popClip();

    if (editing && id == editNode) {
      return;
    }

    int vx = sx + ui.px(8);
    int room = row.right - vx - ui.px(6);

    if (room <= 0) {
      return;
    }

    auto text = valuePreview(doc, id, 600);
    Color vc = selected && (focused || editing) ? fg : valueColor(n.type);

    if (n.isContainer) {
      vc = selected ? fg : t.dimText;
    }

    bool jsonInside = n.type == NodeType.string && looksLikeJson(text);

    if (jsonInside) {
      room -= ui.px(40);
    }

    int vend = c.textFit(f, vx, ty, text, vc, room);

    if (jsonInside) {
      pill(c, vend + ui.px(6), row, "{ }", selected ? fg : t.accent);
    }
  }

  private void pill(Canvas c, int x, Rect row, string label, Color color) {
    auto f = ui.fonts.small;
    int w = f.measure(label) + ui.px(10);
    int h = f.lineHeight + ui.px(1);
    auto r = Rect(x, row.y + (row.h - h) / 2, w, h);

    c.roundRect(r, h / 2.0f, mix(ui.theme.view, color, 0.18), mix(ui.theme.view, color, 0.6));
    c.text(f, x + ui.px(5), r.y + (h - f.lineHeight) / 2, label, color);
  }

  Color valueColor(NodeType type) {
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

  private void drawIcon(Canvas c, int x, int cy, in Node n, bool inverted) {
    auto t = ui.theme;
    int s = ui.px(12);
    float fx = x, fy = cy - s / 2.0f;

    final switch (n.type) {
      case NodeType.object:
        float h = s / 2.0f;

        c.fillPolygon([fx + h, fy, fx + s, fy + h, fx + h, fy + s, fx, fy + h], t.iconObject);
        c.fillPolygon([fx + h, fy + 2.5f, fx + s - 2.5f, fy + h, fx + h, fy + s - 2.5f, fx + 2.5f, fy + h],
          mix(t.iconObject, 0xFFFFFF, 0.35));
        break;
      case NodeType.array:
        foreach (k; 0 .. 3) {
          int ly = cast(int)fy + ui.px(1.5) + k * ui.px(3.5);

          c.fill(Rect(x, ly, ui.px(2.5), ui.px(2.5)), t.iconArray);
          c.fill(Rect(x + ui.px(4), ly, s - ui.px(4), ui.px(2.5)), t.iconArray);
        }

        break;
      case NodeType.string:
        c.roundRect(Rect(x, cast(int)fy + ui.px(1), s, s - ui.px(2)), ui.px(2), t.iconString,
          mix(t.iconString, 0x000000, 0.25));
        break;
      case NodeType.number:
        c.roundRect(Rect(x, cast(int)fy + ui.px(1), s, s - ui.px(2)), ui.px(2), t.iconNumber,
          mix(t.iconNumber, 0x000000, 0.25));
        break;
      case NodeType.boolean:
        c.roundRect(Rect(x, cast(int)fy + ui.px(1), s, s - ui.px(2)), ui.px(2), t.iconBool,
          mix(t.iconBool, 0x000000, 0.25));
        break;
      case NodeType.null_:
        c.roundRect(Rect(x, cast(int)fy + ui.px(1), s, s - ui.px(2)), ui.px(2), t.view, t.dimText);
        break;
    }
    if (n.has(NodeFlags.embedded)) {
      c.fillCircle(x + s - ui.px(1), cy + s / 2.0f - ui.px(1), ui.px(3), t.accent);
    }
  }

  void select(size_t r) {
    if (tree is null || !tree.length) {
      return;
    }

    r = min(r, tree.length - 1);
    bool changed = r != tree.cursor;

    tree.cursor = r;
    ensureVisible();
    ui.invalidate();
    if (changed && onSelect) {
      onSelect();
    }
  }

  void ensureVisible() {
    if (tree is null) {
      return;
    }

    auto page = visibleRows;

    if (tree.cursor < tree.top) {
      tree.top = tree.cursor;
    }

    if (tree.cursor >= tree.top + page) {
      tree.top = tree.cursor - page + 1;
    }

    long maxTop = cast(long)tree.length - page;

    if (cast(long)tree.top > maxTop) {
      tree.top = cast(size_t)max(0, maxTop);
    }
  }

  void reveal(uint node) {
    if (tree is null) {
      return;
    }

    auto old = tree.cursor;

    tree.reveal(node);
    auto page = visibleRows;

    if (tree.cursor < tree.top || tree.cursor >= tree.top + page) {
      tree.top = tree.cursor > page / 2 ? tree.cursor - page / 2 : 0;
    }

    ensureVisible();
    ui.invalidate();
    if (old != tree.cursor && onSelect) {
      onSelect();
    }
  }

  private void moveBy(long delta) {
    if (tree is null || !tree.length) {
      return;
    }

    auto r = cast(long)tree.cursor + delta;

    select(cast(size_t)max(0, min(r, cast(long)tree.length - 1)));
  }

  override bool keyDown(ref const Event e) {
    if (tree is null) {
      return false;
    }

    auto r = tree.cursor;

    switch (e.key) {
      case Key.up: moveBy(-1); break;
      case Key.down: moveBy(1); break;
      case Key.pageUp: moveBy(-(visibleRows - 1)); break;
      case Key.pageDown: moveBy(visibleRows - 1); break;
      case Key.home: select(0); break;
      case Key.end: select(tree.length - 1); break;
      case Key.right:
        if (!tree.canExpand(r)) {
          break;
        }

        if (!tree.isExpanded(r)) {
          toggle(r);
        } else {
          moveBy(1);
        }

        break;
      case Key.left:
        if (tree.isExpanded(r)) {
          toggle(r);
        } else {
          auto p = tree.parentRow(r);

          if (p != noRow) {
            select(p);
          }
        }

        break;
      case Key.space:
        toggle(r);
        break;
      case Key.enter:
        if (tree.canExpand(r)) {
          toggle(r);
        } else if (onActivate) {
          onActivate();
        }

        break;
      case Key.f2:
        if (e.shift) {
          beginEdit(true);
        } else {
          beginEdit(false);
        }

        break;
      case Key.plus:
        if (!e.ctrl) {
          tree.expandAll(r);
          ui.invalidate();
          break;
        }

        return false;
      case Key.minus:
        if (!e.ctrl) {
          tree.collapseAll(r);
          ui.invalidate();
          break;
        }

        return false;
      case Key.menu:
        if (onContextMenu) {
          onContextMenu(rect.x + ui.px(40), rowY(r) + rowH);
        }

        break;
      default:
        return false;
    }

    return true;
  }

  void toggle(size_t r) {
    tree.toggle(r);
    ensureVisible();
    ui.invalidate();
  }

  int rowY(size_t r) {
    return body.y + cast(int)(cast(long)r - cast(long)tree.top) * rowH;
  }

  private size_t rowAt(int y) {
    if (tree is null || y < body.y) {
      return noRow;
    }

    auto r = tree.top + (y - body.y) / rowH;

    return r < tree.length ? r : noRow;
  }

  override Cursor cursorAt(int x, int y) {
    if (draggingSplit || (abs(x - splitX) <= ui.px(3) && y < rect.y + headerH)) {
      return Cursor.resizeH;
    }

    return Cursor.arrow;
  }

  override bool mouseDown(ref const Event e) {
    if (editing && editor.rect.contains(e.x, e.y)) {
      return editor.mouseDown(e);
    }

    if (editing) {
      finishEdit(true);
    }

    ui.setFocus(this);
    ui.capture = this;

    if (e.y < rect.y + headerH) {
      if (abs(e.x - splitX) <= ui.px(5)) {
        draggingSplit = true;
      }

      return true;
    }

    if (vbar.mouseDown(e.x, e.y)) {
      tree.top = cast(size_t)vbar.pos;
      ui.invalidate();

      return true;
    }

    auto r = rowAt(e.y);

    if (r == noRow) {
      return true;
    }

    select(r);

    if (e.button == MouseButton.right) {
      if (onContextMenu) {
        onContextMenu(e.x, e.y);
      }

      return true;
    }

    if (e.button != MouseButton.left) {
      return true;
    }

    int indent = rect.x + ui.px(4) + cast(int)tree.rows[r].depth * ui.px(16);
    bool onArrow = e.x >= indent - ui.px(2) && e.x < indent + ui.px(15);

    if (onArrow && tree.canExpand(r)) {
      toggle(r);
    } else if (e.clicks == 2) {
      if (tree.canExpand(r)) {
        toggle(r);
      } else if (e.x >= splitX) {
        beginEdit(false);
      } else if (onActivate) {
        onActivate();
      }
    }

    return true;
  }

  override void mouseMove(ref const Event e) {
    if (editing && ui.capture is editor) {
      return editor.mouseMove(e);
    }

    if (draggingSplit) {
      auto w = rect.w - barWidth;

      split = max(0.15f, min(0.85f, cast(float)(e.x - rect.x) / w));
      if (editing) {
        placeEditor();
      }

      ui.invalidate();

      return;
    }

    if (vbar.mouseMove(e.x, e.y)) {
      tree.top = cast(size_t)vbar.pos;
      ui.invalidate();

      return;
    }

    bool hot = vbar.rect.contains(e.x, e.y);
    auto r = rowAt(e.y);
    int h = r == noRow || hot ? -1 : cast(int)r;

    if (h != hoverRow || hot != barHot) {
      hoverRow = h;
      barHot = hot;
      ui.invalidate();
    }
  }

  override void mouseUp(ref const Event e) {
    if (editing && ui.capture is editor) {
      return editor.mouseUp(e);
    }

    draggingSplit = false;
    vbar.mouseUp();
  }

  override void mouseLeave() {
    if (hoverRow >= 0 || barHot) {
      hoverRow = -1;
      barHot = false;
      ui.invalidate();
    }
  }

  override bool wheel(ref const Event e) {
    if (tree is null || e.wheelY == 0) {
      return false;
    }

    long top = cast(long)tree.top - cast(long)(e.wheelY * 3);
    long maxTop = cast(long)tree.length - visibleRows;

    tree.top = cast(size_t)max(0, min(top, maxTop));
    ui.invalidate();

    return true;
  }

  @property bool isEditing() const { return editing; }

  void beginEdit(bool key) {
    if (tree is null) {
      return;
    }

    auto id = tree.selected;
    auto doc = tree.doc;
    auto n = &doc.nodes[id];

    if (key && !doc.hasKey(id)) {
      return;
    }

    if (!key && n.isContainer) {
      if (onActivate) {
        onActivate();
      }

      return;
    }

    auto text = key ? doc.key(id) : doc.value(id, 1 << 20);

    if (!key && text.length >= 1 << 20) {
      if (onActivate) {
        onActivate();
      }

      return;
    }

    editing = true;
    editingKey = key;
    editNode = id;
    editor.setText(text, true);
    placeEditor();
    ui.setFocus(editor);
    ui.invalidate();
  }

  private void placeEditor() {
    auto r = tree.rowOf(editNode);

    if (r == noRow) {
      cancelEdit();

      return;
    }

    int y = rowY(r);
    int x0, x1;

    if (editingKey) {
      int indent = rect.x + ui.px(4) + cast(int)tree.rows[r].depth * ui.px(16) + ui.px(34);

      x0 = indent - ui.px(4);
      x1 = splitX - ui.px(2);
    } else {
      x0 = splitX + ui.px(2);
      x1 = body.right - ui.px(2);
    }

    editor.layout(Rect(x0, y + ui.px(1), x1 - x0, rowH - ui.px(2)));
  }

  void finishEdit(bool commit) {
    if (!editing) {
      return;
    }

    editing = false;
    auto node = editNode;

    editNode = noNode;
    ui.setFocus(this);
    ui.invalidate();
    if (commit && onEdit) {
      onEdit(node, editor.text, editingKey);
    }
  }

  void cancelEdit() {
    if (!editing) {
      return;
    }

    editing = false;
    editNode = noNode;
    if (ui.focus is editor) {
      ui.setFocus(this);
    }
  }
}

private int abs(int v) { return v < 0 ? -v : v; }
