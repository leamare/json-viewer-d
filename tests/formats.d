module tests.formats;

import doc.document;
import doc.text;
import formats.compression;
import formats.json;
import formats.kv3;
import formats.kv;
import formats.output : WriteOptions;
import formats;

unittest {
  assert(formatFromContent(`{"a": 1}`) == Format.json);
  assert(formatFromContent(`  [1, 2]`) == Format.json);
  assert(formatFromContent("\"Root\"\n{\n}") == Format.kv);
  assert(formatFromContent("Root { }") == Format.kv);
  assert(formatFromContent("<!-- kv3 -->\n{}") == Format.kv3);
  assert(formatFromContent("{\n\tkey = 1\n}") == Format.kv3);
  assert(formatFromContent("// c\n{\"a\": 1}") == Format.json);

  auto d = documentFromText("{\"a\":1}\n{\"a\":2}\n");

  assert(d.format == Format.jsonl);
  WriteOptions opt;

  assert(nodeToText(d, 0, Format.jsonl, opt) == "{\"a\":1}\n{\"a\":2}\n");
  auto pretty = "[\n    {\n        \"a\": 1\n    },\n    {\n        \"a\": 2\n    }\n]\n";

  assert(nodeToText(d, 0, Format.json, opt) == pretty);
}
