// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A failed first window initialization is retried by the next call instead of
/// being remembered as done (issue 2016).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/desktop_window_port.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a failed initialization is tried again', () async {
    var attempts = 0;
    final port = WindowManagerDesktopWindowPort(
      initializePlugin: () async {
        attempts++;
        if (attempts == 1) throw StateError('plugin not ready');
      },
    );

    await expectLater(port.ensureInitialized(), throwsStateError);
    await port.ensureInitialized();
    await port.ensureInitialized();

    expect(attempts, 2);
  });

  test('concurrent callers share one initialization', () async {
    var attempts = 0;
    final port = WindowManagerDesktopWindowPort(
      initializePlugin: () async => attempts++,
    );

    await Future.wait([port.ensureInitialized(), port.ensureInitialized()]);

    expect(attempts, 1);
  });
}
