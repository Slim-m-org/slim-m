// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The splash window is frameless on Linux, so until the real app mounts its
/// title bar the splash itself must carry the way to move it, and nothing to close it.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/startup_screen.dart';

import '../support/code_only.dart';
import 'support/fake_desktop_window_port.dart';

void main() {
  testWidgets('the splash drags the window and has no close button', (
    tester,
  ) async {
    final port = FakeDesktopWindowPort();
    await tester.pumpWidget(StartupApp(windowPort: port));
    // The loading line moves for as long as the splash is up, so frames are pumped rather than settled.
    await tester.pump(const Duration(milliseconds: 400));

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

    expect(find.bySemanticsLabel('Close'), findsNothing);
    expect(find.byType(IconButton), findsNothing);
    expect(port.destroyCalls, 0);
  });

  testWidgets('the splash clips to rounded corners only when asked', (
    tester,
  ) async {
    await tester.pumpWidget(const StartupApp(rounded: true));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(ClipRRect), findsOneWidget);

    await tester.pumpWidget(const StartupApp());
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(ClipRRect), findsNothing);
  });

  testWidgets('without a window port the splash draws no chrome', (
    tester,
  ) async {
    await tester.pumpWidget(const StartupApp());
    // The loading line moves for as long as the splash is up, so frames are pumped rather than settled.
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('startup-drag-region')), findsNothing);
    expect(find.bySemanticsLabel('Close'), findsNothing);
  });

  test('main hands the real window port to the Linux and Windows splash', () {
    final main = codeOnly(File('lib/main.dart').readAsStringSync());
    expect(main, contains('windowPort:'));
    expect(main, contains('DesktopPlatform.linux'));
    expect(main, contains('DesktopPlatform.windows'));
  });
}
