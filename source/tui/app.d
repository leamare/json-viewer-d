module tui.app;

import core.time : MonoTime, msecs;
import std.algorithm : min, max;
import std.conv : to;
import std.format : format;
import std.path : baseName;
import std.string : splitLines, strip;
import std.uni : toLower;

import doc.document;
import doc.edit;
import formats;
import tui.clipboard;
import tui.screen;
import tui.term;
import view.actions;
import view.search;
import view.stats;
import view.tree;

int runTui(Document doc) {
  auto app = new TuiApp(doc);

  return app.run();
}

private enum detailsLimit = 256 * 1024;

private struct Prompt {
  bool active;
  string label;
  dchar[] text;
  size_t cursor;

  void delegate(string) onAccept;
}

private struct Choice {
  bool active;
  string label;

  void delegate(dchar) onKey;
}

private final class TuiApp {
  Terminal term;
  Screen screen;
  Document doc;
  TreeModel tree;

  bool running = true;
  bool showDetails = true;
  bool detailsFocus;
  bool showHelp;
  int detailsScroll;

  string[] detailsLines;
  ulong detailsRevision;
  uint detailsNode = noNode;
  bool detailsTruncated;

  string message;
  bool messageError;

  Query query;
  Prompt prompt;
  Choice choice;

  int treeX, treeY, treeW, treeH;
  int keyW;
  int detX, detY, detW, detH;

  MonoTime lastClick;
  size_t lastClickRow = noRow;

  this(Document doc) {
    term = new Terminal;
    screen = new Screen;
    setDocument(doc);
  }

  void setDocument(Document d) {
    doc = d;
    tree = new TreeModel(doc);
    detailsNode = noNode;
    if (doc.error.length) {
      error(doc.error);
    }
  }

  int run() {
    term.open();
    scope (exit) term.close();

    while (running) {
      draw();
      KeyEvent ev;

      if (!term.read(ev, 500)) {
        continue;
      }

      if (ev.key != Key.resize) {
        message = null;
      }

      handle(ev);
    }

    return 0;
  }

  void handle(ref KeyEvent ev) {
    if (ev.key == Key.resize) {
      screen.invalidate();

      return;
    }

    if (showHelp) {
      showHelp = false;

      return;
    }

    if (prompt.active) {
      return promptKey(ev);
    }

    if (choice.active) {
      if (ev.key == Key.character) {
        choice.active = false;
        choice.onKey(ev.ch);
      } else if (ev.key == Key.escape || ev.key == Key.enter) {
        choice.active = false;
      }

      return;
    }

    if (ev.key == Key.mouse) {
      return mouse(ev);
    }

    if (detailsFocus && detailsKey(ev)) {
      return;
    }

    treeKey(ev);
  }

  void treeKey(ref KeyEvent ev) {
    auto r = tree.cursor;

    switch (ev.key) {
      case Key.up: move(-1); break;
      case Key.down: move(1); break;
      case Key.pageUp: move(-max(1, treeH - 1)); break;
      case Key.pageDown: move(max(1, treeH - 1)); break;
      case Key.home: tree.cursor = 0; break;
      case Key.end: tree.cursor = tree.length - 1; break;
      case Key.right: goIn(); break;
      case Key.left: goOut(); break;
      case Key.enter: toggle(r); break;
      case Key.tab:
        if (showDetails) {
          detailsFocus = true;
        }

        break;
      case Key.f1: showHelp = true; break;
      case Key.f2: editValue(); break;
      case Key.f3: findNextMatch(ev.shift); break;
      case Key.del: askDelete(); break;
      case Key.f10: quit(); break;
      case Key.paste:
        break;
      case Key.character:
        if (ev.ctrl) {
          ctrlKey(ev.ch);
          break;
        }

        charKey(ev.ch);
        break;
      default:
        break;
    }
  }

  void ctrlKey(dchar c) {
    switch (c) {
      case 's': save(); break;
      case 'z': undo(); break;
      case 'y': redo(); break;
      case 'q': case 'c': quit(); break;
      case 'f': startSearch(); break;
      case 'o': askOpen(); break;
      default: break;
    }
  }

