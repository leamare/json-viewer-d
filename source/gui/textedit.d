module gui.textedit;

import std.algorithm : min, max;
import std.array : split, join;
import std.conv : to;
import std.utf : stride, strideBack;

import gui.ui;

struct TextPos {
  size_t line;
  size_t col;

  int opCmp(in TextPos o) const {
    if (line != o.line) {
      return line < o.line ? -1 : 1;
    }

    if (col != o.col) {
      return col < o.col ? -1 : 1;
    }

    return 0;
  }
}

final class TextEdit : Widget {
  bool readOnly;
  bool highlight = true;

  void delegate() onChange;
  void delegate() onSubmit;

  private string[] lines = [""];
  private TextPos cursor, anchor;
  private size_t preferredX;
  private ScrollBar vbar;
  private ScrollBar hbar = ScrollBar(false);
  private long scrollY;
  private int scrollX;
  private bool selecting;
  private bool barHot;
  private Change[] undoList, redoList;

  private static struct Change {
    TextPos start;
    string removed;
    string inserted;
  }

  this(Ui ui) {
    super(ui);
  }

  override bool focusable() { return true; }

  override Cursor cursorAt(int x, int y) {
    if (vbar.rect.contains(x, y) || hbar.rect.contains(x, y)) {
      return Cursor.arrow;
    }

    return Cursor.text;
  }

  @property Font font() { return ui.fonts.mono; }
  @property int lineH() { return font.lineHeight + ui.px(1); }
  @property int gutterW() { return font.measure(lines.length.to!string) + ui.px(18); }
  @property int barSize() { return ui.px(12); }

  @property Rect textArea() {
    return Rect(rect.x + gutterW, rect.y, rect.w - gutterW - barSize, rect.h - (hbar.needed ? barSize : 0));
  }

  @property int visibleLines() { return max(1, textArea.h / lineH); }

  void setText(string text) {
    lines = text.split('\n');
    if (!lines.length) {
      lines = [""];
    }

    foreach (ref l; lines) {
      if (l.length && l[$ - 1] == '\r') {
        l = l[0 .. $ - 1];
      }
    }

    cursor = anchor = TextPos(0, 0);
    scrollY = 0;
    scrollX = 0;
    undoList.length = 0;
    redoList.length = 0;
    ui.invalidate();
  }

  string text() const { return lines.join('\n'); }

  @property bool hasSelection() const { return cursor != anchor; }
  @property TextPos selStart() const { return cursor < anchor ? cursor : anchor; }
  @property TextPos selEnd() const { return cursor < anchor ? anchor : cursor; }
  @property TextPos caret() const { return cursor; }
  @property size_t lineCount() const { return lines.length; }

  string selectedText() const { return textBetween(selStart, selEnd); }

  override void layout(Rect r) {
    rect = r;
    auto area = textArea;

    vbar.rect = Rect(r.right - barSize, r.y, barSize, area.h);
    hbar.rect = Rect(area.x, r.bottom - barSize, area.w, barSize);
  }

