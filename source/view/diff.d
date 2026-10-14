module view.diff;

import std.algorithm : max;

import doc.document;

enum DiffStatus : ubyte {
  same,
  changed,
  removed,
  added,
}

struct DiffEntry {
  uint a = noNode;
  uint b = noNode;
  DiffStatus status;
  bool expanded;
  bool built;
  uint[] children;
  uint index;
}

final class Diff {
  const Document a, b;
  DiffEntry[] entries;
  size_t added, removed, changed;

  private ulong[] hashA, hashB;

  this(const Document a, const Document b) {
    this.a = a;
    this.b = b;
    hashA = subtreeHashes(a);
    hashB = subtreeHashes(b);
    entries ~= DiffEntry(0, 0);
    entries[0].expanded = true;
    compare(0);
    countAll(0);
  }

  @property bool identical() const { return entries[0].status == DiffStatus.same; }

  const(uint)[] childrenOf(uint e) {
    if (!entries[e].built) {
      build(e);
    }

    return entries[e].children;
  }

  private void compare(uint e) {
    auto ai = entries[e].a, bi = entries[e].b;

    if (ai == noNode) {
      entries[e].status = DiffStatus.added;
    } else if (bi == noNode) {
      entries[e].status = DiffStatus.removed;
    } else if (hashA[ai] == hashB[bi]) {
      entries[e].status = DiffStatus.same;
    } else {
      entries[e].status = DiffStatus.changed;
      build(e);
    }
  }

  private void build(uint e) {
    entries[e].built = true;

    auto ai = entries[e].a, bi = entries[e].b;
    auto na = ai == noNode ? null : &a.nodes[ai];
    auto nb = bi == noNode ? null : &b.nodes[bi];

    if (na !is null && nb !is null) {
      if (na.type != nb.type || !na.isContainer) {
        return;
      }

      if (na.type == NodeType.object) {
        matchByKeys(e, ai, bi);
      } else {
        alignArrays(e, ai, bi);
      }

      return;
    }

    uint index = 0;

    if (na !is null && na.isContainer) {
      foreach (c; a.children(ai)) {
        add(e, c, noNode, index++);
      }
    } else if (nb !is null && nb.isContainer) {
      foreach (c; b.children(bi)) {
        add(e, noNode, c, index++);
      }
    }
  }

  private void add(uint parent, uint ai, uint bi, uint index) {
    auto e = cast(uint)entries.length;

    entries ~= DiffEntry(ai, bi);
    entries[e].index = index;
    entries[parent].children ~= e;
    compare(e);
  }

  private void matchByKeys(uint e, uint ai, uint bi) {
    uint[][string] fromB;
    bool[uint] used;

    foreach (c; b.children(bi)) {
      fromB[b.key(c)] ~= c;
    }

    uint index = 0;

    foreach (c; a.children(ai)) {
      auto list = a.key(c) in fromB;
      uint match = noNode;

      if (list !is null && (*list).length) {
        match = (*list)[0];
        *list = (*list)[1 .. $];
        used[match] = true;
      }

      add(e, c, match, index++);
    }

    foreach (c; b.children(bi)) {
      if (c !in used) {
        add(e, noNode, c, index++);
      }
    }
  }

  private void alignArrays(uint e, uint ai, uint bi) {
    uint[] xs, ys;

    foreach (c; a.children(ai)) {
      xs ~= c;
    }

    foreach (c; b.children(bi)) {
      ys ~= c;
    }

    size_t head = 0;

    while (head < xs.length && head < ys.length && hashA[xs[head]] == hashB[ys[head]]) {
      head++;
    }

    size_t tail = 0;

    while (tail < xs.length - head && tail < ys.length - head &&
      hashA[xs[$ - 1 - tail]] == hashB[ys[$ - 1 - tail]]) {
      tail++;
    }

    foreach (k; 0 .. head) {
      add(e, xs[k], ys[k], cast(uint)k);
    }

    auto midA = xs[head .. $ - tail], midB = ys[head .. $ - tail];

    if (midA.length * midB.length <= 4_000_000) {
      alignMiddle(e, midA, midB, cast(uint)head);
    } else {
      foreach (k; 0 .. max(midA.length, midB.length)) {
        add(e, k < midA.length ? midA[k] : noNode, k < midB.length ? midB[k] : noNode, cast(uint)(head + k));
      }
    }

    foreach (k; 0 .. tail) {
      add(e, xs[$ - tail + k], ys[$ - tail + k], cast(uint)(xs.length - tail + k));
    }
  }