  void charKey(dchar c) {
    switch (c) {
      case 'k': move(-1); break;
      case 'j': move(1); break;
      case 'l': goIn(); break;
      case 'h': goOut(); break;
      case 'g': tree.cursor = 0; break;
      case 'G': tree.cursor = tree.length - 1; break;
      case ' ': toggle(tree.cursor); break;
      case '+': case '*': expandAll(); break;
      case '-': tree.collapseAll(tree.cursor); break;
      case 'e': editValue(); break;
      case 'E': editExternal(); break;
      case 'r': askRename(); break;
      case 'a': askAdd(); break;
      case 'd': askDelete(); break;
      case 'J': toggleEmbedded(); break;
      case 'B': askEmbeddedFormat(); break;
      case 'c': askCopy(); break;
      case 'y': copy(CopyKind.value); break;
      case '/': startSearch(); break;
      case 'n': findNextMatch(false); break;
      case 'N': findNextMatch(true); break;
      case 'u': undo(); break;
      case 'U': redo(); break;
      case 's': save(); break;
      case 'S': askSaveAs(); break;
      case 'x': askExport(); break;
      case 'o': askOpen(); break;
      case 'v': showDetails = !showDetails; detailsFocus = false; break;
      case 'i': showInfo(); break;
      case '?': showHelp = true; break;
      case 'q': quit(); break;
      default: break;
    }
  }

  bool detailsKey(ref KeyEvent ev) {
    int page = max(1, detH - 1);

    switch (ev.key) {
      case Key.up: detailsScroll--; break;
      case Key.down: detailsScroll++; break;
      case Key.pageUp: detailsScroll -= page; break;
      case Key.pageDown: detailsScroll += page; break;
      case Key.home: detailsScroll = 0; break;
      case Key.end: detailsScroll = cast(int)detailsLines.length; break;
      case Key.tab:
      case Key.escape:
        detailsFocus = false;
        break;
      case Key.character:
        if (ev.ch == 'k') {
          detailsScroll--;
        } else if (ev.ch == 'j') {
          detailsScroll++;
        } else {
          return false;
        }

        break;
      default:
        return false;
    }

    return true;
  }

  void mouse(ref KeyEvent ev) {
    bool inTree = ev.x >= treeX && ev.x < treeX + treeW && ev.y >= treeY && ev.y < treeY + treeH;
    bool inDetails = showDetails && ev.x >= detX && ev.x < detX + detW && ev.y >= detY && ev.y < detY + detH;

    if (ev.action == MouseAction.wheelUp || ev.action == MouseAction.wheelDown) {
      int delta = ev.action == MouseAction.wheelUp ? -3 : 3;

      if (inDetails) {
        detailsScroll += delta;
      } else {
        auto top = cast(long)tree.top + delta;

        tree.top = cast(size_t)max(0, min(top, cast(long)tree.length - 1));
        if (tree.cursor < tree.top) {
          tree.cursor = tree.top;
        }

        if (tree.cursor >= tree.top + treeH) {
          tree.cursor = tree.top + treeH - 1;
        }
      }

      return;
    }

    if (ev.action != MouseAction.press || ev.button != 0) {
      return;
    }

    if (inDetails) {
      detailsFocus = true;

      return;
    }

    if (!inTree) {
      return;
    }

    detailsFocus = false;
    auto r = tree.top + (ev.y - treeY);

    if (r >= tree.length) {
      return;
    }

    auto now = MonoTime.currTime;
    bool doubleClick = r == lastClickRow && now - lastClick < 400.msecs;

    lastClick = now;
    lastClickRow = r;

    int markerX = treeX + cast(int)tree.rows[r].depth * 2;

    tree.cursor = r;
    if (doubleClick || (ev.x >= markerX && ev.x < markerX + 2)) {
      toggle(r);
    }
  }

  void promptKey(ref KeyEvent ev) {
    with (prompt) switch (ev.key) {
      case Key.escape:
        active = false;
        break;
      case Key.enter:
        active = false;
        onAccept(text.to!string);
        break;
      case Key.left: if (cursor) cursor--; break;
      case Key.right: if (cursor < text.length) cursor++; break;
      case Key.home: cursor = 0; break;
      case Key.end: cursor = text.length; break;
      case Key.backspace:
        if (cursor) {
          text = text[0 .. cursor - 1] ~ text[cursor .. $];
          cursor--;
        }

        break;
      case Key.del:
        if (cursor < text.length) {
          text = text[0 .. cursor] ~ text[cursor + 1 .. $];
        }

        break;
      case Key.paste:
        auto t = ev.text.to!(dchar[]);

        text = text[0 .. cursor] ~ t ~ text[cursor .. $];
        cursor += t.length;
        break;
      case Key.character:
        if (ev.ctrl) {
          if (ev.ch == 'u') {
            text = text[cursor .. $];
            cursor = 0;
          } else if (ev.ch == 'a') {
            cursor = 0;
          } else if (ev.ch == 'e') {
            cursor = text.length;
          } else if (ev.ch == 'c') {
            active = false;
          }

          break;
        }

        text = text[0 .. cursor] ~ ev.ch ~ text[cursor .. $];
        cursor++;
        break;
      default:
        break;
    }
  }