  override void draw(Canvas c) {
    auto t = ui.theme;
    auto f = font;

    c.fill(rect, t.view);
    auto area = textArea;
    auto gutter = Rect(rect.x, rect.y, gutterW, area.h);

    c.fill(gutter, mix(t.view, t.window, 0.6));
    c.vline(gutter.right - 1, gutter.y, gutter.bottom, mix(t.view, t.border, 0.5));

    auto selA = selStart, selB = selEnd;
    int widest = 0;

    foreach (k; 0 .. visibleLines + 1) {
      auto li = cast(size_t)(scrollY + k);

      if (li >= lines.length) {
        break;
      }

      int y = area.y + k * lineH;
      auto line = lines[li];

      if (li == cursor.line && focused && !hasSelection) {
        c.fill(Rect(area.x, y, area.w, lineH), mix(t.view, t.selection, 0.08));
      }

      auto num = (li + 1).to!string;

      c.text(f, gutter.right - ui.px(8) - f.measure(num), y, num, li == cursor.line ? t.text : t.dimText);

      c.pushClip(area);
      int x0 = area.x + ui.px(4) - scrollX;

      if (hasSelection && li >= selA.line && li <= selB.line) {
        size_t a = li == selA.line ? selA.col : 0;
        size_t b = li == selB.line ? selB.col : line.length;
        int xa = x0 + measure(line, a), xb = x0 + measure(line, b);

        if (li != selB.line) {
          xb += f.measure(" ");
        }

        c.fill(Rect(xa, y, xb - xa, lineH), mix(t.view, t.selection, focused ? 0.45 : 0.25));
      }

      drawLine(c, x0, y, line, area.right);
      if (li == cursor.line && focused && ui.caretOn) {
        c.fill(Rect(x0 + measure(line, cursor.col), y, max(1, ui.px(1.5)), lineH), t.text);
      }

      c.popClip();
      if (line.length < 4096) {
        widest = max(widest, f.measure(line));
      }
    }

    vbar.total = lines.length;
    vbar.page = visibleLines;
    vbar.pos = scrollY;
    vbar.draw(c, t, barHot);
    hbar.total = widest + ui.px(40) > area.w ? widest + ui.px(40) : 0;
    hbar.page = area.w;
    hbar.pos = scrollX;
    if (hbar.needed) {
      hbar.draw(c, t, barHot);
    }
  }

  private int measure(string line, size_t col) {
    return font.measure(line[0 .. min(col, line.length)]);
  }

  private void drawLine(Canvas c, int x, int y, string line, int maxX) {
    auto t = ui.theme;
    auto f = font;

    if (!highlight || line.length > 20_000) {
      c.text(f, x, y, line, t.text, maxX);

      return;
    }

    size_t i = 0;

    while (i < line.length && x < maxX) {
      size_t start = i;
      char ch = line[i];
      Color color = t.text;

      if (ch == '"') {
        i++;
        while (i < line.length && line[i] != '"') {
          if (line[i] == '\\') {
            i++;
          }

          i++;
        }

        i = min(i + 1, line.length);
        size_t j = i;

        while (j < line.length && line[j] == ' ') {
          j++;
        }

        color = j < line.length && (line[j] == ':' || line[j] == '=') ? t.key : t.str;
      } else if (ch == '-' || (ch >= '0' && ch <= '9')) {
        while (i < line.length && (line[i] == '.' || line[i] == '-' || line[i] == '+' || line[i] == 'e' ||
          line[i] == 'E' || (line[i] >= '0' && line[i] <= '9'))) {
          i++;
        }
        color = t.number;
      } else if (ch >= 'a' && ch <= 'z') {
        while (i < line.length && line[i] >= 'a' && line[i] <= 'z') {
          i++;
        }

        auto w = line[start .. i];

        color = w == "null" ? t.nil : (w == "true" || w == "false") ? t.boolean : t.text;
      } else if (ch == '/' && i + 1 < line.length && line[i + 1] == '/') {
        i = line.length;
        color = t.dimText;
      } else {
        while (i < line.length && (line[i] == ' ' || line[i] == '{' || line[i] == '}' || line[i] == '[' ||
          line[i] == ']' || line[i] == ',' || line[i] == ':')) {
          i++;
        }
        if (i == start) {
          i += stride(line, i);
        }

        color = line[start] == ' ' ? t.text : t.punct;
      }

      x = c.text(f, x, y, line[start .. i], color, maxX + ui.px(20));
    }
  }

  private string textBetween(TextPos a, TextPos b) const {
    if (a.line == b.line) {
      return lines[a.line][a.col .. b.col];
    }

    string res = lines[a.line][a.col .. $];

    foreach (li; a.line + 1 .. b.line) {
      res ~= "\n" ~ lines[li];
    }

    return res ~ "\n" ~ lines[b.line][0 .. b.col];
  }

