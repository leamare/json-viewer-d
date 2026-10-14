module formats;

import core.time : MonoTime;
import std.file : exists, getSize, read, remove, rename;
import std.mmfile : MmFile;
import std.path : extension, absolutePath;
import std.stdio : File;
import std.string : toLower;
import std.uni : sicmp;

import doc.document;
import doc.text;
public import formats.output : WriteOptions, StringSink;
public import formats.compression;
import formats.json;
import formats.kv;
import formats.kv3;

Format formatFromExtension(string path) {
  switch (path.withoutCompression.extension.toLower) {
    case ".json":
    case ".jsonc":
    case ".json5":
    case ".geojson":
      return Format.json;
    case ".jsonl":
    case ".ndjson":
    case ".jsonlines":
    case ".ljson":
      return Format.jsonl;
    case ".vdf":
    case ".kv":
    case ".res":
    case ".acf":
    case ".vmt":
      return Format.kv;
    case ".kv3":
    case ".vdata":
    case ".vmat":
    case ".vpcf":
    case ".vsndevts":
      return Format.kv3;
    default:
      return Format.unknown;
  }
}

Format formatFromContent(const(char)[] s) {
  size_t i = 0;

  if (s.length >= 3 && s[0 .. 3] == "\xEF\xBB\xBF") {
    i = 3;
  }

  void skip() {
    while (i < s.length) {
      if (isSpace(s[i])) {
        i++;
      } else if (s[i] == '/' && i + 1 < s.length && s[i + 1] == '/') {
        while (i < s.length && s[i] != '\n') {
          i++;
        }
      } else if (s[i] == '/' && i + 1 < s.length && s[i + 1] == '*') {
        i += 2;
        while (i + 1 < s.length && !(s[i] == '*' && s[i + 1] == '/')) {
          i++;
        }

        i += 2;
      } else {
        break;
      }
    }
  }

  skip();
  if (i >= s.length) {
    return Format.json;
  }

  char c = s[i];

  if (c == '<' && i + 4 <= s.length && s[i .. i + 4] == "<!--") {
    return Format.kv3;
  }

  if (c == '{') {
    i++;
    skip();
    auto start = i;

    while (i < s.length && (isBareKeyChar(s[i]))) {
      i++;
    }

    if (i > start) {
      skip();
      if (i < s.length && s[i] == '=') {
        return Format.kv3;
      }
    }

    return Format.json;
  }

  if (c == '[') {
    return Format.json;
  }

  if (c == '"') {
    i++;
    while (i < s.length && s[i] != '"') {
      if (s[i] == '\\') {
        i++;
      }

      i++;
    }

    i++;
    skip();
    if (i >= s.length || s[i] == ':' || s[i] == ',' || s[i] == '\n') {
      return Format.json;
    }

    return Format.kv;
  }

  if (c == '-' || isDigit(c)) {
    return Format.json;
  }

  foreach (word; ["true", "false", "null"]) {
    if (i + word.length <= s.length && s[i .. i + word.length] == word) {
      return Format.json;
    }
  }

  return Format.kv;
}

private bool isBareKeyChar(char c) {
  return c == '_' || c == '.' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || isDigit(c);
}

Document openDocument(string path, Format format = Format.unknown) {
  MmFile map;
  const(char)[] text;
  auto size = getSize(path);
  auto compression = Compression.none;

  if (size > 0) {
    ubyte[4] head;
    auto f = File(path, "rb");

    compression = compressionFromData(f.rawRead(head[]));
    f.close();
  }

  if (compression != Compression.none) {
    text = cast(const(char)[])decompress(compression, cast(const(ubyte)[])read(path));
  } else if (size > 0) {
    map = new MmFile(path);
    text = cast(const(char)[])map[];
  }

  auto doc = new Document(text, map);

  doc.path = path.absolutePath;
  doc.fileSize = size;
  doc.compression = compression;

  if (format == Format.unknown) {
    // extension is a hint, a .json file saved as KeyValues is still KeyValues
    auto byName = formatFromExtension(path);
    auto byContent = formatFromContent(text);

    format = byName;
    if (byName == Format.unknown || byContent == Format.kv3 ||
      (byContent == Format.kv && (byName == Format.json || byName == Format.jsonl))) {
      format = byContent;
    }
  }

  parseDocument(doc, format);

  return doc;
}