  void toggle(size_t r) {
    auto err = tree.toggle(r);

    if (err.length) {
      error(err);
    }
  }

  void move(long delta) {
    if (!tree.length) {
      return;
    }

    auto c = cast(long)tree.cursor + delta;

    tree.cursor = cast(size_t)max(0, min(c, cast(long)tree.length - 1));
  }

  void goIn() {
    auto r = tree.cursor;

    if (!tree.canExpand(r)) {
      return;
    }

    if (!tree.isExpanded(r)) {
      toggle(r);
    } else {
      move(1);
    }
  }

  void goOut() {
    auto r = tree.cursor;

    if (tree.isExpanded(r)) {
      tree.collapse(r);

      return;
    }

    auto p = tree.parentRow(r);

    if (p != noRow) {
      tree.cursor = p;
    }
  }

  void expandAll() {
    auto n = tree.selected;
    auto size = doc[n].end - n;

    if (size > 2_000_000) {
      ask("This will show " ~ groupDigits(size) ~ " rows. Continue? (y/n)", (c) {
        if (c == 'y') {
          tree.expandAll(tree.cursor);
        }
      });

      return;
    }

    tree.expandAll(tree.cursor);
  }

  void editValue() {
    auto n = tree.selected;

    if (doc[n].isContainer) {
      editExternal();

      return;
    }

    auto current = doc.value(n);

    if (current.length > 64 * 1024 || current.splitLines.length > 1) {
      editExternal();

      return;
    }

    ask("Value: ", current, (text) {
      auto err = setValue(doc, n, text);

      afterEdit(n, err);
    });
  }

  void editExternal() {
    import std.file : tempDir, write, readText, remove, exists;
    import std.path : buildPath;
    import std.process : environment, spawnShell, wait, escapeShellFileName;
    import std.random : uniform;

    auto n = tree.selected;
    auto original = copyText(doc, n, CopyKind.json);
    auto path = buildPath(tempDir, "jsonview-" ~ uniform(100_000, 999_999).to!string ~ ".json");

    write(path, original);
    scope (exit) {
      if (path.exists) {
        remove(path);
      }
    }

    string fallback = "vi";

    version (Windows) {
      fallback = "notepad";
    }

    auto editor = environment.get("VISUAL", environment.get("EDITOR", fallback));

    term.suspend();
    int status;

    try {
      status = spawnShell(editor ~ " " ~ escapeShellFileName(path)).wait;
    } catch (Exception e) {
      status = -1;
    }

    term.resume();
    screen.invalidate();

    if (status != 0) {
      return error("Editor failed to run: " ~ editor);
    }

    auto edited = readText(path);

    if (edited.strip == original.strip) {
      return;
    }

    auto err = replaceWithJson(doc, n, edited);

    afterEdit(n, err);
  }

  void askRename() {
    auto n = tree.selected;

    if (!doc.hasKey(n)) {
      return error("Only object members have keys");
    }

    ask("Key: ", doc.key(n), (text) {
      afterEdit(n, renameKey(doc, n, text));
    });
  }

  void askAdd() {
    auto n = tree.selected;
    uint parent, before;

    if (doc[n].isContainer && (tree.isExpanded(tree.cursor) || doc[n].parent == noNode)) {
      parent = n;
      before = noNode;
    } else if (doc[n].parent != noNode) {
      parent = doc[n].parent;
      before = doc[n].end;
      if (before >= doc[parent].end) {
        before = noNode;
      }
    } else {
      return error("Can't add here");
    }

    void addValue(string key) {
      ask("Value (JSON): ", "", (text) {
        auto at = insertNode(doc, parent, before, key, text);

        afterEdit(at, null);
      });
    }

    if (doc[parent].type == NodeType.object) {
      ask("New key: ", "", (key) { addValue(key); });
    } else {
      addValue(null);
    }
  }

