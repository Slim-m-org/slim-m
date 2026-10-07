// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Un-minimising sends the plugin's `restore`, not `show`; the controller only
/// knows `show` as "the window came back", so the port must map one to the other.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/desktop_window_port.dart';

void main() {
  test(
    'a window restored from the taskbar reaches the controller as show',
    () async {
      final port = WindowManagerDesktopWindowPort();
      final seen = <DesktopWindowEventKind>[];
      final sub = port.events.listen(seen.add);
      addTearDown(sub.cancel);

      // What window_manager's dart side calls when the linux plugin emits 'restore' after a deiconify (GDK_WINDOW_STATE_ICONIFIED cleared).
      port.onWindowRestore();
      await Future<void>.delayed(Duration.zero);

      expect(seen, contains(DesktopWindowEventKind.show));
    },
  );
}
