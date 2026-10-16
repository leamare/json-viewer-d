module tui.table;

import std.algorithm : min, max;
import std.conv : to;

import doc.document;
import tui.screen;
import tui.term;
import view.actions : containerSummary, describeNode, nodeLabel, valuePreview;
import view.search : ValueFilter, parseValueFilter;
import view.tree : TreeModel;

/// Children of a container as a table, columns are keys of child objects
final class TuiTable {
  private Document doc;
  private TreeModel tree;
  private uint node = noNode;
  private ulong revision;

  private uint[] baseRows;
  private const(uint)[] baseIndices;
  private uint[] rows;
  private uint[] indices;
  private Column[] columns;
  private bool byKeys;

  private size_t cursor;
  private size_t top;
  private size_t current;
  private size_t firstShown = 1;
  private int sortColumn = -1;
  private int sortDir;

  private enum Kind {
    label,
    key,
    value,
    type,
  }

  private static struct Column {
    string title;
    string key;
    Kind kind;
    int width;
    string filter;
  }

  @property size_t rowCount() const { return rows.length; }
  @property size_t allRows() const { return baseRows.length; }

  void load(Document d, TreeModel t, uint n) {
    if (d is doc && n == node && d.revision == revision) {
      return;
    }

    bool same = d is doc && n == node;

    doc = d;
    tree = t;
    node = n;
    revision = d.revision;

    const(uint)[] ids, idx;

    t.visibleChildren(n, ids, idx);
    baseRows = ids.dup;
    baseIndices = idx;
    if (!same) {
      cursor = 0;
      top = 0;
      current = 0;
      firstShown = 1;
      sortColumn = -1;
      sortDir = 0;
      buildColumns();
    }

    apply();
  }

  private void buildColumns() {
    columns.length = 0;

    auto sample = baseRows[0 .. min(baseRows.length, 300)];
    size_t objects;

    foreach (c; sample) {
      if (doc.nodes[c].type == NodeType.object) {
        objects++;
      }
    }

    byKeys = sample.length && objects * 10 >= sample.length * 6;
    columns ~= Column(doc.nodes[node].type == NodeType.array ? "#" : "Key", null, Kind.label);
    if (byKeys) {
      bool[string] seen;

      foreach (c; sample) {
        if (doc.nodes[c].type != NodeType.object) {
          continue;
        }

        foreach (k; doc.children(c)) {
          auto key = doc.key(k);

          if (key in seen || columns.length > 60) {
            continue;
          }

          seen[key] = true;
          columns ~= Column(key, key, Kind.key);
        }
      }
    } else {
      columns ~= Column("Value", null, Kind.value);
      columns ~= Column("Type", null, Kind.type);
    }

    foreach (ci, ref col; columns) {
      int w = textWidth(col.title) + 2;

      foreach (k, row; sample[0 .. min(sample.length, 50)]) {
        w = max(w, textWidth(cellText(row, cast(uint)k, ci, 40)));
      }

      col.width = min(w, ci == 0 ? 14 : 30);
    }
  }

  private uint cellNode(uint row, size_t ci) {
    auto col = &columns[ci];

    if (col.kind != Kind.key) {
      return row;
    }

    if (doc.nodes[row].type != NodeType.object) {
      return noNode;
    }

    foreach (k; doc.children(row)) {
      if (doc.key(k) == col.key) {
        return k;
      }
    }

    return noNode;
  }

  private string cellText(uint row, uint index, size_t ci, size_t maxLen = 200) {
    final switch (columns[ci].kind) {
      case Kind.label:
        return nodeLabel(doc, row, maxLen, index);
      case Kind.type:
        return describeNode(doc, row);
      case Kind.value:
      case Kind.key:
        auto n = cellNode(row, ci);

        if (n == noNode) {
          return null;
        }

        return doc.nodes[n].isContainer ? containerSummary(doc, n, maxLen) : valuePreview(doc, n, maxLen);
    }
  }