  void askDelete() {
    auto n = tree.selected;

    if (doc[n].parent == noNode) {
      return error("Root can't be deleted");
    }

    ask("Delete " ~ nodeLabel(doc, n, 40) ~ "? (y/n)", (c) {
      if (c != 'y') {
        return;
      }

      auto next = doc[n].parent;

      deleteNode(doc, n);
      afterEdit(n < doc.length && doc[n].parent == next ? n : next, null);
    });
  }

  void toggleEmbedded() {
    auto n = tree.selected;
    string err;

    if (doc[n].has(NodeFlags.embedded)) {
      err = collapseEmbedded(doc, n);
    } else {
      err = expandEmbedded(doc, n);
    }

    afterEdit(n, err);
    if (!err.length && doc[n].isContainer) {
      tree.expand(tree.cursor);
    }
  }

  void askEmbeddedFormat() {
    auto n = tree.selected;
    bool embedded = doc[n].has(NodeFlags.embedded);

    if (!embedded && doc[n].type != NodeType.string) {
      return error("Only strings can hold documents");
    }

    auto label = embedded
      ? "Store embedded document as: (j)son (k)v (3) kv3"
      : "Parse string as: (j)son (k)v (3) kv3";

    ask(label, (c) {
      Format f;

      switch (c) {
        case 'j': f = Format.json; break;
        case 'k': f = Format.kv; break;
        case '3': f = Format.kv3; break;
        default: return;
      }

      auto err = embedded ? setEmbeddedFormat(doc, n, f) : expandEmbedded(doc, n, f);

      afterEdit(n, err);
      if (!err.length && !embedded) {
        tree.expand(tree.cursor);
      }
    });
  }

  void afterEdit(uint focus, string err) {
    if (err.length) {
      return error(err);
    }

    tree.refresh(focus);
    detailsNode = noNode;
  }

  void undo() {
    if (!doc.canUndo) {
      return info("Nothing to undo");
    }

    afterEdit(doc.undo(), null);
  }

  void redo() {
    if (!doc.canRedo) {
      return info("Nothing to redo");
    }

    afterEdit(doc.redo(), null);
  }

  void askCopy() {
    ask("Copy: (v)alue (k)ey (p)ath (j)son (m)inified json (K)V (3) KV3", (c) {
      switch (c) {
        case 'v': copy(CopyKind.value); break;
        case 'k': copy(CopyKind.key); break;
        case 'p': copy(CopyKind.path); break;
        case 'j': copy(CopyKind.json); break;
        case 'm': copy(CopyKind.jsonCompact); break;
        case 'K': copy(CopyKind.kv); break;
        case '3': copy(CopyKind.kv3); break;
        default: break;
      }
    });
  }

  void copy(CopyKind kind) {
    auto text = copyText(doc, tree.selected, kind);

    if (copyToClipboard(term, text)) {
      info("Copied " ~ formatSize(text.length));
    } else {
      error("No clipboard available");
    }
  }

  void startSearch() {
    ask("Find: ", query.text, (text) {
      query.text = text;
      findNextMatch(false);
    });
  }

  void findNextMatch(bool backwards) {
    if (!query.text.length) {
      return startSearch();
    }

    auto found = findNext(doc, tree.selected, query, backwards);

    if (found == noNode) {
      return error("Not found: " ~ query.text);
    }

    tree.reveal(found);
  }

  void save() {
    if (!doc.path.length) {
      return askSaveAs();
    }

    auto err = saveAs(doc, doc.path, doc.format);

    if (err.length) {
      return error(err);
    }

    info("Saved " ~ doc.path.baseName);
  }

  void askSaveAs() {
    ask("Save as: ", doc.path, (path) {
      if (!path.length) {
        return;
      }

      auto err = saveAs(doc, path);

      if (err.length) {
        return error(err);
      }

      info("Saved " ~ path.baseName ~ " as " ~ formatName(doc.format));
    });
  }

