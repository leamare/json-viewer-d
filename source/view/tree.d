module view.tree;

import std.array : insertInPlace;
import std.range : assumeSorted;

import doc.document;

struct Row {
  uint node;
  uint depth;
}

enum size_t noRow = size_t.max;

/// Keeps the rows that are currently visible. Rows go in the same order as
/// nodes, so a node can be found among rows with a binary search.
final class TreeModel {
  Document doc;
  Row[] rows;
  size_t cursor;
  size_t top;

  this(Document doc) {
    this.doc = doc;
    rebuild();
  }

  @property size_t length() const { return rows.length; }
  @property uint selected() const { return rows.length ? rows[cursor].node : noNode; }

  void rebuild() {
    rows.length = 0;
    rows.assumeSafeAppend();
    if (!doc.empty) {
      collect(0, 0, rows);
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

    return n.isContainer && n.len > 0;
  }

  void expand(size_t r) {
    auto id = rows[r].node;
    auto n = &doc.nodes[id];

    if (!n.isContainer || n.has(NodeFlags.expanded)) {
      return;
    }

    n.set(NodeFlags.expanded);
    Row[] sub;

    collect(id, rows[r].depth, sub);
    rows.insertInPlace(r + 1, sub[1 .. $]);
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

  void toggle(size_t r) {
    if (isExpanded(r)) {
      collapse(r);
    } else {
      expand(r);
    }
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

    collect(id, rows[r].depth, sub);
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
    auto idx = sorted.lowerBound(Row(node, 0)).length;

    if (idx < rows.length && rows[idx].node == node) {
      return idx;
    }

    return noRow;
  }

  void reveal(uint node) {
    if (node == noNode || node >= doc.length) {
      return;
    }

    bool changed;

    for (auto p = doc.nodes[node].parent; p != noNode; p = doc.nodes[p].parent) {
      if (!doc.nodes[p].has(NodeFlags.expanded)) {
        doc.nodes[p].set(NodeFlags.expanded);
        changed = true;
      }
    }

    if (changed) {
      rebuild();
    }

    auto r = rowOf(node);

    if (r != noRow) {
      cursor = r;
    }
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

    reveal(focus);
  }

  private void removeSubRows(size_t r) {
    auto end = doc.nodes[rows[r].node].end;
    auto sorted = rows[r + 1 .. $].assumeSorted!((a, b) => a.node < b.node);
    auto count = sorted.lowerBound(Row(end, 0)).length;

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

  private void collect(uint start, uint depth, ref Row[] output) const {
    static struct Frame {
      uint next;
      uint end;
      uint depth;
    }

    output ~= Row(start, depth);
    if (!expandedContainer(start)) {
      return;
    }

    Frame[] stack = [Frame(start + 1, doc.nodes[start].end, depth + 1)];

    while (stack.length) {
      auto f = stack[$ - 1];

      if (f.next >= f.end) {
        stack.length--;
        continue;
      }

      auto c = f.next;

      stack[$ - 1].next = doc.nodes[c].end;
      output ~= Row(c, f.depth);
      if (expandedContainer(c)) {
        stack ~= Frame(c + 1, doc.nodes[c].end, f.depth + 1);
      }
    }
  }

  private bool expandedContainer(uint i) const {
    auto n = &doc.nodes[i];

    return n.isContainer && n.has(NodeFlags.expanded);
  }
}
