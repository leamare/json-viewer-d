module gui.app;

import core.thread : Thread;
import core.atomic : atomicLoad, atomicStore;
import std.algorithm : min, max;
import std.conv : to;
import std.format : format;
import std.path : baseName, dirName;
import std.string : strip;

import doc.document;
import doc.edit;
import formats;
import gui.dialog;
import gui.menu;
import gui.sourceview;
import gui.tableview;
import gui.textedit;
import gui.treegrid;
import gui.ui;
import platform.dialogs;
import view.actions;
import view.search;
import view.stats;
import view.tree;

int runGui(Document[] docs) {
  GuiApp app;

  try {
    app = new GuiApp();
  } catch (Exception e) {
    import std.stdio : stderr;
    stderr.writeln(e.msg);

    return 1;
  }

  foreach (d; docs) {
    app.addTab(d);
  }

  return app.run();
}

private enum detailsLimit = 4 << 20;

private final class DocTab {
  Document doc;
  TreeModel tree;
  bool sourceMode;
  size_t sourceFormat;
  string generated;
  ulong generatedRevision = ulong.max;
  size_t generatedFormat;
  bool saveCompact;
  ulong shownRevision;
  Stats stats;
  Hashes hashes;
  Thread hashThread;
  shared bool hashCancel;
  bool hashesReady;

  this(Document d) {
    doc = d;
    tree = new TreeModel(d);
    stats = collectStats(d);
  }

  string title() {
    auto name = doc.path.length ? doc.path.baseName : "untitled";

    return doc.modified ? name ~ " *" : name;
  }

  void startHashing() {
    if (hashThread !is null) {
      return;
    }

    auto text = doc.sourceText;

    hashThread = new Thread(() {
      hashes = hashText(text, () => atomicLoad(hashCancel));
    });
    hashThread.isDaemon = true;
    hashThread.start();
  }

  bool pollHashes() {
    if (hashesReady || hashThread is null || hashThread.isRunning) {
      return false;
    }

    hashThread.join();
    hashesReady = true;

    return true;
  }

  void stopHashing() {
    if (hashThread is null) {
      return;
    }

    atomicStore(hashCancel, true);
    hashThread.join();
  }
}

private struct SourceFormat {
  string label;
  Format format;
  bool compact;
}

private immutable SourceFormat[] sourceFormats = [
  SourceFormat("Original", Format.unknown),
  SourceFormat("JSON", Format.json),
  SourceFormat("Minified", Format.json, true),
  SourceFormat("JSON Lines", Format.jsonl),
  SourceFormat("KeyValues", Format.kv),
  SourceFormat("KeyValues3", Format.kv3),
];

private struct Message {
  string label;
  string value;
  int icon;
}

final class GuiApp {
  private Window window;
  private Ui ui;
  private DocTab[] tabs;
  private size_t current;
  private bool running = true;

  private MenuBar menuBar;
  private PopupMenu popup;
  private TreeGrid grid;
  private TextEdit details;
  private SourceView source;
  private TableView table;
  private LineEdit search;
  private Dialog dialog;
  private Button applyButton, revertButton, embedButton, useFormatButton;

  private Rect tabsRect, contentRect, statusRect;
  private Rect structHeader, detailsHeader, detailsStatus;
  private Rect messagesHeader, messagesRect;
  private Rect splitRect, messagesSplitRect;
  private Rect[] tabRects, tabCloseRects;
  private Rect treeToggle, sourceToggle;
  private Rect sourceBar;
  private Rect tableToggle, textToggle;
  private Rect[] sourceFormatRects;
  private float mainSplit = 0.42;
  private int messagesLines = 7;
  private bool showMessages = true;
  private int dragging;

  private Widget hover;
  private Widget overlay;
  private string statusText = "Ready";
  private bool statusError;
  private Query query;

  private uint detailsNode = noNode;
  private bool detailsDirty;
  private bool detailsTruncated;
  private bool detailsAsText;
  private bool detailsTable = true;
  private bool showingTable;

  private FileDialog pendingDialog;

  private void delegate(string) pendingDialogDone;

  private bool detectTypes;
  private bool indentTabs;

  this() {
    window = createWindow("JSON Viewer", 1100, 760);
    ui = new Ui(window);
    window.setIcon(makeIcon(64), 64);
    window.setLiveResize((w, h) { relayout(); draw(); });

    popup = new PopupMenu(ui);
    popup.visible = false;
    menuBar = new MenuBar(ui, popup);
    menuBar.onOpen = (p) { overlay = p; };
    buildMenus();

    grid = new TreeGrid(ui);
    grid.onSelect = () { selectionChanged(); };
    grid.onContextMenu = (x, y) { contextMenu(x, y); };
    grid.onEdit = (node, text, key) { inlineEdit(node, text, key); };
    grid.onActivate = () { ui.setFocus(details); };
    grid.onError = (err) { setStatus(err, true); };

    details = new TextEdit(ui);
    details.onChange = () { detailsDirty = true; updateDetailsButtons(); };
    details.onSubmit = () { applyDetails(); };

    source = new SourceView(ui);
    table = new TableView(ui);
    table.onOpen = (n) {
      grid.reveal(n);
      ui.setFocus(grid);
    };

    search = new LineEdit(ui);
    search.placeholder = "Find in keys and values (Ctrl+F)";
    search.onEnter = () { query.text = search.text; findNextMatch(false); };
    search.onEscape = () { ui.setFocus(grid); };

    applyButton = new Button(ui, "Apply", () { applyDetails(); });
    applyButton.primary = true;
    revertButton = new Button(ui, "Revert", () { revertDetails(); });
    embedButton = new Button(ui, "Parse", () { toggleEmbedded(); });
    useFormatButton = new Button(ui, "Use for saving", () { useSourceFormat(); });

    dialog = new Dialog(ui);
    dialog.visible = false;
    dialog.onClose = () { overlay = null; };

    ui.setFocus(grid);
    updateDetailsButtons();
  }

  void addTab(Document d) {
    auto tab = new DocTab(d);

    tabs ~= tab;
    switchTo(tabs.length - 1);
    tab.startHashing();
    if (d.error.length) {
      setStatus(d.error, true);
      showError("Parse error",
        d.error ~ "\n\nEverything before the error is shown. Source view (Ctrl+U) shows the place.");
    } else {
      setStatus(format("Loaded %s nodes in %.3f s", groupDigits(d.length), d.parseTime));
    }
  }

  private DocTab tab() { return tabs.length ? tabs[current] : null; }
  private Document doc() { return tabs.length ? tabs[current].doc : null; }

  private void switchTo(size_t i) {
    if (i >= tabs.length) {
      return;
    }

    grid.cancelEdit();
    current = i;
    grid.setModel(tabs[i].tree);
    updateSource();
    detailsNode = noNode;
    detailsDirty = false;
    updateTitle();
    relayout();
    selectionChanged();
  }

  private void openPath(string path) {
    foreach (i, t; tabs) {
      if (t.doc.path == path) {
        switchTo(i);

        return;
      }
    }

    try {
      addTab(openDocument(path));
    } catch (Exception e) {
      showError("Can't open file", e.msg);
    }
  }

  private void closeTab(size_t i, void delegate() then = null) {
    if (i >= tabs.length) {
      return;
    }

    void doClose() {
      tabs[i].stopHashing();
      tabs = tabs[0 .. i] ~ tabs[i + 1 .. $];
      if (!tabs.length) {
        grid.setModel(null);
        source.setText(null);
        details.setText("");
        detailsNode = noNode;
        current = 0;
        updateTitle();
      } else {
        switchTo(min(i, tabs.length - 1));
      }

      ui.invalidate();
      if (then) {
        then();
      }
    }
    if (!tabs[i].doc.modified) {
      return doClose();
    }

    switchTo(i);
    auto name = tabs[i].doc.path.length ? tabs[i].doc.path.baseName : "Untitled document";

    ask("Unsaved changes", name ~ " has unsaved changes. Save them?",
      ["Save", "Discard", "Cancel"], (b, _) {
      if (b == 0) {
        save(() { doClose(); });
      } else if (b == 1) {
        doClose();
      }
    });
  }

