// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Destroying the window must not route the close it echoes back.
///
/// On Linux window_manager's destroy calls gtk_window_close, whose delete
/// event comes back as onWindowClose. With Close to tray off that close was
/// routed to quit again, the second gtk_window_close hit a window already
/// gone, and the app segfaulted on its way out (seen on Fedora 44).
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/desktop_window_port.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          (call) async => true,
        );
  });

  test('a close before destroy is routed; the echo after it is not', () async {
    final port = WindowManagerDesktopWindowPort();
    final seen = <DesktopWindowEventKind>[];
    final sub = port.events.listen(seen.add);
    addTearDown(sub.cancel);

    port.onWindowClose();
    await pumpEventQueue();
    expect(seen, [DesktopWindowEventKind.close]);

    await port.destroy();
    port.onWindowClose();
    await pumpEventQueue();
    expect(seen, [DesktopWindowEventKind.close]);
  });
}
