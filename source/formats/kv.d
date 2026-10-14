module formats.kv;

import std.array : uninitializedArray;
import std.conv : to;

import doc.document;
import doc.text;
import formats.json : OpenContainers, ParseResult, estimateNodes, growNodes;
import formats.embedded : embeddedText;
import formats.output;

ParseResult parseKv(const(char)[] text, out Node[] nodes, ulong base = 0, ubyte flags = 0) {
  KvParser p;

  p.s = text;
  p.base = base;
  p.baseFlags = flags;
  p.nodes = uninitializedArray!(Node[])(estimateNodes(text.length));
  p.run();

  nodes = p.nodes[0 .. p.count];

  return ParseResult(p.error, p.errorAt, false);
}

private struct KvParser {
  const(char)[] s;
  size_t i;
  ulong base;
  ubyte baseFlags;

  Node[] nodes;
  size_t count;
  OpenContainers stack;

  string error;
  size_t errorAt;

  size_t lastKey;
  size_t lastKeyLen;
  Syntax lastKeySyntax;
  bool lastKeyEsc;

  void run() {
    if (s.length >= 3 && s[0 .. 3] == "\xEF\xBB\xBF") {
      i = 3;
    }

    Node root;

    root.type = NodeType.object;
    root.pos = base + i;
    root.flags = baseFlags;
    root.setSyntax(Syntax.kv, Syntax.kv);
    stack.push(push(root));

    while (!error.length) {
      skip();
      if (i >= s.length) {
        break;
      }

      char ch = s[i];

      if (ch == '}') {
        if (stack.length == 1) {
          return fail("Unexpected '}'");
        }

        nodes[stack.top].end = cast(uint)count;
        stack.pop();
        i++;
        continue;
      }

      size_t keyStart, keyLen;
      Syntax keySyntax;
      bool keyEsc;

      if (ch == '{') {
        // nameless block, valve's parser reuses the previous name
        if (!lastKeyLen) {
          return fail("Block without a name");
        }

        keyStart = lastKey;
        keyLen = lastKeyLen;
        keySyntax = lastKeySyntax;
        keyEsc = lastKeyEsc;
      } else {
        keyStart = i;
        if (!token(keySyntax, keyEsc)) {
          return;
        }

        keyLen = i - keyStart;
        lastKey = keyStart;
        lastKeyLen = keyLen;
        lastKeySyntax = keySyntax;
        lastKeyEsc = keyEsc;
        skip();
        skipConditional();
        if (i >= s.length) {
          return fail("Expected value");
        }
      }

      Node n;

      n.pos = base + i;
      n.flags = baseFlags;
      n.set(NodeFlags.hasKey);
      n.set(NodeFlags.keyEsc, keyEsc);
      n.keyLen = cast(uint)keyLen;
      n.keyGap = cast(uint)(i - keyStart);
      n.parent = stack.top;

      if (s[i] == '{') {
        n.type = NodeType.object;
        n.setSyntax(Syntax.kv, keySyntax);
        i++;
        stack.push(push(n));
        continue;
      }

      if (s[i] == '}') {
        return fail("Expected value");
      }

      auto start = i;
      Syntax valueSyntax;
      bool esc;

      if (!token(valueSyntax, esc)) {
        return;
      }

      n.type = NodeType.string;
      n.len = cast(uint)(i - start);
      n.set(NodeFlags.escaped, esc);
      n.setSyntax(valueSyntax, keySyntax);
      push(n);

      skip();
      skipConditional();
    }

    foreach (idx; stack[]) {
      nodes[idx].end = cast(uint)count;
    }

    if (!error.length && stack.length > 1) {
      errorAt = s.length;
      error = "Unexpected end of file";
    }
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

  bool token(out Syntax syntax, out bool escaped) {
    if (s[i] == '"') {
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
      syntax = Syntax.kv;

      return true;
    }

    while (i < s.length) {
      char c = s[i];

      if (isSpace(c) || c == '"' || c == '{' || c == '}') {
        break;
      }

      i++;
    }

    syntax = Syntax.bare;

    return true;
  }

  void skipConditional() {
    if (i + 1 < s.length && s[i] == '[' && (s[i + 1] == '$' || s[i + 1] == '!')) {
      while (i < s.length && s[i] != ']' && s[i] != '\n') {
        i++;
      }

      if (i < s.length && s[i] == ']') {
        i++;
      }

      skip();
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
        i += 2;
        while (i + 1 < s.length && !(s[i] == '*' && s[i + 1] == '/')) {
          i++;
        }

        i = i + 2 > s.length ? s.length : i + 2;
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

void writeKv(Out)(ref Out o, const Document doc, uint i, in WriteOptions opt) {
  const n = &doc.nodes[i];

  if (n.isContainer && (!n.has(NodeFlags.embedded) || opt.embeddedRoot)) {
    writeMembers(o, doc, i, opt, 0);
  } else {
    writeEntry(o, doc, i, "value", opt, 0);
  }
}

void writeKvNode(Out)(ref Out o, const Document doc, uint i, in WriteOptions opt) {
  auto k = doc.hasKey(i) ? doc.key(i) : doc.indexInParent(i).to!string;

  writeEntry(o, doc, i, k, opt, 0);
}

private void writeMembers(Out)(ref Out o, const Document doc, uint i, in WriteOptions opt, int level) {
  bool isObject = doc.nodes[i].type == NodeType.object;
  size_t index = 0;

  foreach (c; doc.children(i)) {
    auto k = isObject && doc.hasKey(c) ? doc.key(c) : index.to!string;

    writeEntry(o, doc, c, k, opt, level);
    index++;
    if (o.full) {
      return;
    }
  }
}

private void writeEntry(Out)(ref Out o, const Document doc, uint c, const(char)[] key,
  in WriteOptions opt, int level) {
  const n = &doc.nodes[c];
  bool embedded = n.has(NodeFlags.embedded);

  if (n.type == NodeType.array && !embedded) {
    // repeated keys; nested arrays can't be expressed so they become indexed blocks
    foreach (e; doc.children(c)) {
      if (doc.nodes[e].type == NodeType.array && !doc.nodes[e].has(NodeFlags.embedded)) {
        writeBlock(o, doc, e, key, opt, level);
      } else {
        writeEntry(o, doc, e, key, opt, level);
      }

      if (o.full) {
        return;
      }
    }

    return;
  }

  if (n.type == NodeType.object && !embedded) {
    writeBlock(o, doc, c, key, opt, level);

    return;
  }

  putIndent(o, opt, level);
  putKvString(o, key);
  o.put("\t\t");
  putKvValue(o, doc, c);
  o.put('\n');
}

private void writeBlock(Out)(ref Out o, const Document doc, uint c, const(char)[] key,
  in WriteOptions opt, int level) {
  putIndent(o, opt, level);
  putKvString(o, key);
  o.put('\n');
  putIndent(o, opt, level);
  o.put("{\n");
  writeMembers(o, doc, c, opt, level + 1);
  putIndent(o, opt, level);
  o.put("}\n");
}

private void putKvValue(Out)(ref Out o, const Document doc, uint c) {
  const n = &doc.nodes[c];

  if (n.isContainer) {
    if (n.has(NodeFlags.original) && !n.embedChanged && n.valueSyntax == Syntax.kv) {
      o.put(doc.embeddedSource(c));
    } else {
      putKvString(o, embeddedText(doc, c));
    }

    return;
  }

  final switch (n.type) {
    case NodeType.null_:
      o.put(`""`);
      break;
    case NodeType.boolean:
      o.put(doc.valueRaw(c) == "true" ? `"1"` : `"0"`);
      break;
    case NodeType.number:
      o.put('"');
      o.put(doc.valueRaw(c));
      o.put('"');
      break;
    case NodeType.string:
      if (n.valueSyntax == Syntax.kv) {
        o.put(doc.valueRaw(c));
      } else {
        putKvString(o, doc.value(c));
      }

      break;
    case NodeType.object:
    case NodeType.array:
      assert(0);
  }
}
