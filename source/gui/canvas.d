module gui.canvas;

import std.math : cos, sin, PI, floor, ceil;
import std.utf : decode, UTFException;

import gui.font;
import gui.raster;

alias Color = uint;

Color rgb(int r, int g, int b) {
  return (clamp255(r) << 16) | (clamp255(g) << 8) | clamp255(b);
}

Color mix(Color a, Color b, float t) {
  int ar = (a >> 16) & 0xFF, ag = (a >> 8) & 0xFF, ab = a & 0xFF;
  int br = (b >> 16) & 0xFF, bg = (b >> 8) & 0xFF, bb = b & 0xFF;

  return rgb(cast(int)(ar + (br - ar) * t), cast(int)(ag + (bg - ag) * t), cast(int)(ab + (bb - ab) * t));
}

int luma(Color c) {
  return (((c >> 16) & 0xFF) * 299 + ((c >> 8) & 0xFF) * 587 + (c & 0xFF) * 114) / 1000;
}

private uint clamp255(int v) { return v < 0 ? 0 : v > 255 ? 255 : v; }

struct Rect {
  int x, y, w, h;

  int right() const { return x + w; }
  int bottom() const { return y + h; }
  bool empty() const { return w <= 0 || h <= 0; }

  bool contains(int px, int py) const {
    return px >= x && py >= y && px < x + w && py < y + h;
  }

  Rect intersect(Rect o) const {
    int x0 = x > o.x ? x : o.x, y0 = y > o.y ? y : o.y;
    int x1 = right < o.right ? right : o.right, y1 = bottom < o.bottom ? bottom : o.bottom;

    return Rect(x0, y0, x1 > x0 ? x1 - x0 : 0, y1 > y0 ? y1 - y0 : 0);
  }

  Rect shrink(int d) const { return Rect(x + d, y + d, w - 2 * d, h - 2 * d); }
  Rect shrink(int dx, int dy) const { return Rect(x + dx, y + dy, w - 2 * dx, h - 2 * dy); }
}

final class Canvas {
  uint[] pixels;
  int width, height;

  private Rect clipRect;
  private Rect[] clipStack;

  void resize(int w, int h) {
    if (w == width && h == height) {
      return;
    }

    width = w;
    height = h;
    pixels = new uint[w * h];
    clipRect = Rect(0, 0, w, h);
    clipStack.length = 0;
  }

  @property Rect clip() const { return clipRect; }

  void pushClip(Rect r) {
    clipStack ~= clipRect;
    clipRect = clipRect.intersect(r);
  }

  void popClip() {
    clipRect = clipStack[$ - 1];
    clipStack.length--;
  }

  void fill(Rect r, Color c) {
    r = r.intersect(clipRect);
    if (r.empty) {
      return;
    }

    foreach (y; r.y .. r.bottom) {
      pixels[y * width + r.x .. y * width + r.right] = c;
    }
  }

  void blend(Rect r, Color c, int alpha) {
    r = r.intersect(clipRect);
    if (r.empty) {
      return;
    }

    foreach (y; r.y .. r.bottom) {
      foreach (ref p; pixels[y * width + r.x .. y * width + r.right]) {
        p = blendPixel(p, c, alpha);
      }
    }
  }

  void hline(int x0, int x1, int y, Color c) { fill(Rect(x0, y, x1 - x0, 1), c); }
  void vline(int x, int y0, int y1, Color c) { fill(Rect(x, y0, 1, y1 - y0), c); }

  void frame(Rect r, Color c) {
    hline(r.x, r.right, r.y, c);
    hline(r.x, r.right, r.bottom - 1, c);
    vline(r.x, r.y, r.bottom, c);
    vline(r.right - 1, r.y, r.bottom, c);
  }

  void roundRect(Rect r, float radius, Color fillColor, Color border = Color.max) {
    if (r.empty) {
      return;
    }

    auto outer = roundRectPath(r.x, r.y, r.w, r.h, radius);

    if (border == Color.max) {
      fillPolygon(outer, fillColor);

      return;
    }

    fillPolygon(outer, border);
    auto inner = roundRectPath(r.x + 1, r.y + 1, r.w - 2, r.h - 2, radius > 1 ? radius - 1 : 0);

    fillPolygon(inner, fillColor);
  }

  void fillPolygon(const float[] pts, Color c, int alpha = 255) {
    if (pts.length < 6) {
      return;
    }

    float minX = float.max, minY = float.max, maxX = -float.max, maxY = -float.max;

    for (size_t k = 0; k + 1 < pts.length; k += 2) {
      if (pts[k] < minX) {
        minX = pts[k];
      }

      if (pts[k] > maxX) {
        maxX = pts[k];
      }

      if (pts[k + 1] < minY) {
        minY = pts[k + 1];
      }

      if (pts[k + 1] > maxY) {
        maxY = pts[k + 1];
      }
    }

    int ox = cast(int)floor(minX), oy = cast(int)floor(minY);
    int w = cast(int)ceil(maxX) - ox + 1, h = cast(int)ceil(maxY) - oy + 1;

    if (w <= 0 || h <= 0 || w > 4096 || h > 4096) {
      return;
    }

    auto r = Rasterizer(w, h);
    auto n = pts.length / 2;

    foreach (k; 0 .. n) {
      auto j = (k + 1) % n;

      r.line(pts[k * 2] - ox, pts[k * 2 + 1] - oy, pts[j * 2] - ox, pts[j * 2 + 1] - oy);
    }

    mask(r.finish(1.0f), w, h, ox, oy, c, alpha);
  }

