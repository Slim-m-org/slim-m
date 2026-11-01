// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [DesktopQuitShortcut]'s own guarantee: Ctrl+Q reaches [DesktopWindowPort]
/// regardless of what, if anything, the widget tree has focused - this is
/// what a focus-independent [HardwareKeyboard] handler buys over the app's
/// own remappable [CallbackShortcuts] table, and the whole reason to use it.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/close_behavior.dart';
import 'package:slimm_app/src/desktop/desktop_quit_shortcut.dart';

import 'support/desktop_shell_fixture.dart';
import 'support/fake_desktop_window_port.dart';

void main() {
  testWidgets('Ctrl+Q calls destroy on the port exactly once', (tester) async {
    final port = FakeDesktopWindowPort();
    final shortcut = DesktopQuitShortcut(shellFor(port))
      ..register(platform: DesktopPlatform.linux);
    addTearDown(shortcut.dispose);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyQ);

    expect(port.destroyCalls, 1);
  });

  testWidgets('Q alone, with no Control held, does nothing', (tester) async {
    final port = FakeDesktopWindowPort();
    final shortcut = DesktopQuitShortcut(shellFor(port))
      ..register(platform: DesktopPlatform.linux);
    addTearDown(shortcut.dispose);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyQ);

    expect(port.destroyCalls, 0);
  });

  testWidgets(
    'never registers on macOS, which keeps its own Cmd+Q convention',
    (tester) async {
      final port = FakeDesktopWindowPort();
      final shortcut = DesktopQuitShortcut(shellFor(port))
        ..register(platform: DesktopPlatform.macOS);
      addTearDown(shortcut.dispose);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyQ);

      expect(port.destroyCalls, 0);
    },
  );

  testWidgets('dispose removes the handler for good', (tester) async {
    final port = FakeDesktopWindowPort();
    final shortcut = DesktopQuitShortcut(shellFor(port))
      ..register(platform: DesktopPlatform.linux);
    addTearDown(shortcut.dispose);
    shortcut.dispose();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyQ);

    expect(port.destroyCalls, 0);
  });
}