  private void updateTitle() {
    auto t = tab();

    window.setTitle(t is null ? "JSON Viewer" : t.title ~ " — JSON Viewer");
  }

  int run() {
    relayout();
    while (running) {
      int timeout = -1;

      if (pendingDialog !is null || hashing()) {
        timeout = 100;
      } else if (cast(TextEdit)ui.focus || cast(LineEdit)ui.focus) {
        timeout = 530;
      }

      Event e;

      if (window.nextEvent(e, timeout)) {
        handle(e);
        while (running && window.nextEvent(e, 0)) {
          handle(e);
        }
      } else {
        idle();
      }

      if (ui.dirty && running) {
        draw();
      }
    }

    foreach (t; tabs) {
      t.stopHashing();
    }

    window.close();

    return 0;
  }

  private bool hashing() {
    foreach (t; tabs) {
      if (!t.hashesReady && t.hashThread !is null) {
        return true;
      }
    }

    return false;
  }

  private void idle() {
    if (cast(TextEdit)ui.focus || cast(LineEdit)ui.focus) {
      ui.caretOn = !ui.caretOn;
      ui.invalidate();
    }

    foreach (t; tabs) {
      if (t.pollHashes()) {
        ui.invalidate();
      }
    }

    if (pendingDialog !is null && pendingDialog.done) {
      auto d = pendingDialog;
      auto done = pendingDialogDone;

      pendingDialog = null;
      if (d.result.length) {
        done(d.result);
      }
    }
  }

  private void draw() {
    syncWithDocument();
    ui.dirty = false;
    auto c = ui.canvas;

    c.resize(window.width, window.height);
    auto t = ui.theme;

    c.fill(Rect(0, 0, c.width, c.height), t.window);

    menuBar.draw(c);
    drawTabs(c);

    if (!tabs.length) {
      drawWelcome(c);
    } else if (tab().sourceMode) {
      drawSourceBar(c);
      source.draw(c);
    } else {
      drawStructure(c);
      drawDetails(c);
    }

    drawMessages(c);
    drawStatus(c);

    if (overlay !is null && overlay.visible) {
      overlay.draw(c);
    }

    window.present(c.pixels, c.width, c.height);
  }

  private void relayout() {
    int w = window.width, h = window.height;

    ui.canvas.resize(w, h);
    int row = ui.rowHeight;

    int y = 0;

    menuBar.layout(Rect(0, 0, w, menuBar.preferredHeight));
    y = menuBar.rect.bottom;
    tabsRect = Rect(0, y, w, row + ui.px(8));
    y = tabsRect.bottom;

    statusRect = Rect(0, h - row - ui.px(4), w, row + ui.px(4));
    int msgH = showMessages ? messagesLines * ui.fonts.ui.lineHeight + ui.px(12) : 0;

    messagesHeader = Rect(0, statusRect.y - msgH - row - ui.px(2), w, row + ui.px(2));
    messagesRect = Rect(0, messagesHeader.bottom, w, msgH);
    messagesSplitRect = Rect(0, messagesHeader.y - ui.px(3), w, ui.px(6));
    contentRect = Rect(0, y, w, messagesHeader.y - y);

    auto cr = contentRect.shrink(ui.px(4), ui.px(4));
    int leftW = cast(int)(cr.w * mainSplit);

    splitRect = Rect(cr.x + leftW, cr.y, ui.px(6), cr.h);

    structHeader = Rect(cr.x, cr.y, leftW, row + ui.px(4));
    int searchH = row + ui.px(10);

    grid.layout(Rect(cr.x, structHeader.bottom, leftW, cr.h - structHeader.h - searchH));
    search.layout(Rect(cr.x + ui.px(4), grid.rect.bottom + ui.px(4), leftW - ui.px(8), searchH - ui.px(6)));

    int rx = splitRect.right;

    detailsHeader = Rect(rx, cr.y, cr.right - rx, row + ui.px(4));
    detailsStatus = Rect(rx, cr.bottom - row, cr.right - rx, row);
    details.layout(Rect(rx, detailsHeader.bottom, detailsHeader.w, detailsStatus.y - detailsHeader.bottom));
    table.layout(details.rect);

    int bh = row;
    int bx = detailsHeader.right - ui.px(4);
    auto f = ui.fonts.ui;
    int textW = f.measure("Text") + ui.px(20), tableW = f.measure("Table") + ui.px(20);

    textToggle = Rect(bx - textW, detailsHeader.y + (detailsHeader.h - bh) / 2, textW, bh);
    tableToggle = Rect(textToggle.x - tableW, textToggle.y, tableW, bh);
    bx = tableToggle.x - ui.px(10);

    foreach (b; [revertButton, applyButton]) {
      int bw = b.preferredWidth() - ui.px(20);

      bx -= bw;
      b.layout(Rect(bx, detailsHeader.y + (detailsHeader.h - bh) / 2, bw, bh));
      bx -= ui.px(6);
    }

    int ew = embedButton.preferredWidth() - ui.px(10);

    embedButton.layout(Rect(bx - ew, detailsHeader.y + (detailsHeader.h - bh) / 2, ew, bh));

    sourceBar = Rect(cr.x, cr.y, cr.w, row + ui.px(10));
    source.layout(Rect(cr.x, sourceBar.bottom, cr.w, cr.h - sourceBar.h));
    int uw = useFormatButton.preferredWidth();

    auto useRect = Rect(sourceBar.right - uw - ui.px(6), sourceBar.y + ui.px(4), uw, sourceBar.h - ui.px(8));

    useFormatButton.layout(useRect);
    if (dialog.visible) {
      dialog.layout(Rect(0, 0, w, h));
    }

    ui.invalidate();
  }

  private void panelHeader(Canvas c, Rect r, string title) {
    auto t = ui.theme;

    c.fill(r, t.header);
    c.text(ui.fonts.bold, r.x + ui.px(10), r.y + (r.h - ui.fonts.bold.lineHeight) / 2, title, t.headerText);
  }

