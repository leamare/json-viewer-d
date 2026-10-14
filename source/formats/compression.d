module formats.compression;

import std.path : extension, stripExtension;
import std.stdio : File;
import std.string : toLower;
import std.zlib : Compress, UnCompress, HeaderFormat;

enum Compression : ubyte {
  none,
  gzip,
  bzip2,
}

string compressionName(Compression c) {
  final switch (c) {
    case Compression.none:
      return "";
    case Compression.gzip:
      return "gzip";
    case Compression.bzip2:
      return "bzip2";
  }
}

string compressionExtension(Compression c) {
  final switch (c) {
    case Compression.none:
      return "";
    case Compression.gzip:
      return ".gz";
    case Compression.bzip2:
      return ".bz2";
  }
}

Compression compressionFromExtension(string path) {
  switch (path.extension.toLower) {
    case ".gz":
    case ".gzip":
      return Compression.gzip;
    case ".bz2":
      return Compression.bzip2;
    default:
      return Compression.none;
  }
}

Compression compressionFromData(const(ubyte)[] head) {
  if (head.length >= 2 && head[0] == 0x1F && head[1] == 0x8B) {
    return Compression.gzip;
  }

  if (head.length >= 3 && head[0 .. 3] == "BZh") {
    return Compression.bzip2;
  }

  return Compression.none;
}

string withoutCompression(string path) {
  if (compressionFromExtension(path) != Compression.none) {
    return path.stripExtension;
  }

  return path;
}

ubyte[] decompress(Compression c, const(ubyte)[] data) {
  final switch (c) {
    case Compression.none:
      return data.dup;
    case Compression.gzip:
      return gunzip(data);
    case Compression.bzip2:
      return bunzip(data);
  }
}

private ubyte[] gunzip(const(ubyte)[] data) {
  auto z = new UnCompress(HeaderFormat.gzip);
  ubyte[] res;

  enum chunk = 1 << 20;

  for (size_t at = 0; at < data.length; at += chunk) {
    auto part = data[at .. at + chunk < data.length ? at + chunk : data.length];

    res ~= cast(const(ubyte)[])z.uncompress(part);
  }

  res ~= cast(const(ubyte)[])z.flush();

  return res;
}

struct CompressedSink {
  private File file;
  private Compression mode;
  private char[] buf;
  private size_t used;
  private Compress gz;
  private Bz2Stream bz;

  this(File f, Compression mode, size_t bufferSize = 1 << 20) {
    file = f;
    this.mode = mode;
    buf = new char[bufferSize];

    if (mode == Compression.gzip) {
      gz = new Compress(6, HeaderFormat.gzip);
    } else if (mode == Compression.bzip2) {
      bz.startCompress();
    }
  }

  void put(char c) {
    if (used == buf.length) {
      flushBuffer();
    }

    buf[used++] = c;
  }

  void put(const(char)[] s) {
    while (s.length) {
      if (used == buf.length) {
        flushBuffer();
      }

      auto n = s.length < buf.length - used ? s.length : buf.length - used;

      buf[used .. used + n] = s[0 .. n];
      used += n;
      s = s[n .. $];
    }
  }

  bool full() const { return false; }

  void flush() {
    flushBuffer();

    if (mode == Compression.gzip) {
      file.rawWrite(cast(const(ubyte)[])gz.flush());
    } else if (mode == Compression.bzip2) {
      bz.compress(null, true, (const(ubyte)[] part) { file.rawWrite(part); });
    }
  }

  private void flushBuffer() {
    if (!used) {
      return;
    }

    auto data = cast(const(ubyte)[])buf[0 .. used];

    used = 0;
    final switch (mode) {
      case Compression.none:
        file.rawWrite(data);
        break;
      case Compression.gzip:
        file.rawWrite(cast(const(ubyte)[])gz.compress(data));
        break;
      case Compression.bzip2:
        bz.compress(data, false, (const(ubyte)[] part) { file.rawWrite(part); });
        break;
    }
  }
}

private extern (C) struct bz_stream {
  const(ubyte)* nextIn;
  uint availIn;
  uint totalInLo32;
  uint totalInHi32;
  ubyte* nextOut;
  uint availOut;
  uint totalOutLo32;
  uint totalOutHi32;
  void* state;
  void* bzalloc;
  void* bzfree;
  void* opaque;
}

private alias BzInit = extern (C) int function(bz_stream*, int, int, int) nothrow @nogc;
private alias BzDecompressInit = extern (C) int function(bz_stream*, int, int) nothrow @nogc;
private alias BzStep = extern (C) int function(bz_stream*, int) nothrow @nogc;
private alias BzDecompress = extern (C) int function(bz_stream*) nothrow @nogc;
private alias BzEnd = extern (C) int function(bz_stream*) nothrow @nogc;

