module tests.view_search;

import doc.document;
import view.search;

unittest {
  import formats : documentFromText;

  auto doc = documentFromText(`{"Name": "Alpha", "list": ["beta", "Привет", "a\"q"]}`);
  Query q;

  q.text = "name";
  assert(findNext(doc, 0, q) == 1);
  q.text = "BETA";
  assert(findNext(doc, 0, q) == 3);
  q.text = "привет";
  assert(findNext(doc, 0, q) == 4);
  q.text = `a"q`;
  assert(findNext(doc, 0, q) == 5);
  q.text = "a";
  assert(findNext(doc, 1, q) == 3);
  assert(findNext(doc, 1, q, true) == 5);
  assert(countMatches(doc, q) == 3);
  q.keys = false;
  q.text = "list";
  assert(findNext(doc, 0, q) == noNode);
}

unittest {
  import formats : documentFromText;

  auto text = "{\"type\": \"epilogue\", \"time\": 5}\n" ~
    "{\"type\": \"chat\", \"text\": \"gg epilogue\"}\n";
  auto doc = documentFromText(text);

  bool pass(string filter, uint c) {
    return matchesFilter(doc, c, parseFilter(filter));
  }

  assert(pass("epilogue", 1) && pass("epilogue", 4));
  assert(pass("type=epilogue", 1) && !pass("type=epilogue", 4));
  assert(pass("type=chat -epilogue", 1) == false && !pass("type=chat -epilogue", 4));
  assert(pass("text:", 4) && !pass("text:", 1));
  assert(pass(`"gg epi"`, 4) && !pass(`"gg epi"`, 1));
  assert(pass("TYPE=EPI time=5", 1));
}
