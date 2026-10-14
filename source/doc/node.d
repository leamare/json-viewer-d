module doc.node;

enum NodeType : ubyte {
  null_,
  boolean,
  number,
  string,
  object,
  array,
}

enum Syntax : ubyte {
  json,
  kv,
  bare,
  multiline,
  flagged,
}

enum NodeFlags : ubyte {
  // key and value live in the document pool instead of the source
  pooled   = 1 << 0,
  hasKey   = 1 << 1,
  escaped  = 1 << 2,
  keyEsc   = 1 << 3,
  // container parsed out of a string value, saved back as a string
  embedded = 1 << 4,
  // view state, kept here so it follows the node through edits
  expanded = 1 << 5,
  // embedded container remembers the string it was parsed from
  original = 1 << 6,
  // that string had quotes escaped once more, PHP addslashes style
  slashed  = 1 << 7,
}

/// One element of the document tree. Nodes are stored in a flat array in
/// pre-order, so a subtree of node `i` is always the range [i, end).
///
/// Strings are never copied out of the source: a node only knows where its
/// key and value are. The key is always located before the value in the same
/// buffer, so we only keep the distance between them (keyGap).
struct Node {
  ulong pos;
  // raw value length for scalars, child count for containers
  uint len;
  uint keyLen;
  uint keyGap;
  uint parent = noNode;
  uint end;
  NodeType type;
  ubyte flags;
  // value syntax in low nibble, key syntax in high nibble
  ubyte syntax;
  ubyte embedFormat;

  bool has(NodeFlags f) const { return (flags & f) != 0; }
  void set(NodeFlags f, bool on = true) {
    if (on) {
      flags |= f;
    } else {
      flags &= ~f;
    }
  }

  bool isContainer() const { return type == NodeType.object || type == NodeType.array; }

  /// Format of an embedded document, the high bit marks it as edited since it was parsed
  ubyte embedKind() const { return embedFormat & 0x7F; }
  bool embedChanged() const { return (embedFormat & 0x80) != 0; }
  void setEmbedKind(ubyte f) { embedFormat = cast(ubyte)((embedFormat & 0x80) | f); }
  void markEmbedChanged() { embedFormat |= 0x80; }

  Syntax valueSyntax() const { return cast(Syntax)(syntax & 0x0F); }
  Syntax keySyntax() const { return cast(Syntax)(syntax >> 4); }
  void setSyntax(Syntax value, Syntax key) { syntax = cast(ubyte)((key << 4) | value); }
}

static assert(Node.sizeof == 32, "Node is expected to stay compact");

enum uint noNode = uint.max;