  private void drawTabs(Canvas c) {
    auto t = ui.theme;
    auto f = ui.fonts.ui;

    c.fill(tabsRect, t.window);
    c.hline(0, tabsRect.w, tabsRect.bottom - 1, t.border);
    tabRects.length = 0;
    tabCloseRects.length = 0;

    int sw = f.measure("Source") + ui.px(24), tw = f.measure("Tree") + ui.px(24);
    int th = tabsRect.h - ui.px(10);

    sourceToggle = Rect(tabsRect.right - ui.px(8) - sw, tabsRect.y + ui.px(5), sw, th);
    treeToggle = Rect(sourceToggle.x - tw, sourceToggle.y, tw, th);
    if (tabs.length) {
      bool src = tab().sourceMode;
      auto whole = Rect(treeToggle.x, treeToggle.y, tw + sw, th);

      c.roundRect(whole, ui.px(4), t.button, t.border);
      auto active = src ? sourceToggle : treeToggle;

      c.roundRect(active.shrink(ui.px(2)), ui.px(3), t.selection);
      c.text(f, treeToggle.x + ui.px(12), treeToggle.y + (th - f.lineHeight) / 2, "Tree",
        src ? t.text : t.selectionText);
      c.text(f, sourceToggle.x + ui.px(12), sourceToggle.y + (th - f.lineHeight) / 2, "Source",
        src ? t.selectionText : t.text);
    }

    int x = ui.px(6);
    int limit = treeToggle.x - ui.px(10);

    foreach (i, tb; tabs) {
      auto title = tb.title;
      int w = min(ui.px(260), f.measure(title) + ui.px(44));

      if (x + w > limit) {
        break;
      }

      auto r = Rect(x, tabsRect.y + ui.px(4), w, tabsRect.h - ui.px(4));
      bool active = i == current;

      if (active) {
        c.roundRect(Rect(r.x, r.y, r.w, r.h + ui.px(4)), ui.px(4), t.view, t.border);
        c.fill(Rect(r.x + 1, r.bottom - 1, r.w - 2, ui.px(4)), t.view);
        c.fill(Rect(r.x + ui.px(6), r.y + 1, r.w - ui.px(12), ui.px(2)), t.accent);
      }

      c.textFit(f, r.x + ui.px(10), r.y + (r.h - f.lineHeight) / 2, title,
        active ? t.text : t.dimText, w - ui.px(36));
      auto close = Rect(r.right - ui.px(22), r.y + (r.h - ui.px(16)) / 2, ui.px(16), ui.px(16));
      float cx = close.x + close.w / 2.0f, cy = close.y + close.h / 2.0f, d = ui.px(3.5);
      auto xc = active ? t.text : t.dimText;

      c.line(cx - d, cy - d, cx + d, cy + d, ui.px(1.2), xc);
      c.line(cx - d, cy + d, cx + d, cy - d, ui.px(1.2), xc);
      tabRects ~= r;
      tabCloseRects ~= close;
      x += w + ui.px(2);
    }
  }

  private void drawSourceBar(Canvas c) {
    auto t = ui.theme;
    auto f = ui.fonts.ui;
    auto tb = tab();

    c.fill(sourceBar, t.window);
    int x = sourceBar.x + ui.px(6);
    int h = sourceBar.h - ui.px(8);

    sourceFormatRects.length = 0;
    auto whole = Rect(x, sourceBar.y + ui.px(4), 0, h);

    foreach (k, sf; sourceFormats) {
      int w = f.measure(sf.label) + ui.px(22);

      sourceFormatRects ~= Rect(x, whole.y, w, h);
      x += w;
    }

    whole.w = x - whole.x;
    c.roundRect(whole, ui.px(4), t.button, t.border);
    foreach (k, r; sourceFormatRects) {
      bool active = k == tb.sourceFormat;

      if (active) {
        c.roundRect(r.shrink(ui.px(2)), ui.px(3), t.selection);
      }

      c.text(f, r.x + ui.px(11), r.y + (h - f.lineHeight) / 2, sourceFormats[k].label,
        active ? t.selectionText : t.text);
    }

    string note = tb.sourceFormat ? "Generated from the tree, edits included" : "File as it was loaded";
    auto sf = sourceFormats[tb.sourceFormat];
    bool usable = tb.sourceFormat && (sf.format != tb.doc.format || sf.compact != tb.saveCompact);

    useFormatButton.visible = usable;
    int noteRight = usable ? useFormatButton.rect.x - ui.px(10) : sourceBar.right - ui.px(10);

    c.textFit(f, x + ui.px(14), sourceBar.y + (sourceBar.h - f.lineHeight) / 2, note, t.dimText,
      noteRight - x - ui.px(14));
    if (usable) {
      useFormatButton.draw(c);
    }
  }

  private void updateSource() {
    auto tb = tab();

    if (tb is null) {
      return;
    }

    if (!tb.sourceFormat) {
      source.setText(tb.doc.sourceText);

      return;
    }

    if (tb.generatedRevision != tb.doc.revision || tb.generatedFormat != tb.sourceFormat) {
      auto sf = sourceFormats[tb.sourceFormat];
      auto opt = defaultOptions(tb.doc, sf.format);

      opt.compact = sf.compact;
      opt.tabs = opt.tabs || indentTabs;
      tb.generated = nodeToText(tb.doc, 0, sf.format, opt);
      tb.generatedRevision = tb.doc.revision;
      tb.generatedFormat = tb.sourceFormat;
    }

    source.setText(tb.generated);
  }

  private void useSourceFormat() {
    auto tb = tab();
    auto sf = sourceFormats[tb.sourceFormat];

    tb.doc.format = sf.format;
    tb.saveCompact = sf.compact;
    setStatus("Ctrl+S saves as " ~ sf.label ~ ", Save as picks a new name");
    updateTitle();
    ui.invalidate();
  }

  private void drawWelcome(Canvas c) {
    auto t = ui.theme;

    c.fill(contentRect.shrink(ui.px(4)), t.view);
    auto f = ui.fonts.ui;

    string[] lines = [
      "Open a file with Ctrl+O or drop it here",
      "JSON, JSON with comments, JSON Lines, KeyValues (.vdf) and KeyValues3 (.kv3, .vdata)",
      "Ctrl+Shift+V opens JSON from the clipboard",
    ];
    int y = contentRect.y + contentRect.h / 2 - ui.px(30);

    foreach (k, l; lines) {
      auto font = k == 0 ? ui.fonts.bold : f;
      int w = font.measure(l);

      c.text(font, contentRect.x + (contentRect.w - w) / 2, y, l, k == 0 ? t.text : t.dimText);
      y += font.lineHeight + ui.px(6);
    }
  }

  private void drawStructure(Canvas c) {
    auto t = ui.theme;

    panelHeader(c, structHeader, "Structure");
    grid.draw(c);
    c.fill(
      Rect(structHeader.x, grid.rect.bottom, structHeader.w,
        search.rect.bottom + ui.px(2) - grid.rect.bottom),
      t.window);
    search.draw(c);
    c.frame(
      Rect(structHeader.x, structHeader.y, structHeader.w, search.rect.bottom + ui.px(3) - structHeader.y),
      t.border);
  }

  private void drawDetails(Canvas c) {
    auto t = ui.theme;
    auto d = doc();
    string title = "Details";

    if (detailsNode != noNode && detailsNode < d.length) {
      title ~= " — " ~ describeNode(d, detailsNode);
      if (detailsAsText) {
        title ~= ", plain text";
      }
    }

    panelHeader(c, detailsHeader, title);
    if (applyButton.visible) {
      applyButton.draw(c);
    }

    if (revertButton.visible) {
      revertButton.draw(c);
    }

    if (embedButton.visible) {
      embedButton.draw(c);
    }

    bool container = detailsNode != noNode && detailsNode < d.length && d[detailsNode].isContainer;

    if (container) {
      drawDetailsToggle(c);
    }

    auto f = ui.fonts.small;
    string info;

    if (showingTable) {
      table.draw(c);
      info = format("%s rows, %s columns   Double click shows the element in the tree",
        groupDigits(table.rowCount), table.columnCount);
    } else {
      details.draw(c);
      auto caret = details.caret;

      info = format("Ln %s, Col %s   Lines: %s", caret.line + 1, caret.col + 1, details.lineCount);
    }

    c.fill(detailsStatus, t.window);
    if (!showingTable) {
      info ~= textState();
    }

    c.text(f, detailsStatus.x + ui.px(8), detailsStatus.y + (detailsStatus.h - f.lineHeight) / 2,
      info, t.dimText);
    c.frame(
      Rect(detailsHeader.x, detailsHeader.y, detailsHeader.w, detailsStatus.bottom - detailsHeader.y),
      t.border);
  }

  private string textState() {
    if (details.readOnly && detailsTruncated) {
      return "   Preview is cut, the element is too big to edit here";
    }

    if (details.readOnly) {
      return "   Read only";
    }

    return detailsDirty ? "   Modified, Ctrl+Enter applies" : null;
  }

