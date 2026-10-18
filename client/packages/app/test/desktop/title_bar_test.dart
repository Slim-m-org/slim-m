// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The custom title bar's own controls: reachable by keyboard and a screen
/// reader alike, and the close button routes through the same decision the
/// native close/delete-event does rather than hiding the window
/// unconditionally - decision 0012's own worst-failure-mode warning. See
/// `window_menu_button_test.dart` for the fourth control's own coverage.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_app/src/desktop/close_behavior.dart';
import 'package:slimm_app/src/desktop/title_bar.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import 'support/fake_desktop_window_port.dart';
import '../support/fake_api.dart';

/// A host matching real usage: [TitleBar] sits atop the rest of the app
/// inside a fixed-height slot, the same shape `DesktopChrome`'s own
/// `Column` gives it, so a tap or drag lands where it really would - and
/// the real `AppTokens` theme, since [AppIconButton] reads it unconditionally.
/// [TitleBar] reads `serverInfoProvider`/`syncControllerProvider` now, so
/// this needs the same minimal `apiProvider`/`keyStoreProvider` overrides
/// every other suite hitting a real `SlimmApi` gives it, rather than
/// constructing one against an unconfigured session.
Future<SemanticsHandle> _pump(
  WidgetTester tester, {
  required FakeDesktopWindowPort port,
  required DesktopPlatform platform,
  required Future<void> Function() onRequestClose,
}) async {
  final handle = tester.ensureSemantics();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        mockApiOverride((_) async => http.Response('', 404)),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: Column(
            children: [
              TitleBar(
                port: port,
                platform: platform,
                onRequestClose: onRequestClose,
              ),
              const Expanded(child: SizedBox()),
            ],
          ),
        ),
      ),
    ),
  );
  return handle;
}

void main() {
  group('TitleBar, Linux/Windows branch', () {
    testWidgets('all three window controls carry a real semantics label', (
      tester,
    ) async {
      final handle = await _pump(
        tester,
        port: FakeDesktopWindowPort(),
        platform: DesktopPlatform.linux,
        onRequestClose: () async {},
      );

      expect(find.bySemanticsLabel('Window menu'), findsOneWidget);
      expect(find.bySemanticsLabel('Minimize'), findsOneWidget);
      expect(find.bySemanticsLabel('Maximize'), findsOneWidget);
      expect(find.bySemanticsLabel('Close'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('on Windows the controls sit at the right edge', (
      tester,
    ) async {
      final handle = await _pump(
        tester,
        port: FakeDesktopWindowPort(),
        platform: DesktopPlatform.windows,
        onRequestClose: () async {},
      );

      final width = tester.getSize(find.byType(TitleBar)).width;
      final close = tester.getRect(find.bySemanticsLabel('Close'));
      expect(close.right, closeTo(width, 1));
      expect(
        tester.getRect(find.bySemanticsLabel('Minimize')).left,
        lessThan(close.left),
      );
      handle.dispose();
    });

    testWidgets('the maximize button flips to Restore once maximized', (
      tester,
    ) async {
      final port = FakeDesktopWindowPort();
      final handle = await _pump(
        tester,
        port: port,
        platform: DesktopPlatform.linux,
        onRequestClose: () async {},
      );

      await tester.tap(find.bySemanticsLabel('Maximize'));
      await tester.pumpAndSettle();

      expect(port.maximizeCalls, 1);
      expect(find.bySemanticsLabel('Restore'), findsOneWidget);
      expect(find.bySemanticsLabel('Maximize'), findsNothing);
      handle.dispose();
    });

    /// The custom close button has no native close/delete-event of its own
    /// to reach the tray-availability fallback through, so it must call the
    /// same routing a real close would rather than hiding unconditionally -
    /// the exact failure decision 0012 names as the worst this feature
    /// could ship: a window hidden with nothing left to bring it back.
    testWidgets('the close button routes through onRequestClose, never hide', (
      tester,
    ) async {
      final port = FakeDesktopWindowPort();
      var closeRequested = 0;
      final handle = await _pump(
        tester,
        port: port,
        platform: DesktopPlatform.linux,
        onRequestClose: () async {
          closeRequested++;
        },
      );

      await tester.tap(find.bySemanticsLabel('Close'));
      await tester.pumpAndSettle();

      expect(closeRequested, 1);
      expect(
        port.hideCalls,
        0,
        reason: 'the close button must not call hide() on the port directly',
      );
      handle.dispose();
    });

    testWidgets('a double-tap on the empty region toggles maximized', (
      tester,
    ) async {
      final port = FakeDesktopWindowPort();
      final handle = await _pump(
        tester,
        port: port,
        platform: DesktopPlatform.linux,
        onRequestClose: () async {},
      );
      final region = find.byType(TitleBar);

      await tester.tap(region);
      await tester.pump(kDoubleTapMinTime + const Duration(milliseconds: 10));
      await tester.tap(region);
      await tester.pumpAndSettle();

      expect(port.maximizeCalls, 1);
      expect(port.unmaximizeCalls, 0);
      handle.dispose();
    });

    testWidgets('a pan on the empty region starts a native window drag', (
      tester,
    ) async {
      final port = FakeDesktopWindowPort();
      final handle = await _pump(
        tester,
        port: port,
        platform: DesktopPlatform.linux,
        onRequestClose: () async {},
      );

      await tester.drag(find.byType(TitleBar), const Offset(40, 0));
      await tester.pumpAndSettle();

      expect(port.startDraggingCalls, greaterThan(0));
      handle.dispose();
    });
  });

  group('TitleBar, macOS branch', () {
    testWidgets(
      'draws no window controls of its own, leaving the traffic lights '
      'space empty instead',
      (tester) async {
        final handle = await _pump(
          tester,
          port: FakeDesktopWindowPort(),
          platform: DesktopPlatform.macOS,
          onRequestClose: () async {},
        );

        expect(find.bySemanticsLabel('Window menu'), findsNothing);
        expect(find.bySemanticsLabel('Minimize'), findsNothing);
        expect(find.bySemanticsLabel('Maximize'), findsNothing);
        expect(find.bySemanticsLabel('Close'), findsNothing);
        handle.dispose();
      },
    );
  });
}
