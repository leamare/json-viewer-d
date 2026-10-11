module gui.theme;

import std.algorithm : canFind, startsWith;
import std.array : split;
import std.conv : to;
import std.file : exists, readText, dirEntries, SpanMode, isDir;
import std.path : buildPath, baseName, extension;
import std.process : environment;
import std.string : strip, toLower, indexOf, replace, splitLines;

import gui.canvas : Color, rgb, mix, luma;
import gui.font;

struct Theme {
  bool dark;

  Color window;
  Color view;
  Color alternate;
  Color text;
  Color dimText;
  Color header;
  Color headerText;
  Color border;
  Color selection;
  Color selectionText;
  Color hover;
  Color accent;
  Color button;
  Color buttonText;
  Color error;

  Color key;
  Color str;
  Color number;
  Color boolean;
  Color nil;
  Color punct;

  Color iconObject;
  Color iconArray;
  Color iconString;
  Color iconNumber;
  Color iconBool;
}

Theme breezeLight() {
  Theme t;

  t.window = 0xEFF0F1;
  t.view = 0xFFFFFF;
  t.alternate = 0xF7F7F7;
  t.text = 0x232629;
  t.dimText = 0x707D8A;
  t.selection = 0x3DAEE9;
  t.selectionText = 0xFFFFFF;
  t.accent = 0x3DAEE9;
  t.button = 0xFCFCFC;
  t.buttonText = 0x232629;
  t.header = 0xDEE0E2;
  t.headerText = 0x232629;
  finish(t);

  return t;
}

Theme breezeDark() {
  Theme t;

  t.window = 0x202326;
  t.view = 0x141618;
  t.alternate = 0x1D1F22;
  t.text = 0xFCFCFC;
  t.dimText = 0xA1A9B1;
  t.selection = 0x3DAEE9;
  t.selectionText = 0xFCFCFC;
  t.accent = 0x3DAEE9;
  t.button = 0x292C30;
  t.buttonText = 0xFCFCFC;
  t.header = 0x2A2E32;
  t.headerText = 0xFCFCFC;
  finish(t);

  return t;
}

private void finish(ref Theme t) {
  t.dark = luma(t.view) < 128;
  t.border = mix(t.window, t.text, t.dark ? 0.18 : 0.22);
  t.hover = mix(t.view, t.selection, 0.15);
  t.error = t.dark ? 0xF47174 : 0xDA4453;
  t.punct = t.dimText;
  if (t.dark) {
    t.key = mix(0x8AB4F8, t.text, 0.15);
    t.str = 0xA5D6A7;
    t.number = 0xFFB86C;
    t.boolean = 0xD7A6E8;
    t.nil = 0x9AA0A6;
    t.iconObject = 0x6E9CD4;
    t.iconArray = 0x4FB3BF;
    t.iconString = 0xE5C07B;
    t.iconNumber = 0x9D8CF0;
    t.iconBool = 0x6CC070;
  } else {
    t.key = 0x1D4E89;
    t.str = 0x2E7D32;
    t.number = 0xC2410C;
    t.boolean = 0x8E24AA;
    t.nil = 0x8A8F94;
    t.iconObject = 0x4A7DC4;
    t.iconArray = 0x2A9DAA;
    t.iconString = 0xE0A82E;
    t.iconNumber = 0x7466D8;
    t.iconBool = 0x3E9E44;
  }
}

Theme systemTheme() {
  version (Windows) {
    return windowsAppsUseLight() ? breezeLight() : breezeDark();
  } else {
    auto kde = readKdeGlobals();

    if (kde.length) {
      return kdeTheme(kde);
    }

    auto scheme = environment.get("GTK_THEME").toLower;

    return scheme.canFind("dark") ? breezeDark() : breezeLight();
  }
}

private alias Ini = string[string][string];

private Ini readKdeGlobals() {
  auto home = environment.get("XDG_CONFIG_HOME", buildPath(environment.get("HOME", ""), ".config"));
  auto path = buildPath(home, "kdeglobals");

  if (!path.exists) {
    return null;
  }

  try {
    return parseIni(readText(path));
  } catch (Exception) {
    return null;
  }
}

Ini parseIni(string text) {
  Ini res;
  string section;

  foreach (line; text.splitLines) {
    line = line.strip;
    if (!line.length || line[0] == '#' || line[0] == ';') {
      continue;
    }

    if (line[0] == '[' && line[$ - 1] == ']') {
      section = line[1 .. $ - 1];
      continue;
    }

    auto eq = line.indexOf('=');

    if (eq <= 0) {
      continue;
    }

    res[section][line[0 .. eq].strip] = line[eq + 1 .. $].strip;
  }

  return res;
}

