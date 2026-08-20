module view.stats;

import std.digest : toHexString, LetterCase;
import std.digest.md : MD5;
import std.digest.sha : SHA1, SHA256;
import std.format : format;

import doc.document;

struct Stats {
  ulong fileSize;
  size_t objects;
  size_t arrays;
  size_t values;
  size_t nodes;
  size_t maxDepth;
}

Stats collectStats(const Document doc) {
  Stats s;

  s.fileSize = doc.sourceText.length;
  s.nodes = doc.length;

  // depth of every node is its parent's plus one, parents always come first
  auto depth = new uint[doc.length];

  foreach (i, ref n; doc.nodes) {
    if (n.type == NodeType.object) {
      s.objects++;
    } else if (n.type == NodeType.array) {
      s.arrays++;
    } else {
      s.values++;
    }

    if (n.parent != noNode) {
      depth[i] = depth[n.parent] + 1;
      if (depth[i] > s.maxDepth) {
        s.maxDepth = depth[i];
      }
    }
  }

  return s;
}

struct Hashes {
  string md5;
  string sha1;
  string sha256;
}

Hashes hashText(const(char)[] text, scope bool delegate() cancelled = null) {
  MD5 md5;
  SHA1 sha1;
  SHA256 sha256;

  md5.start();
  sha1.start();
  sha256.start();

  enum chunk = 1 << 20;

  for (size_t at = 0; at < text.length; at += chunk) {
    if (cancelled !is null && cancelled()) {
      return Hashes.init;
    }

    auto part = cast(const(ubyte)[])text[at .. at + chunk < text.length ? at + chunk : text.length];

    md5.put(part);
    sha1.put(part);
    sha256.put(part);
  }

  Hashes h;

  h.md5 = toHexString!(LetterCase.upper)(md5.finish()).idup;
  h.sha1 = toHexString!(LetterCase.upper)(sha1.finish()).idup;
  h.sha256 = toHexString!(LetterCase.upper)(sha256.finish()).idup;

  return h;
}

string formatSize(ulong bytes) {
  if (bytes < 1024) {
    return format("%s B", bytes);
  }

  if (bytes < 1024 * 1024) {
    return format("%.1f KB", bytes / 1024.0);
  }

  if (bytes < 1024UL * 1024 * 1024) {
    return format("%.1f MB", bytes / (1024.0 * 1024));
  }

  return format("%.2f GB", bytes / (1024.0 * 1024 * 1024));
}

string groupDigits(ulong v) {
  auto s = format("%s", v);
  char[] res;

  foreach (k, c; s) {
    if (k && (s.length - k) % 3 == 0) {
      res ~= ' ';
    }

    res ~= c;
  }

  return res.idup;
}
