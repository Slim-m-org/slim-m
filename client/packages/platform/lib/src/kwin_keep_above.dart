// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Keeps a window above the others on KDE Plasma's Wayland session, where a
/// client cannot ask for that itself: GTK's keep-above is X11 only.
///
/// KWin runs a short script that finds the window by process id and title and
/// sets its `keepAbove`, then the script is unloaded. Any other desktop has no
/// KWin on the session bus, so this answers false and nothing changes.
///
/// Keep-above still sits under a focused full screen window, and a script
/// cannot change a window's layer, so [kwinAboveFullScreen] adds a window rule
/// that puts the titled window in KWin's popup layer instead.
library;

import 'dart:io';

import 'package:dbus/dbus.dart';

export 'kwin_window_rule.dart';

const _service = 'org.kde.KWin';
const _scripting = DBusObjectPath.unchecked('/Scripting');
const _scriptingInterface = 'org.kde.kwin.Scripting';
const _plugin = 'slimm-keep-above';

/// The KWin script that sets `keepAbove` on this process's window titled [caption].
String keepAboveScript({required int pid, required String caption}) {
  final title = caption.replaceAll(r'\', r'\\').replaceAll("'", r"\'");
  return '''
const windows = workspace.windowList ? workspace.windowList() : workspace.clientList();
for (const w of windows) {
  if (w.pid === $pid && w.caption === '$title') w.keepAbove = true;
}
''';
}

/// Asks KWin to keep this process's window titled [caption] above others; false where KWin is not running.
Future<bool> kwinKeepAbove(String caption, {DBusClient? client}) async {
  final bus = client ?? DBusClient.session();
  final dir = await Directory.systemTemp.createTemp('slimm-kwin-');
  try {
    final file = File('${dir.path}/keep_above.js');
    await file.writeAsString(keepAboveScript(pid: pid, caption: caption));
    await _unload(bus);
    final loaded = await bus.callMethod(
      destination: _service,
      path: _scripting,
      interface: _scriptingInterface,
      name: 'loadScript',
      values: [DBusString(file.path), const DBusString(_plugin)],
      replySignature: DBusSignature('i'),
    );
    final id = (loaded.values.first as DBusInt32).value;
    if (id < 0) return false;
    await _run(bus, id);
    await _unload(bus);
    return true;
  } on DBusMethodResponseException {
    return false;
  } finally {
    await dir.delete(recursive: true);
    if (client == null) await bus.close();
  }
}

/// Plasma 6 puts a loaded script at `/Scripting/Script<id>`, Plasma 5 at `/<id>`.
Future<void> _run(DBusClient bus, int id) async {
  for (final path in ['/Scripting/Script$id', '/$id']) {
    try {
      await bus.callMethod(
        destination: _service,
        path: DBusObjectPath(path),
        interface: 'org.kde.kwin.Script',
        name: 'run',
        replySignature: DBusSignature(''),
      );
      return;
    } on DBusMethodResponseException {
      continue;
    }
  }
}

Future<void> _unload(DBusClient bus) => bus.callMethod(
      destination: _service,
      path: _scripting,
      interface: _scriptingInterface,
      name: 'unloadScript',
      values: [const DBusString(_plugin)],
      replySignature: DBusSignature('b'),
    );
