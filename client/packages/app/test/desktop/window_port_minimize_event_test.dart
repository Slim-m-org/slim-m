// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The app's own minimise is reported as a minimise: GTK on Wayland never
/// tells the window it was iconified, and a video playing in the panel must
/// pause when the window goes (decision 0128).
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/desktop_window_port.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('minimise reports itself before the window manager does', () async {
    const channel = MethodChannel('window_manager');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final port = WindowManagerDesktopWindowPort();
    final seen = <DesktopWindowEventKind>[];
    final sub = port.events.listen(seen.add);
    addTearDown(sub.cancel);

    await port.minimize();
    await Future<void>.delayed(Duration.zero);

    expect(seen, [DesktopWindowEventKind.minimize]);
  });
}
