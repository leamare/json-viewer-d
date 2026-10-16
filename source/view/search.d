module view.search;

import std.conv : to;
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

struct Filter {
  string text;
  private Term[] terms;

  @property bool empty() const { return terms.length == 0; }
}

private struct Term {
  string key;
  bool hasKey;
  bool negate;
  Matcher value;
}

Filter parseFilter(string text) {
  Filter f;

  f.text = text;
  foreach (word; splitWords(text)) {
    Term t;

    if (word.length > 1 && word[0] == '-') {
      t.negate = true;
      word = word[1 .. $];
    }

    auto eq = indexOfAny(word, "=:");

    if (eq > 0) {
      t.hasKey = true;
      t.key = word[0 .. eq].toLower;
      word = word[eq + 1 .. $];
    }

    Query q;

    q.text = word;
    t.value = Matcher(q);
    f.terms ~= t;
  }

  return f;
}

bool matchesFilter(const Document doc, uint child, in Filter f) {
  foreach (ref t; f.terms) {
    bool found = false;

    foreach (i; child .. doc.nodes[child].end) {
      if (termMatches(doc, i, t)) {
        found = true;
        break;
      }
    }

    if (found == t.negate) {
      return false;
    }
  }

  return true;
}

private bool termMatches(const Document doc, uint i, ref const Term t) {
  const n = &doc.nodes[i];

  if (t.hasKey) {
    if (!n.has(NodeFlags.hasKey) || !keyIs(doc, i, t.key)) {
      return false;
    }

    if (!t.value.needle.length) {
      return true;
    }

    return !n.isContainer && valueMatches(doc, i, t.value);
  }

  if (!t.value.needle.length) {
    return true;
  }

  if (n.has(NodeFlags.hasKey)) {
    auto key = n.has(NodeFlags.keyEsc) || !t.value.ascii ? doc.key(i) : doc.keyRaw(i);

    if (t.value.match(key)) {
      return true;
    }
  }

  return !n.isContainer && valueMatches(doc, i, t.value);
}

private bool valueMatches(const Document doc, uint i, ref const Matcher m) {
  if (doc.nodes[i].has(NodeFlags.escaped) || !m.ascii) {
    return m.match(doc.value(i));
  }

  return m.match(doc.valueRaw(i));
}

private bool keyIs(const Document doc, uint i, string lowerKey) {
  const n = &doc.nodes[i];

  if (n.has(NodeFlags.keyEsc) || n.keySyntax == Syntax.multiline) {
    return doc.key(i).toLower == lowerKey;
  }

  auto raw = doc.keyRaw(i);

  if (raw.length >= 2 && raw[0] == '"') {
    raw = raw[1 .. $ - 1];
  }

  foreach (char c; raw) {
    if (c >= 0x80) {
      return doc.key(i).toLower == lowerKey;
    }
  }

  if (raw.length != lowerKey.length) {
    return false;
  }

  foreach (k, char c; raw) {
    if (c >= 'A' && c <= 'Z') {
      c += 32;
    }

    if (c != lowerKey[k]) {
      return false;
    }
  }

  return true;
}

private string[] splitWords(string text) {
  string[] res;
  string cur;
  bool quoted;

  foreach (char c; text) {
    if (c == '"') {
      quoted = !quoted;
    } else if (c == ' ' && !quoted) {
      if (cur.length) {
        res ~= cur;
      }

      cur = null;
    } else {
      cur ~= c;
    }
  }

  if (cur.length) {
    res ~= cur;
  }

  return res;
}

private ptrdiff_t indexOfAny(string s, string chars) {
  foreach (k, char c; s) {
    foreach (char x; chars) {
      if (c == x) {
        return k;
      }
    }
  }

  return -1;
}

struct ValueFilter {
  enum Op {
    contains,
    exact,
    less,
    more,
    lessOrEqual,
    moreOrEqual,
  }

  Op op;
  string text;
  double number;
  bool negate;

  bool matches(string value) const {
    import std.algorithm : canFind;
    import std.uni : toLower;

    if (op == Op.contains) {
      return value.toLower.canFind(text);
    }

    if (op == Op.exact) {
      return value.toLower == text;
    }

    double v;

    try {
      v = value.to!double;
    } catch (Exception) {
      return false;
    }

    final switch (op) {
      case Op.contains:
      case Op.exact:
        return false;
      case Op.less: return v < number;
      case Op.more: return v > number;
      case Op.lessOrEqual: return v <= number;
      case Op.moreOrEqual: return v >= number;
    }
  }
}

/// "text", "=text", "!text", ">5", "<=5"
ValueFilter parseValueFilter(string s) {
  import std.string : strip;
  import std.uni : toLower;

  ValueFilter f;

  s = s.strip;
  if (s.length > 1 && s[0] == '!') {
    f.negate = true;
    s = s[1 .. $].strip;
  }

  foreach (op; [">=", "<=", ">", "<"]) {
    if (s.length > op.length && s[0 .. op.length] == op) {
      try {
        f.number = s[op.length .. $].strip.to!double;
        f.op = op == ">=" ? ValueFilter.Op.moreOrEqual : op == "<=" ? ValueFilter.Op.lessOrEqual :
          op == ">" ? ValueFilter.Op.more : ValueFilter.Op.less;

        return f;
      } catch (Exception) {
        break;
      }
    }
  }

  if (s.length && s[0] == '=') {
    f.op = ValueFilter.Op.exact;
    s = s[1 .. $];
  }

  f.text = s.toLower;

  return f;
}