  void fillCircle(float cx, float cy, float radius, Color c) {
    float[] pts;
    enum segments = 24;

    foreach (k; 0 .. segments) {
      float a = 2 * PI * k / segments;

      pts ~= [cx + radius * cos(a), cy + radius * sin(a)];
    }

    fillPolygon(pts, c);
  }

  void mask(const ubyte[] alpha, int w, int h, int x, int y, Color c, int opacity = 255) {
    auto area = Rect(x, y, w, h).intersect(clipRect);

    foreach (py; area.y .. area.bottom) {
      auto src = alpha[(py - y) * w .. (py - y + 1) * w];
      auto dst = pixels[py * width .. (py + 1) * width];

      foreach (px; area.x .. area.right) {
        int a = src[px - x];

        if (!a) {
          continue;
        }

        if (opacity != 255) {
          a = a * opacity / 255;
        }

        dst[px] = a == 255 ? c : blendPixel(dst[px], c, a);
      }
    }
  }

  int text(Font font, int x, int y, const(char)[] s, Color c, int maxX = int.max) {
    float pen = x;
    int baseline = y + font.ascent;
    size_t i = 0;

    while (i < s.length) {
      dchar ch = s[i] < 0x80 ? s[i++] : decodeSafe(s, i);

      if (ch == '\t') {
        ch = ' ';
      }

      auto g = font.glyph(ch, pen);

      if (pen + g.advance > maxX) {
        break;
      }

      if (g.alpha.length) {
        mask(g.alpha, g.width, g.height, cast(int)floor(pen) + g.left, baseline - g.top, c);
      }

      pen += font.advance(ch);
    }

    return cast(int)ceil(pen);
  }

  int textFit(Font font, int x, int y, const(char)[] s, Color c, int width) {
    if (width <= 0) {
      return x;
    }

    if (font.measure(s) <= width) {
      return text(font, x, y, s, c);
    }

    enum ellipsis = "…";
    int room = width - font.measure(ellipsis);
    auto end = font.hitTest(s, room);
    while (end > 0 && font.measure(s[0 .. end]) > room) {
      end--;
      while (end > 0 && (s[end] & 0xC0) == 0x80) {
        end--;
      }
    }

    int ex = text(font, x, y, s[0 .. end], c);

    return text(font, ex, y, ellipsis, c);
  }

  void arrow(int cx, int cy, int size, int dir, Color c) {
    float s = size / 2.0f;
    float x = cx + 0.5f, y = cy + 0.5f;

    if (dir == 0) {
      fillPolygon([x - s * 0.5f, y - s, x + s * 0.6f, y, x - s * 0.5f, y + s], c);
    } else if (dir == 1) {
      fillPolygon([x - s, y - s * 0.5f, x + s, y - s * 0.5f, x, y + s * 0.6f], c);
    } else if (dir == 2) {
      fillPolygon([x + s * 0.5f, y - s, x - s * 0.6f, y, x + s * 0.5f, y + s], c);
    } else {
      fillPolygon([x - s, y + s * 0.5f, x + s, y + s * 0.5f, x, y - s * 0.6f], c);
    }
  }

  void line(float x0, float y0, float x1, float y1, float thickness, Color c) {
    import std.math : sqrt;

    float dx = x1 - x0, dy = y1 - y0;
    float len = sqrt(dx * dx + dy * dy);

    if (len < 1e-3f) {
      return;
    }

    float nx = -dy / len * thickness / 2, ny = dx / len * thickness / 2;

    fillPolygon([x0 + nx, y0 + ny, x1 + nx, y1 + ny, x1 - nx, y1 - ny, x0 - nx, y0 - ny], c);
  }
}

private uint blendPixel(uint dst, uint src, int a) {
  uint ia = 255 - a;
  uint rb = ((src & 0xFF00FF) * a + (dst & 0xFF00FF) * ia) >> 8;
  uint g = ((src & 0x00FF00) * a + (dst & 0x00FF00) * ia) >> 8;

  return (rb & 0xFF00FF) | (g & 0x00FF00);
}

private float[] roundRectPath(float x, float y, float w, float h, float r) {
  if (r > w / 2) {
    r = w / 2;
  }

  if (r > h / 2) {
    r = h / 2;
  }

  float[] pts;

  if (r < 0.5f) {
    return [x, y, x + w, y, x + w, y + h, x, y + h];
  }

  enum steps = 6;

  void corner(float cx, float cy, float start) {
    foreach (k; 0 .. steps + 1) {
      float a = start + (PI / 2) * k / steps;

      pts ~= [cx + r * cos(a), cy + r * sin(a)];
    }
  }
  corner(x + w - r, y + r, -PI / 2);
  corner(x + w - r, y + h - r, 0);
  corner(x + r, y + h - r, PI / 2);
  corner(x + r, y + r, PI);

  return pts;
}

private dchar decodeSafe(const(char)[] s, ref size_t i) {
  try {
    return decode(s, i);
  } catch (UTFException) {
    i++;

    return '�';
  }
}