  private TextPos replaceText(TextPos a, TextPos b, string text, bool record = true) {
    auto removed = textBetween(a, b);
    auto prefix = lines[a.line][0 .. a.col];
    auto suffix = lines[b.line][b.col .. $];
    auto fresh = (prefix ~ text ~ suffix).split('\n');

    if (!fresh.length) {
      fresh = [""];
    }

    lines = lines[0 .. a.line] ~ fresh ~ lines[b.line + 1 .. $];
    auto end = TextPos(a.line + fresh.length - 1, fresh[$ - 1].length - suffix.length);

    if (record) {
      if (undoList.length && !removed.length && text.length == 1 && text != "\n") {
        auto last = &undoList[$ - 1];
        auto lastEnd = endOf(last.start, last.inserted);

        if (!last.removed.length && lastEnd == a && last.inserted.length < 64) {
          last.inserted ~= text;
          redoList.length = 0;
          changed();

          return end;
        }
      }

      undoList ~= Change(a, removed, text);
      redoList.length = 0;
    }

    changed();

    return end;
  }

  private static TextPos endOf(TextPos start, string text) {
    size_t line = start.line, col = start.col;

    foreach (char ch; text) {
      if (ch == '\n') {
        line++;
        col = 0;
      } else {
        col++;
      }
    }

    return TextPos(line, col);
  }

  private void changed() {
    ui.invalidate();
    if (onChange) {
      onChange();
    }
  }

  void insert(string s) {
    if (readOnly) {
      return;
    }

    import std.string : replace;
    s = s.replace("\r\n", "\n").replace("\r", "\n");
    cursor = anchor = replaceText(selStart, selEnd, s);
    preferredX = size_t.max;
    ensureCaretVisible();
  }

  void undo() {
    if (!undoList.length || readOnly) {
      return;
    }

    auto c = undoList[$ - 1];

    undoList.length--;
    auto end = endOf(c.start, c.inserted);

    cursor = anchor = replaceText(c.start, end, c.removed, false);
    redoList ~= c;
    ensureCaretVisible();
  }

  void redo() {
    if (!redoList.length || readOnly) {
      return;
    }

    auto c = redoList[$ - 1];

    redoList.length--;
    auto end = endOf(c.start, c.removed);

    cursor = anchor = replaceText(c.start, end, c.inserted, false);
    undoList ~= c;
    ensureCaretVisible();
  }

  void selectAll() {
    anchor = TextPos(0, 0);
    cursor = TextPos(lines.length - 1, lines[$ - 1].length);
    ui.invalidate();
  }

  void goTo(size_t line, size_t col = 0) {
    line = min(line, lines.length - 1);
    cursor = anchor = TextPos(line, min(col, lines[line].length));
    scrollY = max(0, cast(long)line - visibleLines / 3);
    ensureCaretVisible();
  }

