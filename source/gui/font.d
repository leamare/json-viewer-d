module gui.font;

import std.file : read, exists;
import std.math : floor, ceil, sqrt;

import gui.raster;

final class FontFace {
  private const(ubyte)[] data;
  private uint glyf, loca, hmtx, cmap;
  private int cmapFormat;
  private int locFormat;
  private int numHMetrics;
  private int numGlyphs;

  int unitsPerEm;
  int ascender, descender, lineGap;

  static FontFace load(string path) {
    if (!path.exists) {
      return null;
    }

    try {
      auto f = new FontFace;

      f.data = cast(const(ubyte)[])read(path);
      if (!f.parse()) {
        return null;
      }

      return f;
    } catch (Exception) {
      return null;
    }
  }

  private bool parse() {
    if (data.length < 12) {
      return false;
    }

    uint base = 0;
    if (data[0 .. 4] == "ttcf") {
      base = u32(12);
    }

    auto tag = u32(base);

    // only TrueType outlines, CFF fonts are not supported
    if (tag != 0x00010000 && tag != 0x74727565) {
      return false;
    }

    uint head, hhea, maxp;
    int numTables = u16(base + 4);

    foreach (t; 0 .. numTables) {
      uint rec = base + 12 + t * 16;
      auto name = cast(const(char)[])data[rec .. rec + 4];
      uint offset = u32(rec + 8);

      switch (name) {
        case "head": head = offset; break;
        case "hhea": hhea = offset; break;
        case "maxp": maxp = offset; break;
        case "hmtx": hmtx = offset; break;
        case "loca": loca = offset; break;
        case "glyf": glyf = offset; break;
        case "cmap": cmap = offset; break;
        default: break;
      }
    }

    if (!head || !hhea || !maxp || !hmtx || !loca || !glyf || !cmap) {
      return false;
    }

    unitsPerEm = u16(head + 18);
    locFormat = s16(head + 50);
    ascender = s16(hhea + 4);
    descender = s16(hhea + 6);
    lineGap = s16(hhea + 8);
    numHMetrics = u16(hhea + 34);
    numGlyphs = u16(maxp + 4);

    return pickCmap();
  }

  private bool pickCmap() {
    int count = u16(cmap + 2);
    uint best;
    int bestScore = 0;

    foreach (k; 0 .. count) {
      uint rec = cmap + 4 + k * 8;
      int platform = u16(rec), encoding = u16(rec + 2);
      uint sub = cmap + u32(rec + 4);
      int format = u16(sub);
      int score = 0;

      if (format == 12 && (platform == 3 || platform == 0)) {
        score = 3;
      } else if (format == 4 && platform == 3 && encoding == 1) {
        score = 2;
      } else if (format == 4 && platform == 0) {
        score = 1;
      }

      if (score > bestScore) {
        bestScore = score;
        best = sub;
      }
    }

    if (!best) {
      return false;
    }

    cmap = best;
    cmapFormat = u16(best);

    return true;
  }

  uint glyphIndex(dchar c) {
    if (cmapFormat == 12) {
      uint groups = u32(cmap + 12);
      uint lo = 0, hi = groups;

      while (lo < hi) {
        uint mid = (lo + hi) / 2;
        uint g = cmap + 16 + mid * 12;
        uint start = u32(g), end = u32(g + 4);

        if (c < start) {
          hi = mid;
        } else if (c > end) {
          lo = mid + 1;
        } else {
          return u32(g + 8) + (c - start);
        }
      }

      return 0;
    }

    if (c > 0xFFFF) {
      return 0;
    }

    int segCount = u16(cmap + 6) / 2;
    uint ends = cmap + 14;
    uint starts = ends + segCount * 2 + 2;
    uint deltas = starts + segCount * 2;
    uint ranges = deltas + segCount * 2;
    int lo = 0, hi = segCount;

    while (lo < hi) {
      int mid = (lo + hi) / 2;

      if (u16(ends + mid * 2) < c) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }

    if (lo >= segCount) {
      return 0;
    }

    int start = u16(starts + lo * 2);

    if (c < start) {
      return 0;
    }

    int delta = s16(deltas + lo * 2);
    int rangeOffset = u16(ranges + lo * 2);

    if (!rangeOffset) {
      return (c + delta) & 0xFFFF;
    }

    uint at = ranges + lo * 2 + rangeOffset + (c - start) * 2;

    if (at + 2 > data.length) {
      return 0;
    }

    int g = u16(at);

    return g ? (g + delta) & 0xFFFF : 0;
  }

