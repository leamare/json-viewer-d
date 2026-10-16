module tests.platform_x11;

version (Posix):
version (OSX) {
} else:

import core.sys.posix.poll;
import platform.window;
import platform.x11;

unittest {
  auto files = parseUriList("file:///home/user/a%20b.json\r\nfile://host/tmp/c.json\r\n");

  assert(files == ["/home/user/a b.json", "/tmp/c.json"]);
}
