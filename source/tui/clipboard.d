module tui.clipboard;

import std.base64 : Base64;

import tui.term;

/// Puts text into system clipboard. Terminal itself is asked with OSC 52
/// (Konsole, kitty, foot, WezTerm, Windows Terminal support it), and on Linux
/// wl-copy/xclip/xsel are used too when present, since some terminals ignore OSC 52.
bool copyToClipboard(Terminal term, string text) {
  bool done = false;

  version (Windows) {
    done = windowsCopy(text);
  } else {
    done = externalCopy(text);
  }

  if (text.length < 512 * 1024) {
    term.write("\x1b]52;c;");
    term.write(Base64.encode(cast(const(ubyte)[])text));
    term.write("\x07");
    term.flush();
    done = true;
  }

  return done;
}

version (Posix) private bool externalCopy(string text) {
  import std.process : environment, pipeProcess, Redirect, ProcessException;
  import std.file : exists;

  string[][] candidates;

  if (environment.get("WAYLAND_DISPLAY").length) {
    candidates ~= ["wl-copy"];
  }

  if (environment.get("DISPLAY").length) {
    candidates ~= ["xclip", "-selection", "clipboard"];
    candidates ~= ["xsel", "--clipboard", "--input"];
  }

  candidates ~= ["pbcopy"];

  foreach (cmd; candidates) {
    if (!findInPath(cmd[0])) {
      continue;
    }

    try {
      auto p = pipeProcess(cmd, Redirect.stdin | Redirect.stdout | Redirect.stderr);

      p.stdin.rawWrite(text);
      p.stdin.close();

      // these tools keep running to serve the clipboard, don't wait for them
      return true;
    } catch (ProcessException) {
    } catch (Exception) {
    }
  }

  return false;
}

version (Posix) private bool findInPath(string name) {
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

version (Windows) bool windowsCopy(string text) {
  import core.sys.windows.windows;
  import std.utf : toUTF16;

  auto w = text.toUTF16;

  if (!OpenClipboard(null)) {
    return false;
  }

  scope (exit) CloseClipboard();

  EmptyClipboard();
  auto mem = GlobalAlloc(GMEM_MOVEABLE, (w.length + 1) * wchar.sizeof);

  if (!mem) {
    return false;
  }

  auto p = cast(wchar*)GlobalLock(mem);

  p[0 .. w.length] = w[];
  p[w.length] = 0;
  GlobalUnlock(mem);

  return SetClipboardData(CF_UNICODETEXT, mem) !is null;
}
