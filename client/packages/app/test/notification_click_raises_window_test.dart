// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Clicking a desktop notification brings the window forward.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/desktop_window_shell.dart';

import 'desktop/support/fake_desktop_window_port.dart';

void main() {
  test(
    'the notification activation hook shows and restores the window',
    () async {
      final port = FakeDesktopWindowPort();
      DesktopWindowShell.debugPort = port;
      addTearDown(DesktopWindowShell.debugReset);

      await DesktopWindowShell.raise();

      expect(port.showCalls, 1);
      expect(port.restoreCalls, 1);
    },
  );
}