  private void apply() {
    ValueFilter[] tests;
    size_t[] filtered;

    foreach (ci, ref col; columns) {
      if (col.filter.length) {
        tests ~= parseValueFilter(col.filter);
        filtered ~= ci;
      }
    }

    rows.length = 0;
    indices.length = 0;
    foreach (k, row; baseRows) {
      uint index = k < baseIndices.length ? baseIndices[k] : cast(uint)k;
      bool ok = true;

      foreach (f, ci; filtered) {
        auto text = cellText(row, index, ci, 1000);

        if (tests[f].matches(text) == tests[f].negate) {
          ok = false;
          break;
        }
      }

      if (ok) {
        rows ~= row;
        indices ~= index;
      }
    }

    if (sortColumn >= 0 && sortDir) {
      sortRows();
    }

    cursor = min(cursor, rows.length ? rows.length - 1 : 0);
  }

  private void sortRows() {
    import std.algorithm : sort, SwapStrategy;
    import std.uni : icmp;

    auto texts = new string[rows.length];
    auto numbers = new double[rows.length];
    auto isNumber = new bool[rows.length];

    foreach (k, row; rows) {
      texts[k] = cellText(row, indices[k], sortColumn, 1000);
      try {
        numbers[k] = columns[sortColumn].kind == Kind.label ? indices[k] : texts[k].to!double;
        isNumber[k] = true;
      } catch (Exception) {
      }
    }

    auto order = new size_t[rows.length];

    foreach (k; 0 .. order.length) {
      order[k] = k;
    }

    int dir = sortDir;

    bool less(size_t a, size_t b) {
      bool emptyA = !texts[a].length, emptyB = !texts[b].length;

      if (emptyA != emptyB) {
        return emptyB;
      }

      int cmp;

      if (isNumber[a] && isNumber[b]) {
        cmp = numbers[a] < numbers[b] ? -1 : numbers[a] > numbers[b];
      } else if (isNumber[a] != isNumber[b]) {
        cmp = isNumber[a] ? -1 : 1;
      } else {
        cmp = icmp(texts[a], texts[b]);
      }

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

  void draw(Screen screen, int x, int y, int w, int h, bool focused) {
    if (doc is null) {
      return;
    }

    auto dim = Style(Color.none, Color.none, Attr.dim);
    auto head = Style(Color.none, Color.none, Attr.bold);
    int bodyH = h - 1;

    if (current >= columns.length) {
      current = columns.length - 1;
    }

    // keep the current column on screen, the label column always stays
    if (current > 0 && current < firstShown) {
      firstShown = current;
    }

    while (current > 0 && columnRight(firstShown, current) > w && firstShown < current) {
      firstShown++;
    }

    if (cursor < top) {
      top = cursor;
    }

    if (cursor >= top + bodyH) {
      top = cursor - bodyH + 1;
    }

    auto shown = shownColumns(w);

    foreach (k, ci; shown) {
      auto col = &columns[ci];
      int cx = x + columnX(shown, k);
      auto st = col.filter.length ? Style(Color.blue, Color.none, Attr.bold) : head;

      if (focused && ci == current) {
        st.attr |= Attr.reverse;
      }

      auto title = col.title;

      if (sortColumn == cast(int)ci && sortDir) {
        title ~= sortDir > 0 ? " ▲" : " ▼";
      }

      screen.fill(cx, y, col.width, ' ', st);
      screen.put(cx, y, title, st, cx + col.width);
      screen.put(cx + col.width, y, "│", dim);
    }

    foreach (k; 0 .. bodyH) {
      auto r = top + k;

      if (r >= rows.length) {
        break;
      }

      int ry = y + 1 + k;

      foreach (j, ci; shown) {
        int cx = x + columnX(shown, j);
        auto n = cellNode(rows[r], ci);
        auto st = columns[ci].kind == Kind.label || columns[ci].kind == Kind.type ? dim : valueStyle(n);

        screen.put(cx, ry, cellText(rows[r], indices[r], ci, 300), st, cx + columns[ci].width);
        screen.put(cx + columns[ci].width, ry, "│", dim);
      }

      if (r == cursor) {
        screen.addAttr(x, ry, w, focused ? Attr.reverse : Attr.underline);
      }
    }
  }

  private Style valueStyle(uint n) {
    if (n == noNode) {
      return Style.init;
    }

    final switch (doc.nodes[n].type) {
      case NodeType.string: return tree.holdsDocument(n) ? Style(Color.none, Color.none, Attr.dim) : Style(Color.green);
      case NodeType.number: return Style(Color.cyan);
      case NodeType.boolean: return Style(Color.yellow);
      case NodeType.null_: return Style(Color.magenta, Color.none, Attr.dim);
      case NodeType.object:
      case NodeType.array: return Style(Color.none, Color.none, Attr.dim);
    }
  }

  private size_t[] shownColumns(int w) {
    size_t[] res = [0];
    int used = columns[0].width + 1;

    foreach (ci; firstShown .. columns.length) {
      if (used >= w) {
        break;
      }

      res ~= ci;
      used += columns[ci].width + 1;
    }

    return res;
  }

  private int columnX(const(size_t)[] shown, size_t k) {
    int x = 0;

    foreach (j; 0 .. k) {
      x += columns[shown[j]].width + 1;
    }

    return x;
  }

  private int columnRight(size_t from, size_t to) {
    int x = columns[0].width + 1;

    foreach (ci; from .. to + 1) {
      x += columns[ci].width + 1;
    }

    return x;
  }

  /// Keys while the table has focus. ask shows a prompt, open shows a node in the tree.
  bool key(ref KeyEvent ev, int page, void delegate(string, string, void delegate(string)) ask, void delegate(uint) open) {
    switch (ev.key) {
      case Key.up: move(-1); break;
      case Key.down: move(1); break;
      case Key.pageUp: move(-page); break;
      case Key.pageDown: move(page); break;
      case Key.home: cursor = 0; break;
      case Key.end: cursor = rows.length ? rows.length - 1 : 0; break;
      case Key.left:
        if (current) {
          current--;
        }

        break;
      case Key.right:
        if (current + 1 < columns.length) {
          current++;
        }

        break;
      case Key.enter:
        if (rows.length) {
          auto n = cellNode(rows[cursor], current);

          open(n == noNode ? rows[cursor] : n);
        }

        break;
      case Key.character:
        return charKey(ev.ch, ask);
      default:
        return false;
    }

    return true;
  }

  private bool charKey(dchar c, void delegate(string, string, void delegate(string)) ask) {
    switch (c) {
      case 'k': move(-1); break;
      case 'j': move(1); break;
      case 'h':
        if (current) {
          current--;
        }

        break;
      case 'l':
        if (current + 1 < columns.length) {
          current++;
        }

        break;
      case 'o':
        if (sortColumn != cast(int)current) {
          sortColumn = cast(int)current;
          sortDir = 1;
        } else if (sortDir == 1) {
          sortDir = -1;
        } else {
          sortColumn = -1;
          sortDir = 0;
        }

        apply();
        break;
      case 'f':
        auto ci = current;

        ask("Filter " ~ columns[ci].title ~ " (text, =text, !text, >10): ", columns[ci].filter, (text) {
          columns[ci].filter = text;
          apply();
        });
        break;
      case 'F':
        foreach (ref col; columns) {
          col.filter = null;
        }

        apply();
        break;
      default:
        return false;
    }

    return true;
  }

  private void move(long delta) {
    if (!rows.length) {
      return;
    }

    cursor = cast(size_t)max(0, min(cast(long)cursor + delta, cast(long)rows.length - 1));
  }
}