private __gshared {
  BzInit bzCompressInit;
  BzStep bzCompress;
  BzEnd bzCompressEnd;
  BzDecompressInit bzDecompressInit;
  BzDecompress bzDecompress;
  BzEnd bzDecompressEnd;
  bool bzLoaded;
}

private enum {
  bzRun = 0,
  bzFinish = 2,
  bzOk = 0,
  bzRunOk = 1,
  bzFinishOk = 3,
  bzStreamEnd = 4,
}

private void loadBzip2() {
  if (bzLoaded) {
    return;
  }

  void* lib;

  version (Windows) {
    import core.sys.windows.windows : LoadLibraryA, GetProcAddress;

    foreach (name; ["bz2.dll", "libbz2.dll", "libbz2-1.dll"]) {
      lib = LoadLibraryA(name.ptr);

      if (lib !is null) {
        break;
      }
    }

    alias find = (string s) => cast(void*)GetProcAddress(lib, s.ptr);
  } else {
    import core.sys.posix.dlfcn : dlopen, dlsym, RTLD_NOW;

    foreach (name; ["libbz2.so.1", "libbz2.so.1.0", "libbz2.so", "libbz2.dylib"]) {
      lib = dlopen(name.ptr, RTLD_NOW);

      if (lib !is null) {
        break;
      }
    }

    alias find = (string s) => dlsym(lib, s.ptr);
  }

  if (lib is null) {
    throw new Exception("bzip2 library (libbz2) is not installed");
  }

  bzCompressInit = cast(BzInit)find("BZ2_bzCompressInit");
  bzCompress = cast(BzStep)find("BZ2_bzCompress");
  bzCompressEnd = cast(BzEnd)find("BZ2_bzCompressEnd");
  bzDecompressInit = cast(BzDecompressInit)find("BZ2_bzDecompressInit");
  bzDecompress = cast(BzDecompress)find("BZ2_bzDecompress");
  bzDecompressEnd = cast(BzEnd)find("BZ2_bzDecompressEnd");

  if (bzCompressInit is null || bzCompress is null || bzDecompressInit is null || bzDecompress is null) {
    throw new Exception("bzip2 library is not usable");
  }

  bzLoaded = true;
}

private ubyte[] bunzip(const(ubyte)[] data) {
  loadBzip2();

  bz_stream s;

  if (bzDecompressInit(&s, 0, 0) != bzOk) {
    throw new Exception("Can't start bzip2 decompression");
  }

  scope (exit) {
    bzDecompressEnd(&s);
  }

  auto res = new ubyte[data.length * 6 + 4096];
  size_t produced = 0;

  s.nextIn = data.ptr;
  s.availIn = cast(uint)data.length;
  while (true) {
    if (produced == res.length) {
      res.length = res.length * 2;
    }

    s.nextOut = res.ptr + produced;
    s.availOut = cast(uint)(res.length - produced);
    auto before = s.availOut;
    auto r = bzDecompress(&s);

    produced += before - s.availOut;

    if (r == bzStreamEnd) {
      // concatenated streams, like pbzip2 makes
      if (s.availIn == 0) {
        break;
      }

      auto rest = s.nextIn[0 .. s.availIn];

      bzDecompressEnd(&s);
      s = bz_stream.init;

      if (bzDecompressInit(&s, 0, 0) != bzOk) {
        break;
      }

      s.nextIn = rest.ptr;
      s.availIn = cast(uint)rest.length;
      continue;
    }

    if (r != bzOk) {
      throw new Exception("Broken bzip2 data");
    }

    if (s.availIn == 0 && s.availOut != 0) {
      throw new Exception("Unexpected end of bzip2 data");
    }
  }

  res.length = produced;

  return res;
}

private struct Bz2Stream {
  bz_stream s;
  ubyte[] outBuf;

  void startCompress() {
    loadBzip2();
    outBuf = new ubyte[1 << 20];

    if (bzCompressInit(&s, 9, 0, 0) != bzOk) {
      throw new Exception("Can't start bzip2 compression");
    }
  }

  void compress(const(ubyte)[] data, bool finish, scope void delegate(const(ubyte)[]) write) {
    s.nextIn = data.ptr;
    s.availIn = cast(uint)data.length;
    while (true) {
      s.nextOut = outBuf.ptr;
      s.availOut = cast(uint)outBuf.length;
      auto r = bzCompress(&s, finish ? bzFinish : bzRun);
      auto n = outBuf.length - s.availOut;

      if (n) {
        write(outBuf[0 .. n]);
      }

      if (finish && r == bzStreamEnd) {
        bzCompressEnd(&s);
        break;
      }

      if (r != bzRunOk && r != bzFinishOk) {
        throw new Exception("bzip2 compression failed");
      }

      if (!finish && s.availIn == 0) {
        break;
      }
    }
  }
}
