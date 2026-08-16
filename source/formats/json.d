module formats.json;

import core.memory : GC;
import std.array : uninitializedArray;
import std.conv : to;

import doc.document;
import doc.text;
import formats.embedded : embeddedText;
import formats.output;

struct ParseResult {
  string error;
  size_t errorAt;
  bool sequence;
}

/// Parses JSON with comments and trailing commas allowed. Several top level
/// values (JSON Lines) are wrapped into an array.
///
/// Positions are offset by `base`, nodes get `flags` set. Both are used to
/// parse text that lives in the document pool. On error the tree contains
/// everything read before it, with unfinished containers closed.
ParseResult parseJson(const(char)[] text, out Node[] nodes, ulong base = 0, ubyte flags = 0,
  bool forceSequence = false) {
  JsonParser p;

  p.s = text;
  p.base = base;
  p.baseFlags = flags;
  p.nodes = uninitializedArray!(Node[])(estimateNodes(text.length));

  if (forceSequence) {
    p.startSequence();
  }

  p.run();
  p.finish();

  nodes = p.nodes[0 .. p.count];

  return ParseResult(p.error, p.errorAt, p.sequence);
}

/// Makes room for more nodes. New part stays uninitialized, so memory that
/// is never used is never touched either.
void growNodes(ref Node[] nodes, size_t used) {
  auto bigger = uninitializedArray!(Node[])(nodes.length * 3 / 2 + 64);

  bigger[0 .. used] = nodes[0 .. used];
  GC.free(nodes.ptr);
  nodes = bigger;
}

size_t estimateNodes(size_t textLength) {
  auto n = textLength / 16;

  return n < 64 ? 64 : n;
}

private struct JsonParser {
  const(char)[] s;
  size_t i;
  ulong base;
  ubyte baseFlags;

  Node[] nodes;
  size_t count;
  OpenContainers stack;
  bool afterValue;
  bool sequence;
  uint topValues;

  string error;
  size_t errorAt;

  void run() {
    if (s.length >= 3 && s[0 .. 3] == "\xEF\xBB\xBF") {
      i = 3;
    }

    while (!error.length) {
      skip();
      if (error.length || i >= s.length) {
        break;
      }

      char ch = s[i];

      if (!stack.length) {
        if (topValues == 1 && !sequence) {
          startSequence();
        }

        topValues++;
        value(false, 0, 0, false);
        continue;
      }

      auto top = stack.top;
      bool isObject = nodes[top].type == NodeType.object;

      if (ch == ',') {
        if (!afterValue) {
          return fail("Unexpected ','");
        }

        afterValue = false;
        i++;
        continue;
      }

      if (ch == '}' || ch == ']') {
        if ((ch == '}') != isObject) {
          return fail(isObject ? "Expected '}'" : "Expected ']'");
        }

        nodes[top].end = cast(uint)count;
        stack.pop();
        afterValue = true;
        i++;
        continue;
      }

      if (afterValue) {
        return fail(isObject ? "Expected ',' or '}'" : "Expected ',' or ']'");
      }

      if (!isObject) {
        value(false, 0, 0, false);
        continue;
      }

      if (ch != '"') {
        return fail("Expected property name");
      }

      auto keyStart = i;
      bool keyEsc;

      if (!scanString(keyEsc)) {
        return;
      }

      auto keyLen = i - keyStart;

      skip();
      if (i >= s.length || s[i] != ':') {
        return fail("Expected ':'");
      }

      i++;
      skip();
      if (i >= s.length) {
        return fail("Unexpected end of file");
      }

      value(true, keyStart, keyLen, keyEsc);
    }

    if (!error.length && stack.length) {
      fail("Unexpected end of file");
    }
  }

