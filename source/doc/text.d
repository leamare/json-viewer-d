module doc.text;

import std.array : Appender;
import std.utf : encode;

import doc.node : Syntax;

string decodeString(const(char)[] raw, Syntax syntax, size_t maxLen = size_t.max) {
  final switch (syntax) {
    case Syntax.json:
      return unescape!true(stripQuotes(raw), maxLen);
    case Syntax.kv:
      return unescape!false(stripQuotes(raw), maxLen);
    case Syntax.bare:
    case Syntax.flagged:
      return clip(raw, maxLen).idup;
    case Syntax.multiline:
      auto s = raw.length >= 6 ? raw[3 .. $ - 3] : raw;
      // first newline after the opening quotes is not a part of the value
      if (s.length && s[0] == '\r') {
        s = s[1 .. $];
      }

      if (s.length && s[0] == '\n') {
        s = s[1 .. $];
      }

      if (s.length && s[$ - 1] == '\n') {
        s = s[0 .. $ - 1];
      }

      if (s.length && s[$ - 1] == '\r') {
        s = s[0 .. $ - 1];
      }

      return clip(s, maxLen).idup;
  }
}

private const(char)[] stripQuotes(const(char)[] raw) {
  if (raw.length >= 2 && raw[0] == '"' && raw[$ - 1] == '"') {
    return raw[1 .. $ - 1];
  }

  if (raw.length && raw[0] == '"') {
    return raw[1 .. $];
  }

  return raw;
}

private const(char)[] clip(const(char)[] s, size_t maxLen) {
  if (s.length <= maxLen) {
    return s;
  }

  size_t n = maxLen;
  while (n > 0 && (s[n] & 0xC0) == 0x80) {
    n--;
  }

  return s[0 .. n];
}

private string unescape(bool json)(const(char)[] s, size_t maxLen) {
  import std.algorithm : canFind;

  if (!s.canFind('\\')) {
    return clip(s, maxLen).idup;
  }

  Appender!string res;

  res.reserve(s.length < maxLen ? s.length : maxLen);
  size_t i = 0;

  while (i < s.length && res.data.length < maxLen) {
    char ch = s[i];

    if (ch != '\\' || i + 1 >= s.length) {
      res.put(ch);
      i++;
      continue;
    }

    char e = s[i + 1];

    i += 2;
    switch (e) {
      case 'n': res.put('\n'); break;
      case 't': res.put('\t'); break;
      case 'r': res.put('\r'); break;
      case '"': res.put('"'); break;
      case '\\': res.put('\\'); break;
      static if (json) {
        case '/': res.put('/'); break;
        case 'b': res.put('\b'); break;
        case 'f': res.put('\f'); break;
        case 'u':
          dchar c;

          if (!readUnicodeEscape(s, i, c)) {
            res.put("\\u");
            break;
          }

          char[4] buf;

          res.put(buf[0 .. encode(buf, c)]);
          break;
      }
      default:
        res.put('\\');
        res.put(e);
        break;
    }
  }

  return res.data;
}

private bool readUnicodeEscape(const(char)[] s, ref size_t i, out dchar c) {
  uint hi;

  if (!readHex4(s, i, hi)) {
    return false;
  }

  i += 4;
  if (hi >= 0xD800 && hi < 0xDC00) {
    uint lo;

    if (i + 6 <= s.length &&
      s[i] == '\\' &&
      s[i + 1] == 'u' &&
      readHex4(s, i + 2, lo) &&
      lo >= 0xDC00 &&
      lo < 0xE000) {
      i += 6;
      c = cast(dchar)(0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00));

      return true;
    }

    c = '\uFFFD';

    return true;
  }

  if (hi >= 0xDC00 && hi < 0xE000) {
    c = '\uFFFD';

    return true;
  }

  c = cast(dchar)hi;

  return true;
}

private bool readHex4(const(char)[] s, size_t at, out uint value) {
  if (at + 4 > s.length) {
    return false;
  }

  foreach (k; 0 .. 4) {
    char h = s[at + k];
    uint d;

    if (h >= '0' && h <= '9') {
      d = h - '0';
    } else if (h >= 'a' && h <= 'f') {
      d = h - 'a' + 10;
    } else if (h >= 'A' && h <= 'F') {
      d = h - 'A' + 10;
    } else {
      return false;
    }

    value = value * 16 + d;
  }

  return true;
}