  int advance(uint glyph) {
    if (glyph < numHMetrics) {
      return u16(hmtx + glyph * 4);
    }

    return u16(hmtx + (numHMetrics - 1) * 4);
  }

  bool outline(uint glyph, ref float[] lines, out int[4] box) {
    auto off = glyphOffset(glyph);

    if (off == uint.max) {
      return false;
    }

    box = [s16(off + 2), s16(off + 4), s16(off + 6), s16(off + 8)];
    float[6] identity = [1, 0, 0, 1, 0, 0];

    addGlyph(glyph, identity, lines, 0);

    return true;
  }

  private uint glyphOffset(uint glyph) {
    if (glyph >= numGlyphs) {
      return uint.max;
    }

    uint a, b;

    if (locFormat == 0) {
      a = u16(loca + glyph * 2) * 2;
      b = u16(loca + glyph * 2 + 2) * 2;
    } else {
      a = u32(loca + glyph * 4);
      b = u32(loca + glyph * 4 + 4);
    }

    if (a == b) {
      return uint.max;
    }

    return glyf + a;
  }

  private void addGlyph(uint glyph, in float[6] m, ref float[] lines, int depth) {
    auto off = glyphOffset(glyph);

    if (off == uint.max || depth > 8) {
      return;
    }

    int contours = s16(off);

    if (contours >= 0) {
      addSimple(off, contours, m, lines);
    } else {
      addComposite(off, m, lines, depth);
    }
  }

  private void addSimple(uint off, int contours, in float[6] m, ref float[] lines) {
    if (!contours) {
      return;
    }

    uint p = off + 10;
    auto endPts = new int[contours];

    foreach (k; 0 .. contours) {
      endPts[k] = u16(p + k * 2);
    }

    p += contours * 2;
    p += 2 + u16(p);
    int count = endPts[$ - 1] + 1;

    auto flags = new ubyte[count];

    for (int k = 0; k < count;) {
      ubyte f = data[p++];

      flags[k++] = f;
      if (f & 8) {
        int repeat = data[p++];

        while (repeat-- > 0 && k < count) {
          flags[k++] = f;
        }
      }
    }

    auto xs = new float[count];
    auto ys = new float[count];
    int v = 0;

    foreach (k; 0 .. count) {
      ubyte f = flags[k];

      if (f & 2) {
        int dx = data[p++];

        v += (f & 16) ? dx : -dx;
      } else if (!(f & 16)) {
        v += s16(p);
        p += 2;
      }

      xs[k] = v;
    }

    v = 0;
    foreach (k; 0 .. count) {
      ubyte f = flags[k];

      if (f & 4) {
        int dy = data[p++];

        v += (f & 32) ? dy : -dy;
      } else if (!(f & 32)) {
        v += s16(p);
        p += 2;
      }

      ys[k] = v;
    }

    foreach (k; 0 .. count) {
      float x = xs[k], y = ys[k];

      xs[k] = m[0] * x + m[2] * y + m[4];
      ys[k] = m[1] * x + m[3] * y + m[5];
    }

    int start = 0;

    foreach (end; endPts) {
      addContour(xs[start .. end + 1], ys[start .. end + 1], flags[start .. end + 1], lines);
      start = end + 1;
    }
  }

