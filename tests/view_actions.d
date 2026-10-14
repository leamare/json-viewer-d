module tests.view_actions;

import doc.document;
import formats;
import view.actions;

unittest {
  auto list = documentFromText(`[{"id": 1, "n": "a"}, {"id": 2, "n": "b"}]`);
  auto mixed = documentFromText(`[1, "x", {"a": 1}, [2]]`);

  assert(containerSummary(list, 0) == "2 \u00D7 {id, n}");
  assert(containerSummary(list, 1) == `{"id":1,"n":"a"}`);
  assert(containerSummary(list, 1, 8) == `{"id":1,` ~ "\u2026");
  assert(containerSummary(mixed, 0) == "4 items: number, string, object, \u2026");
}

unittest {
  auto doc = documentFromText(`{"a": {"b": [1, "two\nlines"]}}`);

  assert(copyText(doc, 4, CopyKind.value) == "two\nlines");
  assert(copyText(doc, 1, CopyKind.jsonCompact) == `{"b":[1,"two\nlines"]}`);
  assert(copyText(doc, 2, CopyKind.path) == "$.a.b");
  assert(copyText(doc, 1, CopyKind.kv) == "\"a\"\n{\n\t\"b\"\t\t\"1\"\n\t\"b\"\t\t\"two\\nlines\"\n}\n");
  assert(valuePreview(doc, 4) == "two↵lines");
  assert(nodeLabel(doc, 4) == "[1]");
  assert(formatFromName("VDF") == Format.kv);

  assert(findPath(doc, "$.a.b[1]") == 4);
  assert(findPath(doc, `$["a"].b`) == 2);
  assert(findPath(doc, "$") == 0);
  assert(findPath(doc, "$.a.c") == noNode);
  assert(findPath(doc, doc.pathOf(3)) == 3);
}