  private void drawDetailsToggle(Canvas c) {
    auto t = ui.theme;
    auto f = ui.fonts.ui;
    auto whole = Rect(tableToggle.x, tableToggle.y, textToggle.right - tableToggle.x, tableToggle.h);

    c.roundRect(whole, ui.px(4), t.button, t.border);
    c.roundRect((showingTable ? tableToggle : textToggle).shrink(ui.px(2)), ui.px(3), t.selection);
    foreach (k, r; [tableToggle, textToggle]) {
      bool active = (k == 0) == showingTable;

      c.text(f, r.x + ui.px(10), r.y + (r.h - f.lineHeight) / 2, k == 0 ? "Table" : "Text",
        active ? t.selectionText : t.text);
    }
  }

  private void setDetailsTable(bool on) {
    if (detailsDirty) {
      return setStatus("Apply or revert the changes first", true);
    }

    detailsTable = on;
    detailsNode = noNode;
    loadDetails();
    ui.invalidate();
  }

  private Message[] messages() {
    Message[] res;
    auto tb = tab();

    if (tb is null) {
      return res;
    }

    auto d = tb.doc;
    auto s = tb.stats;

    if (d.error.length) {
      res ~= Message("Error", d.error, 4);
    }

    res ~= Message("File", d.path.length ? d.path : "(not saved)", 0);
    res ~= Message("Format", describeFormat(d), 0);
    res ~= Message("File size", formatSize(s.fileSize) ~ " (" ~ groupDigits(s.fileSize) ~ " bytes)", 0);

    if (s.textSize != s.fileSize) {
      res ~= Message("Unpacked size", formatSize(s.textSize) ~ " (" ~ groupDigits(s.textSize) ~ " bytes)", 0);
    }

    auto pending = tb.hashesReady ? null : "computing…";

    res ~= Message("MD5", tb.hashesReady ? tb.hashes.md5 : pending, 1);
    res ~= Message("SHA1", tb.hashesReady ? tb.hashes.sha1 : pending, 1);
    res ~= Message("SHA256", tb.hashesReady ? tb.hashes.sha256 : pending, 1);
    res ~= Message("Object count", groupDigits(s.objects), 2);
    res ~= Message("Array count", groupDigits(s.arrays), 2);
    res ~= Message("Value count", groupDigits(s.values), 2);
    res ~= Message("Node count", groupDigits(s.nodes), 2);
    res ~= Message("Max depth", s.maxDepth.to!string, 2);
    res ~= Message("Parsing time", format("%.3f s", d.parseTime), 3);

    return res;
  }

  private void messageColumns(size_t count, out int colW, out int perColumn) {
    perColumn = max(1, (messagesRect.h - ui.px(8)) / ui.fonts.ui.lineHeight);
    int columns = max(2, cast(int)((count + perColumn - 1) / perColumn));

    colW = max(ui.px(320), (messagesRect.w - ui.px(10)) / columns);
  }

  private void drawMessages(Canvas c) {
    auto t = ui.theme;
    auto f = ui.fonts.ui;

    panelHeader(c, messagesHeader, "");
    c.arrow(messagesHeader.x + ui.px(12), messagesHeader.y + messagesHeader.h / 2, ui.px(9),
      showMessages ? 1 : 0, t.headerText);
    c.text(ui.fonts.bold, messagesHeader.x + ui.px(24),
      messagesHeader.y + (messagesHeader.h - f.lineHeight) / 2, "Messages", t.headerText);
    if (!showMessages) {
      return;
    }

    c.fill(messagesRect, t.view);
    auto list = messages();
    int colW, perColumn;

    messageColumns(list.length, colW, perColumn);
    int labelW = ui.px(110);

    foreach (k, m; list) {
      int col = cast(int)k / perColumn;
      int x = messagesRect.x + ui.px(10) + col * colW;
      int y = messagesRect.y + ui.px(6) + (cast(int)k % perColumn) * f.lineHeight;

      if (x > messagesRect.right) {
        break;
      }

      Color ic = m.icon == 4
        ? t.error
        : m.icon == 1 ? t.iconNumber : m.icon == 2 ? t.iconObject : m.icon == 3 ? t.iconBool : t.iconString;

      c.roundRect(Rect(x, y + f.lineHeight / 2 - ui.px(4), ui.px(8), ui.px(8)), ui.px(2), ic);
      c.text(f, x + ui.px(16), y, m.label ~ ":", t.dimText);
      c.pushClip(Rect(x, y, colW - ui.px(14), f.lineHeight));
      c.textFit(f, x + ui.px(16) + labelW, y, m.value, m.icon == 4 ? t.error : t.text,
        colW - labelW - ui.px(40));
      c.popClip();
    }
  }

  private void drawStatus(Canvas c) {
    auto t = ui.theme;
    auto f = ui.fonts.ui;

    c.fill(statusRect, t.window);
    c.hline(0, statusRect.w, statusRect.y, t.border);
    int ty = statusRect.y + (statusRect.h - f.lineHeight) / 2;
    int leftW = min(ui.px(360), statusRect.w / 3);

    c.textFit(f, statusRect.x + ui.px(10), ty, statusText, statusError ? t.error : t.text, leftW - ui.px(16));
    c.vline(leftW, statusRect.y + ui.px(4), statusRect.bottom - ui.px(4), t.border);

    auto d = doc();

    if (d is null) {
      return;
    }

    string right = describeFormat(d) ~ (d.modified ? "  •  Modified" : "");
    int rw = f.measure(right);

    c.text(f, statusRect.right - rw - ui.px(12), ty, right, t.dimText);
    auto sel = grid.tree !is null ? grid.tree.selected : noNode;

    if (sel != noNode) {
      auto pathW = statusRect.w - leftW - rw - ui.px(40);

      c.textFit(f, leftW + ui.px(10), ty, grid.tree.selectedPath, t.text, pathW);
    }
  }

  private void handle(ref Event e) {
    final switch (e.type) {
      case EventType.none:
      case EventType.focusIn:
      case EventType.focusOut:
        break;
      case EventType.close:
        quit();
        break;
      case EventType.resize:
        if (window.scale() != ui.scale) {
          ui.reload();
        }

        relayout();
        break;
      case EventType.expose:
        ui.invalidate();
        break;
      case EventType.keyDown:
        keyDown(e);
        break;
      case EventType.text:
        textInput(e.text);
        break;
      case EventType.mouseDown:
        mouseDown(e);
        break;
      case EventType.mouseUp:
        mouseUp(e);
        break;
      case EventType.mouseMove:
        mouseMove(e);
        break;
      case EventType.wheel:
        if (overlay !is null && overlay.visible) {
          break;
        }

        if (auto w = widgetAt(e.x, e.y)) {
          w.wheel(e);
        }

        break;
      case EventType.drop:
        foreach (f; e.files) {
          openPath(f);
        }

        break;
    }
  }

  private Widget widgetAt(int x, int y) {
    if (menuBar.contains(x, y)) {
      return menuBar;
    }

    if (!tabs.length) {
      return null;
    }

    if (tab().sourceMode) {
      if (useFormatButton.visible && useFormatButton.contains(x, y)) {
        return useFormatButton;
      }

      return source.contains(x, y) ? source : null;
    }

    Widget body = showingTable ? table : details;

    foreach (w; [cast(Widget)applyButton, revertButton, embedButton, grid, search, body]) {
      if (w.contains(x, y)) {
        return w;
      }
    }

    return null;
  }

