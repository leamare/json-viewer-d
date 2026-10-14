module doc.document;

import core.stdc.string : memmove;
import std.array : Appender;
import std.mmfile : MmFile;

public import doc.node;
import formats.compression : Compression;
import doc.text;

enum Format : ubyte {
  unknown,
  json,
  jsonl,
  kv,
  kv3,
}

string formatName(Format f) {
  final switch (f) {
    case Format.unknown: return "Unknown";
    case Format.json: return "JSON";
    case Format.jsonl: return "JSON Lines";
    case Format.kv: return "KeyValues";
    case Format.kv3: return "KeyValues3";
  }
}

final class Document {
  string path;
  Format format;
  string kv3Header;
  Node[] nodes;

  Compression compression;
  ulong fileSize;

  string error;
  ulong errorPos;
  double parseTime = 0;

  private const(char)[] source;
  private MmFile mapping;
  private char[] pool;

  private Change[] undoList;
  private Change[] redoList;
  private ulong lastChangeId;
  private ulong savedState;
  private ulong changes;

  this() {}

  this(const(char)[] text, MmFile map = null) {
    source = text;
    mapping = map;
    fileSize = text.length;
  }

  @property const(char)[] sourceText() const { return source; }
  @property size_t poolSize() const { return pool.length; }

  void detachSource() {
    if (mapping is null) {
      return;
    }

    source = source.idup;
    destroy(mapping);
    mapping = null;
  }

  @property uint root() const { return 0; }
  @property size_t length() const { return nodes.length; }
  bool empty() const { return nodes.length == 0; }

  ref inout(Node) opIndex(uint i) inout { return nodes[i]; }

  const(char)[] bufferOf(ref const Node n) const {
    return n.has(NodeFlags.pooled) ? pool : source;
  }

  const(char)[] keyRaw(uint i) const {
    auto n = &nodes[i];

    if (!n.has(NodeFlags.hasKey)) {
      return null;
    }

    auto buf = bufferOf(*n);
    auto start = n.pos - n.keyGap;

    return buf[cast(size_t)start .. cast(size_t)(start + n.keyLen)];
  }

  const(char)[] valueRaw(uint i) const {
    auto n = &nodes[i];

    if (n.isContainer) {
      return null;
    }

    auto buf = bufferOf(*n);

    return buf[cast(size_t)n.pos .. cast(size_t)(n.pos + n.len)];
  }

  bool hasKey(uint i) const { return nodes[i].has(NodeFlags.hasKey); }

  string key(uint i, size_t maxLen = size_t.max) const {
    auto raw = keyRaw(i);

    if (raw is null) {
      return null;
    }

    return decodeString(raw, nodes[i].keySyntax, maxLen);
  }

  string value(uint i, size_t maxLen = size_t.max) const {
    auto n = &nodes[i];

    final switch (n.type) {
      case NodeType.string:
        return decodeString(valueRaw(i), n.valueSyntax, maxLen);
      case NodeType.null_:
        return "null";
      case NodeType.boolean:
      case NodeType.number:
        return valueRaw(i).idup;
      case NodeType.object:
      case NodeType.array:
        return null;
    }
  }

  uint childCount(uint i) const { return nodes[i].isContainer ? nodes[i].len : 0; }
  uint parentOf(uint i) const { return nodes[i].parent; }

  auto children(uint i) const {
    static struct Children {
      const(Node)[] nodes;
      uint cur, end;

      bool empty() const { return cur >= end; }
      uint front() const { return cur; }
      void popFront() { cur = nodes[cur].end; }
    }

    return Children(nodes, i + 1, nodes[i].end);
  }

  uint childAt(uint i, size_t index) const {
    size_t k = 0;

    foreach (c; children(i)) {
      if (k++ == index) {
        return c;
      }
    }

    return noNode;
  }

  size_t indexInParent(uint i) const {
    auto p = nodes[i].parent;

    if (p == noNode) {
      return 0;
    }

    size_t k = 0;

    foreach (c; children(p)) {
      if (c == i) {
        return k;
      }

      k++;
    }

    return 0;
  }

  uint depthOf(uint i) const {
    uint d = 0;

    for (uint p = nodes[i].parent; p != noNode; p = nodes[p].parent) {
      d++;
    }

    return d;
  }

  ulong sourcePos(uint i) const {
    if (nodes[i].has(NodeFlags.pooled)) {
      return ulong.max;
    }

    return nodes[i].pos;
  }

  string pathOf(uint i) const {
    uint[] chain;

    for (uint c = i; c != noNode && nodes[c].parent != noNode; c = nodes[c].parent) {
      chain ~= c;
    }

    Appender!string res;

    res.put('$');
    foreach_reverse (c; chain) {
      auto p = nodes[c].parent;

      if (nodes[p].type == NodeType.array || !hasKey(c)) {
        import std.conv : to;
        res.put('[');
        res.put(indexInParent(c).to!string);
        res.put(']');
      } else {
        auto k = key(c);

        if (k.length && isBareKey(k)) {
          res.put('.');
          res.put(k);
        } else {
          res.put('[');
          putJsonString(res, k);
          res.put(']');
        }
      }
    }

    return res.data;
  }

