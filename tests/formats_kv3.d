module tests.formats_kv3;

import doc.document;
import doc.text;
import formats.json : writeJson;
import formats.output;
import formats.kv3;

unittest {
  auto text = defaultKv3Header ~ `
{
  m_Name = "test"
  m_flValue = 1.5
  m_bEnabled = true
  m_Model = resource:"models/heroes/x.vmdl"
  m_Thing = subclass:
  {
    inner = null
  }
  m_Array =
  [
    1,
    -2.5,
    "three",
  ]
  m_Multi = """
line1
line2
"""
  "quoted key" = value_ident
}
`;
  Node[] nodes;
  string header;
  auto r = parseKv3(text, nodes, header);

  assert(!r.error.length, r.error);
  assert(header == defaultKv3Header);

  auto doc = new Document(text);

  doc.nodes = nodes;
  doc.format = Format.kv3;
  assert(doc.nodes[0].len == 8);
  assert(doc.key(1) == "m_Name" && doc.value(1) == "test");
  assert(doc.nodes[2].type == NodeType.number);
  assert(doc.nodes[3].type == NodeType.boolean);
  assert(doc.value(4) == `resource:"models/heroes/x.vmdl"`);
  assert(doc.nodes[5].type == NodeType.object && doc.nodes[6].type == NodeType.null_);
  assert(doc.nodes[7].len == 3);
  assert(doc.value(11) == "line1\nline2");
  assert(doc.key(12) == "quoted key" && doc.value(12) == "value_ident");

  StringSink o;
  WriteOptions opt;

  opt.tabs = true;
  writeKv3(o, doc, 0, opt);
  Node[] again;
  string h2;
  auto r2 = parseKv3(o.data, again, h2);

  assert(!r2.error.length, r2.error ~ "\n" ~ o.data);
  assert(again.length == nodes.length);

  StringSink j;

  opt.compact = true;
  writeJson(j, doc, 0, opt);
  auto expected = `{"m_Name":"test","m_flValue":1.5,"m_bEnabled":true,` ~
    `"m_Model":"resource:\"models/heroes/x.vmdl\"","m_Thing":{"inner":null},` ~
    `"m_Array":[1,-2.5,"three"],"m_Multi":"line1\nline2","quoted key":"value_ident"}`;
  assert(j.data == expected, j.data);
}