  private void mouseDown(ref Event e) {
    if (overlay !is null && overlay.visible) {
      if (overlay is dialog) {
        if (auto part = dialog.partAt(e.x, e.y)) {
          ui.capture = part;
          part.mouseDown(e);
        }

        return;
      }

      if (!overlay.mouseDown(e)) {
        overlay = null;
        if (menuBar.contains(e.x, e.y)) {
          menuBar.mouseDown(e);
        }

        return;
      }

      ui.capture = overlay;

      return;
    }

    if (grid.isEditing && !grid.editor.rect.contains(e.x, e.y)) {
      grid.finishEdit(true);
    }

    if (tabs.length && !tab().sourceMode && splitRect.contains(e.x, e.y)) {
      dragging = 1;

      return;
    }

    if (showMessages && messagesSplitRect.contains(e.x, e.y)) {
      dragging = 2;

      return;
    }

    if (tabs.length && !tab().sourceMode && detailsNode != noNode && doc()[detailsNode].isContainer) {
      if (tableToggle.contains(e.x, e.y)) {
        return setDetailsTable(true);
      }

      if (textToggle.contains(e.x, e.y)) {
        return setDetailsTable(false);
      }
    }

    if (messagesHeader.contains(e.x, e.y)) {
      showMessages = !showMessages;
      relayout();

      return;
    }

    if (showMessages && messagesRect.contains(e.x, e.y)) {
      messageClick(e);

      return;
    }

    if (tabsRect.contains(e.x, e.y)) {
      tabClick(e);

      return;
    }

    if (tabs.length && tab().sourceMode) {
      foreach (k, r; sourceFormatRects) {
        if (!r.contains(e.x, e.y)) {
          continue;
        }

        tab().sourceFormat = k;
        updateSource();
        if (!k) {
          showInSource();
        }

        ui.invalidate();

        return;
      }
    }

    auto w = widgetAt(e.x, e.y);

    if (w is null) {
      return;
    }

    if (w.mouseDown(e) && ui.capture is null) {
      ui.capture = w;
    }
  }

  private void mouseUp(ref Event e) {
    if (dragging) {
      dragging = 0;

      return;
    }

    auto target = ui.capture;

    ui.capture = null;
    if (target !is null) {
      target.mouseUp(e);
    }
  }

  private void mouseMove(ref Event e) {
    if (dragging == 1) {
      auto cr = contentRect.shrink(ui.px(4));

      mainSplit = max(0.2f, min(0.8f, cast(float)(e.x - cr.x) / cr.w));
      relayout();

      return;
    }

    if (dragging == 2) {
      int lines = (statusRect.y - e.y - ui.rowHeight) / ui.fonts.ui.lineHeight;

      messagesLines = max(2, min(lines, 20));
      relayout();

      return;
    }

    if (ui.capture !is null) {
      ui.capture.mouseMove(e);

      return;
    }

    Widget w;

    if (overlay !is null && overlay.visible) {
      w = overlay is dialog ? dialog.partAt(e.x, e.y) : overlay;
      if (overlay is popup && menuBar.contains(e.x, e.y)) {
        w = menuBar;
      }
    } else {
      w = widgetAt(e.x, e.y);
    }

    if (w !is hover) {
      if (hover !is null) {
        hover.mouseLeave();
      }

      hover = w;
    }

    if (w !is null) {
      w.mouseMove(e);
    }

    Cursor cur = Cursor.arrow;

    if (overlay is null || !overlay.visible) {
      if (tabs.length && !tab().sourceMode && splitRect.contains(e.x, e.y)) {
        cur = Cursor.resizeH;
      } else if (showMessages && messagesSplitRect.contains(e.x, e.y)) {
        cur = Cursor.resizeV;
      } else if (w !is null) {
        cur = w.cursorAt(e.x, e.y);
      }
    } else if (w !is null) {
      cur = w.cursorAt(e.x, e.y);
    }

    window.setCursor(cur);
  }

  private void tabClick(ref Event e) {
    if (tabs.length && treeToggle.contains(e.x, e.y)) {
      return setSourceMode(false);
    }

    if (tabs.length && sourceToggle.contains(e.x, e.y)) {
      return setSourceMode(true);
    }

    foreach (i, r; tabRects) {
      if (!r.contains(e.x, e.y)) {
        continue;
      }

      if (tabCloseRects[i].contains(e.x, e.y) || e.button == MouseButton.middle) {
        closeTab(i);
      } else {
        switchTo(i);
      }

      return;
    }
  }

  private void messageClick(ref Event e) {
    auto f = ui.fonts.ui;
    auto list = messages();
    int colW, perColumn;

    messageColumns(list.length, colW, perColumn);
    int col = (e.x - messagesRect.x - ui.px(10)) / colW;
    int rowIdx = (e.y - messagesRect.y - ui.px(6)) / f.lineHeight;

    if (col < 0 || rowIdx < 0 || rowIdx >= perColumn) {
      return;
    }

    auto k = col * perColumn + rowIdx;

    if (k >= list.length || !list[k].value.length) {
      return;
    }

    ui.copy(list[k].value);
    setStatus("Copied " ~ list[k].label);
  }

  private void textInput(string text) {
    if (overlay !is null && overlay.visible) {
      if (overlay is dialog && ui.focus !is null) {
        ui.focus.textInput(text);
      }

      return;
    }

    if (ui.focus is grid && tabs.length) {
      ui.setFocus(search);
      search.setText(text);

      return;
    }

    if (ui.focus !is null) {
      ui.focus.textInput(text);
    }
  }

  private void keyDown(ref Event e) {
    if (overlay !is null && overlay.visible) {
      if (overlay is dialog) {
        if (ui.focus !is dialog && ui.focus !is null) {
          if (dialog.inputKey(e)) {
            return;
          }

          if (ui.focus.keyDown(e)) {
            return;
          }
        }

        dialog.keyDown(e);

        return;
      }

      overlay.keyDown(e);

      return;
    }

    auto focus = ui.focus;
    bool textFocus = cast(TextEdit)focus !is null || cast(LineEdit)focus !is null;

    if (textFocus && focus.keyDown(e)) {
      return;
    }

    if (globalShortcut(e)) {
      return;
    }

    if (focus is grid && grid.keyDown(e)) {
      return;
    }

    if (focus is grid && treeShortcut(e)) {
      return;
    }

    if (focus is source && source.keyDown(e)) {
      return;
    }

    if (e.key == Key.escape && focus !is grid && tabs.length) {
      ui.setFocus(grid);
    }
  }

  private bool globalShortcut(ref Event e) {
    bool ctrl = e.ctrl, shift = e.shift;

    if (e.key == Key.f10 || (e.alt && e.key == Key.f)) {
      menuBar.open(0);

      return true;
    }

    if (e.key == Key.f3) {
      findNextMatch(shift);

      return true;
    }

    if (e.key == Key.f5) {
      reload();

      return true;
    }

    if (!ctrl) {
      return false;
    }

    switch (e.key) {
      case Key.o: openDialog(); return true;
      case Key.s: if (shift) saveAsDialog(Format.unknown); else save(); return true;
      case Key.w: if (tabs.length) closeTab(current); return true;
      case Key.q: quit(); return true;
      case Key.n: newDocument(); return true;
      case Key.f: ui.setFocus(search); search.setText(search.text, true); return true;
      case Key.g: goToDialog(); return true;
      case Key.u: if (tabs.length) setSourceMode(!tab().sourceMode); return true;
      case Key.tab:
        if (tabs.length > 1) {
          switchTo((current + (shift ? tabs.length - 1 : 1)) % tabs.length);
        }

        return true;
      case Key.v:
        if (shift) {
          openFromClipboard();

          return true;
        }

        return false;
      default:
        return false;
    }
  }

  private bool treeShortcut(ref Event e) {
    if (!tabs.length) {
      return false;
    }

    bool ctrl = e.ctrl, shift = e.shift;

    switch (e.key) {
      case Key.del: deleteSelected(); return true;
      case Key.insert: addDialog(); return true;
      case Key.c:
        if (!ctrl) {
          return false;
        }

        copy(shift ? CopyKind.json : CopyKind.value);

        return true;
      case Key.z: if (!ctrl) return false; if (shift) redo(); else undo(); return true;
      case Key.y: if (!ctrl) return false; redo(); return true;
      case Key.j: if (!ctrl) return false; toggleEmbedded(); return true;
      case Key.e: if (!ctrl) return false; expandAll(); return true;
      default: return false;
    }
  }