  void value(bool withKey, size_t keyStart, size_t keyLen, bool keyEsc) {
    Node n;

    n.pos = base + i;
    n.flags = baseFlags;
    n.setSyntax(Syntax.json, Syntax.json);
    n.parent = stack.length ? stack.top : (sequence ? 0 : noNode);
    if (withKey) {
      n.set(NodeFlags.hasKey);
      n.set(NodeFlags.keyEsc, keyEsc);
      n.keyLen = cast(uint)keyLen;
      n.keyGap = cast(uint)(i - keyStart);
    }

    char ch = s[i];
    auto start = i;

    switch (ch) {
      case '{':
      case '[':
        n.type = ch == '{' ? NodeType.object : NodeType.array;
        i++;
        auto idx = push(n);

        stack.push(idx);
        afterValue = false;

        return;
      case '"':
        bool esc;

        if (!scanString(esc)) {
          return;
        }

        n.type = NodeType.string;
        n.set(NodeFlags.escaped, esc);
        break;
      case 't':
        if (!literal("true")) {
          return;
        }

        n.type = NodeType.boolean;
        break;
      case 'f':
        if (!literal("false")) {
          return;
        }

        n.type = NodeType.boolean;
        break;
      case 'n':
        if (!literal("null")) {
          return;
        }

        n.type = NodeType.null_;
        break;
      case '-':
      case '0': .. case '9':
        i++;
        while (i < s.length && isNumberChar(s[i])) {
          i++;
        }

        n.type = NodeType.number;
        break;
      default:
        return fail("Unexpected character");
    }

    n.len = cast(uint)(i - start);
    push(n);
    afterValue = true;
  }

  uint push(ref Node n) {
    if (count == nodes.length) {
      growNodes(nodes, count);
    }

    auto idx = cast(uint)count;

    n.end = idx + 1;
    nodes[count++] = n;
    if (n.parent != noNode) {
      nodes[n.parent].len++;
    }

    return idx;
  }

  bool scanString(out bool escaped) {
    auto start = i;

    i++;
    while (i < s.length) {
      char c = s[i];

      if (c == '"') {
        i++;

        return true;
      }

      if (c == '\\') {
        escaped = true;
        i += 2;
        continue;
      }

      i++;
    }

    i = start;
    fail("Unterminated string");

    return false;
  }

  bool literal(string word) {
    if (i + word.length > s.length || s[i .. i + word.length] != word) {
      fail("Unexpected character");

      return false;
    }

    i += word.length;

    return true;
  }

  void skip() {
    while (i < s.length) {
      char c = s[i];

      if (c == ' ' || c == '\n' || c == '\r' || c == '\t') {
        i++;
      } else if (c == '/' && i + 1 < s.length && s[i + 1] == '/') {
        while (i < s.length && s[i] != '\n') {
          i++;
        }
      } else if (c == '/' && i + 1 < s.length && s[i + 1] == '*') {
        auto start = i;

        i += 2;
        while (i + 1 < s.length && !(s[i] == '*' && s[i + 1] == '/')) {
          i++;
        }

        if (i + 1 >= s.length) {
          i = start;

          return fail("Unterminated comment");
        }

        i += 2;
      } else {
        return;
      }
    }
  }

  void startSequence() {
    sequence = true;
    if (count == nodes.length) {
      growNodes(nodes, count);
    }

    foreach_reverse (k; 0 .. count) {
      auto n = nodes[k];

      n.parent = n.parent == noNode ? 0 : n.parent + 1;
      n.end++;
      nodes[k + 1] = n;
    }

    foreach (ref idx; stack[]) {
      idx++;
    }

    Node root;

    root.type = NodeType.array;
    root.pos = base;
    root.flags = baseFlags;
    root.len = cast(uint)topValues;
    nodes[0] = root;
    count++;
  }

  void finish() {
    foreach (idx; stack[]) {
      nodes[idx].end = cast(uint)count;
    }

    stack.clear();
    if (sequence) {
      nodes[0].end = cast(uint)count;
    }
  }

  void fail(string msg) {
    if (error.length) {
      return;
    }

    error = msg;
    errorAt = i;
  }
}

struct OpenContainers {
  private uint[] items;
  private size_t used;

  @property size_t length() const { return used; }
  uint top() const { return items[used - 1]; }
  void pop() { used--; }
  void clear() { used = 0; }

  void push(uint idx) {
    if (used == items.length) {
      items.length = items.length * 2 + 16;
    }

    items[used++] = idx;
  }

  inout(uint)[] opSlice() inout { return items[0 .. used]; }
}

private bool isNumberChar(char c) {
  return (c >= '0' && c <= '9') || c == '.' || c == 'e' || c == 'E' || c == '+' || c == '-';
}

