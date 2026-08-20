module view.search;

import std.uni : toLower;

import doc.document;

struct Query {
  string text;
  bool keys = true;
  bool values = true;
  bool caseSensitive;
}

uint findNext(const Document doc, uint from, in Query q, bool backwards = false) {
  if (!q.text.length || doc.empty) {
    return noNode;
  }

  auto matcher = Matcher(q);
  auto total = cast(uint)doc.length;

  if (from >= total) {
    from = backwards ? 0 : total - 1;
  }

  foreach (step; 1 .. total + 1) {
    uint i = backwards
      ? cast(uint)((from + total - step % total) % total)
      : cast(uint)((from + step) % total);
    if (matches(doc, i, matcher)) {
      return i;
    }
  }

  return noNode;
}

size_t countMatches(const Document doc, in Query q, size_t limit = 100_000) {
  if (!q.text.length) {
    return 0;
  }

  auto matcher = Matcher(q);
  size_t count;

  foreach (i; 0 .. cast(uint)doc.length) {
    if (matches(doc, i, matcher) && ++count >= limit) {
      break;
    }
  }

  return count;
}

private bool matches(const Document doc, uint i, ref const Matcher m) {
  const n = &doc.nodes[i];

  if (m.q.keys && n.has(NodeFlags.hasKey)) {
    if (n.has(NodeFlags.keyEsc) || !m.ascii ? m.match(doc.key(i)) : m.match(doc.keyRaw(i))) {
      return true;
    }
  }

  if (m.q.values && !n.isContainer) {
    if (n.has(NodeFlags.escaped) || !m.ascii ? m.match(doc.value(i)) : m.match(doc.valueRaw(i))) {
      return true;
    }
  }

  return false;
}

private struct Matcher {
  Query q;
  string needle;
  bool ascii;

  this(in Query query) {
    q = query;
    ascii = true;
    foreach (char c; q.text) {
      if (c >= 0x80) {
        ascii = false;
      }
    }

    needle = q.caseSensitive ? q.text : q.text.toLower;
  }

  bool match(const(char)[] hay) const {
    import std.algorithm : canFind;

    if (q.caseSensitive) {
      return hay.canFind(needle);
    }

    if (!ascii) {
      return hay.toLower.canFind(needle);
    }

    auto n = needle;

    if (n.length > hay.length) {
      return false;
    }

    outer: foreach (k; 0 .. hay.length - n.length + 1) {
      foreach (j; 0 .. n.length) {
        char c = hay[k + j];

        if (c >= 'A' && c <= 'Z') {
          c += 32;
        }

        if (c != n[j]) {
          continue outer;
        }
      }

      return true;
    }

    return false;
  }
}