  private void selectionChanged() {
    ui.invalidate();
    if (!tabs.length || grid.tree is null) {
      return;
    }

    auto sel = grid.tree.selected;

    if (sel == detailsNode) {
      return;
    }

    if (detailsDirty && detailsNode != noNode && detailsNode < doc().length) {
      auto target = sel;
      auto old = detailsNode;

      ask("Apply changes?", "Text of " ~ nodeLabel(doc(), old, 60) ~ " was changed in the details pane.",
        ["Apply", "Discard", "Cancel"], (b, _) {
          if (b == 2 || b == -1) {
            grid.tree.reveal(old);
            ui.invalidate();

            return;
          }

          if (b == 0 && !applyDetails()) {
            return;
          }

          detailsDirty = false;
          grid.reveal(target);
          loadDetails();
        });

      return;
    }

    loadDetails();
  }

  /// Strings opened as documents right in the tree change the document
  /// without going through afterEdit
  private void syncWithDocument() {
    auto t = tab();

    if (t is null || t.doc.revision == t.shownRevision) {
      return;
    }

    t.shownRevision = t.doc.revision;
    t.stats = collectStats(t.doc);
    if (!detailsDirty) {
      detailsNode = noNode;
      loadDetails();
    }

    if (t.sourceMode) {
      updateSource();
    }

    updateTitle();
  }

  private void loadDetails() {
    auto d = doc();

    detailsNode = grid.tree.selected;
    detailsDirty = false;
    if (detailsNode == noNode) {
      details.setText("");

      return;
    }

    auto n = &d.nodes[detailsNode];

    showingTable = detailsTable && n.isContainer;
    if (showingTable) {
      const(uint)[] ids, indices;

      grid.tree.visibleChildren(detailsNode, ids, indices);
      table.setNode(d, detailsNode, ids, indices);
      details.setText("");
      detailsAsText = false;
      updateDetailsButtons();

      return;
    }

    detailsAsText = n.type == NodeType.string;
    string text;

    if (detailsAsText) {
      text = d.value(detailsNode, detailsLimit);
      detailsTruncated = !n.has(NodeFlags.pooled) && n.len > detailsLimit;
    } else {
      auto opt = defaultOptions(d, Format.json);

      opt.tabs = indentTabs;
      opt.embeddedRoot = true;
      opt.readable = true;
      text = nodeToText(d, detailsNode, Format.json, opt, detailsLimit, &detailsTruncated);
    }

    details.setText(text);
    details.readOnly = detailsTruncated;
    details.highlight = !detailsAsText;
    updateDetailsButtons();
    if (tab().sourceMode) {
      showInSource();
    }
  }

  private void updateDetailsButtons() {
    applyButton.visible = detailsDirty;
    revertButton.visible = detailsDirty;
    auto d = doc();

    embedButton.visible = false;
    if (d !is null && detailsNode != noNode && detailsNode < d.length && !detailsDirty) {
      auto n = &d.nodes[detailsNode];

      if (n.has(NodeFlags.embedded)) {
        embedButton.label = "To string";
        embedButton.visible = true;
      } else if (n.type == NodeType.string && (n.has(NodeFlags.pooled) || n.len < 16 << 20)) {
        import formats.embedded : embeddedFormat;
        auto f = embeddedFormat(d.value(detailsNode));

        if (f != Format.unknown) {
          embedButton.label = "Parse " ~ (f == Format.json ? "JSON" : f == Format.kv ? "KV" : "KV3");
          embedButton.visible = true;
        }
      }
    }

    relayout();
  }

  private bool applyDetails() {
    auto d = doc();

    if (d is null || !detailsDirty || detailsNode == noNode) {
      return true;
    }

    auto node = detailsNode;
    string err = detailsAsText ? setValue(d, node, details.text) : replaceWithJson(d, node, details.text);

    if (err.length) {
      showError("Can't apply", err);

      return false;
    }

    detailsDirty = false;
    afterEdit(node);
    setStatus("Changes applied");

    return true;
  }

  private void revertDetails() {
    detailsNode = noNode;
    detailsDirty = false;
    loadDetails();
  }

  private void afterEdit(uint focus) {
    auto t = tab();
    auto top = t.tree.top;

    t.tree.refresh(focus);
    t.tree.top = top;
    grid.ensureVisible();
    t.stats = collectStats(t.doc);
    t.shownRevision = t.doc.revision;
    detailsNode = noNode;
    loadDetails();
    if (t.sourceMode) {
      updateSource();
    }

    updateTitle();
    ui.invalidate();
  }

  private void inlineEdit(uint node, string text, bool key) {
    auto d = doc();

    if (key && text == d.key(node)) {
      return;
    }

    if (!key && text == d.value(node)) {
      return;
    }

    auto err = key ? renameKey(d, node, text) : setValue(d, node, text);

    if (err.length) {
      return showError("Can't change value", err);
    }

    afterEdit(node);
  }

  private void deleteSelected() {
    auto d = doc();
    auto n = grid.tree.selected;

    if (d[n].parent == noNode) {
      return setStatus("Root element can't be deleted", true);
    }

    auto label = nodeLabel(d, n, 60);
    auto parent = d[n].parent;

    deleteNode(d, n);
    afterEdit(n < d[parent].end ? n : parent);
    setStatus("Deleted " ~ label ~ ", Ctrl+Z brings it back");
  }

  private void addDialog() {
    auto d = doc();
    auto n = grid.tree.selected;
    uint parent, before = noNode;

    if (d[n].isContainer && (grid.tree.isExpanded(grid.tree.cursor) || d[n].parent == noNode || !d[n].len)) {
      parent = n;
    } else if (d[n].parent != noNode) {
      parent = d[n].parent;
      before = d[n].end < d[parent].end ? d[n].end : noNode;
    } else {
      return setStatus("Can't add an element here", true);
    }

    bool withKey = d[parent].type == NodeType.object;
    string where = "into " ~ nodeLabel(d, parent, 40);

    auto inputs = withKey
      ? ["Key", "Value (JSON, plain text becomes a string)"]
      : ["Value (JSON, plain text becomes a string)"];
    auto values = withKey ? ["", ""] : [""];

    ask("Add element", "New element goes " ~ where ~ ".", ["Add", "Cancel"], (b, vals) {
      if (b != 0) {
        return;
      }

      auto key = withKey ? vals[0] : null;
      auto value = withKey ? vals[1] : vals[0];
      auto at = insertNode(d, parent, before, key, value);

      afterEdit(at);
      setStatus("Element added");
    }, inputs, values);
  }

  private void toggleEmbedded(Format format = Format.unknown) {
    auto d = doc();

    if (d is null) {
      return;
    }

    auto n = grid.tree.selected;
    string err = d[n].has(NodeFlags.embedded) ? collapseEmbedded(d, n) : expandEmbedded(d, n, format);

    if (err.length) {
      return setStatus(err, true);
    }

    afterEdit(n);
    auto r = grid.tree.rowOf(n);

    if (r != noRow && d[n].isContainer) {
      grid.tree.expand(r);
    }

    if (d[n].isContainer) {
      setStatus("String parsed as " ~ embeddedFormatName(d[n]) ~ ", it's saved back as a string");
    } else {
      setStatus("Turned back into a string");
    }
  }

  private void changeEmbeddedFormat(Format format) {
    auto d = doc();
    auto n = grid.tree.selected;
    auto err = setEmbeddedFormat(d, n, format);

    if (err.length) {
      return setStatus(err, true);
    }

    afterEdit(n);
    setStatus("Embedded document is saved as " ~ embeddedFormatName(d[n]) ~ " now");
  }