  ulong appendPool(const(char)[] text) {
    auto at = pool.length;

    pool ~= text;

    return at;
  }

  @property bool modified() const { return currentState != savedState; }
  @property ulong revision() const { return changes; }
  @property bool canUndo() const { return currentState != 0; }
  @property bool canRedo() const { return redoList.length > 0; }

  void markSaved() { savedState = currentState; }

  private ulong currentState() const {
    foreach_reverse (ref c; undoList) {
      if (!c.silent) {
        return c.id;
      }
    }

    return 0;
  }

  /// Called after nodes [start, oldEnd) were replaced and everything after
  /// them moved by delta, so views can fix indices they keep
  void delegate(uint start, uint oldEnd, long delta)[] onShift;

  /// Replaces `count` nodes at `start` (complete sibling subtrees of `parent`)
  /// with `fresh` nodes. Fresh nodes use local indices: parent/end are
  /// relative to the start of the fresh array, top level nodes have no parent.
  /// Silent changes are view things like opening JSON inside a string, they
  /// don't make the document modified.
  void replace(uint parent, uint start, uint count, const(Node)[] fresh, bool silent = false) {
    auto c = Change(parent, start, count, fresh.dup, false);

    if (!silent) {
      redoList.length = 0;
    }

    auto back = apply(c);

    back.silent = silent;
    pushUndo(back);
  }

  void patch(uint i, Node n) {
    n.parent = nodes[i].parent;
    n.end = nodes[i].end;
    if (nodes[i].isContainer) {
      n.len = nodes[i].len;
    }

    auto c = Change(n.parent, i, 1, [n], true);

    redoList.length = 0;
    pushUndo(apply(c));
  }

  uint undo() {
    while (undoList.length && undoList[$ - 1].silent) {
      apply(undoList[$ - 1]);
      undoList.length--;
    }

    if (!undoList.length) {
      return noNode;
    }

    auto c = undoList[$ - 1];

    undoList.length--;
    auto back = apply(c);

    back.id = c.id;
    redoList ~= back;

    return c.start < nodes.length ? c.start : 0;
  }

  uint redo() {
    if (!redoList.length) {
      return noNode;
    }

    auto c = redoList[$ - 1];

    redoList.length--;
    auto back = apply(c);

    back.id = c.id;
    undoList ~= back;

    return c.start < nodes.length ? c.start : 0;
  }

  private void pushUndo(Change c) {
    c.id = ++lastChangeId;
    undoList ~= c;
  }

  private struct Change {
    uint parent;
    uint start;
    uint count;
    Node[] nodes;
    bool patch;
    ulong id;
    bool silent;
  }

  private Change apply(Change c) {
    changes++;
    if (c.patch) {
      auto old = nodes[c.start];
      auto n = c.nodes[0];

      n.parent = old.parent;
      n.end = old.end;
      nodes[c.start] = n;

      return Change(c.parent, c.start, 1, [old], true);
    }

    auto removed = replaceRange(c.parent, c.start, c.count, c.nodes);
    long delta = cast(long)c.nodes.length - c.count;

    foreach (listener; onShift) {
      listener(c.start, c.start + c.count, delta);
    }

    return Change(c.parent, c.start, cast(uint)c.nodes.length, removed, false);
  }

  private Node[] replaceRange(uint parent, uint start, uint count, const(Node)[] fresh) {
    auto oldEnd = start + count;
    auto removed = nodes[start .. oldEnd].dup;
    size_t removedTop = 0;

    foreach (ref n; removed) {
      if (n.parent == parent) {
        n.parent = noNode;
        removedTop++;
      } else {
        n.parent -= start;
      }

      n.end -= start;
    }

    long delta = cast(long)fresh.length - count;
    auto oldLen = nodes.length;

    if (delta > 0) {
      nodes.length = oldLen + cast(size_t)delta;
      if (oldLen > oldEnd) {
        memmove(&nodes[oldEnd + cast(size_t)delta], &nodes[oldEnd], (oldLen - oldEnd) * Node.sizeof);
      }
    } else if (delta < 0) {
      if (oldLen > oldEnd) {
        memmove(&nodes[start + fresh.length], &nodes[oldEnd], (oldLen - oldEnd) * Node.sizeof);
      }

      nodes.length = cast(size_t)(oldLen + delta);
      nodes.assumeSafeAppend();
    }

    size_t freshTop = 0;

    foreach (k, n; fresh) {
      auto dst = &nodes[start + k];

      *dst = n;
      if (n.parent == noNode) {
        dst.parent = parent;
        freshTop++;
      } else {
        dst.parent = n.parent + start;
      }

      dst.end = n.end + start;
    }

    foreach (ref n; nodes[start + fresh.length .. $]) {
      n.end = cast(uint)(n.end + delta);
      if (n.parent != noNode && n.parent >= oldEnd) {
        n.parent = cast(uint)(n.parent + delta);
      }
    }

    for (auto p = parent; p != noNode; p = nodes[p].parent) {
      nodes[p].end = cast(uint)(nodes[p].end + delta);
    }

    if (parent != noNode) {
      nodes[parent].len = cast(uint)(nodes[parent].len + freshTop - removedTop);
    }

    return removed;
  }
}