  /// Longest common subsequence, elements in between are paired when they
  /// stand at the same place, so changed objects show what changed inside
  private void alignMiddle(uint e, const(uint)[] xs, const(uint)[] ys, uint offset) {
    auto n = xs.length, m = ys.length;
    auto table = new uint[(n + 1) * (m + 1)];

    foreach_reverse (i; 0 .. n) {
      foreach_reverse (j; 0 .. m) {
        auto at = i * (m + 1) + j;

        if (hashA[xs[i]] == hashB[ys[j]]) {
          table[at] = table[(i + 1) * (m + 1) + j + 1] + 1;
        } else {
          table[at] = max(table[(i + 1) * (m + 1) + j], table[i * (m + 1) + j + 1]);
        }
      }
    }

    size_t i = 0, j = 0;
    uint[] gapA, gapB;

    void flush() {
      foreach (k; 0 .. max(gapA.length, gapB.length)) {
        add(e, k < gapA.length ? gapA[k] : noNode, k < gapB.length ? gapB[k] : noNode, cast(uint)(offset + i));
      }

      gapA.length = 0;
      gapB.length = 0;
    }

    while (i < n || j < m) {
      if (i < n && j < m && hashA[xs[i]] == hashB[ys[j]]) {
        flush();
        add(e, xs[i], ys[j], cast(uint)(offset + i));
        i++;
        j++;
      } else if (j >= m || (i < n && table[(i + 1) * (m + 1) + j] >= table[i * (m + 1) + j + 1])) {
        gapA ~= xs[i++];
      } else {
        gapB ~= ys[j++];
      }
    }

    flush();
  }

  private void countAll(uint e) {
    final switch (entries[e].status) {
      case DiffStatus.same:
        return;
      case DiffStatus.added:
        added++;

        return;
      case DiffStatus.removed:
        removed++;

        return;
      case DiffStatus.changed:
        if (!entries[e].children.length) {
          changed++;
        }

        break;
    }

    foreach (c; entries[e].children) {
      countAll(c);
    }
  }
}

/// Hash of every subtree: type, key, value and children in order. Parents go
/// before children in the node array, so walking it backwards is enough.
ulong[] subtreeHashes(const Document doc) {
  auto res = new ulong[doc.length];

  foreach_reverse (i; 0 .. cast(uint)doc.length) {
    const n = &doc.nodes[i];
    ulong h = fnv(0xcbf29ce484222325UL, cast(ubyte)n.type);

    if (n.has(NodeFlags.hasKey)) {
      h = fnv(h, n.has(NodeFlags.keyEsc) || n.keySyntax != Syntax.json ? doc.key(i) : unquote(doc.keyRaw(i)));
    }

    if (n.isContainer) {
      foreach (c; doc.children(i)) {
        h = (h ^ res[c]) * 0x100000001b3UL;
      }
    } else if (n.type == NodeType.string && (n.has(NodeFlags.escaped) || n.valueSyntax != Syntax.json)) {
      h = fnv(h, doc.value(i));
    } else if (n.type == NodeType.string) {
      h = fnv(h, unquote(doc.valueRaw(i)));
    } else {
      h = fnv(h, doc.valueRaw(i));
    }

    res[i] = h;
  }

  return res;
}

private const(char)[] unquote(const(char)[] raw) {
  return raw.length >= 2 ? raw[1 .. $ - 1] : raw;
}

private ulong fnv(ulong h, ubyte v) {
  return (h ^ v) * 0x100000001b3UL;
}

private ulong fnv(ulong h, const(char)[] s) {
  foreach (char c; s) {
    h = (h ^ c) * 0x100000001b3UL;
  }

  return (h ^ 0xFF) * 0x100000001b3UL;
}