  private void undo() {
    auto d = doc();

    if (d is null || !d.canUndo) {
      return setStatus("Nothing to undo");
    }

    afterEdit(d.undo());
  }

  private void redo() {
    auto d = doc();

    if (d is null || !d.canRedo) {
      return setStatus("Nothing to redo");
    }

    afterEdit(d.redo());
  }

  private void copy(CopyKind kind) {
    auto d = doc();

    if (d is null) {
      return;
    }

    auto text = copyText(d, grid.tree.selected, kind);

    ui.copy(text);
    setStatus("Copied " ~ formatSize(text.length));
  }

  private void expandAll() {
    auto t = tab();
    auto r = t.tree.cursor;
    auto n = t.tree.selected;
    auto size = t.doc[n].end - n;

    void run() {
      t.tree.expandAll(r);
      ui.invalidate();
    }
    if (size > 2_000_000) {
      ask("Expand all",
        "This shows " ~ groupDigits(size) ~ " rows, it may take a moment and some memory.",
        ["Expand", "Cancel"], (b, _) {
        if (b == 0) {
          run();
        }
      });
    } else {
      run();
    }
  }

  private void findNextMatch(bool backwards) {
    auto d = doc();

    if (d is null) {
      return;
    }

    if (!query.text.length) {
      query.text = search.text;
    }

    if (!query.text.length) {
      ui.setFocus(search);

      return;
    }

    auto found = findNext(d, grid.tree.selected, query, backwards);

    if (found == noNode) {
      return setStatus("Not found: " ~ query.text, true);
    }

    grid.reveal(found);
    setStatus("Found " ~ d.pathOf(found));
  }

  private void setSourceMode(bool on) {
    auto t = tab();

    if (t is null || t.sourceMode == on) {
      return;
    }

    t.sourceMode = on;
    if (on) {
      updateSource();
      showInSource();
      ui.setFocus(source);
    } else {
      ui.setFocus(grid);
    }

    ui.invalidate();
  }

  private void showInSource() {
    if (tab().sourceFormat) {
      return;
    }

    auto d = doc();
    auto pos = d.sourcePos(grid.tree.selected);

    if (pos != ulong.max) {
      source.goTo(pos);
    }
  }

  private void newDocument() {
    auto d = documentFromText("{}");

    addTab(d);
  }

  private void openFromClipboard() {
    auto text = ui.paste();

    if (!text.strip.length) {
      return setStatus("Clipboard is empty", true);
    }

    auto d = documentFromText(text);

    addTab(d);
    if (!d.error.length) {
      setStatus("Opened " ~ formatName(d.format) ~ " from the clipboard");
    }
  }

  private void reload() {
    auto t = tab();

    if (t is null || !t.doc.path.length) {
      return;
    }

    void run() {
      auto path = t.doc.path;

      try {
        auto fresh = openDocument(path);

        t.stopHashing();
        auto replacement = new DocTab(fresh);

        tabs[current] = replacement;
        switchTo(current);
        replacement.startHashing();
        setStatus("Reloaded " ~ path.baseName);
      } catch (Exception e) {
        showError("Can't reload", e.msg);
      }
    }
    if (t.doc.modified) {
      ask("Reload", "Unsaved changes will be lost.", ["Reload", "Cancel"], (b, _) { if (b == 0) run(); });
    } else {
      run();
    }
  }

  private void openDialog() {
    auto dir = doc() !is null && doc().path.length ? doc().path.dirName : "";

    runFileDialog(showOpenDialog("Open file", documentFilters(), dir, window.nativeHandle()), (path) {
      openPath(path);
    }, () {
      ask("Open file", "", ["Open", "Cancel"], (b, vals) {
        if (b == 0 && vals[0].strip.length) {
          openPath(vals[0].strip);
        }
      }, ["Path"], [dir.length ? dir ~ "/" : ""]);
    });
  }

  private void save(void delegate() then = null) {
    auto d = doc();

    if (d is null) {
      return;
    }

    if (!d.path.length) {
      return saveAsDialog(Format.json, then);
    }

    saveTo(d.path, d.format, then);
  }

  private void saveTo(string path, Format format, void delegate() then = null) {
    auto d = doc();

    grid.finishEdit(true);
    auto err = saveAs(d, path, format, detectTypes,
      tab().saveCompact && (format == Format.json || (format == Format.unknown && d.format == Format.json)));

    if (err.length) {
      return showError("Can't save", err);
    }

    setStatus("Saved " ~ path.baseName ~ " as " ~ formatName(d.format));
    updateTitle();
    ui.invalidate();
    if (then) {
      then();
    }
  }

  private void saveAsDialog(Format format, void delegate() then = null) {
    auto d = doc();

    if (d is null) {
      return;
    }

    auto target = format == Format.unknown ? d.format : format;
    auto suggested = suggestName(d, target);
    auto title = format == Format.unknown ? "Save as" : "Save as " ~ formatName(format);
    FileFilter[] filters = documentFilters()[1 .. $];

    runFileDialog(showSaveDialog(title, filters, suggested, window.nativeHandle()), (path) {
      saveTo(path, format, then);
    }, () {
      ask(title, "Format is chosen by the file extension when not given.", ["Save", "Cancel"], (b, vals) {
        if (b == 0 && vals[0].strip.length) {
          saveTo(vals[0].strip, format, then);
        }
      }, ["Path"], [suggested]);
    });
  }

  private void runFileDialog(FileDialog d, void delegate(string) done, void delegate() fallback) {
    if (d is null) {
      return fallback();
    }

    if (d.done) {
      if (d.result.length) {
        done(d.result);
      }

      return;
    }

    pendingDialog = d;
    pendingDialogDone = done;
  }

  private void goToDialog() {
    auto d = doc();

    if (d is null) {
      return;
    }

    ask("Go to", "Path like $.items[3].name", ["Go", "Cancel"], (b, vals) {
      if (b != 0) {
        return;
      }

      auto n = findPath(d, vals[0]);

      if (n == noNode) {
        return setStatus("No element at " ~ vals[0], true);
      }

      grid.reveal(n);
      ui.setFocus(grid);
    }, ["Path"], [d.pathOf(grid.tree.selected)]);
  }

  private void quit() {
    foreach (i, t; tabs) {
      if (t.doc.modified) {
        closeTab(i, () { quit(); });

        return;
      }
    }

    running = false;
  }

  private void buildMenus() {
    menuBar.add("File", () => [
      item("New", "Ctrl+N", () { newDocument(); }),
      item("Open…", "Ctrl+O", () { openDialog(); }),
      item("Open from clipboard", "Ctrl+Shift+V", () { openFromClipboard(); }),
      item("Reload", "F5", () { reload(); }, hasPath()),
      separator(),
      item("Save", "Ctrl+S", () { save(); }, tabs.length > 0),
      item("Save as…", "Ctrl+Shift+S", () { saveAsDialog(Format.unknown); }, tabs.length > 0),
      item("Save as JSON…", "", () { saveAsDialog(Format.json); }, tabs.length > 0),
      item("Save as JSON Lines…", "", () { saveAsDialog(Format.jsonl); }, tabs.length > 0),
      item("Save as KeyValues…", "", () { saveAsDialog(Format.kv); }, tabs.length > 0),
      item("Save as KeyValues3…", "", () { saveAsDialog(Format.kv3); }, tabs.length > 0),
      separator(),
      item("Close", "Ctrl+W", () { closeTab(current); }, tabs.length > 0),
      item("Quit", "Ctrl+Q", () { quit(); }),
    ]);
    menuBar.add("Edit", () => editItems(true));
    menuBar.add("View", () => [
      check("Tree", "", tabs.length && !tab().sourceMode, () { setSourceMode(false); }),
      check("Source", "Ctrl+U", tabs.length && tab().sourceMode, () { setSourceMode(true); }),
      separator(),
      item("Expand all below", "Ctrl+E", () { expandAll(); }, tabs.length > 0),
      item("Collapse all below", "−",
        () { grid.tree.collapseAll(grid.tree.cursor); ui.invalidate(); }, tabs.length > 0),
      item("Go to path…", "Ctrl+G", () { goToDialog(); }, tabs.length > 0),
      separator(),
      check("Messages panel", "", showMessages, () { showMessages = !showMessages; relayout(); }),
      separator(),
      item("Next tab", "Ctrl+Tab",
        () { if (tabs.length > 1) switchTo((current + 1) % tabs.length); }, tabs.length > 1),
    ]);
    menuBar.add("Options", () => [
      check("Typed values when converting KeyValues", "", detectTypes, () { detectTypes = !detectTypes; }),
      check("Indent details with tabs", "", indentTabs,
        () { indentTabs = !indentTabs; detailsNode = noNode; loadDetailsSafe(); }),
    ]);
    menuBar.add("Help", () => [
      item("Keyboard shortcuts", "", () { showShortcuts(); }),
      item("About", "", () {
        ask("About JSON Viewer",
          "Lightweight viewer and editor for JSON, JSON Lines, KeyValues and KeyValues3.\n\n" ~
          "Written in D, draws everything itself and needs no libraries besides the system ones.",
          ["Close"], null);
      }),
    ]);
  }

