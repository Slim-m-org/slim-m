// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// #2016: a first window initialization that fails is retried by the next
/// call, which then registers the window listener, instead of the port
/// believing the failed attempt succeeded.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/desktop_window_port.dart';
import 'package:window_manager/window_manager.dart' as wm;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('window_manager');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('a failed first initialization is retried and registers', () async {
    var asked = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method != 'ensureInitialized') return null;
          asked++;
          if (asked == 1) throw PlatformException(code: 'not-ready');
          return null;
        });
    final port = WindowManagerDesktopWindowPort();

    await expectLater(
      port.ensureInitialized(),
      throwsA(isA<PlatformException>()),
    );
    expect(wm.windowManager.listeners, isNot(contains(port)));

    await port.ensureInitialized();
    await port.ensureInitialized();
    expect(asked, 2);
    expect(wm.windowManager.listeners, contains(port));
    wm.windowManager.removeListener(port);
  });
}
