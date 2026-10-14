module tests.formats_kv;

import doc.document;
import doc.text;
import formats.json : writeJson;
import formats.output;
import formats.kv;

unittest {
  auto text = `// comment
"Root"
{
  "name"		"value"
  bare		token
  "nested" [$WIN32]
  {
    "esc"	"say \"hi\""
    "dup"	"1"
    "dup"	"2"
  }
}
`;
  Node[] nodes;
  auto r = parseKv(text, nodes);

  assert(!r.error.length, r.error);

  auto doc = new Document(text);

  doc.nodes = nodes;
  assert(doc.nodes[0].len == 1);
  assert(doc.key(1) == "Root" && doc.nodes[1].len == 3);
  assert(doc.key(3) == "bare" && doc.value(3) == "token");
  assert(doc.value(5) == `say "hi"`);

  WriteOptions opt;

  opt.tabs = true;
  StringSink o;

  writeKv(o, doc, 0, opt);
  auto back = new Document(o.data.idup);

  parseKv(back.sourceText, back.nodes);
  assert(back.nodes.length == doc.nodes.length);
  assert(back.value(5) == `say "hi"`);

  opt.groupDuplicates = true;
  opt.compact = true;
  StringSink j;

  writeJson(j, doc, 0, opt);
  assert(
    j.data == `{"Root":{"name":"value","bare":"token","nested":{"esc":"say \"hi\"","dup":["1","2"]}}}`,
    j.data);
}