void putJsonString(Out)(ref Out o, const(char)[] s) {
  static immutable hexDigits = "0123456789abcdef";

  o.put('"');
  size_t start = 0;

  foreach (i, char ch; s) {
    if (ch >= 0x20 && ch != '"' && ch != '\\' && ch != 0x7F) {
      continue;
    }

    if (start < i) {
      o.put(s[start .. i]);
    }

    start = i + 1;
    switch (ch) {
      case '"': o.put(`\"`); break;
      case '\\': o.put(`\\`); break;
      case '\n': o.put(`\n`); break;
      case '\r': o.put(`\r`); break;
      case '\t': o.put(`\t`); break;
      case '\b': o.put(`\b`); break;
      case '\f': o.put(`\f`); break;
      default:
        char[6] u = `\u00..`;

        u[4] = hexDigits[ch >> 4];
        u[5] = hexDigits[ch & 0xF];
        o.put(u[]);
        break;
    }
  }

  if (start < s.length) {
    o.put(s[start .. $]);
  }

  o.put('"');
}

void putKvString(Out)(ref Out o, const(char)[] s) {
  o.put('"');
  size_t start = 0;

  foreach (i, char ch; s) {
    if (ch != '"' && ch != '\\' && ch != '\n' && ch != '\t') {
      continue;
    }

    if (start < i) {
      o.put(s[start .. i]);
    }

    start = i + 1;
    switch (ch) {
      case '"': o.put(`\"`); break;
      case '\\': o.put(`\\`); break;
      case '\n': o.put(`\n`); break;
      default: o.put(`\t`); break;
    }
  }

  if (start < s.length) {
    o.put(s[start .. $]);
  }

  o.put('"');
}

bool isJsonNumber(const(char)[] s) {
  size_t i = 0;

  if (i < s.length && s[i] == '-') {
    i++;
  }

  if (i >= s.length) {
    return false;
  }

  if (s[i] == '0') {
    i++;
  } else if (s[i] >= '1' && s[i] <= '9') {
    while (i < s.length && isDigit(s[i])) {
      i++;
    }
  } else {
    return false;
  }

  if (i < s.length && s[i] == '.') {
    i++;
    if (i >= s.length || !isDigit(s[i])) {
      return false;
    }

    while (i < s.length && isDigit(s[i])) {
      i++;
    }
  }

  if (i < s.length && (s[i] == 'e' || s[i] == 'E')) {
    i++;
    if (i < s.length && (s[i] == '+' || s[i] == '-')) {
      i++;
    }

    if (i >= s.length || !isDigit(s[i])) {
      return false;
    }

    while (i < s.length && isDigit(s[i])) {
      i++;
    }
  }

  return i == s.length;
}

bool isDigit(char c) { return c >= '0' && c <= '9'; }

bool isSpace(char c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r'; }

bool looksLikeJson(const(char)[] s) {
  size_t a = 0, b = s.length;

  while (a < b && isSpace(s[a])) {
    a++;
  }

  while (b > a && isSpace(s[b - 1])) {
    b--;
  }

  if (b - a < 2) {
    return false;
  }

  return (s[a] == '{' && s[b - 1] == '}') || (s[a] == '[' && s[b - 1] == ']');
}

bool rawLooksLikeJson(const(char)[] raw, Syntax syntax) {
  if (syntax == Syntax.multiline && raw.length >= 6) {
    raw = raw[3 .. $ - 3];
  } else if ((syntax == Syntax.json || syntax == Syntax.kv) && raw.length >= 2) {
    raw = raw[1 .. $ - 1];
  }

  size_t a = 0, b = raw.length;

  while (true) {
    if (a < b && isSpace(raw[a])) {
      a++;
    } else if (a + 1 < b && raw[a] == '\\' && (raw[a + 1] == 'n' || raw[a + 1] == 't' || raw[a + 1] == 'r')) {
      a += 2;
    } else {
      break;
    }
  }

  while (true) {
    if (b > a && isSpace(raw[b - 1])) {
      b--;
    } else if (b >= a + 2 && raw[b - 2] == '\\' && (raw[b - 1] == 'n' || raw[b - 1] == 't' || raw[b - 1] == 'r')) {
      b -= 2;
    } else {
      break;
    }
  }

  if (b - a < 2) {
    return false;
  }

  return (raw[a] == '{' && raw[b - 1] == '}') || (raw[a] == '[' && raw[b - 1] == ']');
}

bool isBareKey(const(char)[] s) {
  if (!s.length || isDigit(s[0])) {
    return false;
  }

  foreach (char c; s) {
    if (!(c == '_' || c == '.' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || isDigit(c))) {
      return false;
    }
  }

  return true;
}

bool isFlaggedString(const(char)[] s) {
  import std.string : indexOf;

  auto colon = s.indexOf(':');

  if (colon <= 0 || s.length < colon + 3 || s[colon + 1] != '"' || s[$ - 1] != '"') {
    return false;
  }

  foreach (char c; s[0 .. colon]) {
    if (!(c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'))) {
      return false;
    }
  }

  foreach (char c; s[colon + 2 .. $ - 1]) {
    if (c == '"' || c == '\n') {
      return false;
    }
  }

  return true;
}
