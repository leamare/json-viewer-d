module formats.embedded;

import doc.document;
import doc.text : decodeString;
import formats.json : writeJson;
import formats.kv : writeKv;
import formats.kv3 : writeKv3;
import formats.output;

string embeddedText(const Document doc, uint i) {
  import doc.edit : addSlashes, stripSlashes;

  const n = &doc.nodes[i];
  WriteOptions opt;
  StringSink s;

  opt.embeddedRoot = true;
  string original;
  if (n.has(NodeFlags.original)) {
    original = decodeString(doc.embeddedSource(i), n.valueSyntax);
    if (n.has(NodeFlags.slashed)) {
      original = stripSlashes(original);
    }
  }

  bool pretty = detectIndent(original, opt);

  switch (cast(Format)n.embedKind) {
    case Format.kv:
      opt.tabs = true;
      writeKv(s, doc, i, opt);
      break;
    case Format.kv3:
      opt.tabs = true;
      writeKv3(s, doc, i, opt);
      break;
    default:
      opt.compact = !pretty;
      writeJson(s, doc, i, opt);
      break;
  }

  auto text = s.data;

  while (text.length && text[$ - 1] == '\n') {
    text = text[0 .. $ - 1];
  }

  return n.has(NodeFlags.slashed) ? addSlashes(text) : text.idup;
}

private bool detectIndent(string text, ref WriteOptions opt) {
  import std.string : indexOf;

  auto nl = text.indexOf('\n');

  if (nl < 0) {
    return false;
  }

  auto line = text[nl + 1 .. $];

  if (line.length && line[0] == '\t') {
    opt.tabs = true;
  } else {
    int spaces = 0;

    while (spaces < line.length && line[spaces] == ' ') {
      spaces++;
    }

    opt.indent = spaces ? spaces : 2;
  }

  return true;
}

Format embeddedFormat(const(char)[] text) {
  import doc.text : looksLikeJson, isSpace;
  import formats : formatFromContent;
  import std.algorithm : canFind;

  if (looksLikeJson(text)) {
    return Format.json;
  }

  size_t i = 0;

  while (i < text.length && isSpace(text[i])) {
    i++;
  }

  if (text.length - i > 4 && text[i .. i + 4] == "<!--") {
    return Format.kv3;
  }

  // plain words would pass as KeyValues too, so a block is required
  if (text.canFind('{') && text.canFind('}')) {
    auto f = formatFromContent(text);

    if (f == Format.kv || f == Format.kv3) {
      return f;
    }
  }

  return Format.unknown;
}