  void askExport() {
    ask("Save as format: (j)son json(l)ines (k)v (3) kv3", (c) {
      Format f;

      switch (c) {
        case 'j': f = Format.json; break;
        case 'l': f = Format.jsonl; break;
        case 'k': f = Format.kv; break;
        case '3': f = Format.kv3; break;
        default: return;
      }

      ask("Save " ~ formatName(f) ~ " as: ", suggestName(doc, f), (path) {
        if (!path.length) {
          return;
        }

        auto err = saveAs(doc, path, f);

        if (err.length) {
          return error(err);
        }

        info("Saved " ~ path.baseName ~ " as " ~ formatName(f));
      });
    });
  }

  void askOpen() {
    void open() {
      ask("Open: ", "", (path) {
        if (!path.length) {
          return;
        }

        try {
          setDocument(openDocument(path));
          if (!doc.error.length) {
            info("Opened " ~ path.baseName);
          }
        } catch (Exception e) {
          error(e.msg);
        }
      });
    }

    if (doc.modified) {
      ask("Discard unsaved changes? (y/n)", (c) { if (c == 'y') open(); });
    } else {
      open();
    }
  }

  void showInfo() {
    auto s = collectStats(doc);

    info(format("%s, %s nodes: %s objects, %s arrays, %s values, depth %s, parsed in %.3f s",
      formatSize(s.fileSize), groupDigits(s.nodes), groupDigits(s.objects), groupDigits(s.arrays),
      groupDigits(s.values), s.maxDepth, doc.parseTime));
  }

  void quit() {
    if (!doc.modified) {
      running = false;

      return;
    }

    ask("Save changes before closing? (y)es (n)o (c)ancel", (c) {
      if (c == 'y') {
        save();
        if (!doc.modified) {
          running = false;
        }
      } else if (c == 'n') {
        running = false;
      }
    });
  }

  void ask(string label, string initial, void delegate(string) onAccept) {
    prompt.active = true;
    prompt.label = label;
    prompt.text = initial.to!(dchar[]);
    prompt.cursor = prompt.text.length;
    prompt.onAccept = onAccept;
  }

  void ask(string label, void delegate(dchar) onKey) {
    choice.active = true;
    choice.label = label;
    choice.onKey = onKey;
  }

  void info(string msg) {
    message = msg;
    messageError = false;
  }

  void error(string msg) {
    message = msg;
    messageError = true;
  }

  static immutable Style titleStyle = Style(Color.none, Color.none, Attr.reverse | Attr.bold);
  static immutable Style dimStyle = Style(Color.none, Color.none, Attr.dim);
  static immutable Style keyStyle = Style(Color.none, Color.none, Attr.bold);
  static immutable Style indexStyle = Style(Color.none, Color.none, Attr.dim);

  static Style valueStyle(NodeType t) {
    final switch (t) {
      case NodeType.string: return Style(Color.green);
      case NodeType.number: return Style(Color.cyan);
      case NodeType.boolean: return Style(Color.yellow);
      case NodeType.null_: return Style(Color.magenta, Color.none, Attr.dim);
      case NodeType.object:
      case NodeType.array: return Style(Color.none, Color.none, Attr.dim);
    }
  }

  void draw() {
    screen.resize(term.width, term.height);
    screen.clear();
    int w = screen.width, h = screen.height;

    if (w < 20 || h < 6) {
      screen.put(0, 0, "Terminal is too small", Style.init);
      screen.render(term);

      return;
    }

    screen.fill(0, 0, w, ' ', titleStyle);
    auto title = " " ~ (doc.path.length ? doc.path.baseName : "untitled") ~ (doc.modified ? " *" : "") ~
      "  " ~ describeFormat(doc) ~ "  " ~ groupDigits(doc.length) ~ " nodes ";
    screen.put(0, 0, title, titleStyle, w);
    screen.put(w - 9, 0, "F1 Help ", titleStyle, w);

    int bodyY = 1, bodyH = h - 3;

    treeX = 0;
    treeY = bodyY;
    treeW = w;
    treeH = bodyH;
    if (showDetails) {
      if (w >= 100) {
        detW = w * 45 / 100;
        detX = w - detW;
        detY = bodyY;
        detH = bodyH;
        treeW = detX - 1;
        foreach (y; bodyY .. bodyY + bodyH) {
          screen.put(detX - 1, y, "│", dimStyle);
        }
      } else {
        detH = bodyH * 40 / 100;
        treeH = bodyH - detH - 1;
        detX = 0;
        detW = w;
        detY = bodyY + treeH + 1;
        screen.fill(0, detY - 1, w, '─', dimStyle);
      }
    }

    drawTree();
    if (showDetails) {
      drawDetails();
    }

    auto sel = tree.selected;
    auto status = sel == noNode ? "" : tree.selectedPath;

    auto kind = sel == noNode ? "" : describeNode(doc, sel) ~ "  " ~ (tree.cursor + 1).to!string ~
      "/" ~ tree.length.to!string ~ " ";

    screen.fill(0, h - 2, w, ' ', titleStyle);
    screen.put(1, h - 2, status, titleStyle, w - textWidth(kind) - 2);
    screen.put(w - textWidth(kind), h - 2, kind, titleStyle);

    drawFooter(h - 1, w);
    if (showHelp) {
      drawHelp();
    }

    screen.render(term);
  }

