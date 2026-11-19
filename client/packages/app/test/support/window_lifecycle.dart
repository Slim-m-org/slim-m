// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A window state a test sets directly, standing in for the embedder.
library;

import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/app_lifecycle.dart';

/// A lifecycle that starts in [state]; move it with `didChangeAppLifecycleState`.
AppLifecycleNotifier windowIn(AppLifecycleState state) =>
    AppLifecycleNotifier(mobile: false, windowEvents: const Stream.empty())
      ..didChangeAppLifecycleState(state);

Override windowLifecycle(AppLifecycleNotifier window) =>
    appLifecycleProvider.overrideWith((ref) => window);

extension WindowFocus on AppLifecycleNotifier {
  /// Focused, or on screen behind another app.
  void setFocused(bool focused) => didChangeAppLifecycleState(
    focused ? AppLifecycleState.resumed : AppLifecycleState.inactive,
  );
}

/// Hides the test window as the embedder does: the frame already asked for is
/// drawn, then none is until the window returns.
Future<void> hideTestWindow(WidgetTester tester) async {
  addTearDown(
    () => tester.binding.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    ),
  );
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  while (tester.binding.hasScheduledFrame) {
    await tester.pump();
  }
  expect(SchedulerBinding.instance.framesEnabled, isFalse);
}

/// Leaves the test window on screen behind another app: frames still draw.
void unfocusTestWindow(WidgetTester tester) {
  addTearDown(
    () => tester.binding.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    ),
  );
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  expect(SchedulerBinding.instance.framesEnabled, isTrue);
}
