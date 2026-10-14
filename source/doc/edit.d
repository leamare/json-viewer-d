module doc.edit;

import std.algorithm : canFind;
import std.string : strip;

import doc.document;
import doc.text;
import formats : describePosition;
import formats.json : parseJson, ParseResult;
import formats.output : StringSink;

string setValue(Document doc, uint i, string input) {
  auto n = doc[i];

  if (n.type != NodeType.string) {
    auto t = input.strip;

    if (t.length && (t[0] == '{' || t[0] == '[' || t[0] == '"')) {
      return replaceWithJson(doc, i, t);
    }

    if (t == "null" || t == "true" || t == "false" || isJsonNumber(t)) {
      return replaceWithJson(doc, i, t);
    }
  }

  StringSink raw;

  putJsonString(raw, input);
  auto fresh = makeNode(doc, i, raw.data, NodeType.string);

  fresh.set(NodeFlags.escaped, raw.data.length != input.length + 2);
  doc.replace(n.parent, i, n.end - i, [fresh]);

  return null;
}

string replaceWithJson(Document doc, uint i, const(char)[] text) {
  return replaceWithText(doc, i, text, Format.json);
}

string replaceWithText(Document doc, uint i, const(char)[] text, Format format, ubyte extraFlags = 0,
  bool silent = false) {
  import formats.kv : parseKv;
  import formats.kv3 : parseKv3;

  auto n = doc[i];
  auto keyRaw = doc.keyRaw(i);
  bool embedding = (extraFlags & NodeFlags.embedded) != 0;
  auto keyAt = doc.appendPool(keyRaw);

  doc.appendPool(keyRaw.length ? ":" : "");

  // the string a document is parsed from is kept, so it can be saved untouched
  const(char)[] original = embedding ? doc.valueRaw(i) : doc.embeddedSource(i);
  auto originAt = original.length ? appendOriginal(doc, original) : 0;
  auto at = doc.appendPool(text);

  Node[] fresh;
  ParseResult r;

  if (format == Format.kv) {
    r = parseKv(text, fresh, at, NodeFlags.pooled);
  } else if (format == Format.kv3) {
    string header;

    r = parseKv3(text, fresh, header, at, NodeFlags.pooled);
  } else {
    r = parseJson(text, fresh, at, NodeFlags.pooled);
  }

  if (r.error.length) {
    return r.error ~ " at " ~ describePosition(text, r.errorAt);
  }

  if (r.sequence) {
    return "Expected a single value";
  }

  if (!fresh.length) {
    return "Nothing to insert";
  }

  auto root = &fresh[0];

  root.flags |= extraFlags;
  if (embedding) {
    root.embedFormat = format;
    root.pos = originAt;
    root.set(NodeFlags.original);
    copyKey(*root, n, keyAt, originAt);
    root.setSyntax(n.valueSyntax, n.keySyntax);
  } else if (n.has(NodeFlags.embedded) && root.isContainer) {
    root.flags |= n.flags & (NodeFlags.embedded | NodeFlags.slashed | NodeFlags.original);
    root.embedFormat = n.embedFormat;
    root.markEmbedChanged();
    root.pos = originAt;
    copyKey(*root, n, keyAt, originAt);
    root.setSyntax(n.valueSyntax, n.keySyntax);
  } else {
    copyKey(*root, n, keyAt, at);
  }

  if (root.isContainer) {
    root.set(NodeFlags.expanded, n.has(NodeFlags.expanded) || embedding);
  }

  doc.replace(n.parent, i, n.end - i, fresh, silent);

  return null;
}

private ulong appendOriginal(Document doc, const(char)[] raw) {
  ulong len = raw.length;
  auto at = doc.appendPool((cast(const(char)*)&len)[0 .. ulong.sizeof]);

  doc.appendPool(raw);

  return at;
}

string renameKey(Document doc, uint i, string newKey) {
  auto n = doc[i];

  if (!n.has(NodeFlags.hasKey)) {
    return "This element has no key";
  }

  StringSink key;

  putJsonString(key, newKey);
  auto keyAt = doc.appendPool(key.data);

  doc.appendPool(":");

  Node fresh = n;

  if (n.isContainer && n.has(NodeFlags.original)) {
    fresh.pos = appendOriginal(doc, doc.embeddedSource(i));
  } else if (n.isContainer) {
    fresh.pos = doc.appendPool("");
  } else {
    fresh.pos = doc.appendPool(doc.valueRaw(i));
    if (!n.has(NodeFlags.pooled)) {
      fresh.set(NodeFlags.pooled);
    }
  }

  fresh.set(NodeFlags.pooled);
  fresh.keyLen = cast(uint)key.data.length;
  fresh.keyGap = cast(uint)(fresh.pos - keyAt);
  fresh.setSyntax(n.valueSyntax, Syntax.json);
  fresh.set(NodeFlags.keyEsc, key.data.length != newKey.length + 2);
  doc.patch(i, fresh);

  return null;
}

void deleteNode(Document doc, uint i) {
  auto n = doc[i];

  if (n.parent == noNode) {
    return;
  }

  doc.replace(n.parent, i, n.end - i, []);
}