  void drawTree() {
    if (tree.cursor < tree.top) {
      tree.top = tree.cursor;
    }

    if (tree.cursor >= tree.top + treeH) {
      tree.top = tree.cursor - treeH + 1;
    }

    keyW = max(12, treeW * 45 / 100);
    bool focused = !detailsFocus;

    foreach (k; 0 .. treeH) {
      auto r = tree.top + k;

      if (r >= tree.length) {
        break;
      }

      int y = treeY + k;
      auto row = tree.rows[r];
      auto n = row.node;
      auto node = &doc.nodes[n];

      int x = treeX + cast(int)min(row.depth * 2, keyW - 6);
      string marker = node.isContainer && node.len ? (tree.isExpanded(r) ? "▾ " : "▸ ") : "  ";

      x = screen.put(x, y, marker, dimStyle, treeX + keyW);

      bool isIndex = !doc.hasKey(n) && node.parent != noNode;
      auto label = nodeLabel(doc, n, 200, row.index);

      x = screen.put(x, y, label, isIndex ? indexStyle : keyStyle, treeX + keyW - 1);
      if (node.has(NodeFlags.embedded)) {
        screen.put(x + 1, y, "\u2039" ~ embeddedFormatName(*node).toLower ~ "\u203A",
          Style(Color.blue), treeX + keyW - 1);
      }

      screen.put(treeX + keyW, y, "│", dimStyle);
      auto preview = valuePreview(doc, n, cast(size_t)treeW * 4);
      auto vs = valueStyle(node.type);
      int vx = screen.put(treeX + keyW + 2, y, preview, vs, treeX + treeW);

      if (tree.holdsDocument(n) && vx + 7 < treeX + treeW) {
        screen.put(vx + 1, y, "‹json›", Style(Color.blue, Color.none, Attr.dim), treeX + treeW);
      }

      if (r == tree.cursor) {
        screen.addAttr(treeX, y, treeW, focused ? Attr.reverse : Attr.underline);
      }
    }
  }

  void drawDetails() {
    auto sel = tree.selected;

    if (sel != detailsNode || doc.revision != detailsRevision) {
      detailsRevision = doc.revision;
      detailsNode = sel;
      detailsScroll = 0;
      if (sel == noNode) {
        detailsLines = null;
      } else {
        auto opt = defaultOptions(doc, Format.json);

        opt.indent = 2;
        opt.embeddedRoot = true;
        opt.readable = true;
        auto text = nodeToText(doc, sel, Format.json, opt, detailsLimit, &detailsTruncated);

        detailsLines = text.splitLines;
        if (detailsTruncated) {
          detailsLines ~= "… (truncated, " ~ formatSize(detailsLimit) ~ " shown)";
        }
      }
    }

    detailsScroll = max(0, min(detailsScroll, cast(int)detailsLines.length - detH));
    foreach (k; 0 .. detH) {
      auto li = detailsScroll + k;

      if (li >= detailsLines.length) {
        break;
      }

      drawJsonLine(detX + 1, detY + k, detailsLines[li], detX + detW);
    }

    if (detailsFocus) {
      screen.put(detX + detW - 3, detY, "●", Style(Color.blue));
    }
  }

