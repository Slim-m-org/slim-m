// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Windows pop-out: the control is offered, and the window opens between frames.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/popout/popout_windowing.dart';

import '../../ui_snapshot_support.dart';
import 'popout_window_support.dart';

void main() {
  setUpAll(loadRealFonts);

  testWidgets('Windows offers the pop-out control', (tester) async {
    final rig = await pumpPopOut(
      tester,
      supported: true,
      factory: nativePopOutWindowFactory(
        windowing: true,
        linux: false,
        windows: true,
      ),
    );
    expect(popOutButton, findsOneWidget);
    await teardownFixture(tester, rig.container, rig.db);
  });

  testWidgets('on Windows the window opens between frames, not inside one', (
    tester,
  ) async {
    final rig = await pumpPopOut(tester, supported: true);
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await tester.tap(popOutButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    debugDefaultTargetPlatformOverride = null;
    expect(rig.windows, hasLength(1));
    expect(rig.openedInPhase, [SchedulerPhase.idle]);
    await teardownFixture(tester, rig.container, rig.db);
  });
}
