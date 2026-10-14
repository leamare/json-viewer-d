module tests.view_diff;

import doc.document;
import view.diff;

unittest {
  import formats : documentFromText;

  auto a = documentFromText(`{"name": "x", "list": [1, 2, 3, 4], "obj": {"k": 1, "gone": true}, "same": [1]}`);
  auto b = documentFromText(`{"name": "y", "list": [1, 9, 2, 3, 4], "obj": {"k": 1, "new": null}, "same": [1]}`);
  auto d = new Diff(a, b);

  assert(!d.identical);
  assert(d.added == 2 && d.removed == 1 && d.changed == 1);

  auto top = d.childrenOf(0);

  assert(d.entries[top[0]].status == DiffStatus.changed);
  assert(d.entries[top[3]].status == DiffStatus.same);

  // inserted 9 doesn't break the rest of the list
  auto list = d.childrenOf(top[1]);

  assert(list.length == 5 && d.entries[list[1]].status == DiffStatus.added);
  foreach (k; [0, 2, 3, 4]) {
    assert(d.entries[list[k]].status == DiffStatus.same);
  }

  // escaping doesn't matter
  auto c = documentFromText(`{"а": "б"}`);
  auto e = documentFromText(`{"а": "б"}`);

  assert(new Diff(c, e).identical);
}