private Theme kdeTheme(Ini ini) {
  bool dark = false;

  if (auto c = color(ini, "Colors:View", "BackgroundNormal")) {
    dark = luma(*c) < 128;
  }

  Theme t = dark ? breezeDark() : breezeLight();

  void take(ref Color dst, string section, string key) {
    if (auto c = color(ini, section, key)) {
      dst = *c;
    }
  }

  take(t.window, "Colors:Window", "BackgroundNormal");
  take(t.view, "Colors:View", "BackgroundNormal");
  take(t.alternate, "Colors:View", "BackgroundAlternate");
  take(t.text, "Colors:View", "ForegroundNormal");
  take(t.dimText, "Colors:View", "ForegroundInactive");
  take(t.selection, "Colors:Selection", "BackgroundNormal");
  take(t.selectionText, "Colors:Selection", "ForegroundNormal");
  take(t.accent, "Colors:View", "DecorationFocus");
  take(t.button, "Colors:Button", "BackgroundNormal");
  take(t.buttonText, "Colors:Button", "ForegroundNormal");
  t.header = mix(t.window, t.text, dark ? 0.07 : 0.06);
  t.headerText = t.text;
  take(t.header, "Colors:Header", "BackgroundNormal");
  take(t.headerText, "Colors:Header", "ForegroundNormal");
  finish(t);

  return t;
}

private Color* color(Ini ini, string section, string key) {
  auto s = section in ini;

  if (s is null) {
    return null;
  }

  auto v = key in *s;

  if (v is null) {
    return null;
  }

  auto parts = (*v).split(',');

  if (parts.length < 3) {
    return null;
  }

  try {
    return new Color(rgb(parts[0].strip.to!int, parts[1].strip.to!int, parts[2].strip.to!int));
  } catch (Exception) {
    return null;
  }
}

version (Windows) private bool windowsAppsUseLight() {
  import core.sys.windows.windows;

  DWORD value = 1, size = DWORD.sizeof;
  HKEY key;

  enum personalize = "Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"w;

  if (RegOpenKeyExW(HKEY_CURRENT_USER, personalize.ptr,
    0, KEY_READ, &key) != 0) {
    return true;
  }
  scope (exit) RegCloseKey(key);

  RegQueryValueExW(key, "AppsUseLightTheme"w.ptr, null, null, cast(ubyte*)&value, &size);

  return value != 0;
}

struct FontChoice {
  string family;
  float points;
}

struct Fonts {
  Font ui;
  Font bold;
  Font mono;
  Font small;
}

Fonts loadFonts(float scale, bool dark) {
  FontChoice ui = FontChoice("Noto Sans", 10), mono = FontChoice("Noto Sans Mono", 10);

  version (Windows) {
    ui = FontChoice("Segoe UI", 9);
    mono = FontChoice("Consolas", 10);
  } else {
    auto kde = readKdeGlobals();

    if (auto g = "General" in kde) {
      if (auto f = "font" in *g) {
        ui = parseQtFont(*f, ui);
      }

      if (auto f = "fixed" in *g) {
        mono = parseQtFont(*f, mono);
      }
    }
  }

  float px(float pt) { return pt * 96 / 72 * scale; }

  auto uiFace = findFace(ui.family, false, false);
  auto boldFace = findFace(ui.family, true, false);
  auto monoFace = findFace(mono.family, false, true);

  if (uiFace is null) {
    throw new Exception("No usable TrueType font found");
  }

  if (boldFace is null) {
    boldFace = uiFace;
  }

  if (monoFace is null) {
    monoFace = uiFace;
  }

  auto symbols = fallbackFaces();

  Font make(FontFace face, float size) {
    auto f = new Font(face, size);

    f.gamma = dark ? 0.85f : 1.0f;
    Font last = f;

    foreach (s; symbols) {
      if (s is face) {
        continue;
      }

      last.fallback = new Font(s, size);
      last.fallback.gamma = f.gamma;
      last = last.fallback;
    }

    return f;
  }

  Fonts fonts;

  fonts.ui = make(uiFace, px(ui.points));
  fonts.bold = make(boldFace, px(ui.points));
  fonts.mono = make(monoFace, px(mono.points));
  fonts.small = make(uiFace, px(ui.points * 0.9f));

  return fonts;
}

FontChoice parseQtFont(string value, FontChoice fallback) {
  auto parts = value.split(',');

  if (parts.length < 2) {
    return fallback;
  }

  try {
    auto size = parts[1].strip.to!float;

    return FontChoice(parts[0].strip, size > 4 && size < 40 ? size : fallback.points);
  } catch (Exception) {
    return FontChoice(parts[0].strip, fallback.points);
  }
}

private FontFace[string] faceCache;

private FontFace loadFace(string path) {
  if (auto f = path in faceCache) {
    return *f;
  }

  auto f = FontFace.load(path);

  faceCache[path] = f;

  return f;
}

private FontFace findFace(string family, bool bold, bool mono) {
  foreach (path; candidates(family, bold, mono)) {
    auto f = loadFace(path);

    if (f !is null) {
      return f;
    }
  }

  return null;
}