  override bool keyDown(ref const Event e) {
    bool shift = e.shift, ctrl = e.ctrl;
    auto line = lines[cursor.line];
    bool keepX = false;

    switch (e.key) {
      case Key.left:
        if (hasSelection && !shift) {
          cursor = selStart;
        } else if (cursor.col) {
          cursor.col = ctrl
            ? wordLeft(line, cursor.col)
            : cursor.col - strideBack(line, cursor.col);
        } else if (cursor.line) {
          cursor = TextPos(cursor.line - 1, lines[cursor.line - 1].length);
        }

        break;
      case Key.right:
        if (hasSelection && !shift) {
          cursor = selEnd;
        } else if (cursor.col < line.length) {
          cursor.col = ctrl
            ? wordRight(line, cursor.col)
            : cursor.col + stride(line, cursor.col);
        } else if (cursor.line + 1 < lines.length) {
          cursor = TextPos(cursor.line + 1, 0);
        }

        break;
      case Key.up:
        if (ctrl) {
          scrollY = max(0, scrollY - 1);
          ui.invalidate();

          return true;
        }

        moveLines(-1);
        keepX = true;
        break;
      case Key.down:
        if (ctrl) {
          scrollY = min(scrollY + 1, max(0, cast(long)lines.length - visibleLines));
          ui.invalidate();

          return true;
        }

        moveLines(1);
        keepX = true;
        break;
      case Key.pageUp:
        moveLines(-(visibleLines - 1));
        keepX = true;
        break;
      case Key.pageDown:
        moveLines(visibleLines - 1);
        keepX = true;
        break;
      case Key.home:
        if (ctrl) {
          cursor = TextPos(0, 0);
        } else {
          size_t indent = 0;

          while (indent < line.length && (line[indent] == ' ' || line[indent] == '\t')) {
            indent++;
          }

          cursor.col = cursor.col == indent ? 0 : indent;
        }

        break;
      case Key.end:
        if (ctrl) {
          cursor = TextPos(lines.length - 1, lines[$ - 1].length);
        } else {
          cursor.col = line.length;
        }

        break;
      case Key.backspace:
        if (readOnly) {
          return true;
        }

        if (!hasSelection) {
          if (cursor.col) {
            anchor = TextPos(cursor.line,
              ctrl ? wordLeft(line, cursor.col) : cursor.col - strideBack(line, cursor.col));
          } else if (cursor.line) {
            anchor = TextPos(cursor.line - 1, lines[cursor.line - 1].length);
          }
        }

        insert("");

        return true;
      case Key.del:
        if (readOnly) {
          return true;
        }

        if (!hasSelection) {
          if (cursor.col < line.length) {
            anchor = TextPos(cursor.line,
              ctrl ? wordRight(line, cursor.col) : cursor.col + stride(line, cursor.col));
          } else if (cursor.line + 1 < lines.length) {
            anchor = TextPos(cursor.line + 1, 0);
          }
        }

        insert("");

        return true;
      case Key.enter:
        if (ctrl) {
          if (onSubmit) {
            onSubmit();
          }

          return true;
        }

        if (readOnly) {
          return true;
        }

        insert("\n" ~ autoIndent(line, cursor.col));

        return true;
      case Key.tab:
        if (readOnly) {
          return false;
        }

        insert("    ");

        return true;
      case Key.a:
        if (!ctrl) {
          return false;
        }

        selectAll();

        return true;
      case Key.c:
      case Key.x:
        if (!ctrl) {
          return false;
        }

        if (hasSelection) {
          ui.copy(selectedText);
          if (e.key == Key.x && !readOnly) {
            insert("");
          }
        }

        return true;
      case Key.v:
        if (!ctrl) {
          return false;
        }

        insert(ui.paste());

        return true;
      case Key.z:
        if (!ctrl) {
          return false;
        }

        if (shift) {
          redo();
        } else {
          undo();
        }

        return true;
      case Key.y:
        if (!ctrl) {
          return false;
        }

        redo();

        return true;
      default:
        return false;
    }

    if (!shift) {
      anchor = cursor;
    }

    if (!keepX) {
      preferredX = size_t.max;
    }

    ui.caretOn = true;
    ensureCaretVisible();
    ui.invalidate();

    return true;
  }

  override bool textInput(string s) {
    if (readOnly) {
      return false;
    }

    insert(s);

    return true;
  }

  private string autoIndent(string line, size_t col) {
    size_t indent = 0;

    while (indent < line.length && (line[indent] == ' ' || line[indent] == '\t')) {
      indent++;
    }

    auto res = line[0 .. indent];
    size_t k = col;

    while (k > 0 && line[k - 1] == ' ') {
      k--;
    }

    if (k > 0 && (line[k - 1] == '{' || line[k - 1] == '[')) {
      res ~= "    ";
    }

    return res;
  }

  private void moveLines(long delta) {
    if (preferredX == size_t.max) {
      preferredX = measure(lines[cursor.line], cursor.col);
    }

    auto target = cast(long)cursor.line + delta;

    target = max(0, min(target, cast(long)lines.length - 1));
    cursor.line = cast(size_t)target;
    cursor.col = font.hitTest(lines[cursor.line], preferredX);
  }

