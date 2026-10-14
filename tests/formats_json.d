module tests.formats_json;

import doc.document;
import doc.text;
import formats.output;
import formats.json;

unittest {
  Node[] nodes;
  auto r = parseJson(`{"a": 1, "b": [true, null, "x\"y"], "c": {}}`, nodes);

  assert(!r.error.length, r.error);
  assert(nodes.length == 7);
  assert(nodes[0].type == NodeType.object && nodes[0].len == 3 && nodes[0].end == 7);
  assert(nodes[2].type == NodeType.array && nodes[2].len == 3 && nodes[2].end == 6);
  assert(nodes[5].type == NodeType.string && nodes[5].has(NodeFlags.escaped));
  assert(nodes[6].type == NodeType.object && nodes[6].len == 0);
}

unittest {
  // comments and trailing commas
  Node[] nodes;
  auto r = parseJson("// header\n{\"a\": [1, 2,], /* inline */ \"b\": 2,}", nodes);

  assert(!r.error.length, r.error);
  assert(nodes[0].len == 2);
}

unittest {
  // JSON Lines
  Node[] nodes;
  auto r = parseJson("{\"a\":1}\n{\"a\":2}\n[3]\n", nodes);

  assert(!r.error.length && r.sequence);
  assert(nodes[0].type == NodeType.array && nodes[0].len == 3 && nodes[0].end == nodes.length);
  assert(nodes[1].parent == 0 && nodes[2].parent == 1 && nodes[3].parent == 0);
  assert(nodes[4].parent == 3 && nodes[6].parent == 5);
}

unittest {
  // truncated file keeps what was read
  Node[] nodes;
  auto r = parseJson(`{"a": [1, 2, {"b": 3`, nodes);

  assert(r.error.length);
  assert(nodes.length == 6);
  foreach (n; nodes) {
    assert(n.end <= nodes.length);
  }
}

unittest {
  auto text = `{"a":1,"b":[true,null,"x"],"c":{}}`;
  auto doc = new Document(text);

  parseJson(text, doc.nodes);

  StringSink o;
  WriteOptions opt;

  opt.compact = true;
  writeJson(o, doc, 0, opt);
  assert(o.data == text, o.data);

  StringSink p;

  opt = WriteOptions.init;
  opt.indent = 2;
  writeJson(p, doc, 0, opt);
  assert(
    p.data == "{\n  \"a\": 1,\n  \"b\": [\n    true,\n    null,\n    \"x\"\n  ],\n  \"c\": {}\n}",
    p.data);
}

unittest {
  // readable output decodes escapes, normal one keeps the file as it is
  auto text = `{"\u043a":"\u0433\u0433 \"wp\""}`;
  auto doc = new Document(text);

  parseJson(text, doc.nodes);

  WriteOptions opt;
  StringSink plain, nice;

  opt.compact = true;
  writeJson(plain, doc, 0, opt);
  opt.readable = true;
  writeJson(nice, doc, 0, opt);
  assert(plain.data == text);
  assert(nice.data == `{"к":"гг \"wp\""}`, nice.data);
}
