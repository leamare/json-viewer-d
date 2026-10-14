module tests.doc_document;

import doc.node;
import doc.text;
import doc.document;

unittest {
  // {"a":1,"b":[2,3]} built by hand
  auto text = `{"a":1,"b":[2,3]}`;
  auto d = new Document(text);
  Node n;

  n.type = NodeType.object; n.pos = 0; n.len = 2; n.end = 5;
  d.nodes ~= n;
  n = Node.init; n.type = NodeType.number; n.pos = 5; n.len = 1; n.keyLen = 3; n.keyGap = 4;
  n.parent = 0; n.end = 2; n.set(NodeFlags.hasKey);
  d.nodes ~= n;
  n = Node.init; n.type = NodeType.array; n.pos = 11; n.len = 2; n.keyLen = 3; n.keyGap = 4;
  n.parent = 0; n.end = 5; n.set(NodeFlags.hasKey);
  d.nodes ~= n;
  n = Node.init; n.type = NodeType.number; n.pos = 12; n.len = 1; n.parent = 2; n.end = 4;
  d.nodes ~= n;
  n.pos = 14; n.end = 5;
  d.nodes ~= n;

  assert(d.key(1) == "a");
  assert(d.value(1) == "1");
  assert(d.pathOf(4) == "$.b[1]");

  // remove "a"
  d.replace(0, 1, 1, []);
  assert(d.nodes.length == 4);
  assert(d.nodes[0].len == 1 && d.nodes[0].end == 4);
  assert(d.nodes[1].end == 4 && d.nodes[2].parent == 1);
  assert(d.modified);

  d.undo();
  assert(d.nodes.length == 5 && d.key(1) == "a" && d.nodes[3].parent == 2);
  assert(!d.modified);
  d.redo();
  assert(d.nodes.length == 4 && d.modified);
}
