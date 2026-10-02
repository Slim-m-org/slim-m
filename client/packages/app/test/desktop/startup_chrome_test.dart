// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The splash window is frameless on Linux, so until the real app mounts its
/// title bar the splash itself must carry the only way to move or close it.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/startup_screen.dart';

import '../support/code_only.dart';
import 'support/fake_desktop_window_port.dart';

void main() {
  testWidgets('the splash drags the window and closes it', (tester) async {
    final port = FakeDesktopWindowPort();
    await tester.pumpWidget(StartupApp(windowPort: port));
    await tester.pumpAndSettle();

    final drag = find.byKey(const ValueKey('startup-drag-region'));
    expect(drag, findsOneWidget);
    final box = tester.getRect(drag);
    expect(box.top, 0);
    expect(
      box.width,
      tester.view.physicalSize.width / tester.view.devicePixelRatio,
    );

    await tester.dragFrom(box.center, const Offset(40, 10));
    expect(port.startDraggingCalls, 1);

    await tester.tap(find.bySemanticsLabel('Close'));
    await tester.pump();
    expect(port.destroyCalls, 1);
  });

  testWidgets('without a window port the splash draws no chrome', (
    tester,
  ) async {
    await tester.pumpWidget(const StartupApp());
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('startup-drag-region')), findsNothing);
    expect(find.bySemanticsLabel('Close'), findsNothing);
  });

  test('main hands the real window port to the Linux splash', () {
    final main = codeOnly(File('lib/main.dart').readAsStringSync());
    expect(main, contains('windowPort:'));
    expect(main, contains('DesktopPlatform.linux'));
  });
}
