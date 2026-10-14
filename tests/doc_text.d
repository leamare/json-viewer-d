module tests.doc_text;

import doc.node : Syntax;
import std.array : Appender;
import doc.text;

unittest {
  assert(decodeString(`"a\nb"`, Syntax.json) == "a\nb");
  assert(decodeString(`"\u0041\u00e9"`, Syntax.json) == "Aé");
  assert(decodeString(`"\ud83d\ude00"`, Syntax.json) == "😀");
  assert(decodeString(`"c:\path"`, Syntax.kv) == `c:\path`);
  assert(decodeString(`"say \"hi\""`, Syntax.kv) == `say "hi"`);
  assert(decodeString("\"\"\"\nline1\nline2\n\"\"\"", Syntax.multiline) == "line1\nline2");
  assert(decodeString(`"abcdef"`, Syntax.json, 3) == "abc");

  assert(isJsonNumber("0"));
  assert(isJsonNumber("-1.5e+10"));
  assert(!isJsonNumber("01"));
  assert(!isJsonNumber("1."));
  assert(!isJsonNumber(""));

  assert(looksLikeJson(` {"a":1} `));
  assert(!looksLikeJson(`{abc`));
  assert(isFlaggedString(`resource:"a/b.vmat"`));
  assert(!isFlaggedString(`http://x`));

  Appender!string o;

  putJsonString(o, "a\"b\\\n\x01");
  assert(o.data == `"a\"b\\\n\u0001"`);
}
