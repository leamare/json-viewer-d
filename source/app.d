module app;

import std.conv : to;
import std.getopt;
import std.process : environment;
import std.stdio;

import doc.document;
import formats;
import view.actions : describeFormat, formatFromName;
import view.stats;

enum appVersion = "1.0.1";

int main(string[] args) {
  bool tui, gui, stats, compact, tabs, kvTypes, showVersion, compare;
  string convertTo, output, inputFormat;
  int indent = 4;

  GetoptResult help;

  try {
    help = getopt(args,
      "tui|t", "Open in the terminal interface", &tui,
      "gui|g", "Open in the graphical interface (default when there is a display)", &gui,
      "convert|c", "Convert to json, jsonl, kv or kv3 and print it, or write to --output", &convertTo,
      "output|o", "Output file for --convert", &output,
      "format|f", "Input format: json, jsonl, kv or kv3, detected by default", &inputFormat,
      "indent|i", "Indent width for written files, " ~ indent.to!string ~ " by default", &indent,
      "tabs", "Indent with tabs", &tabs,
      "compact", "Write JSON without whitespace", &compact,
      "kv-types", "Write KeyValues strings that look like numbers or booleans as typed values", &kvTypes,
      "stats|s", "Print file statistics and hashes", &stats,
      "diff|d", "Compare two files, prints the differences without a display", &compare,
      "version|v", "Print version", &showVersion,
    );
  } catch (Exception e) {
    stderr.writeln(e.msg);

    return 1;
  }

  if (help.helpWanted) {
    defaultGetoptPrinter(
      "jsonview " ~ appVersion ~ " - viewer and editor for JSON, JSON Lines and Valve KeyValues\n\n" ~
      "Usage: jsonview [options] [file...]\n" ~
      "       jsonview -c kv3 -o items.kv3 items.json\n" ~
      "       curl -s https://example.com/api | jsonview -t\n\n" ~
      "Options:",
      help.options
    );

    return 0;
  }

  if (showVersion) {
    writeln("jsonview ", appVersion);

    return 0;
  }

  auto forced = Format.unknown;

  if (inputFormat.length) {
    forced = formatFromName(inputFormat);
    if (forced == Format.unknown) {
      stderr.writeln("Unknown format: ", inputFormat);

      return 1;
    }
  }

  string[] files = args[1 .. $];
  bool fromStdin = (files.length == 1 && files[0] == "-") || (!files.length && !stdinIsTerminal());

  if (fromStdin) {
    files = null;
  }

  Document[] docs;

  try {
    if (fromStdin) {
      docs ~= documentFromText(readStdin(), forced);
      reattachTerminal();
    }

    foreach (f; files) {
      docs ~= openDocument(f, forced);
    }
  } catch (Exception e) {
    stderr.writeln(e.msg);

    return 1;
  }

  if (convertTo.length) {
    auto target = formatFromName(convertTo);

    if (target == Format.unknown) {
      stderr.writeln("Unknown format: ", convertTo);

      return 1;
    }

    if (docs.length != 1) {
      stderr.writeln("--convert needs exactly one input");

      return 1;
    }

    return convert(docs[0], target, output, indent, tabs, compact, kvTypes);
  }

  if (stats) {
    foreach (d; docs) {
      printStats(d);
    }

    return 0;
  }

  if (compare) {
    if (docs.length != 2) {
      stderr.writeln("--diff needs two files");

      return 1;
    }

    if (tui || (!gui && !displayAvailable()) || !stdoutIsTerminal()) {
      return printDiff(docs[0], docs[1]);
    }

    import gui.app : runGui;

    return runGui(docs, true);
  }

  if (tui || (!gui && !displayAvailable())) {
    import tui.app : runTui;

    if (docs.length > 1) {
      stderr.writeln("Terminal interface shows one file at a time, opening the first one");
    }

    auto d = docs.length ? docs[0] : documentFromText("{}");

    foreach (extra; docs.length > 1 ? docs[1 .. $] : null) {
      destroy(extra);
    }

    return runTui(d);
  }

  import gui.app : runGui;
  detachConsole();

  return runGui(docs);
}

private int convert(Document doc, Format target, string output, int indent, bool tabs, bool compact,
  bool kvTypes) {
  if (doc.error.length) {
    stderr.writeln("warning: ", doc.error);
  }

  auto opt = defaultOptions(doc, target);

  opt.indent = indent;
  opt.tabs = tabs || opt.tabs;
  opt.compact = compact;
  opt.detectTypes = kvTypes;

  try {
    if (output.length) {
      saveDocument(doc, output, target, opt);
    } else {
      import formats.output : FileSink;

      auto sink = FileSink(stdout);

      writeDocument(sink, doc, 0, target, opt);
      sink.flush();
    }
  } catch (Exception e) {
    stderr.writeln(e.msg);

    return 1;
  }

  return 0;
}

