module gui.dialog;

import std.algorithm : max, min;
import std.array : split;
import std.string : splitLines;

import gui.ui;

final class Dialog : Widget {
  string title;
  string message;
  string[] labels;
  LineEdit[] inputs;
  Button[] buttons;
  int cancelButton = -1;
  void delegate(int, string[]) onResult;
  void delegate() onClose;

  private Rect panel;
  private string[] wrapped;

  this(Ui ui) {
    super(ui);
  }

  void setup(string title, string message, string[] buttonLabels, string[] inputLabels = null,
    string[] values = null) {
    this.title = title;
    this.message = message;
    labels = inputLabels;
    inputs = null;
    foreach (i, l; inputLabels) {
      auto e = new LineEdit(ui);

      e.setText(i < values.length ? values[i] : "", true);
      e.onEnter = () { press(0); };
      e.onEscape = () { press(cancelButton); };
      inputs ~= e;
    }

    buttons = null;
    foreach (i, l; buttonLabels) {
      auto idx = cast(int)i;
      auto b = new Button(ui, l, () { press(idx); });

      b.primary = i == 0;
      buttons ~= b;
    }

    cancelButton = buttonLabels.length > 1 ? cast(int)buttonLabels.length - 1 : -1;
    visible = true;
    layout(Rect(0, 0, ui.canvas.width, ui.canvas.height));
    ui.setFocus(inputs.length ? cast(Widget)inputs[0] : this);
    ui.invalidate();
  }

  override bool focusable() { return true; }

  void press(int button) {
    if (!visible) {
      return;
    }

    visible = false;
    ui.invalidate();
    string[] values;

    foreach (e; inputs) {
      values ~= e.text;
    }

    if (onClose) {
      onClose();
    }

    if (onResult) {
      onResult(button, values);
    }
  }

  override void layout(Rect r) {
    rect = r;
    auto f = ui.fonts.ui;
    int w = min(r.w - ui.px(40), max(ui.px(420), f.measure(title) + ui.px(60)));

    if (inputs.length) {
      w = max(w, min(r.w - ui.px(40), ui.px(560)));
    }

    wrapped = wrap(message, w - ui.px(40));
    int h = ui.px(16) + f.lineHeight + ui.px(14);

    h += cast(int)wrapped.length * f.lineHeight + (wrapped.length ? ui.px(12) : 0);
    h += cast(int)inputs.length * (f.lineHeight + ui.rowHeight + ui.px(14));
    h += ui.rowHeight + ui.px(10) + ui.px(16);

    panel = Rect(r.x + (r.w - w) / 2, r.y + max(ui.px(20), (r.h - h) / 3), w, h);
    int messageH = cast(int)wrapped.length * f.lineHeight + (wrapped.length ? ui.px(12) : 0);
    int y = panel.y + ui.px(16) + f.lineHeight + ui.px(14) + messageH;

    foreach (e; inputs) {
      y += f.lineHeight + ui.px(4);
      e.layout(Rect(panel.x + ui.px(20), y, panel.w - ui.px(40), ui.rowHeight + ui.px(4)));
      y += ui.rowHeight + ui.px(10);
    }

    int bx = panel.right - ui.px(20);
    int by = panel.bottom - ui.px(16) - ui.rowHeight - ui.px(6);

    foreach_reverse (b; buttons) {
      int bw = b.preferredWidth();

      bx -= bw;
      b.layout(Rect(bx, by, bw, ui.rowHeight + ui.px(6)));
      bx -= ui.px(8);
    }
  }

  private string[] wrap(string text, int width) {
    auto f = ui.fonts.ui;
    string[] res;

    foreach (para; text.splitLines) {
      string line;

      foreach (word; para.split(' ')) {
        auto candidate = line.length ? line ~ " " ~ word : word;

        if (line.length && f.measure(candidate) > width) {
          res ~= line;
          line = word;
        } else {
          line = candidate;
        }
      }

      res ~= line;
    }

    return res;
  }

  override void draw(Canvas c) {
    auto t = ui.theme;
    auto f = ui.fonts.ui;

    c.blend(rect, 0x000000, t.dark ? 110 : 70);
    foreach (k; 1 .. 6) {
      c.blend(Rect(panel.x - k + 3, panel.y - k + 6, panel.w + 2 * k - 6, panel.h + 2 * k - 6), 0x000000, 12);
    }

    c.roundRect(panel, ui.px(6), t.window, t.border);

    int y = panel.y + ui.px(16);

    c.text(ui.fonts.bold, panel.x + ui.px(20), y, title, t.text);
    y += f.lineHeight + ui.px(14);
    foreach (l; wrapped) {
      c.text(f, panel.x + ui.px(20), y, l, t.text);
      y += f.lineHeight;
    }

    foreach (i, e; inputs) {
      c.text(f, e.rect.x, e.rect.y - f.lineHeight - ui.px(4), labels[i], t.dimText);
      e.draw(c);
    }

    foreach (b; buttons) {
      b.draw(c);
    }
  }

  Widget partAt(int x, int y) {
    foreach (e; inputs) {
      if (e.rect.contains(x, y)) {
        return e;
      }
    }

    foreach (b; buttons) {
      if (b.rect.contains(x, y)) {
        return b;
      }
    }

    return null;
  }

  override bool keyDown(ref const Event e) {
    switch (e.key) {
      case Key.escape:
        press(cancelButton);

        return true;
      case Key.enter:
        press(0);

        return true;
      case Key.tab:
        cycleFocus(e.shift ? -1 : 1);

        return true;
      case Key.left:
      case Key.right:
        return true;
      default:
        return true;
    }
  }

  bool inputKey(ref const Event e) {
    if (e.key == Key.tab) {
      cycleFocus(e.shift ? -1 : 1);

      return true;
    }

    return false;
  }

  private void cycleFocus(int dir) {
    if (!inputs.length) {
      return;
    }

    size_t at = 0;

    foreach (i, inp; inputs) {
      if (inp is ui.focus) {
        at = i;
      }
    }

    at = (at + dir + inputs.length) % inputs.length;
    ui.setFocus(inputs[at]);
  }
}
