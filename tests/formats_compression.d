module tests.formats_compression;

import std.stdio : File;
import formats.compression;

unittest {
  import std.file : tempDir, remove, read;
  import std.path : buildPath;

  auto text = `{"a": [1, 2, 3], "b": "` ~ "x" ~ `"}`;
  auto gzPath = buildPath(tempDir, "jsonview-test.json.gz");

  {
    auto f = File(gzPath, "wb");
    auto sink = CompressedSink(f, Compression.gzip);

    sink.put(text);
    sink.flush();
  }

  auto packed = cast(ubyte[])read(gzPath);

  remove(gzPath);
  assert(compressionFromData(packed) == Compression.gzip);
  assert(cast(string)decompress(Compression.gzip, packed) == text);
  assert(withoutCompression("a/items.vdf.bz2") == "a/items.vdf");
  assert(compressionFromExtension("x.JSON.GZ") == Compression.gzip);

  // bzip2 only where the library is there
  auto bzPath = buildPath(tempDir, "jsonview-test.json.bz2");

  try {
    auto f = File(bzPath, "wb");
    auto sink = CompressedSink(f, Compression.bzip2);

    foreach (k; 0 .. 1000) {
      sink.put(text);
    }

    sink.flush();
  } catch (Exception) {
    return;
  }

  auto bz = cast(ubyte[])read(bzPath);

  remove(bzPath);
  assert(compressionFromData(bz) == Compression.bzip2);

  auto unpacked = cast(string)decompress(Compression.bzip2, bz);

  assert(unpacked.length == text.length * 1000 && unpacked[0 .. text.length] == text);
}
