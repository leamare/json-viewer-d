module tests.view_stats;

import doc.document;
import view.stats;

unittest {
  import formats : documentFromText;

  auto doc = documentFromText(`{"a": [1, {"b": null}], "c": "d"}`);
  auto s = collectStats(doc);

  assert(s.objects == 2 && s.arrays == 1 && s.values == 3 && s.nodes == 6 && s.maxDepth == 3);
  assert(hashText("").md5 == "D41D8CD98F00B204E9800998ECF8427E");
  assert(groupDigits(1234567) == "1 234 567");
  assert(formatSize(2048) == "2.0 KB");
}