  private static size_t wordLeft(string s, size_t i) {
    while (i > 0 && !isWord(s[i - 1])) {
      i--;
    }

    while (i > 0 && isWord(s[i - 1])) {
      i--;
    }

    return i;
  }

  private static size_t wordRight(string s, size_t i) {
    while (i < s.length && isWord(s[i])) {
      i++;
    }

    while (i < s.length && !isWord(s[i])) {
      i++;
    }

    return i;
  }

  private static bool isWord(char c) {
    return c == '_' || c >= 0x80 ||
      (c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9');
  }

  void ensureCaretVisible() {
    if (cursor.line < scrollY) {
      scrollY = cursor.line;
    }

    if (cursor.line >= scrollY + visibleLines) {
      scrollY = cursor.line - visibleLines + 1;
    }

    auto area = textArea;
    int x = measure(lines[cursor.line], cursor.col);

    if (x - scrollX > area.w - ui.px(20)) {
      scrollX = x - area.w + ui.px(40);
    }

    if (x - scrollX < 0) {
      scrollX = max(0, x - ui.px(40));
    }

    ui.invalidate();
  }

  private TextPos posAt(int x, int y) {
    auto area = textArea;
    long li = scrollY + (y - area.y) / lineH;

    li = max(0, min(li, cast(long)lines.length - 1));
    auto line = lines[cast(size_t)li];

    return TextPos(cast(size_t)li, font.hitTest(line, x - area.x - ui.px(4) + scrollX));
  }

  override bool mouseDown(ref const Event e) {
    ui.setFocus(this);
    ui.capture = this;
    if (vbar.mouseDown(e.x, e.y)) {
      scrollY = vbar.pos;

      return true;
    }

    if (hbar.mouseDown(e.x, e.y)) {
      scrollX = cast(int)hbar.pos;

      return true;
    }

    if (e.button == MouseButton.right) {
      return true;
    }

    auto p = posAt(e.x, e.y);

    if (e.clicks == 2) {
      auto line = lines[p.line];
      size_t a = p.col, b = p.col;

      while (a > 0 && isWord(line[a - 1])) {
        a--;
      }

      while (b < line.length && isWord(line[b])) {
        b++;
      }

      anchor = TextPos(p.line, a);
      cursor = TextPos(p.line, b);
    } else if (e.clicks >= 3) {
      anchor = TextPos(p.line, 0);
      cursor = TextPos(p.line, lines[p.line].length);
    } else {
      cursor = p;
      if (!e.shift) {
        anchor = p;
      }

      selecting = true;
    }

    preferredX = size_t.max;
    ui.caretOn = true;
    ui.invalidate();

    return true;
  }

  override void mouseMove(ref const Event e) {
    if (vbar.mouseMove(e.x, e.y)) {
      scrollY = vbar.pos;
      ui.invalidate();

      return;
    }

    if (hbar.mouseMove(e.x, e.y)) {
      scrollX = cast(int)hbar.pos;
      ui.invalidate();

      return;
    }

    bool hot = vbar.rect.contains(e.x, e.y) || (hbar.needed && hbar.rect.contains(e.x, e.y));

    if (hot != barHot) {
      barHot = hot;
      ui.invalidate();
    }

    if (!selecting) {
      return;
    }

    cursor = posAt(e.x, e.y);
    ensureCaretVisible();
  }

  override void mouseUp(ref const Event e) {
    selecting = false;
    vbar.mouseUp();
    hbar.mouseUp();
  }

  override bool wheel(ref const Event e) {
    if (e.wheelY != 0) {
      scrollY = max(0, min(scrollY - cast(long)(e.wheelY * 3), cast(long)lines.length - visibleLines));
    }

    if (e.wheelX != 0) {
      scrollX = max(0, scrollX - cast(int)(e.wheelX * ui.px(40)));
    }

    ui.invalidate();

    return true;
  }
}