  private static void addContour(const float[] xs, const float[] ys, const ubyte[] flags, ref float[] lines) {
    auto n = xs.length;

    if (n < 2) {
      return;
    }

    // start from an on-curve point, or from a midpoint between two off-curve ones
    size_t first = n;

    foreach (k; 0 .. n) {
      if (flags[k] & 1) {
        first = k;
        break;
      }
    }

    float sx, sy;
    size_t begin;

    if (first == n) {
      sx = (xs[0] + xs[1]) / 2;
      sy = (ys[0] + ys[1]) / 2;
      begin = 1;
    } else {
      sx = xs[first];
      sy = ys[first];
      begin = first + 1;
    }

    float cx = sx, cy = sy;
    float qx, qy;
    bool control = false;
    auto steps = first == n ? n : n - 1;

    foreach (step; 0 .. steps) {
      auto k = (begin + step) % n;
      float x = xs[k], y = ys[k];

      if (flags[k] & 1) {
        if (control) {
          addQuad(lines, cx, cy, qx, qy, x, y);
        } else {
          addLine(lines, cx, cy, x, y);
        }

        cx = x;
        cy = y;
        control = false;
      } else {
        if (control) {
          float mx = (qx + x) / 2, my = (qy + y) / 2;

          addQuad(lines, cx, cy, qx, qy, mx, my);
          cx = mx;
          cy = my;
        }

        qx = x;
        qy = y;
        control = true;
      }
    }

    if (control) {
      addQuad(lines, cx, cy, qx, qy, sx, sy);
    } else {
      addLine(lines, cx, cy, sx, sy);
    }
  }

  private void addComposite(uint off, in float[6] m, ref float[] lines, int depth) {
    uint p = off + 10;

    while (true) {
      int flags = u16(p);
      uint glyph = u16(p + 2);

      p += 4;
      float dx = 0, dy = 0;

      if (flags & 1) {
        dx = s16(p);
        dy = s16(p + 2);
        p += 4;
      } else {
        dx = cast(byte)data[p];
        dy = cast(byte)data[p + 1];
        p += 2;
      }

      if (!(flags & 2)) {
        dx = dy = 0;
      }

      float a = 1, b = 0, c = 0, d = 1;

      if (flags & 8) {
        a = d = f2dot14(p);
        p += 2;
      } else if (flags & 0x40) {
        a = f2dot14(p);
        d = f2dot14(p + 2);
        p += 4;
      } else if (flags & 0x80) {
        a = f2dot14(p);
        b = f2dot14(p + 2);
        c = f2dot14(p + 4);
        d = f2dot14(p + 6);
        p += 8;
      }

      float[6] t = [
        m[0] * a + m[2] * b, m[1] * a + m[3] * b,
        m[0] * c + m[2] * d, m[1] * c + m[3] * d,
        m[0] * dx + m[2] * dy + m[4], m[1] * dx + m[3] * dy + m[5],
      ];
      addGlyph(glyph, t, lines, depth + 1);
      if (!(flags & 0x20)) {
        break;
      }
    }
  }

  private static void addLine(ref float[] lines, float x0, float y0, float x1, float y1) {
    lines ~= [x0, y0, x1, y1];
  }

  private static void addQuad(ref float[] lines, float x0, float y0, float x1, float y1, float x2, float y2) {
    float ddx = x0 - 2 * x1 + x2, ddy = y0 - 2 * y1 + y2;
    float dev = sqrt(ddx * ddx + ddy * ddy);
    int n = 1 + cast(int)sqrt(dev / 8);

    if (n > 16) {
      n = 16;
    }

    float px = x0, py = y0;

    foreach (k; 1 .. n + 1) {
      float t = cast(float)k / n, u = 1 - t;
      float x = u * u * x0 + 2 * u * t * x1 + t * t * x2;
      float y = u * u * y0 + 2 * u * t * y1 + t * t * y2;

      lines ~= [px, py, x, y];
      px = x;
      py = y;
    }
  }

  private int u16(size_t at) const { return (data[at] << 8) | data[at + 1]; }
  private int s16(size_t at) const { return cast(short)u16(at); }
  private uint u32(size_t at) const {
    return (cast(uint)data[at] << 24) | (data[at + 1] << 16) | (data[at + 2] << 8) | data[at + 3];
  }
  private float f2dot14(size_t at) const { return s16(at) / 16_384.0f; }
}

