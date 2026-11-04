// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The camera and screen source pickers (an anchored dropdown on a wide window,
/// a sheet on a phone) and the merged scoped-clear sheet. The overflow
/// assertion runs everywhere; the PNGs are written only under
/// SLIMM_UI_SNAPSHOTS=1.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_app/src/features/canvas/widgets/canvas_clear_scope.dart';
import 'package:slimm_app/src/features/canvas/widgets/canvas_clear_sheet.dart';
import 'package:slimm_app/src/features/voice/widgets/camera_source_sheet.dart';
import 'package:slimm_app/src/features/voice/widgets/screen_source_sheet.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../support/mid_flight_capture.dart';
import '../ui_snapshot_support.dart';

final _opens = <String, FutureOr<void> Function(BuildContext)>{
  'camera-source': (context) => showCameraDeviceSheet(context, const [
    CameraDevice(id: 'a', label: 'Integrated Webcam'),
    CameraDevice(id: 'b', label: 'Logitech C920'),
  ]),
  'screen-source': (context) => showScreenSourceSheet(context, const [
    ScreenShareSource(id: '1', name: 'Screen 1'),
    ScreenShareSource(id: '2', name: 'Screen 2'),
    ScreenShareSource(id: '3', name: 'Terminal', isWindow: true),
  ], selectedId: '2'),
  'canvas-clear': (context) => requestScopedCanvasClear(
    context,
    CanvasScopedClear(clear: (_) async {}, authorIds: () => {'ann', 'bo'}),
  ),
};

const _viewports = <String, Size>{
  'desktop': Size(1400, 880),
  'phone': Size(390, 844),
};

GoRouter _router(FutureOr<void> Function(BuildContext) open) => GoRouter(
  initialLocation: '/start',
  routes: [
    GoRoute(
      path: '/start',
      builder: (context, state) => Scaffold(
        body: Align(
          alignment: const Alignment(-0.3, 0.8),
          child: Builder(
            builder: (context) => TextButton(
              onPressed: () => open(context),
              child: const Text('open popup'),
            ),
          ),
        ),
      ),
    ),
  ],
);

void main() {
  setUpAll(loadRealFonts);

  for (final viewport in _viewports.entries) {
    for (final open in _opens.entries) {
      testWidgets('${open.key} at ${viewport.key} fits its viewport', (
        tester,
      ) async {
        tester.view.physicalSize = viewport.value;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          ProviderScope(
            child: RepaintBoundary(
              key: snapshotBoundary,
              child: MaterialApp.router(
                debugShowCheckedModeBanner: false,
                theme: buildTheme(Brightness.dark, AppTokens.dark),
                routerConfig: _router(open.value),
              ),
            ),
          ),
        );
        await tester.pump();

        await tester.tap(find.text('open popup'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));

        final name = '${open.key}-${viewport.key}';
        await expectSettled(tester, name);
        await writeSnapshot(tester, name);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
