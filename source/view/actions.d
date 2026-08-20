module view.actions;

import std.path : setExtension;
import std.string : toLower;

import doc.document;
import doc.text : decodeString;
import formats;

enum CopyKind {
  value,
  key,
  path,
  json,
  jsonCompact,
  kv,
  kv3,
}

string copyText(const Document doc, uint i, CopyKind kind) {
  auto text = makeCopyText(doc, i, kind);
  if ((kind == CopyKind.json || kind == CopyKind.jsonCompact || kind == CopyKind.value) &&
    text.length &&
    text[$ - 1] == '\n') {
    text = text[0 .. $ - 1];
  }

  return text;
}

private string makeCopyText(const Document doc, uint i, CopyKind kind) {
  final switch (kind) {
    case CopyKind.value:
      if (!doc.nodes[i].isContainer) {
        return doc.value(i);
      }

      goto case CopyKind.json;
    case CopyKind.key:
      return doc.hasKey(i) ? doc.key(i) : null;
    case CopyKind.path:
      return doc.pathOf(i);
    case CopyKind.json:
      auto opt = defaultOptions(doc, Format.json);

      opt.embeddedRoot = true;

      return nodeToText(doc, i, Format.json, opt);
    case CopyKind.jsonCompact:
      auto opt = defaultOptions(doc, Format.json);

      opt.compact = true;
      opt.embeddedRoot = true;

      return nodeToText(doc, i, Format.json, opt);
    case CopyKind.kv:
      return nodeToText(doc, i, Format.kv, defaultOptions(doc, Format.kv));
    case CopyKind.kv3:
      return nodeToText(doc, i, Format.kv3, defaultOptions(doc, Format.kv3));
  }
}

string extensionFor(Format f) {
  final switch (f) {
    case Format.unknown:
    case Format.json: return ".json";
    case Format.jsonl: return ".jsonl";
    case Format.kv: return ".vdf";
    case Format.kv3: return ".kv3";
  }
}

Format formatFromName(string name) {
  switch (name.toLower) {
    case "json": case "jsonc": return Format.json;
    case "jsonl": case "ndjson": case "lines": return Format.jsonl;
    case "kv": case "vdf": case "kv1": case "keyvalues": return Format.kv;
    case "kv3": case "vdata": return Format.kv3;
    default: return Format.unknown;
  }
}

string suggestName(const Document doc, Format target) {
  auto name = doc.path.length ? doc.path : "untitled.json";

  if (formatFromExtension(name) == target) {
    return name;
  }

  return name.setExtension(extensionFor(target));
}

string saveAs(Document doc, string path, Format format = Format.unknown, bool detectTypes = false,
  bool compact = false) {
  if (format == Format.unknown) {
    format = formatFromExtension(path);
  }

  if (format == Format.unknown) {
    format = doc.format;
  }

  auto opt = defaultOptions(doc, format);

  opt.detectTypes = detectTypes;
  opt.compact = compact;
  try {
    saveDocument(doc, path, format, opt);
  } catch (Exception e) {
    return e.msg;
  }

  return null;
}

string describeNode(const Document doc, uint i) {
  import std.conv : to;

  auto n = &doc.nodes[i];

  final switch (n.type) {
    case NodeType.null_: return "null";
    case NodeType.boolean: return "boolean";
    case NodeType.number: return "number";
    case NodeType.string:
      return n.has(NodeFlags.pooled) || n.len < 1024 ? "string" : "string, " ~ n.len.to!string ~ " bytes";
    case NodeType.object:
      return embeddedPrefix(*n) ~ "object {" ~ n.len.to!string ~ "}";
    case NodeType.array:
      return embeddedPrefix(*n) ~ "array [" ~ n.len.to!string ~ "]";
  }
}

private string embeddedPrefix(in Node n) {
  if (!n.has(NodeFlags.embedded)) {
    return "";
  }

  return "embedded " ~ embeddedFormatName(n) ~ " ";
}

string embeddedFormatName(in Node n) {
  switch (cast(Format)n.embedFormat) {
    case Format.kv: return "KV";
    case Format.kv3: return "KV3";
    default: return "JSON";
  }
}

string nodeLabel(const Document doc, uint i, size_t maxLen = 256) {
  import std.conv : to;

  if (doc.nodes[i].parent == noNode) {
    if (doc.format == Format.jsonl) {
      return "<lines>";
    }

    return doc.nodes[i].type == NodeType.array
      ? "<array>"
      : doc.nodes[i].type == NodeType.object ? "<object>" : "<value>";
  }

  if (doc.hasKey(i)) {
    return doc.key(i, maxLen);
  }

  return "[" ~ doc.indexInParent(i).to!string ~ "]";
}

string valuePreview(const Document doc, uint i, size_t maxLen = 256) {
  import std.conv : to;

  auto n = &doc.nodes[i];

  if (n.isContainer) {
    auto count = n.len.to!string;

    return n.type == NodeType.object ? "{" ~ count ~ "}" : "[" ~ count ~ "]";
  }

  auto v = doc.value(i, maxLen);
  char[] res;

  foreach (char c; v) {
    if (c == '\n') {
      res ~= "↵";
    } else if (c == '\r' || c == '\t') {
      res ~= ' ';
    } else {
      res ~= c;
    }
  }

  return cast(string)res;
}

uint findPath(const Document doc, string path) {
  import std.conv : to;
  import std.string : strip;

  path = path.strip;
  size_t i = 0;

  if (i < path.length && path[i] == '$') {
    i++;
  }

  uint cur = 0;

  while (i < path.length) {
    string key;
    bool isIndex;

    if (path[i] == '.') {
      i++;
      auto start = i;

      while (i < path.length && path[i] != '.' && path[i] != '[') {
        i++;
      }

      key = path[start .. i];
    } else if (path[i] == '[') {
      i++;
      if (i < path.length && path[i] == '"') {
        auto start = i;

        i++;
        while (i < path.length && path[i] != '"') {
          if (path[i] == '\\') {
            i++;
          }

          i++;
        }

        key = decodeString(path[start .. (i < path.length ? i + 1 : i)], Syntax.json);
        i++;
      } else {
        auto start = i;

        while (i < path.length && path[i] != ']') {
          i++;
        }

        key = path[start .. i];
        isIndex = true;
      }

      if (i < path.length && path[i] == ']') {
        i++;
      }
    } else {
      return noNode;
    }

    if (!doc.nodes[cur].isContainer) {
      return noNode;
    }

    uint next = noNode;

    if (isIndex) {
      try {
        next = doc.childAt(cur, key.to!size_t);
      } catch (Exception) {
        return noNode;
      }
    } else {
      foreach (c; doc.children(cur)) {
        if (doc.hasKey(c) && doc.key(c) == key) {
          next = c;
          break;
        }
      }
    }

    if (next == noNode) {
      return noNode;
    }

    cur = next;
  }

  return cur;
}