private string[] candidates(string family, bool bold, bool mono) {
  string[] res;

  version (Windows) {
    auto dir = buildPath(environment.get("WINDIR", "C:\\Windows"), "Fonts");
    auto local = buildPath(environment.get("LOCALAPPDATA", ""), "Microsoft", "Windows", "Fonts");
    string[] names;

    if (mono) {
      names = ["consola.ttf", "cour.ttf"];
    } else if (bold) {
      names = ["segoeuib.ttf", "tahomabd.ttf", "arialbd.ttf"];
    } else {
      names = ["segoeui.ttf", "tahoma.ttf", "arial.ttf"];
    }

    foreach (d; [dir, local]) {
      foreach (n; names) {
        res ~= buildPath(d, n);
      }
    }

    // Wine keeps its fonts outside of the Windows folder, Linux paths are on drive Z:
    auto wine = mono ? ["Z:/usr/share/fonts/noto/NotoSansMono-Regular.ttf",
      "Z:/usr/share/fonts/TTF/DejaVuSansMono.ttf"]
      : ["Z:/usr/share/fonts/noto/NotoSans-" ~ (bold ? "Bold" : "Regular") ~ ".ttf",
        "Z:/usr/share/wine/fonts/" ~
          (bold ? "tahomabd.ttf" : "tahoma.ttf"), "Z:/usr/share/fonts/TTF/DejaVuSans.ttf"];
    res ~= wine;
    try {
      foreach (e; dirEntries(dir, "*.ttf", SpanMode.shallow, false)) {
        res ~= e.name;
      }
    } catch (Exception) {
    }
  } else {
    auto style = bold ? "Bold" : "Regular";

    res ~= fcMatch(family ~ ":style=" ~ style);
    res ~= scanFonts(family, style);
    auto generic = mono ? "monospace" : "sans-serif";

    res ~= fcMatch(generic ~ ":style=" ~ style);
    foreach (dir; ["/usr/share/fonts/noto", "/usr/share/fonts/TTF", "/usr/share/fonts/truetype/dejavu",
      "/usr/share/fonts/dejavu", "/usr/share/fonts/liberation", "/usr/share/fonts/truetype/liberation"]) {
      if (mono) {
        res ~= buildPath(dir, "NotoSansMono-" ~ style ~ ".ttf");
        res ~= buildPath(dir, bold ? "DejaVuSansMono-Bold.ttf" : "DejaVuSansMono.ttf");
        res ~= buildPath(dir, "LiberationMono-" ~ style ~ ".ttf");
      } else {
        res ~= buildPath(dir, "NotoSans-" ~ style ~ ".ttf");
        res ~= buildPath(dir, bold ? "DejaVuSans-Bold.ttf" : "DejaVuSans.ttf");
        res ~= buildPath(dir, "LiberationSans-" ~ style ~ ".ttf");
      }
    }
  }

  return res;
}

private FontFace[] fallbackFaces() {
  FontFace[] res;

  version (Windows) {
    auto dir = buildPath(environment.get("WINDIR", "C:\\Windows"), "Fonts");

    foreach (n; ["seguisym.ttf", "msyh.ttc", "malgun.ttf", "meiryo.ttc"]) {
      if (auto f = loadFace(buildPath(dir, n))) {
        res ~= f;
      }
    }
  } else {
    auto families = [
      "DejaVu Sans",
      "Noto Sans Symbols2",
      "Noto Sans Symbols",
      "Droid Sans Fallback",
      "WenQuanYi Zen Hei",
    ];

    foreach (pattern; families) {
      foreach (path; fcMatch(pattern) ~ scanFonts(pattern, "")) {
        auto f = loadFace(path);

        if (f !is null && !res.canFind(f)) {
          res ~= f;
          break;
        }
      }
    }
  }

  return res;
}

version (Posix) {
  private string[] fcMatch(string pattern) {
    import std.process : execute;

    try {
      auto r = execute(["fc-match", "-f", "%{file}", pattern]);

      if (r.status == 0 && r.output.strip.length) {
        return [r.output.strip];
      }
    } catch (Exception) {
    }

    return null;
  }

  private string[] fontFiles;

  private string[] scanFonts(string family, string style) {
    if (!fontFiles.length) {
      auto home = environment.get("HOME", "");

      auto dirs = [
        "/usr/share/fonts",
        "/usr/local/share/fonts",
        buildPath(home, ".local/share/fonts"),
        buildPath(home, ".fonts"),
      ];

      foreach (dir; dirs) {
        if (!dir.exists || !dir.isDir) {
          continue;
        }

        try {
          foreach (e; dirEntries(dir, SpanMode.depth, false)) {
            auto ext = e.name.extension.toLower;

            if (ext == ".ttf" || ext == ".ttc") {
              fontFiles ~= e.name;
            }
          }
        } catch (Exception) {
        }
      }
    }

    auto want = normalize(family);
    auto wantStyled = want ~ normalize(style);
    string[] exact, loose;

    foreach (f; fontFiles) {
      auto name = normalize(f.baseName.replace(f.extension, ""));

      if (name == wantStyled || (style == "Regular" && name == want)) {
        exact ~= f;
      } else if (!style.length && name.startsWith(want)) {
        loose ~= f;
      }
    }

    return exact ~ loose;
  }

  private string normalize(string s) {
    char[] res;

    foreach (char c; s.toLower) {
      if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) {
        res ~= c;
      }
    }

    return cast(string)res;
  }
}