  private bool hasPath() { return tabs.length && doc().path.length; }

  private void loadDetailsSafe() {
    if (tabs.length) {
      loadDetails();
    }
  }

  private MenuItem[] editItems(bool full) {
    bool has = tabs.length > 0;
    auto d = doc();
    auto sel = has ? grid.tree.selected : noNode;
    bool hasKey = has && d.hasKey(sel);
    bool isString = has && d[sel].type == NodeType.string;
    bool embedded = has && d[sel].has(NodeFlags.embedded);

    MenuItem[] items;

    if (full) {
      items ~= item("Undo", "Ctrl+Z", () { undo(); }, has && d.canUndo);
      items ~= item("Redo", "Ctrl+Y", () { redo(); }, has && d.canRedo);
      items ~= separator();
    }

    items ~= [
      item("Copy value", "Ctrl+C", () { copy(CopyKind.value); }, has),
      item("Copy key", "", () { copy(CopyKind.key); }, hasKey),
      item("Copy path", "", () { copy(CopyKind.path); }, has),
      item("Copy as JSON", "Ctrl+Shift+C", () { copy(CopyKind.json); }, has),
      item("Copy as minified JSON", "", () { copy(CopyKind.jsonCompact); }, has),
      item("Copy as KeyValues", "", () { copy(CopyKind.kv); }, has),
      item("Copy as KeyValues3", "", () { copy(CopyKind.kv3); }, has),
      separator(),
      item("Edit value", "F2", () { grid.beginEdit(false); }, has),
      item("Rename key", "Shift+F2", () { grid.beginEdit(true); }, hasKey),
      item("Add element…", "Ins", () { addDialog(); }, has),
      item("Delete", "Del", () { deleteSelected(); }, has && sel != 0),
      separator(),
    ];
    if (embedded) {
      auto f = cast(Format)d[sel].embedKind;

      items ~= item("Turn back into string", "Ctrl+J", () { toggleEmbedded(); });
      items ~= check("Store as JSON", "", f != Format.kv && f != Format.kv3,
        () { changeEmbeddedFormat(Format.json); });
      items ~= check("Store as KeyValues", "", f == Format.kv, () { changeEmbeddedFormat(Format.kv); });
      items ~= check("Store as KeyValues3", "", f == Format.kv3, () { changeEmbeddedFormat(Format.kv3); });
    } else {
      items ~= item("Parse string as document", "Ctrl+J", () { toggleEmbedded(); }, isString);
      if (full) {
        items ~= item("Parse string as JSON", "", () { toggleEmbedded(Format.json); }, isString);
        items ~= item("Parse string as KeyValues", "", () { toggleEmbedded(Format.kv); }, isString);
        items ~= item("Parse string as KeyValues3", "", () { toggleEmbedded(Format.kv3); }, isString);
      }
    }

    if (full) {
      items ~= separator();
      items ~= item("Find", "Ctrl+F", () { ui.setFocus(search); });
      items ~= item("Find next", "F3", () { findNextMatch(false); }, has);
      items ~= item("Find previous", "Shift+F3", () { findNextMatch(true); }, has);
    } else {
      items ~= separator();
      items ~= item("Expand all below", "Ctrl+E", () { expandAll(); }, has && d[sel].isContainer);
      items ~= item("Show in source", "", () { setSourceMode(true); }, has && d.sourcePos(sel) != ulong.max);
    }

    return items;
  }

  private void contextMenu(int x, int y) {
    popup.onClose = null;
    popup.onSideKey = null;
    popup.open(x, y, editItems(false));
    overlay = popup;
  }

  private void showShortcuts() {
    ask("Keyboard shortcuts",
      "Arrows, PgUp, PgDn, Home, End: move in the tree, Left/Right collapse and expand\n" ~
      "Enter, Space: expand or collapse,  + and −: expand or collapse everything below\n" ~
      "F2: edit value,  Shift+F2: rename key,  Ins: add,  Del: delete,  Ctrl+Z/Ctrl+Y: undo/redo\n" ~
      "Ctrl+J: parse string as JSON or turn it back,  Ctrl+Enter in details: apply changes\n" ~
      "Ctrl+C: copy value,  Ctrl+Shift+C: copy as JSON,  right click: all copy options\n" ~
      "Ctrl+F or just typing: find,  F3/Shift+F3: next/previous,  Ctrl+G: go to path\n" ~
      "Ctrl+U: source view,  Ctrl+O/Ctrl+S/Ctrl+Shift+S: open, save, save as,  Ctrl+W: close tab",
      ["Close"], null);
  }

  private void ask(string title, string message, string[] buttons, void delegate(int, string[]) onResult,
      string[] inputs = null, string[] values = null) {
    auto returnFocus = ui.focus;

    dialog.onResult = (b, vals) {
      if (ui.focus is dialog || cast(LineEdit)ui.focus) {
        ui.setFocus(returnFocus is null ? grid : returnFocus);
      }

      if (onResult) {
        onResult(b, vals);
      }
    };
    dialog.setup(title, message, buttons, inputs, values);
    overlay = dialog;
  }

  private void showError(string title, string message) {
    setStatus(message, true);
    ask(title, message, ["Close"], null);
  }

  private void setStatus(string text, bool error = false) {
    import std.string : lineSplitter;
    import std.array : array;

    auto lines = text.lineSplitter.array;

    statusText = lines.length ? lines[0] : "";
    statusError = error;
    ui.invalidate();
  }

  private uint[] makeIcon(int size) {
    auto shape = new Canvas;

    shape.resize(size, size);
    shape.fill(Rect(0, 0, size, size), 0);
    shape.roundRect(Rect(2, 2, size - 4, size - 4), size / 5.0f, 0xFFFFFF);

    auto art = new Canvas;

    art.resize(size, size);
    auto accent = ui.theme.accent;

    art.fill(Rect(0, 0, size, size), accent);
    art.fill(Rect(0, size / 2, size, size / 2), mix(accent, 0x000000, 0.12));
    auto font = new Font(ui.fonts.bold.face, size * 0.62f);
    auto label = "{ }";
    int w = font.measure(label);

    art.text(font, (size - w) / 2, (size - font.lineHeight) / 2 - size / 24, label, 0xFFFFFF);

    auto res = new uint[size * size];

    foreach (k; 0 .. size * size) {
      res[k] = ((shape.pixels[k] >> 16) << 24) | art.pixels[k];
    }

    return res;
  }
}
