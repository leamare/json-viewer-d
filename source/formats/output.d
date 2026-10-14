module formats.output;

import std.array : Appender;
import std.stdio : File;

struct StringSink {
  Appender!(char[]) buf;
  size_t limit = size_t.max;

  this(size_t limit) {
    this.limit = limit;
  }

  void put(char c) { buf.put(c); }
  void put(const(char)[] s) { buf.put(s); }

  bool full() const { return buf.data.length >= limit; }
  bool truncated() const { return limit != size_t.max && full(); }

  char[] data() { return buf.data; }
}

struct FileSink {
  private File file;
  private char[] buf;
  private size_t used;

  this(File f, size_t bufferSize = 1 << 20) {
    file = f;
    buf = new char[bufferSize];
  }

  void put(char c) {
    if (used == buf.length) {
      flush();
    }

    buf[used++] = c;
  }

  void put(const(char)[] s) {
    if (used + s.length > buf.length) {
      flush();
      if (s.length >= buf.length) {
        file.rawWrite(s);

        return;
      }
    }

    buf[used .. used + s.length] = s[];
    used += s.length;
  }

  bool full() const { return false; }

  void flush() {
    if (used) {
      file.rawWrite(buf[0 .. used]);
    }

    used = 0;
  }
}

struct WriteOptions {
  bool compact;
  int indent = 4;
  bool tabs;
  bool detectTypes;
  bool groupDuplicates;
  bool embeddedRoot;
  bool readable;
}

void putIndent(Out)(ref Out o, in WriteOptions opt, int level) {
  if (opt.tabs) {
    foreach (_; 0 .. level) {
      o.put('\t');
    }
  } else {
    foreach (_; 0 .. level * opt.indent) {
      o.put(' ');
    }
  }
}
