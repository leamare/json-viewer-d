module formats.embedded;

import doc.document;
import formats.json : writeJson;
import formats.kv : writeKv;
import formats.kv3 : writeKv3;
import formats.output;

string embeddedText(const Document doc, uint i) {
  WriteOptions opt;

  opt.embeddedRoot = true;
  StringSink s;

  switch (cast(Format)doc.nodes[i].embedFormat) {
    case Format.kv:
      opt.tabs = true;
      writeKv(s, doc, i, opt);
      break;
    case Format.kv3:
      opt.tabs = true;
      writeKv3(s, doc, i, opt);
      break;
    default:
      opt.compact = true;
      writeJson(s, doc, i, opt);
      break;
  }

  auto text = s.data;

  while (text.length && text[$ - 1] == '\n') {
    text = text[0 .. $ - 1];
  }

  return text.idup;
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