void writeJson(Out)(ref Out o, const Document doc, uint i, in WriteOptions opt, int level = 0) {
  const n = &doc.nodes[i];

  if (n.has(NodeFlags.embedded) && n.isContainer && !(level == 0 && opt.embeddedRoot)) {
    putJsonString(o, embeddedText(doc, i));

    return;
  }

  if (n.isContainer) {
    writeJsonContainer(o, doc, i, opt, level);

    return;
  }

  final switch (n.type) {
    case NodeType.null_:
      o.put("null");
      break;
    case NodeType.boolean:
      o.put(doc.valueRaw(i) == "false" ? "false" : "true");
      break;
    case NodeType.number:
      putJsonNumber(o, doc.valueRaw(i));
      break;
    case NodeType.string:
      if (n.valueSyntax == Syntax.json) {
        o.put(doc.valueRaw(i));
        break;
      }

      auto v = doc.value(i);

      if (opt.detectTypes && (v == "true" || v == "false" || isJsonNumber(v))) {
        o.put(v);
      } else {
        putJsonString(o, v);
      }

      break;
    case NodeType.object:
    case NodeType.array:
      assert(0);
  }
}

void writeJsonLines(Out)(ref Out o, const Document doc, in WriteOptions opt) {
  WriteOptions compact = opt;

  compact.compact = true;
  if (doc.nodes[0].type == NodeType.array && !doc.nodes[0].has(NodeFlags.embedded)) {
    foreach (c; doc.children(0)) {
      writeJson(o, doc, c, compact);
      o.put('\n');
      if (o.full) {
        return;
      }
    }
  } else {
    writeJson(o, doc, 0, compact);
    o.put('\n');
  }
}

private void writeJsonContainer(Out)(ref Out o, const Document doc, uint i, in WriteOptions opt, int level) {
  const n = &doc.nodes[i];
  bool isObject = n.type == NodeType.object;

  if (n.len == 0) {
    o.put(isObject ? "{}" : "[]");

    return;
  }

  if (isObject && opt.groupDuplicates) {
    auto groups = groupByKey(doc, i);

    if (groups.length < n.len) {
      writeGroupedObject(o, doc, groups, opt, level);

      return;
    }
  }

  o.put(isObject ? '{' : '[');
  bool first = true;

  foreach (c; doc.children(i)) {
    if (!first) {
      o.put(',');
    }

    first = false;
    newline(o, opt, level + 1);
    if (isObject) {
      putKey(o, doc, c, opt);
    }

    writeJson(o, doc, c, opt, level + 1);
    if (o.full) {
      return;
    }
  }

  newline(o, opt, level);
  o.put(isObject ? '}' : ']');
}

private void writeGroupedObject(Out)(ref Out o, const Document doc, uint[][] groups,
  in WriteOptions opt, int level) {
  o.put('{');
  foreach (g, members; groups) {
    if (g) {
      o.put(',');
    }

    newline(o, opt, level + 1);
    putKey(o, doc, members[0], opt);
    if (members.length == 1) {
      writeJson(o, doc, members[0], opt, level + 1);
      continue;
    }

    o.put('[');
    foreach (k, c; members) {
      if (k) {
        o.put(',');
      }

      newline(o, opt, level + 2);
      writeJson(o, doc, c, opt, level + 2);
    }

    newline(o, opt, level + 1);
    o.put(']');
    if (o.full) {
      return;
    }
  }

  newline(o, opt, level);
  o.put('}');
}

uint[][] groupByKey(const Document doc, uint i) {
  size_t[string] index;
  uint[][] groups;

  foreach (c; doc.children(i)) {
    auto k = doc.key(c);

    if (auto at = k in index) {
      groups[*at] ~= c;
    } else {
      index[k] = groups.length;
      groups ~= [c];
    }
  }

  return groups;
}

private void putKey(Out)(ref Out o, const Document doc, uint c, in WriteOptions opt) {
  if (!doc.hasKey(c)) {
    putJsonString(o, doc.indexInParent(c).to!string);
  } else if (doc.nodes[c].keySyntax == Syntax.json) {
    o.put(doc.keyRaw(c));
  } else {
    putJsonString(o, doc.key(c));
  }

  o.put(opt.compact ? ":" : ": ");
}

private void newline(Out)(ref Out o, in WriteOptions opt, int level) {
  if (opt.compact) {
    return;
  }

  o.put('\n');
  putIndent(o, opt, level);
}

/// Numbers from other formats may not be valid JSON (".5", "1.", "+3")
private void putJsonNumber(Out)(ref Out o, const(char)[] raw) {
  if (isJsonNumber(raw)) {
    o.put(raw);

    return;
  }

  try {
    import std.format : format;
    auto v = raw.to!double;
    auto s = format("%.17g", v);

    if (isJsonNumber(s)) {
      o.put(s);

      return;
    }
  } catch (Exception) {
  }

  putJsonString(o, raw);
}
