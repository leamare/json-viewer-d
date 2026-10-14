module formats.kv3;

import std.array : uninitializedArray;
import std.conv : to;
import std.string : indexOf;

import doc.document;
import doc.text;
import formats.json : OpenContainers, ParseResult, estimateNodes, growNodes, groupByKey;
import formats.embedded : embeddedText;
import formats.output;

enum defaultKv3Header = "<!-- kv3 encoding:text:version{e21c7f3c-8a33-41c5-9977-a76d3a32aa0d} " ~
  "format:generic:version{7412167c-06e9-4698-aff2-e63eb59037e7} -->";

ParseResult parseKv3(const(char)[] text, out Node[] nodes, out string header, ulong base = 0,
  ubyte flags = 0) {
  Kv3Parser p;

  p.s = text;
  p.base = base;
  p.baseFlags = flags;
  p.nodes = uninitializedArray!(Node[])(estimateNodes(text.length));
  p.run();

  nodes = p.nodes[0 .. p.count];
  header = p.header;

  return ParseResult(p.error, p.errorAt, false);
}

private struct Kv3Parser {
  const(char)[] s;
  size_t i;
  ulong base;
  ubyte baseFlags;
  string header;

  Node[] nodes;
  size_t count;
  OpenContainers stack;

  string error;
  size_t errorAt;

  void run() {
    if (s.length >= 3 && s[0 .. 3] == "\xEF\xBB\xBF") {
      i = 3;
    }

    skipSpace();
    if (i + 4 <= s.length && s[i .. i + 4] == "<!--") {
      auto close = s[i .. $].indexOf("-->");

      if (close < 0) {
        return fail("Unterminated header");
      }

      header = s[i .. i + close + 3].idup;
      i += close + 3;
    }

    skip();
    if (i >= s.length) {
      return fail("Empty document");
    }

    value(false, 0, 0, Syntax.bare, false);

    while (!error.length && stack.length) {
      skip();
      if (i >= s.length) {
        return fail("Unexpected end of file");
      }

      auto top = stack.top;
      bool isObject = nodes[top].type == NodeType.object;
      char ch = s[i];

      if (ch == ',') {
        i++;
        continue;
      }

      if (ch == '}' || ch == ']') {
        if ((ch == '}') != isObject) {
          return fail(isObject ? "Expected '}'" : "Expected ']'");
        }

        nodes[top].end = cast(uint)count;
        stack.pop();
        i++;
        continue;
      }

      if (!isObject) {
        value(false, 0, 0, Syntax.bare, false);
        continue;
      }

      auto keyStart = i;
      Syntax keySyntax = Syntax.bare;
      bool keyEsc;

      if (ch == '"') {
        if (!quoted(keyEsc)) {
          return;
        }

        keySyntax = Syntax.kv;
      } else {
        while (i < s.length && isKeyChar(s[i])) {
          i++;
        }

        if (i == keyStart) {
          return fail("Expected key");
        }
      }

      auto keyLen = i - keyStart;

      skip();
      if (i >= s.length || s[i] != '=') {
        return fail("Expected '='");
      }

      i++;
      skip();
      if (i >= s.length) {
        return fail("Unexpected end of file");
      }

      value(true, keyStart, keyLen, keySyntax, keyEsc);
    }

    if (!error.length) {
      skip();
      if (i < s.length) {
        fail("Unexpected data after the root object");
      }
    }
  }

