module app;

import std.conv : to;
import std.getopt;
import std.stdio;

import doc.document;
import formats;
import view.actions : formatFromName;
import view.stats;

enum appVersion = "1.0.0";

int main(string[] args) {
  bool stats, compact, tabs, kvTypes, showVersion;
  string convertTo, output, inputFormat;
  int indent = 4;

  GetoptResult help;

  try {
    help = getopt(args,
      "convert|c", "Convert to json, jsonl, kv or kv3 and print it, or write to --output", &convertTo,
      "output|o", "Output file for --convert", &output,
      "format|f", "Input format: json, jsonl, kv or kv3, detected by default", &inputFormat,
      "indent|i", "Indent width for written files, " ~ indent.to!string ~ " by default", &indent,
      "tabs", "Indent with tabs", &tabs,
      "compact", "Write JSON without whitespace", &compact,
      "kv-types", "Write KeyValues strings that look like numbers or booleans as typed values", &kvTypes,
      "stats|s", "Print file statistics and hashes", &stats,
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

  stderr.writeln("Nothing to do, see --help");

  return 1;
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
  writeln("  Format:      ", formatName(doc.format));
  writeln("  File size:   ", formatSize(s.fileSize), " (", groupDigits(s.fileSize), " bytes)");
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

private string readStdin() {
  char[] data;

  foreach (chunk; stdin.byChunk(1 << 20)) {
    data ~= cast(char[])chunk;
  }

  return cast(string)data;
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
