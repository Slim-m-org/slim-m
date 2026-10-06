// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Only a bare Ctrl+Q quits: an extra modifier is another chord, and a second
/// register call must not stack a second handler.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/close_behavior.dart';
import 'package:slimm_app/src/desktop/desktop_quit_shortcut.dart';

import 'support/fake_desktop_window_port.dart';

void main() {
  tearDown(DesktopQuitShortcut.debugUnregister);

  final extras = <String, LogicalKeyboardKey>{
    'Shift': LogicalKeyboardKey.shiftLeft,
    'Alt': LogicalKeyboardKey.altLeft,
    'Meta': LogicalKeyboardKey.metaLeft,
  };
  for (final e in extras.entries) {
    testWidgets('Ctrl+${e.key}+Q does not quit', (tester) async {
      final port = FakeDesktopWindowPort();
      DesktopQuitShortcut.register(port, platform: DesktopPlatform.linux);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(e.value);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyQ);
      expect(port.destroyCalls, 0);
    });
  }

  testWidgets('registering twice still destroys once', (tester) async {
    final port = FakeDesktopWindowPort();
    DesktopQuitShortcut.register(port, platform: DesktopPlatform.linux);
    DesktopQuitShortcut.register(port, platform: DesktopPlatform.linux);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyQ);
    expect(port.destroyCalls, 1);
  });
}