  void value(bool withKey, size_t keyStart, size_t keyLen, Syntax keySyntax, bool keyEsc) {
    Node n;

    n.flags = baseFlags;
    n.parent = stack.length ? stack.top : noNode;
    if (withKey) {
      n.set(NodeFlags.hasKey);
      n.set(NodeFlags.keyEsc, keyEsc);
      n.keyLen = cast(uint)keyLen;
    }

    // prefixes like subclass:{ } carry no data we can keep, skip them
    auto start = i;

    while (i < s.length && isKeyChar(s[i])) {
      i++;
    }

    bool prefixed = false;

    if (i > start && i + 1 < s.length && s[i] == ':') {
      auto j = i + 1;

      if (s[j] == '"') {
        prefixed = true;
      } else {
        while (j < s.length && isSpace(s[j])) {
          j++;
        }

        if (j < s.length && (s[j] == '{' || s[j] == '[')) {
          start = j;
        }
      }
    }

    i = start;

    n.pos = base + i;
    n.keyGap = withKey ? cast(uint)(i - keyStart) : 0;
    Syntax syntax = Syntax.bare;
    char ch = s[i];

    if (ch == '{' || ch == '[') {
      n.type = ch == '{' ? NodeType.object : NodeType.array;
      n.setSyntax(Syntax.kv, keySyntax);
      i++;
      stack.push(push(n));

      return;
    }

    if (ch == '"') {
      if (i + 2 < s.length && s[i + 1] == '"' && s[i + 2] == '"') {
        auto close = s[i + 3 .. $].indexOf(`"""`);

        if (close < 0) {
          return fail("Unterminated multiline string");
        }

        i += 3 + close + 3;
        syntax = Syntax.multiline;
      } else {
        bool esc;

        if (!quoted(esc)) {
          return;
        }

        n.set(NodeFlags.escaped, esc);
        syntax = Syntax.kv;
      }

      n.type = NodeType.string;
    } else if (ch == '#' && i + 1 < s.length && s[i + 1] == '[') {
      auto close = s[i .. $].indexOf(']');

      if (close < 0) {
        return fail("Unterminated binary blob");
      }

      i += close + 1;
      n.type = NodeType.string;
    } else if (prefixed) {
      i = s[i .. $].indexOf(':') + i + 1;
      bool esc;

      if (!quoted(esc)) {
        return;
      }

      n.type = NodeType.string;
      syntax = Syntax.flagged;
    } else {
      while (i < s.length && isTokenChar(s[i])) {
        i++;
      }

      if (i == start) {
        return fail("Unexpected character");
      }

      auto word = s[start .. i];

      if (word == "true" || word == "false") {
        n.type = NodeType.boolean;
      } else if (word == "null") {
        n.type = NodeType.null_;
      } else if (isKv3Number(word)) {
        n.type = NodeType.number;
      } else {
        n.type = NodeType.string;
      }
    }

    n.len = cast(uint)(i - (n.pos - base));
    n.setSyntax(syntax, keySyntax);
    push(n);
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

  bool quoted(out bool escaped) {
    auto start = i;

    i++;
    while (i < s.length && s[i] != '"') {
      if (s[i] == '\\' && i + 1 < s.length) {
        escaped = true;
        i++;
      }

      i++;
    }

    if (i >= s.length) {
      i = start;
      fail("Unterminated string");

      return false;
    }

    i++;

    return true;
  }

  void skipSpace() {
    while (i < s.length && isSpace(s[i])) {
      i++;
    }
  }

  void skip() {
    while (i < s.length) {
      char c = s[i];

      if (isSpace(c)) {
        i++;
      } else if (c == '/' && i + 1 < s.length && s[i + 1] == '/') {
        while (i < s.length && s[i] != '\n') {
          i++;
        }
      } else if (c == '/' && i + 1 < s.length && s[i + 1] == '*') {
        auto close = s[i + 2 .. $].indexOf("*/");

        i = close < 0 ? s.length : i + 2 + close + 2;
      } else if (c == '<' && i + 3 < s.length && s[i .. i + 4] == "<!--") {
        auto close = s[i .. $].indexOf("-->");

        i = close < 0 ? s.length : i + close + 3;
      } else {
        return;
      }
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

private bool isKeyChar(char c) {
  return c == '_' || c == '.' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || isDigit(c);
}

private bool isTokenChar(char c) {
  return isKeyChar(c) || c == '-' || c == '+';
}

private bool isKv3Number(const(char)[] w) {
  if (!w.length) {
    return false;
  }

  size_t i = (w[0] == '-' || w[0] == '+') ? 1 : 0;
  bool digits;
  bool dot;

  for (; i < w.length; i++) {
    char c = w[i];

    if (isDigit(c)) {
      digits = true;
    } else if (c == '.' && !dot) {
      dot = true;
    } else if ((c == 'e' || c == 'E') && digits) {
      i++;
      if (i < w.length && (w[i] == '-' || w[i] == '+')) {
        i++;
      }

      if (i >= w.length) {
        return false;
      }

      foreach (char d; w[i .. $]) {
        if (!isDigit(d)) {
          return false;
        }
      }

      return true;
    } else {
      return false;
    }
  }

  return digits;
}

void writeKv3(Out)(ref Out o, const Document doc, uint i, in WriteOptions opt) {
  o.put(doc.kv3Header.length && i == 0 ? doc.kv3Header : defaultKv3Header);
  o.put('\n');
  if (doc.nodes[i].type == NodeType.object && (!doc.nodes[i].has(NodeFlags.embedded) || opt.embeddedRoot)) {
    writeKv3Value(o, doc, i, opt, 0);
  } else {
    o.put("{\n");
    putIndent(o, opt, 1);
    o.put("root =");
    putValueStart(o, doc, i, opt, 1);
    writeKv3Value(o, doc, i, opt, 1);
    o.put("\n}");
  }

  o.put('\n');
}

void writeKv3Node(Out)(ref Out o, const Document doc, uint i, in WriteOptions opt) {
  if (doc.hasKey(i)) {
    auto k = doc.key(i);

    if (isBareKey(k)) {
      o.put(k);
    } else {
      putKvString(o, k);
    }

    o.put(" =");
    putValueStart(o, doc, i, opt, 0);
  }

  writeKv3Value(o, doc, i, opt, 0);
}

private void writeKv3Value(Out)(ref Out o, const Document doc, uint i, in WriteOptions opt, int level) {
  const n = &doc.nodes[i];
  bool embedded = n.has(NodeFlags.embedded) && !(level == 0 && opt.embeddedRoot);

  if (n.type == NodeType.object && !embedded) {
    o.put("{\n");
    if (opt.groupDuplicates) {
      foreach (members; groupByKey(doc, i)) {
        putMember(o, doc, members[0], opt, level + 1);
        if (members.length == 1) {
          putValueStart(o, doc, members[0], opt, level + 1);
          writeKv3Value(o, doc, members[0], opt, level + 1);
        } else {
          o.put('\n');
          putIndent(o, opt, level + 1);
          o.put("[\n");
          foreach (c; members) {
            putIndent(o, opt, level + 2);
            writeKv3Value(o, doc, c, opt, level + 2);
            o.put(",\n");
          }

          putIndent(o, opt, level + 1);
          o.put(']');
        }

        o.put('\n');
        if (o.full) {
          return;
        }
      }
    } else {
      size_t index;

      foreach (c; doc.children(i)) {
        putMember(o, doc, c, opt, level + 1, index++);
        putValueStart(o, doc, c, opt, level + 1);
        writeKv3Value(o, doc, c, opt, level + 1);
        o.put('\n');
        if (o.full) {
          return;
        }
      }
    }

    putIndent(o, opt, level);
    o.put('}');

    return;
  }

  if (n.type == NodeType.array && !embedded) {
    if (!n.len) {
      o.put("[]");

      return;
    }

    o.put("[\n");
    foreach (c; doc.children(i)) {
      putIndent(o, opt, level + 1);
      writeKv3Value(o, doc, c, opt, level + 1);
      o.put(",\n");
      if (o.full) {
        return;
      }
    }

    putIndent(o, opt, level);
    o.put(']');

    return;
  }

  if (embedded) {
    auto syntax = n.valueSyntax;

    if (n.has(NodeFlags.original) && !n.embedChanged && (syntax == Syntax.kv || syntax == Syntax.multiline)) {
      o.put(doc.embeddedSource(i));
    } else {
      putKv3String(o, embeddedText(doc, i), false);
    }

    return;
  }

  final switch (n.type) {
    case NodeType.null_:
      o.put("null");
      break;
    case NodeType.boolean:
    case NodeType.number:
      o.put(doc.valueRaw(i));
      break;
    case NodeType.string:
      // KV quoting is the same in both KeyValues versions, so such strings are copied
      auto syntax = n.valueSyntax;

      if (syntax == Syntax.flagged || syntax == Syntax.multiline || syntax == Syntax.kv) {
        o.put(doc.valueRaw(i));
      } else {
        putKv3String(o, doc.value(i), opt.detectTypes);
      }

      break;
    case NodeType.object:
    case NodeType.array:
      assert(0);
  }
}

private void putMember(Out)(ref Out o, const Document doc, uint c, in WriteOptions opt, int level,
  size_t index = 0) {
  putIndent(o, opt, level);
  auto k = doc.hasKey(c) ? doc.key(c) : index.to!string;

  if (isBareKey(k)) {
    o.put(k);
  } else {
    putKvString(o, k);
  }

  o.put(" =");
}

private void putValueStart(Out)(ref Out o, const Document doc, uint c, in WriteOptions opt, int level) {
  const n = &doc.nodes[c];

  if (n.isContainer && n.len && !n.has(NodeFlags.embedded)) {
    o.put('\n');
    putIndent(o, opt, level);
  } else {
    o.put(' ');
  }
}

private void putKv3String(Out)(ref Out o, const(char)[] v, bool detectTypes) {
  if (isFlaggedString(v) || (v.length > 2 && v[0 .. 2] == "#[" && v[$ - 1] == ']')) {
    o.put(v);
  } else if (detectTypes && (v == "true" || v == "false" || isJsonNumber(v))) {
    o.put(v);
  } else if (v.indexOf('\n') >= 0 && v.indexOf(`"""`) < 0) {
    o.put("\"\"\"\n");
    o.put(v);
    o.put("\n\"\"\"");
  } else {
    putKvString(o, v);
  }
}
