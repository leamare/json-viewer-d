module tests.doc_edit;

import doc.document;
import doc.text;
import formats.output : WriteOptions;
import std.algorithm : canFind;
import std.string : strip;
import doc.edit;

unittest {
  import formats : documentFromText, nodeToText;
  import doc.document : Format;

  auto doc = documentFromText(`{"a": 1, "b": "{\"x\": [1, 2]}", "c": [true]}`);
  WriteOptions opt;

  opt.compact = true;
  string json() { return nodeToText(doc, 0, Format.json, opt).strip; }

  assert(setValue(doc, 1, "42") is null);
  assert(json == `{"a":42,"b":"{\"x\": [1, 2]}","c":[true]}`, json);
  assert(setValue(doc, 1, "hello") is null);
  assert(json == `{"a":"hello","b":"{\"x\": [1, 2]}","c":[true]}`, json);

  assert(renameKey(doc, 1, "renamed") is null);
  assert(doc.key(1) == "renamed" && doc.value(1) == "hello");

  assert(expandEmbedded(doc, 2) is null);
  assert(doc[2].type == NodeType.object && doc.key(2) == "b");
  assert(doc.key(3) == "x" && doc[3].len == 2);
  setValue(doc, 4, "5");
  assert(json == `{"renamed":"hello","b":"{\"x\":[5,2]}","c":[true]}`, json);
  assert(collapseEmbedded(doc, 2) is null);
  assert(doc[2].type == NodeType.string && doc.value(2) == `{"x":[5,2]}`);

  auto added = insertNode(doc, 0, noNode, "d", `{"e": null}`);

  assert(doc.key(added) == "d" && doc[added].len == 1);
  insertNode(doc, 3, noNode, "", "text");
  assert(json == `{"renamed":"hello","b":"{\"x\":[5,2]}","c":[true,"text"],"d":{"e":null}}`, json);

  deleteNode(doc, 2);
  assert(json == `{"renamed":"hello","c":[true,"text"],"d":{"e":null}}`, json);

  while (doc.canUndo) {
    doc.undo();
  }

  assert(json == `{"a":1,"b":"{\"x\": [1, 2]}","c":[true]}`, json);
  assert(!doc.modified);

  assert(replaceWithJson(doc, 0, `[1, 2`) !is null);
}

unittest {
  import formats : documentFromText;
  import view.actions : copyText, CopyKind;

  // editing text of embedded JSON keeps it embedded
  auto doc = documentFromText(`{"s": "[1, 2]"}`);

  assert(expandEmbedded(doc, 1) is null);
  assert(copyText(doc, 1, CopyKind.jsonCompact) == "[1,2]");
  assert(replaceWithJson(doc, 1, "[3]") is null);
  assert(doc[1].has(NodeFlags.embedded));
  assert(copyText(doc, 0, CopyKind.jsonCompact).strip == `{"s":"[3]"}`);
}

unittest {
  import formats : documentFromText;
  import view.actions : copyText, CopyKind;

  // KeyValues inside a JSON string, switched to KV3 and back to a string
  auto doc = documentFromText(`{"kv": "\"root\" { \"a\" \"1\" }"}`);

  assert(doc.value(1) == `"root" { "a" "1" }`);
  assert(expandEmbedded(doc, 1) is null);
  assert(doc[1].embedKind == Format.kv && doc[1].type == NodeType.object);
  assert(doc.key(2) == "root" && doc.key(3) == "a");

  assert(setEmbeddedFormat(doc, 1, Format.json) is null);
  assert(copyText(doc, 0, CopyKind.jsonCompact) == `{"kv":"{\"root\":{\"a\":\"1\"}}"}`);
  assert(setEmbeddedFormat(doc, 1, Format.kv3) is null);
  assert(collapseEmbedded(doc, 1) is null);
  import std.algorithm : canFind;
  assert(doc.value(1).canFind("root =") && doc.value(1).canFind(`a = "1"`));
  assert(expandEmbedded(doc, 1) is null && doc[1].embedKind == Format.kv3);
}

unittest {
  import formats : documentFromText;
  import view.actions : copyText, CopyKind;

  // opening untouched embedded JSON changes nothing, even its odd escaping
  auto src = `{"log":"[{\\\"x\\\":1,\"y\":\u0032}]","p":"{\n  \"a\": [1, 2]\n}"}`;
  auto doc = documentFromText(src);

  string json() { return copyText(doc, 0, CopyKind.jsonCompact); }

  assert(expandEmbedded(doc, 1) is null);
  assert(doc[1].has(NodeFlags.slashed) && doc[1].type == NodeType.array);
  assert(!doc.modified && json == src);

  // after an edit the string is rebuilt, still with slashes
  auto x = doc.childAt(doc.childAt(1, 0), 0);

  assert(setValue(doc, x, "5") is null && doc.modified);
  assert(json == `{"log":"[{\\\"x\\\":5,\\\"y\\\":2}]","p":"{\n  \"a\": [1, 2]\n}"}`, json);

  // pretty printed one stays pretty
  auto p = doc.childAt(0, 1);

  assert(expandEmbedded(doc, p) is null);
  insertNode(doc, doc.childAt(p, 0), noNode, null, "3");
  assert(
    json == `{"log":"[{\\\"x\\\":5,\\\"y\\\":2}]","p":"{\n  \"a\": [\n    1,\n    2,\n    3\n  ]\n}"}`,
    json);

  // collapsing untouched one gives the exact string back
  auto doc2 = documentFromText(src);

  expandEmbedded(doc2, 1);
  assert(collapseEmbedded(doc2, 1) is null);
  assert(doc2.valueRaw(1) == `"[{\\\"x\\\":1,\"y\":\u0032}]"` && !doc2.modified);
}