  void drawJsonLine(int x, int y, string line, int maxX) {
    size_t i = 0;

    while (i < line.length && x < maxX) {
      char c = line[i];
      size_t start = i;
      Style st;

      if (c == '"') {
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

        st = j < line.length && line[j] == ':'
          ? Style(Color.blue, Color.none, Attr.bold)
          : Style(Color.green);
      } else if (c == '-' || (c >= '0' && c <= '9')) {
        while (i < line.length && line[i] != ',' && line[i] != ' ' && line[i] != ']' && line[i] != '}') {
          i++;
        }

        st = Style(Color.cyan);
      } else if (c == 't' || c == 'f' || c == 'n') {
        while (i < line.length && line[i] >= 'a' && line[i] <= 'z') {
          i++;
        }

        st = c == 'n' ? Style(Color.magenta) : Style(Color.yellow);
      } else {
        i++;
        st = dimStyle;
      }

      if (i == start) {
        i++;
      }

      x = screen.put(x, y, line[start .. i], st, maxX);
    }
  }

  void drawFooter(int y, int w) {
    if (prompt.active) {
      auto label = prompt.label;
      int x = screen.put(0, y, label, keyStyle);
      int room = w - x - 1;
      auto before = prompt.text[0 .. prompt.cursor].to!string;
      auto after = prompt.text[prompt.cursor .. $].to!string;
      while (textWidth(before) > room && before.length) {
        import std.utf : stride;
        before = before[stride(before, 0) .. $];
      }

      int cx = screen.put(x, y, before, Style.init);

      screen.put(cx, y, after, Style.init, w);
      screen.cursorX = cx;
      screen.cursorY = y;

      return;
    }

    if (choice.active) {
      screen.put(0, y, choice.label, keyStyle, w);

      return;
    }

    if (message.length) {
      screen.put(0, y, message,
        messageError ? Style(Color.red, Color.none, Attr.bold) : Style(Color.green), w);

      return;
    }

    static immutable hints = [
      ["⏎", "Toggle"], ["e", "Edit"], ["r", "Rename"], ["a", "Add"], ["d", "Delete"], ["J", "Parse string"],
      ["c", "Copy"], ["/", "Find"], ["u", "Undo"], ["s", "Save"], ["x", "Export"], ["q", "Quit"],
    ];
    int x = 0;

    foreach (hint; hints) {
      if (x + textWidth(hint[0]) + textWidth(hint[1]) + 3 > w) {
        break;
      }

      x = screen.put(x, y, hint[0], keyStyle);
      x = screen.put(x + 1, y, hint[1], dimStyle) + 2;
    }
  }

  void drawHelp() {
    static immutable lines = [
      "Navigation",
      "  ↑ ↓ j k        move            PgUp PgDn    page",
      "  → l / ← h      expand / collapse, go to child / parent",
      "  Enter Space    toggle          + -          expand / collapse all below",
      "  Home End g G   first / last    Tab          focus details pane",
      "  v              show or hide details pane",
      "",
      "Editing",
      "  e F2           edit value (containers and long text open $EDITOR)",
      "  E              edit selected element as JSON in $EDITOR",
      "  r              rename key      a            add element",
      "  d Del          delete          J            parse document in a string / back to string",
      "  B              parse string as JSON, KV or KV3, or change the format of embedded one",
      "  u Ctrl+Z       undo            U Ctrl+Y     redo",
      "",
      "Search and copy",
      "  / Ctrl+F       find            n N F3       next / previous match",
      "  c              copy menu       y            copy value",
      "",
      "Files",
      "  s Ctrl+S       save            S            save as (format from extension)",
      "  x              save in another format (JSON, JSON Lines, KV, KV3)",
      "  o Ctrl+O       open file       i            file statistics",
      "  q Ctrl+Q F10   quit",
      "",
      "Press any key to close",
    ];
    int w = 0;

    foreach (l; lines) {
      w = max(w, textWidth(l));
    }

    w += 4;
    int h = cast(int)lines.length + 2;
    int x0 = max(0, (screen.width - w) / 2);
    int y0 = max(0, (screen.height - h) / 2);

    foreach (y; y0 .. y0 + h) {
      screen.fill(x0, y, w, ' ', Style.init);
    }

    screen.fill(x0, y0, w, '─', dimStyle);
    screen.fill(x0, y0 + h - 1, w, '─', dimStyle);
    screen.put(x0 + 2, y0, " Keys ", keyStyle);
    foreach (k, l; lines) {
      bool header = l.length && l[0] != ' ';

      screen.put(x0 + 2, y0 + 1 + cast(int)k, l, header ? keyStyle : Style.init, x0 + w);
    }
  }
}
