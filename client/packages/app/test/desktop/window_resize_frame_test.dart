// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [WindowResizeFrame] is the one piece nothing else in this package's own
/// tree can exercise: it never renders inside a real widget, only inside a
/// window, so this file is what actually proves the eight regions exist,
/// each drags the right [ResizeEdge], each carries the matching cursor, and
/// the whole frame disappears once the window is maximized - the property a
/// visual pass on a real desktop cannot substitute for either, since a
/// wrong edge or a stale cursor is invisible to the eye until the drag
/// itself goes the wrong way.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/desktop_window_port.dart';
import 'package:slimm_app/src/desktop/window_resize_frame.dart';

import 'support/fake_desktop_window_port.dart';

/// A fixed-size host so every edge and corner lands at a known offset.
Future<void> _pump(WidgetTester tester, FakeDesktopWindowPort port) async {
  tester.view.physicalSize = const Size(1000, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: SizedBox.expand(child: WindowResizeFrame(port: port)),
    ),
  );
  // Flushes the initial isMaximized() microtask before assertions.
  await tester.pump();
}

/// Matches `desktop_window_controller_test.dart`'s own precedent: a
/// broadcast stream's event needs a real event-loop turn, not just a
/// pumped frame, to reach a listener registered in `initState`.
Future<void> _flushPortEvent(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
}

MouseRegion _regionFor(WidgetTester tester, ResizeEdge edge) =>
    tester.widget<MouseRegion>(
      find.descendant(
        of: find.byKey(ValueKey(edge)),
        matching: find.byType(MouseRegion),
      ),
    );

void main() {
  group('WindowResizeFrame, not maximized', () {
    testWidgets('all eight edges and corners are present', (tester) async {
      final port = FakeDesktopWindowPort();
      await _pump(tester, port);

      for (final edge in ResizeEdge.values) {
        expect(
          find.byKey(ValueKey(edge)),
          findsOneWidget,
          reason: '$edge has no handle',
        );
      }
    });

    testWidgets('each edge starts a resize with its own ResizeEdge', (
      tester,
    ) async {
      final port = FakeDesktopWindowPort();
      await _pump(tester, port);

      // Every drag moves toward the interior, past the pan slop, so none lands outside the 1000x800 test view.
      const towardInterior = {
        ResizeEdge.top: Offset(0, 20),
        ResizeEdge.bottom: Offset(0, -20),
        ResizeEdge.left: Offset(20, 0),
        ResizeEdge.right: Offset(-20, 0),
        ResizeEdge.topLeft: Offset(20, 20),
        ResizeEdge.topRight: Offset(-20, 20),
        ResizeEdge.bottomLeft: Offset(20, -20),
        ResizeEdge.bottomRight: Offset(-20, -20),
      };

      for (final edge in ResizeEdge.values) {
        await tester.drag(find.byKey(ValueKey(edge)), towardInterior[edge]!);
      }

      expect(port.startResizingCalls, ResizeEdge.values);
    });

    testWidgets('each handle shows the matching platform resize cursor', (
      tester,
    ) async {
      final port = FakeDesktopWindowPort();
      await _pump(tester, port);

      const expected = {
        ResizeEdge.top: SystemMouseCursors.resizeUpDown,
        ResizeEdge.bottom: SystemMouseCursors.resizeUpDown,
        ResizeEdge.left: SystemMouseCursors.resizeLeftRight,
        ResizeEdge.right: SystemMouseCursors.resizeLeftRight,
        ResizeEdge.topLeft: SystemMouseCursors.resizeUpLeftDownRight,
        ResizeEdge.bottomRight: SystemMouseCursors.resizeUpLeftDownRight,
        ResizeEdge.topRight: SystemMouseCursors.resizeUpRightDownLeft,
        ResizeEdge.bottomLeft: SystemMouseCursors.resizeUpRightDownLeft,
      };

      for (final entry in expected.entries) {
        expect(
          _regionFor(tester, entry.key).cursor,
          entry.value,
          reason: '${entry.key} has the wrong hover cursor',
        );
      }
    });

    testWidgets(
      'a diagonal corner never claims the same pixels as its own edges',
      (tester) async {
        final port = FakeDesktopWindowPort();
        await _pump(tester, port);

        final topLeft = tester.getRect(
          find.byKey(const ValueKey(ResizeEdge.topLeft)),
        );
        final top = tester.getRect(find.byKey(const ValueKey(ResizeEdge.top)));
        final left = tester.getRect(
          find.byKey(const ValueKey(ResizeEdge.left)),
        );

        expect(topLeft.overlaps(top), isFalse);
        expect(topLeft.overlaps(left), isFalse);
      },
    );
  });

  group('WindowResizeFrame, maximized', () {
    testWidgets('renders no handles once already maximized on first frame', (
      tester,
    ) async {
      final port = FakeDesktopWindowPort()..maximized = true;
      await _pump(tester, port);

      expect(find.byKey(const ValueKey(ResizeEdge.top)), findsNothing);
    });

    testWidgets('a maximize event during the session removes every handle', (
      tester,
    ) async {
      final port = FakeDesktopWindowPort();
      await _pump(tester, port);
      expect(find.byKey(const ValueKey(ResizeEdge.top)), findsOneWidget);

      port.emit(DesktopWindowEventKind.maximize);
      await _flushPortEvent(tester);

      expect(find.byKey(const ValueKey(ResizeEdge.top)), findsNothing);
    });

    testWidgets('unmaximize brings every handle back', (tester) async {
      final port = FakeDesktopWindowPort()..maximized = true;
      await _pump(tester, port);
      expect(find.byKey(const ValueKey(ResizeEdge.top)), findsNothing);

      port.emit(DesktopWindowEventKind.unmaximize);
      await _flushPortEvent(tester);

      expect(find.byKey(const ValueKey(ResizeEdge.top)), findsOneWidget);
    });
  });

  group('WindowResizeFrame, full screen', () {
    testWidgets('a full-screen event removes every handle', (tester) async {
      final port = FakeDesktopWindowPort();
      await _pump(tester, port);
      expect(find.byKey(const ValueKey(ResizeEdge.top)), findsOneWidget);

      port.emit(DesktopWindowEventKind.fullScreen);
      await _flushPortEvent(tester);

      expect(find.byKey(const ValueKey(ResizeEdge.top)), findsNothing);
    });

    testWidgets('already full screen at mount renders no handles', (
      tester,
    ) async {
      final port = FakeDesktopWindowPort()..fullScreen = true;
      await _pump(tester, port);

      expect(find.byKey(const ValueKey(ResizeEdge.top)), findsNothing);
    });

    testWidgets('leaving full screen while maximized keeps handles away', (
      tester,
    ) async {
      final port = FakeDesktopWindowPort()
        ..maximized = true
        ..fullScreen = true;
      await _pump(tester, port);

      port.emit(DesktopWindowEventKind.leaveFullScreen);
      await _flushPortEvent(tester);

      expect(find.byKey(const ValueKey(ResizeEdge.top)), findsNothing);
    });

    testWidgets('leaving full screen brings every handle back', (tester) async {
      final port = FakeDesktopWindowPort()..fullScreen = true;
      await _pump(tester, port);

      port.emit(DesktopWindowEventKind.leaveFullScreen);
      await _flushPortEvent(tester);

      expect(find.byKey(const ValueKey(ResizeEdge.top)), findsOneWidget);
    });
  });
}
