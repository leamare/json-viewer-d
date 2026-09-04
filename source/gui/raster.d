/// Antialiased polygon rasterizer, used for glyphs and icons. It accumulates
/// exact signed area coverage, same idea as in font-rs and stb_truetype v2.
module gui.raster;

import std.math : floor, ceil, abs, pow;

struct Rasterizer {
  int w, h;
  float[] acc;

  this(int w, int h) {
    this.w = w;
    this.h = h;
    acc = new float[w * h + 4];
    acc[] = 0;
  }

  void line(float x0, float y0, float x1, float y1) {
    if (abs(y0 - y1) < 1e-6f) {
      return;
    }

    float dir = 1;

    if (y0 > y1) {
      dir = -1;
      float t = x0; x0 = x1; x1 = t;

      t = y0; y0 = y1; y1 = t;
    }

    float dxdy = (x1 - x0) / (y1 - y0);
    float x = x0;

    if (y0 < 0) {
      x -= y0 * dxdy;
      y0 = 0;
    }

    int yEnd = cast(int)ceil(y1);

    if (yEnd > h) {
      yEnd = h;
    }

    foreach (y; cast(int)y0 .. yEnd) {
      size_t row = cast(size_t)y * w;
      float dy = (y + 1 < y1 ? y + 1 : y1) - (y > y0 ? y : y0);
      float xnext = x + dxdy * dy;
      float d = dy * dir;
      float xa = x < xnext ? x : xnext;
      float xb = x < xnext ? xnext : x;

      if (xa < 0) {
        xa = 0;
      }

      if (xb < 0) {
        xb = 0;
      }

      float xaFloor = floor(xa);
      int xai = cast(int)xaFloor;
      float xbCeil = ceil(xb);
      int xbi = cast(int)xbCeil;

      if (xbi <= xai + 1) {
        float xmf = 0.5f * (x + xnext) - xaFloor;

        put(row + xai, d - d * xmf);
        put(row + xai + 1, d * xmf);
      } else {
        float s = 1 / (xb - xa);
        float xaf = xa - xaFloor;
        float a0 = 0.5f * s * (1 - xaf) * (1 - xaf);
        float xbf = xb - xbCeil + 1;
        float am = 0.5f * s * xbf * xbf;

        put(row + xai, d * a0);
        if (xbi == xai + 2) {
          put(row + xai + 1, d * (1 - a0 - am));
        } else {
          float a1 = s * (1.5f - xaf);

          put(row + xai + 1, d * (a1 - a0));
          foreach (xi; xai + 2 .. xbi - 1) {
            put(row + xi, d * s);
          }

          float a2 = a1 + (xbi - xai - 3) * s;

          put(row + xbi - 1, d * (1 - a2 - am));
        }

        put(row + xbi, d * am);
      }

      x = xnext;
    }
  }

  private void put(size_t at, float v) {
    if (at < acc.length) {
      acc[at] += v;
    }
  }

  ubyte[] finish(float gamma) {
    auto res = new ubyte[w * h];
    float sum = 0;

    foreach (k; 0 .. w * h) {
      sum += acc[k];
      float a = abs(sum);

      if (a > 1) {
        a = 1;
      }

      if (gamma != 1) {
        a = pow(a, gamma);
      }

      res[k] = cast(ubyte)(a * 255 + 0.5f);
    }

    return res;
  }
}
