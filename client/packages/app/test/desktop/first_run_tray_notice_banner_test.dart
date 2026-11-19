// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [FirstRunTrayNoticeBanner] must say the true thing for the resolved
/// [CloseAction] it is handed, never the other path's copy - the bug this
/// file exists to catch had the tray-only copy shown unconditionally,
/// including on the no-tray minimise fallback where there is no tray icon
/// to point at.
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/desktop/close_behavior.dart';
import 'package:slimm_app/src/desktop/first_run_tray_notice.dart';
import 'package:slimm_app/src/desktop/first_run_tray_notice_banner.dart';
import 'package:slimm_app/src/widgets/status_banner.dart';
import 'package:slimm_design_system/design_system.dart';

const _trayCopy = 'still running in the tray';
const _taskbarCopy = 'minimised, not closed';

Future<void> _pump(WidgetTester tester, CloseAction? action) async {
  SharedPreferences.setMockInitialValues({});
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        firstRunTrayNoticeCloseActionProvider.overrideWith((ref) => action),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(body: FirstRunTrayNoticeBanner()),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('renders nothing while no close has resolved yet', (
    tester,
  ) async {
    await _pump(tester, null);

    expect(find.textContaining(_trayCopy), findsNothing);
    expect(find.textContaining(_taskbarCopy), findsNothing);
    expect(find.byType(StatusBanner), findsNothing);
  });

  testWidgets(
    'names the tray icon on the hideToTray path, never the taskbar copy',
    (tester) async {
      await _pump(tester, CloseAction.hideToTray);

      expect(find.textContaining(_trayCopy), findsOneWidget);
      expect(find.textContaining(_taskbarCopy), findsNothing);
    },
  );

  testWidgets(
    'names the taskbar on the minimizeToTaskbar path, never the tray copy',
    (tester) async {
      await _pump(tester, CloseAction.minimizeToTaskbar);

      expect(find.textContaining(_taskbarCopy), findsOneWidget);
      expect(find.textContaining(_trayCopy), findsNothing);
    },
  );

  testWidgets('dismissing marks only the shown outcome as seen', (
    tester,
  ) async {
    await _pump(tester, CloseAction.minimizeToTaskbar);

    await tester.tap(find.byType(AppIconButton));
    await tester.pump();
    await tester.pump();

    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getBool(firstRunTrayNoticeShownKey(CloseAction.minimizeToTaskbar)),
      isTrue,
    );
    expect(
      prefs.getBool(firstRunTrayNoticeShownKey(CloseAction.hideToTray)),
      isNot(isTrue),
    );
  });

  testWidgets('paints the window surface around itself, not the bare window', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final boundary = GlobalKey();
    // The desktop chrome hosts it on a transparent Material, so its margin shows the native window, black on Windows.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          firstRunTrayNoticeCloseActionProvider.overrideWith(
            (ref) => CloseAction.hideToTray,
          ),
        ],
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: Material(
            type: MaterialType.transparency,
            child: Align(
              alignment: Alignment.topCenter,
              child: RepaintBoundary(
                key: boundary,
                child: const FirstRunTrayNoticeBanner(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final render =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final corner = await tester.runAsync(() async {
      final image = await render.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      return bytes!.getUint32(0);
    });

    final rgb = AppTokens.light.surfaceBase.toARGB32() & 0xFFFFFF;
    expect(corner, rgb << 8 | 0xFF);
  });
}
