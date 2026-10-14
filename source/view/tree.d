module view.tree;

import std.array : insertInPlace;
import std.range : assumeSorted;

import doc.document;
import view.search : Filter, parseFilter, matchesFilter;

struct Row {
  uint node;
  uint depth;
  uint index;
}

struct ChildFilter {
  Filter filter;
  uint[] ids;
  uint[] indices;
  bool dirty;
}

enum size_t noRow = size_t.max;

/// Keeps the rows that are currently visible. Rows go in the same order as
/// nodes, so a node can be found among rows with a binary search.
final class TreeModel {
  Document doc;
  Row[] rows;
  size_t cursor;
  size_t top;

  private ChildFilter[uint] filters;
  private uint pathNode = noNode;
  private ulong pathRevision;
  private string path;

  this(Document doc) {
    this.doc = doc;
    doc.onShift ~= &shifted;
    rebuild();
  }

  @property size_t length() const { return rows.length; }
  @property uint selected() const { return rows.length ? rows[cursor].node : noNode; }

  void rebuild() {
    rows.length = 0;
    rows.assumeSafeAppend();
    if (!doc.empty) {
      collect(0, 0, 0, rows);
    }

    if (cursor >= rows.length) {
      cursor = rows.length ? rows.length - 1 : 0;
    }
  }

  bool isExpanded(size_t r) const {
    auto n = &doc.nodes[rows[r].node];

    return n.isContainer && n.has(NodeFlags.expanded);
  }

  bool canExpand(size_t r) const {
    auto n = &doc.nodes[rows[r].node];

    if (n.type == NodeType.string) {
      return holdsDocument(rows[r].node);
    }

    return n.isContainer && n.len > 0;
  }

  bool holdsDocument(uint i) const {
    import doc.text : rawLooksLikeJson;

    auto n = &doc.nodes[i];

    return n.type == NodeType.string && rawLooksLikeJson(doc.valueRaw(i), n.valueSyntax);
  }

  string expand(size_t r) {
    auto id = rows[r].node;
    auto n = &doc.nodes[id];

    if (holdsDocument(id)) {
      import doc.edit : expandEmbedded;

      auto err = expandEmbedded(doc, id);

      if (!err.length) {
        rebuild();
      }

      return err;
    }

    if (!n.isContainer || n.has(NodeFlags.expanded)) {
      return null;
    }

    n.set(NodeFlags.expanded);
    Row[] sub;

    collect(id, rows[r].depth, rows[r].index, sub);
    rows.insertInPlace(r + 1, sub[1 .. $]);

    return null;
  }

  void collapse(size_t r) {
    auto id = rows[r].node;
    auto n = &doc.nodes[id];

    if (!n.has(NodeFlags.expanded)) {
      return;
    }

    n.set(NodeFlags.expanded, false);
    removeSubRows(r);
  }

  string toggle(size_t r) {
    if (isExpanded(r)) {
      collapse(r);

      return null;
    }

    return expand(r);
  }

  void expandAll(size_t r) {
    auto id = rows[r].node;

    foreach (ref n; doc.nodes[id .. doc.nodes[id].end]) {
      if (n.isContainer) {
        n.set(NodeFlags.expanded);
      }
    }

    removeSubRows(r);
    Row[] sub;

    collect(id, rows[r].depth, rows[r].index, sub);
    rows.insertInPlace(r + 1, sub[1 .. $]);
  }

  void collapseAll(size_t r) {
    auto id = rows[r].node;

    foreach (ref n; doc.nodes[id .. doc.nodes[id].end]) {
      n.set(NodeFlags.expanded, false);
    }

    removeSubRows(r);
  }

  size_t rowOf(uint node) const {
    auto sorted = rows.assumeSorted!((a, b) => a.node < b.node);
    auto idx = sorted.lowerBound(Row(node, 0, 0)).length;

    if (idx < rows.length && rows[idx].node == node) {
      return idx;
    }

    return noRow;
  }

  void reveal(uint node, bool keepFilters = false) {
    if (node == noNode || node >= doc.length) {
      return;
    }

    bool changed;
    uint child = node;

    for (auto p = doc.nodes[node].parent; p != noNode; p = doc.nodes[p].parent) {
      if (!doc.nodes[p].has(NodeFlags.expanded)) {
        doc.nodes[p].set(NodeFlags.expanded);
        changed = true;
      }

      if (auto f = keepFilters ? null : p in filters) {
        if (f.dirty) {
          evaluate(p, *f);
        }

        if (!hasId(f.ids, child)) {
          filters.remove(p);
          changed = true;
        }
      }

      child = p;
    }

    if (changed) {
      rebuild();
    }

    for (auto n = node; n != noNode; n = doc.nodes[n].parent) {
      auto r = rowOf(n);

      if (r != noRow) {
        cursor = r;
        break;
      }
    }
  }