private void printStats(Document doc) {
  import std.format : format;

  auto s = collectStats(doc);
  auto h = hashText(doc.sourceText);

  writeln(doc.path.length ? doc.path : "<stdin>");
  writeln("  Format:      ", describeFormat(doc));
  writeln("  File size:   ", formatSize(s.fileSize), " (", groupDigits(s.fileSize), " bytes)");

  if (s.textSize != s.fileSize) {
    writeln("  Unpacked:    ", formatSize(s.textSize), " (", groupDigits(s.textSize), " bytes)");
  }

  writeln("  MD5:         ", h.md5);
  writeln("  SHA1:        ", h.sha1);
  writeln("  SHA256:      ", h.sha256);
  writeln("  Objects:     ", groupDigits(s.objects));
  writeln("  Arrays:      ", groupDigits(s.arrays));
  writeln("  Values:      ", groupDigits(s.values));
  writeln("  Nodes:       ", groupDigits(s.nodes));
  writeln("  Max depth:   ", s.maxDepth);
  writeln("  Parsing:     ", format("%.3f s", doc.parseTime));
  if (doc.error.length) {
    writeln("  Error:       ", doc.error);
  }
}

private int printDiff(Document a, Document b) {
  import view.actions : valuePreview;
  import view.diff : Diff, DiffStatus;

  auto d = new Diff(a, b);

  void walk(uint e) {
    auto en = d.entries[e];

    final switch (en.status) {
      case DiffStatus.same:
        return;
      case DiffStatus.added:
        writeln("+ ", b.pathOf(en.b), "  ", valuePreview(b, en.b, 80));

        return;
      case DiffStatus.removed:
        writeln("- ", a.pathOf(en.a), "  ", valuePreview(a, en.a, 80));

        return;
      case DiffStatus.changed:
        auto children = d.childrenOf(e);

        if (!children.length) {
          writeln("~ ", a.pathOf(en.a), "  ", valuePreview(a, en.a, 80), " -> ", valuePreview(b, en.b, 80));
        }

        foreach (c; children) {
          walk(c);
        }

        return;
    }
  }

  walk(0);

  return d.identical ? 0 : 1;
}

private bool stdoutIsTerminal() {
  version (Windows) {
    import core.sys.windows.windows;

    DWORD mode;

    return GetConsoleMode(GetStdHandle(STD_OUTPUT_HANDLE), &mode) != 0;
  } else {
    import core.sys.posix.unistd : isatty;

    return isatty(1) != 0;
  }
}

private string readStdin() {
  char[] data;

  foreach (chunk; stdin.byChunk(1 << 20)) {
    data ~= cast(char[])chunk;
  }

  return cast(string)data;
}

private bool displayAvailable() {
  version (Windows) {
    return true;
  } else version (OSX) {
    return !environment.get("SSH_CONNECTION").length;
  } else {
    return environment.get("DISPLAY").length > 0 || environment.get("WAYLAND_DISPLAY").length > 0;
  }
}

private bool stdinIsTerminal() {
  version (Windows) {
    import core.sys.windows.windows;
    DWORD mode;

    return GetConsoleMode(GetStdHandle(STD_INPUT_HANDLE), &mode) != 0;
  } else {
    import core.sys.posix.unistd : isatty;

    return isatty(0) != 0;
  }
}

/// After reading piped data the terminal interface still needs keyboard input
private void reattachTerminal() {
  version (Posix) {
    import core.sys.posix.fcntl : open, O_RDONLY;
    import core.sys.posix.unistd : dup2, close;

    auto fd = open("/dev/tty", O_RDONLY);

    if (fd < 0) {
      return;
    }

    dup2(fd, 0);
    close(fd);
  }
}

/// Console window of a double-clicked exe is useless for the GUI
private void detachConsole() {
  version (Windows) {
    import core.sys.windows.windows;

    DWORD[2] list;

    if (GetConsoleProcessList(list.ptr, 2) == 1) {
      FreeConsole();
    }
  }
}

version (Windows) {
  import core.sys.windows.windef : DWORD;

  private extern (Windows) DWORD GetConsoleProcessList(DWORD*, DWORD) nothrow @nogc;
}
