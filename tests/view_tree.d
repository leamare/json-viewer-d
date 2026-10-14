module tests.view_tree;

import doc.document;
import view.tree;

unittest {
  import formats : documentFromText;

  auto doc = documentFromText(`{"a": [1, 2, {"b": 3}], "c": {"d": 4}}`);
  auto t = new TreeModel(doc);

  assert(t.length == 3); // root, a, c

  t.expand(1);
  assert(t.length == 6 && t.rows[4].node == 4 && t.rows[4].depth == 2);
  t.expand(4);
  assert(t.length == 7 && t.rows[5].depth == 3);
  t.cursor = 5;
  t.collapse(1);
  assert(t.length == 3 && t.cursor == 1);

  t.expand(1);
  assert(t.length == 7); // remembers nested expansion

  t.collapseAll(0);
  assert(t.length == 1);
  t.expandAll(0);
  assert(t.length == doc.length);

  t.collapseAll(0);
  t.reveal(5);
  assert(t.selected == 5 && t.rows[t.cursor].depth == 3);
  assert(t.rowOf(7) == noRow);
  assert(t.rows[t.rowOf(4)].index == 2);
}

unittest {
  import formats : documentFromText;
  import doc.edit : deleteNode, setValue;

  auto doc = documentFromText("{\"t\":\"a\"}\n{\"t\":\"b\"}\n{\"t\":\"a\"}\n");
  auto t = new TreeModel(doc);

  assert(t.setFilter(0, "t=a") == 2);
  assert(t.length == 3 && t.rows[1].node == 1 && t.rows[2].node == 5 && t.rows[2].index == 2);

  // filter stays on its container and follows the edits
  setValue(doc, 2, "b");
  t.refresh(2);
  assert(t.length == 2 && t.rows[1].node == 5 && t.selected == 0);
  deleteNode(doc, 3);
  t.refresh(0);
  assert(t.length == 2 && t.rows[1].node == 3 && t.rows[1].index == 1);

  t.reveal(1);
  assert(t.filterOf(0) is null && t.length == 4 && t.selected == 1);
}

unittest {
  import formats : documentFromText;

  // strings with JSON among visible children open by themselves, broken ones stay strings
  auto doc = documentFromText(`{"a": "{\"x\": 1}", "b": "[1, 2", "c": [3]}`);
  auto t = new TreeModel(doc);

  assert(doc[1].type == NodeType.object && doc[1].has(NodeFlags.embedded));
  assert(!doc[1].has(NodeFlags.expanded) && !doc.modified);
  assert(doc[3].type == NodeType.string);
  assert(t.length == 4);
}