  size_t setFilter(uint node, string text) {
    auto f = ChildFilter(parseFilter(text));

    if (f.filter.empty) {
      clearFilter(node);

      return doc.nodes[node].len;
    }

    evaluate(node, f);
    filters[node] = f;
    doc.nodes[node].set(NodeFlags.expanded);
    rebuild();

    return f.ids.length;
  }

  void clearFilter(uint node) {
    if (filters.remove(node)) {
      rebuild();
    }
  }

  const(ChildFilter)* filterOf(uint node) {
    auto f = node in filters;

    if (f !is null && f.dirty) {
      evaluate(node, *f);
    }

    return f;
  }

  void visibleChildren(uint node, out const(uint)[] ids, out const(uint)[] indices) {
    if (auto f = filterOf(node)) {
      ids = f.ids;
      indices = f.indices;

      return;
    }

    uint[] all, at;
    uint k = 0;

    all.reserve(doc.nodes[node].len);
    at.reserve(doc.nodes[node].len);
    foreach (c; doc.children(node)) {
      all ~= c;
      at ~= k++;
    }

    ids = all;
    indices = at;
  }

  private void evaluate(uint node, ref ChildFilter f) {
    f.ids.length = 0;
    f.indices.length = 0;
    uint index = 0;

    foreach (c; doc.children(node)) {
      if (matchesFilter(doc, c, f.filter)) {
        f.ids ~= c;
        f.indices ~= index;
      }

      index++;
    }

    f.dirty = false;
  }

  private void shifted(uint start, uint oldEnd, long delta) {
    ChildFilter[uint] moved;

    foreach (id, f; filters) {
      if (id >= oldEnd) {
        foreach (ref c; f.ids) {
          c = cast(uint)(c + delta);
        }

        moved[cast(uint)(id + delta)] = f;
      } else if (id < start) {
        if (doc.nodes[id].end >= start) {
          f.dirty = true;
        }

        moved[id] = f;
      }
    }

    filters = moved;
  }

  private static bool hasId(const(uint)[] ids, uint id) {
    auto sorted = ids.assumeSorted;

    return sorted.contains(id);
  }

  string selectedPath() {
    auto sel = selected;

    if (sel == noNode) {
      return null;
    }

    if (sel != pathNode || doc.revision != pathRevision) {
      path = doc.pathOf(sel);
      pathNode = sel;
      pathRevision = doc.revision;
    }

    return path;
  }

  size_t parentRow(size_t r) const {
    auto p = doc.nodes[rows[r].node].parent;

    return p == noNode ? noRow : rowOf(p);
  }

  void refresh(uint focus) {
    rebuild();
    if (focus == noNode) {
      return;
    }

    if (focus >= doc.length) {
      focus = cast(uint)doc.length - 1;
    }

    reveal(focus, true);
  }

  private void removeSubRows(size_t r) {
    auto end = doc.nodes[rows[r].node].end;
    auto sorted = rows[r + 1 .. $].assumeSorted!((a, b) => a.node < b.node);
    auto count = sorted.lowerBound(Row(end, 0, 0)).length;

    if (!count) {
      return;
    }

    if (cursor > r && cursor <= r + count) {
      cursor = r;
    } else if (cursor > r + count) {
      cursor -= count;
    }

    rows = rows[0 .. r + 1] ~ rows[r + 1 + count .. $];
  }

  private void collect(uint start, uint depth, uint index, ref Row[] output) {
    static struct Frame {
      uint next;
      uint end;
      uint depth;
      uint index;
      const(ChildFilter)* filter;
    }

    Frame open(uint node, uint d) {
      return Frame(node + 1, doc.nodes[node].end, d, 0, filterOf(node));
    }

    output ~= Row(start, depth, index);
    if (!expandedContainer(start)) {
      return;
    }

    Frame[] stack = [open(start, depth + 1)];

    while (stack.length) {
      auto f = &stack[$ - 1];
      uint c, at;

      if (f.filter !is null) {
        if (f.index >= f.filter.ids.length) {
          stack.length--;
          continue;
        }

        c = f.filter.ids[f.index];
        at = f.filter.indices[f.index];
      } else {
        if (f.next >= f.end) {
          stack.length--;
          continue;
        }

        c = f.next;
        at = f.index;
        f.next = doc.nodes[c].end;
      }

      f.index++;
      output ~= Row(c, f.depth, at);
      if (expandedContainer(c)) {
        stack ~= open(c, f.depth + 1);
      }
    }
  }

  private bool expandedContainer(uint i) const {
    auto n = &doc.nodes[i];

    return n.isContainer && n.has(NodeFlags.expanded);
  }
}
