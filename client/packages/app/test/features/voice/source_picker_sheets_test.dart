// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The camera and screen-source sheets used a bare Material `ListTile` for
/// each device row: a taller, differently-inset row than every other picker
/// sheet in the app, which builds on `AppListRow` instead.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/widgets/camera_source_sheet.dart';
import 'package:slimm_app/src/features/voice/widgets/screen_source_sheet.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

void main() {
  testWidgets('the camera picker rows are AppListRow, not a bare ListTile', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showCameraDeviceSheet(context, const [
                CameraDevice(id: 'cam-0', label: 'FaceTime HD Camera'),
              ]),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('FaceTime HD Camera'), findsOneWidget);
    expect(find.byType(AppListRow), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);
  });

  testWidgets(
    'the screen-source picker rows are AppListRow, not a bare ListTile',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showScreenSourceSheet(context, const [
                  ScreenShareSource(id: 'screen-0', name: 'Screen 1'),
                ]),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Screen 1'), findsOneWidget);
      expect(find.byType(AppListRow), findsOneWidget);
      expect(find.byType(ListTile), findsNothing);
    },
  );

  testWidgets('picking a camera still returns it and closes the sheet', (
    tester,
  ) async {
    const device = CameraDevice(id: 'cam-1', label: 'Logitech BRIO');
    CameraDevice? picked;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                picked = await showCameraDeviceSheet(context, const [device]);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Logitech BRIO'));
    await tester.pumpAndSettle();

    expect(picked, device);
    expect(find.text('Logitech BRIO'), findsNothing);
  });

  testWidgets('a window is offered next to the screens and can be picked', (
    tester,
  ) async {
    ScreenShareSource? picked;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async =>
                  picked = await showScreenSourceSheet(context, const [
                    ScreenShareSource(id: 'screen-0', name: 'Screen 1'),
                    ScreenShareSource(
                      id: 'w1',
                      name: 'Notepad',
                      isWindow: true,
                    ),
                  ]),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Share a screen or window'), findsOneWidget);
    expect(find.text('Screen 1'), findsOneWidget);

    await tester.tap(find.text('Notepad'));
    await tester.pumpAndSettle();
    expect(picked?.id, 'w1');
  });
}