uint insertNode(Document doc, uint parent, uint before, string key, string valueText) {
  auto p = doc[parent];
  bool withKey = p.type == NodeType.object;

  StringSink keyRaw;

  if (withKey) {
    putJsonString(keyRaw, key);
  }

  auto keyAt = doc.appendPool(keyRaw.data);

  doc.appendPool(withKey ? ":" : "");

  auto t = valueText.strip;
  Node[] fresh;
  auto at = doc.appendPool(t);
  auto r = parseJson(t, fresh, at, NodeFlags.pooled);

  if (r.error.length || r.sequence || !fresh.length) {
    StringSink s;

    putJsonString(s, valueText);
    at = doc.appendPool(s.data);
    Node n;

    n.type = NodeType.string;
    n.pos = at;
    n.len = cast(uint)s.data.length;
    n.end = 1;
    n.flags = NodeFlags.pooled;
    fresh = [n];
  }

  auto root = &fresh[0];

  root.parent = noNode;
  if (withKey) {
    root.set(NodeFlags.hasKey);
    root.keyLen = cast(uint)keyRaw.data.length;
    root.keyGap = cast(uint)(at - keyAt);
  }

  uint start = before == noNode ? p.end : before;

  doc.replace(parent, start, 0, fresh);

  return start;
}

string expandEmbedded(Document doc, uint i, Format format = Format.unknown) {
  import formats.embedded : embeddedFormat;
  import std.algorithm : canFind;

  auto n = doc[i];

  if (n.type != NodeType.string) {
    return "Not a string";
  }

  auto text = doc.value(i);

  if (format == Format.unknown) {
    format = embeddedFormat(text);
  }

  if (format == Format.unknown) {
    return "The string doesn't look like JSON or KeyValues";
  }

  if (format == Format.jsonl) {
    format = Format.json;
  }

  if (format == Format.json && !looksLikeJson(text)) {
    return "The string doesn't contain a JSON object or array";
  }

  auto err = replaceWithText(doc, i, text, format, NodeFlags.embedded, true);

  // JSON that went through addslashes: {\"a\":1}
  if (err.length && text.canFind(`\"`)) {
    if (!replaceWithText(doc, i, stripSlashes(text), format, NodeFlags.embedded | NodeFlags.slashed, true).length) {
      return null;
    }
  }

  return err;
}

string setEmbeddedFormat(Document doc, uint i, Format format) {
  auto n = doc[i];

  if (!n.has(NodeFlags.embedded)) {
    return "Not an embedded document";
  }

  if (format == Format.jsonl) {
    format = Format.json;
  }

  n.setEmbedKind(format);
  n.markEmbedChanged();
  doc.patch(i, n);

  return null;
}

string collapseEmbedded(Document doc, uint i) {
  import formats.embedded : embeddedText;

  auto n = doc[i];

  if (!n.has(NodeFlags.embedded)) {
    return "Not an embedded document";
  }

  if (n.has(NodeFlags.original) && !n.embedChanged) {
    auto raw = doc.embeddedSource(i);
    auto fresh = makeNode(doc, i, raw, NodeType.string);

    fresh.setSyntax(n.valueSyntax, n.keySyntax);
    fresh.set(NodeFlags.escaped, raw.canFind('\\'));
    doc.replace(n.parent, i, n.end - i, [fresh], true);

    return null;
  }

  StringSink raw;

  putJsonString(raw, embeddedText(doc, i));

  auto fresh = makeNode(doc, i, raw.data, NodeType.string);

  fresh.set(NodeFlags.escaped);
  doc.replace(n.parent, i, n.end - i, [fresh]);

  return null;
}

string stripSlashes(const(char)[] s) {
  char[] res;

  for (size_t k = 0; k < s.length; k++) {
    if (s[k] == '\\' && k + 1 < s.length && (s[k + 1] == '"' || s[k + 1] == '\\' || s[k + 1] == '\'')) {
      k++;
    }

    res ~= s[k];
  }

  return cast(string)res;
}

string addSlashes(const(char)[] s) {
  char[] res;

  foreach (char c; s) {
    if (c == '"' || c == '\\' || c == '\'') {
      res ~= '\\';
    }

    res ~= c;
  }

  return cast(string)res;
}

private Node makeNode(Document doc, uint i, const(char)[] valueRaw, NodeType type) {
  auto old = doc[i];
  auto keyRaw = doc.keyRaw(i);
  auto keyAt = doc.appendPool(keyRaw);

  doc.appendPool(keyRaw.length ? ":" : "");
  auto at = doc.appendPool(valueRaw);

  Node n;

  n.type = type;
  n.pos = at;
  n.len = cast(uint)valueRaw.length;
  n.end = 1;
  n.flags = NodeFlags.pooled;
  copyKey(n, old, keyAt, at);

  return n;
}

private void copyKey(ref Node n, in Node old, ulong keyAt, ulong at) {
  n.parent = noNode;
  n.setSyntax(n.valueSyntax, old.keySyntax);
  if (!old.has(NodeFlags.hasKey)) {
    return;
  }

  n.set(NodeFlags.hasKey);
  n.set(NodeFlags.keyEsc, old.has(NodeFlags.keyEsc));
  n.keyLen = old.keyLen;
  n.keyGap = cast(uint)(at - keyAt);
}
