// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The property that matters: with the tray probe answering "no host" -
/// GNOME with no AppIndicator extension, the well-known Discord-on-GNOME
/// case decision 0012 itself names - close falls back to an ordinary
/// minimise, and a real quit path still exists and still works.
///
/// Before this, it did not: [CloseAction.minimizeToTaskbar] correctly kept
/// the window reachable, but the only "Quit slim-m" anywhere in this app
/// was the tray menu's own item, and that menu is never rendered without a
/// tray host to display it - so the process could never be ended from the
/// running app's own interface on exactly this desktop. A test that only
/// checked the tray menu carries a Quit item would have passed against that
/// bug, since the bug was the menu being unreachable entirely, not its
/// contents; this drives the real close routing and the real quit controls
/// side by side against one fake port instead.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/desktop/close_behavior.dart';
import 'package:slimm_app/src/desktop/desktop_quit_shortcut.dart';
import 'package:slimm_app/src/desktop/desktop_window_controller.dart';
import 'package:slimm_app/src/desktop/title_bar.dart';
import 'package:slimm_app/src/desktop/window_geometry_store.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import 'support/fake_desktop_window_port.dart';
import '../support/fake_api.dart';

void main() {
  tearDown(DesktopQuitShortcut.debugUnregister);

  testWidgets('no tray host: close minimises rather than hiding, and both quit '
      'routes - the title bar menu and Ctrl+Q - still actually terminate', (
    tester,
  ) async {
    final port = FakeDesktopWindowPort();
    SharedPreferences.setMockInitialValues({});
    final store = WindowGeometryStore(await SharedPreferences.getInstance());
    final controller = DesktopWindowController(
      port: port,
      store: store,
      platform: DesktopPlatform.linux,
      trayAvailable: () async => false,
    );
    addTearDown(controller.dispose);
    DesktopQuitShortcut.register(port, platform: DesktopPlatform.linux);

    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          mockApiOverride((_) async => http.Response('', 404)),
        ],
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: Scaffold(
            body: Column(
              children: [
                TitleBar(
                  port: port,
                  platform: DesktopPlatform.linux,
                  onRequestClose: controller.requestClose,
                ),
                const Expanded(child: SizedBox()),
              ],
            ),
          ),
        ),
      ),
    );

    // The same routing a real delete-event or the close button would take.
    await controller.requestClose();

    expect(
      port.minimizeCalls,
      1,
      reason: 'no tray host: this is the fallback the bug lived on',
    );
    expect(port.hideCalls, 0);
    expect(
      port.destroyCalls,
      0,
      reason: 'a fallback minimise must never itself end the process',
    );

    await tester.tap(find.bySemanticsLabel('Window menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Quit slim-m'));
    await tester.pumpAndSettle();

    expect(
      port.destroyCalls,
      1,
      reason: 'the title bar menu is a real quit with no tray at all',
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyQ);

    expect(
      port.destroyCalls,
      2,
      reason: 'Ctrl+Q is the second, independent route to the same quit',
    );

    handle.dispose();
  });
}
