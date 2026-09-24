/// Native file dialogs. Linux has no standard dialog API without big libraries,
/// so kdialog or zenity are used when installed, they look native on KDE and
/// GNOME. When neither is there the app asks for a path itself.
module platform.dialogs;

import std.string : strip, join;

struct FileFilter {
  string name;
  string[] patterns;
}

final class FileDialog {
  private bool finished;
  private string chosen;

  version (Posix) {
    import std.process : tryWait, pipeProcess, ProcessPipes, Redirect;
    private ProcessPipes pipes;
  }

  @property bool done() {
    version (Posix) {
      if (!finished) {
        auto r = tryWait(pipes.pid);

        if (r.terminated) {
          finished = true;
          if (r.status == 0) {
            import std.array : appender;
            auto output = appender!string;

            foreach (chunk; pipes.stdout.byChunk(4096)) {
              output.put(cast(const(char)[])chunk);
            }

            chosen = output.data.strip;
          }
        }
      }
    }

    return finished;
  }

  @property string result() { return chosen; }
}

FileDialog showOpenDialog(string title, FileFilter[] filters, string startDir, ulong parentWindow) {
  return show(title, filters, startDir, false, parentWindow);
}

FileDialog showSaveDialog(string title, FileFilter[] filters, string suggested, ulong parentWindow) {
  return show(title, filters, suggested, true, parentWindow);
}

version (Posix) private FileDialog show(string title, FileFilter[] filters, string path, bool save,
  ulong parent) {
  import std.process : environment, pipeProcess, Redirect;
  import std.conv : to;
  import std.algorithm : canFind;

  bool kde = environment.get("XDG_CURRENT_DESKTOP").canFind("KDE");
  bool hasKdialog = inPath("kdialog"), hasZenity = inPath("zenity");
  string[] cmd;

  if (hasKdialog && (kde || !hasZenity)) {
    string[] lines;

    foreach (f; filters) {
      lines ~= f.patterns.join(" ") ~ "|" ~ f.name;
    }

    cmd = ["kdialog", "--title", title];
    if (parent) {
      cmd ~= ["--attach", parent.to!string];
    }

    cmd ~= [save ? "--getsavefilename" : "--getopenfilename", path.length ? path : ".", lines.join("\n")];
  } else if (hasZenity) {
    cmd = ["zenity", "--file-selection", "--title=" ~ title];
    if (save) {
      cmd ~= ["--save", "--confirm-overwrite"];
    }

    if (path.length) {
      cmd ~= "--filename=" ~ path;
    }

    foreach (f; filters) {
      cmd ~= "--file-filter=" ~ f.name ~ " | " ~ f.patterns.join(" ");
    }
  } else {
    return null;
  }

  try {
    auto d = new FileDialog;

    d.pipes = pipeProcess(cmd, Redirect.stdout | Redirect.stderrToStdout);

    return d;
  } catch (Exception) {
    return null;
  }
}

version (Posix) private bool inPath(string name) {
  import std.process : environment;
  import std.path : buildPath;
  import std.file : exists;
  import std.algorithm : splitter;

  foreach (dir; environment.get("PATH", "/usr/bin").splitter(':')) {
    if (dir.length && buildPath(dir, name).exists) {
      return true;
    }
  }

  return false;
}

version (Windows) private FileDialog show(string title, FileFilter[] filters, string path,
  bool save, ulong parent) {
  import core.sys.windows.windows;
  import core.sys.windows.commdlg;
  import std.utf : toUTF16, toUTF8;

  wchar[] filter;

  foreach (f; filters) {
    filter ~= f.name.toUTF16 ~ '\0' ~ f.patterns.join(";").toUTF16 ~ '\0';
  }

  filter ~= '\0';

  auto buf = new wchar[32_768];

  buf[] = 0;
  if (save && path.length) {
    auto name = path.toUTF16;

    buf[0 .. name.length] = name[];
  }

  auto wtitle = (title ~ "\0").toUTF16;

  OPENFILENAMEW ofn;

  ofn.lStructSize = OPENFILENAMEW.sizeof;
  ofn.hwndOwner = cast(HWND)parent;
  ofn.lpstrFilter = filter.ptr;
  ofn.lpstrFile = buf.ptr;
  ofn.nMaxFile = cast(DWORD)buf.length;
  ofn.lpstrTitle = wtitle.ptr;
  ofn.Flags = OFN_EXPLORER | OFN_NOCHANGEDIR | (save ? OFN_OVERWRITEPROMPT : OFN_FILEMUSTEXIST);

  auto ok = save ? GetSaveFileNameW(&ofn) : GetOpenFileNameW(&ofn);
  auto d = new FileDialog;

  d.finished = true;
  if (ok) {
    size_t n = 0;

    while (buf[n]) {
      n++;
    }

    d.chosen = buf[0 .. n].toUTF8;
  }

  return d;
}

FileFilter[] documentFilters() {
  return [
    FileFilter("All supported files",
      ["*.json", "*.jsonc", "*.jsonl", "*.ndjson", "*.vdf", "*.kv", "*.kv3", "*.vdata", "*.res",
        "*.acf", "*.txt"]),
    FileFilter("JSON", ["*.json", "*.jsonc"]),
    FileFilter("JSON Lines", ["*.jsonl", "*.ndjson"]),
    FileFilter("KeyValues", ["*.vdf", "*.kv", "*.res", "*.acf", "*.txt"]),
    FileFilter("KeyValues3", ["*.kv3", "*.vdata"]),
    FileFilter("All files", ["*"]),
  ];
}