struct Glyph {
  int left, top;
  int width, height;
  ubyte[] alpha;
  float advance;
}

final class Font {
  FontFace face;
  Font fallback;
  float size;
  int ascent, descent, lineHeight;
  float gamma = 1.0;

  private float scale;

  private Glyph*[uint] cache;
  private uint[dchar] glyphIds;
  private float[dchar] advances;

  enum subpixels = 4;

  this(FontFace face, float pixelSize) {
    this.face = face;
    size = pixelSize;
    scale = pixelSize / face.unitsPerEm;
    ascent = cast(int)ceil(face.ascender * scale);
    descent = cast(int)ceil(-face.descender * scale);
    lineHeight = ascent + descent + cast(int)(face.lineGap * scale + 0.5f);
  }

  Font fontFor(dchar c) {
    if (c < 0x80 || glyphId(c)) {
      return this;
    }

    for (auto f = fallback; f !is null; f = f.fallback) {
      if (f.glyphId(c)) {
        return f;
      }
    }

    return this;
  }

  uint glyphId(dchar c) {
    if (auto g = c in glyphIds) {
      return *g;
    }

    auto g = face.glyphIndex(c);

    glyphIds[c] = g;

    return g;
  }

  float advance(dchar c) {
    if (auto a = c in advances) {
      return *a;
    }

    auto f = fontFor(c);
    float a = f.face.advance(f.glyphId(c)) * f.scale;

    advances[c] = a;

    return a;
  }

  int measure(const(char)[] text) {
    import std.utf : decode;

    float w = 0;
    size_t i = 0;

    while (i < text.length) {
      dchar c = text[i] < 0x80 ? text[i++] : decodeSafe(text, i);

      w += advance(c);
    }

    return cast(int)ceil(w);
  }

  size_t hitTest(const(char)[] text, float x) {
    float w = 0;
    size_t i = 0;

    while (i < text.length) {
      size_t start = i;
      dchar c = text[i] < 0x80 ? text[i++] : decodeSafe(text, i);
      float a = advance(c);

      if (w + a / 2 > x) {
        return start;
      }

      w += a;
    }

    return text.length;
  }

  Glyph* glyph(dchar c, float penX) {
    auto f = fontFor(c);
    int sub = cast(int)((penX - floor(penX)) * subpixels) % subpixels;
    auto id = f.glyphId(c);
    uint key = (id << 2) | sub;

    if (auto g = key in f.cache) {
      return *g;
    }

    auto g = f.render(id, cast(float)sub / subpixels);

    f.cache[key] = g;

    return g;
  }

  private Glyph* render(uint id, float shift) {
    auto g = new Glyph;

    g.advance = face.advance(id) * scale;

    float[] lines;
    int[4] box;

    if (!face.outline(id, lines, box) || !lines.length) {
      return g;
    }

    int left = cast(int)floor(box[0] * scale + shift);
    int right = cast(int)ceil(box[2] * scale + shift);
    int top = cast(int)ceil(box[3] * scale);
    int bottom = cast(int)floor(box[1] * scale);

    g.left = left;
    g.top = top;
    g.width = right - left + 1;
    g.height = top - bottom + 1;
    if (g.width <= 0 || g.height <= 0 || g.width > 1024 || g.height > 1024) {
      return g;
    }

    auto r = Rasterizer(g.width, g.height);

    for (size_t k = 0; k + 3 < lines.length; k += 4) {
      r.line(lines[k] * scale + shift - left, top - lines[k + 1] * scale,
        lines[k + 2] * scale + shift - left, top - lines[k + 3] * scale);
    }

    g.alpha = r.finish(gamma);

    return g;
  }
}

private dchar decodeSafe(const(char)[] s, ref size_t i) {
  import std.utf : decode, UTFException;

  try {
    return decode(s, i);
  } catch (UTFException) {
    i++;

    return '�';
  }
}