Document documentFromText(const(char)[] text, Format format = Format.unknown) {
  auto doc = new Document(text);

  parseDocument(doc, format == Format.unknown ? formatFromContent(text) : format);

  return doc;
}

private void parseDocument(Document doc, Format format) {
  import core.memory : GC;

  auto started = MonoTime.currTime;
  auto text = doc.sourceText;
  ParseResult r;

  // parser allocates few big blocks, collections in between only waste time
  GC.disable();
  scope (exit) {
    GC.enable();
  }

  final switch (format) {
    case Format.unknown:
    case Format.json:
    case Format.jsonl:
      r = parseJson(text, doc.nodes, 0, 0, format == Format.jsonl);
      format = r.sequence ? Format.jsonl : Format.json;
      break;
    case Format.kv:
      r = parseKv(text, doc.nodes);
      break;
    case Format.kv3:
      r = parseKv3(text, doc.nodes, doc.kv3Header);
      break;
  }

  if (!doc.nodes.length) {
    Node root;

    root.type = NodeType.object;
    root.end = 1;
    doc.nodes = [root];
  }

  doc.nodes[0].set(NodeFlags.expanded);
  doc.format = format;
  if (r.error.length) {
    doc.error = r.error ~ " at " ~ describePosition(text, r.errorAt);
    doc.errorPos = r.errorAt;
  }

  doc.parseTime = (MonoTime.currTime - started).total!"usecs" / 1e6;
}

string describePosition(const(char)[] text, size_t at) {
  import std.conv : to;

  if (at > text.length) {
    at = text.length;
  }

  size_t line = 1, lineStart = 0;

  foreach (k, char c; text[0 .. at]) {
    if (c == '\n') {
      line++;
      lineStart = k + 1;
    }
  }

  return "line " ~ line.to!string ~ ", column " ~ (at - lineStart + 1).to!string;
}

WriteOptions defaultOptions(const Document doc, Format target) {
  WriteOptions opt;

  opt.groupDuplicates = doc.format == Format.kv && target != Format.kv;
  opt.tabs = target == Format.kv || target == Format.kv3;

  return opt;
}

void saveDocument(Document doc, string path, Format format, WriteOptions opt) {
  path = path.absolutePath;
  auto tmp = path ~ ".saving";
  auto compression = compressionFromExtension(path);

  if (compression == Compression.none && doc.path == path) {
    compression = doc.compression;
  }

  {
    auto f = File(tmp, "wb");

    scope (failure) {
      f.close();
      remove(tmp);
    }

    auto sink = CompressedSink(f, compression);

    writeDocument(sink, doc, 0, format, opt);
    sink.flush();
    f.close();
  }

  version (Windows) {
    // mapped file can't be replaced on Windows
    if (doc.path.length && sicmp(doc.path, path) == 0) {
      doc.detachSource();
    }

    if (path.exists) {
      remove(path);
    }
  }

  rename(tmp, path);

  doc.path = path;
  doc.format = format;
  doc.compression = compression;
  doc.fileSize = getSize(path);
  doc.markSaved();
}

string nodeToText(const Document doc, uint i, Format format, WriteOptions opt,
  size_t limit = size_t.max, bool* truncated = null) {
  auto sink = StringSink(limit);

  writeDocument(sink, doc, i, format, opt);
  if (truncated) {
    *truncated = sink.truncated;
  }

  return cast(string)sink.data;
}

void writeDocument(Out)(ref Out o, const Document doc, uint i, Format format, in WriteOptions opt) {
  final switch (format) {
    case Format.unknown:
    case Format.json:
      writeJson(o, doc, i, opt);
      if (i == 0) {
        o.put('\n');
      }

      break;
    case Format.jsonl:
      if (i == 0) {
        writeJsonLines(o, doc, opt);
      } else {
        WriteOptions compact = opt;

        compact.compact = true;
        writeJson(o, doc, i, compact);
      }

      break;
    case Format.kv:
      if (i == 0) {
        writeKv(o, doc, i, opt);
      } else {
        writeKvNode(o, doc, i, opt);
      }

      break;
    case Format.kv3:
      if (i == 0) {
        writeKv3(o, doc, i, opt);
      } else {
        writeKv3Node(o, doc, i, opt);
      }

      break;
  }
}
