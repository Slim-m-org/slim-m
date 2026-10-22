// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Full screen on a canvas tile keeps the canvas, with the dock collapsible behind a handle.
/// Driven through the real [CanvasPane]; the feed must fill the surface and a collapsed dock must leave a handle on screen.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart' show AppSpacing;
import 'package:slimm_app/src/desktop/desktop_window_shell.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_bar.dart';
import 'package:slimm_app/src/features/voice/providers/fullscreen_video.dart';
import '../../desktop/support/fake_desktop_window_port.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_call_dock.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_compact_dock.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_dock_collapse.dart';
import 'package:slimm_app/src/features/modules/providers/dock_reservation.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_fullscreen.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_pane.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/fullscreen_video_overlay.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../voice/voice_controller_harness.dart';
import 'canvas_pane_harness.dart';

class _DrivenVoiceController extends VoiceController {
  _DrivenVoiceController(super.ref, VoiceState initial)
    : super(session: FakeSession()) {
    state = initial;
  }

  void become(VoiceState next) => state = next;
}

VoiceParticipant _ada({bool sharing = true}) => VoiceParticipant(
  identity: 'user-ada',
  name: 'Ada',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: sharing,
  isCameraOn: false,
);

VoiceState _call({bool sharing = true}) => VoiceState(
  channelId: 'c1',
  state: VoiceSessionState.connected,
  participants: [_ada(sharing: sharing)],
);

const _tileKey = 'screen:user-ada';
const _expandLabel = 'Show this tile full screen';

Future<({_DrivenVoiceController voice, ProviderContainer container})> _pump(
  WidgetTester tester, {
  bool fullscreenFirst = false,
  bool focusFirst = false,
  bool sharing = true,
  Size size = const Size(1280, 800),
}) async {
  final fixture = CanvasPaneFixture();
  late _DrivenVoiceController voice;
  final container = fixture.container(
    extraOverrides: [
      voiceControllerProvider.overrideWith(
        (ref) => voice = _DrivenVoiceController(ref, _call(sharing: sharing)),
      ),
    ],
  );
  addTearDown(container.dispose);
  addTearDown(fixture.events.close);
  container.read(canvasOpenProvider.notifier).state = 'c1';
  if (fullscreenFirst) {
    container.read(canvasFullscreenProvider.notifier).state = 'c1';
  }
  if (focusFirst) {
    container.read(canvasFocusedTileProvider.notifier).state = (
      channelId: 'c1',
      tileKey: _tileKey,
    );
  }
  // The view itself, not just the surface: only that makes MediaQuery agree, so a phone width really builds the compact dock.
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await pumpCanvasPane(tester, container, tool: null);
  await tester.pumpAndSettle();
  return (voice: voice, container: container);
}

Future<TestGesture> _focusTheShare(
  WidgetTester tester, [
  TestGesture? existing,
]) async {
  final center = tester.getCenter(find.byKey(_tileKeyValue));
  final mouse =
      existing ?? await tester.createGesture(kind: PointerDeviceKind.mouse);
  if (existing == null) {
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: center);
  } else {
    await mouse.moveTo(center);
  }
  await tester.pump(const Duration(milliseconds: 200));
  await tester.tap(
    find.descendant(
      of: find.byKey(_tileKeyValue),
      matching: find.bySemanticsLabel(_expandLabel),
    ),
  );
  await tester.pumpAndSettle();
  return mouse;
}

const _tileKeyValue = ValueKey(_tileKey);

// Collapsed, the dock is still in the tree but neither visible nor reachable.
final _pen = find.bySemanticsLabel('Pen').hitTestable();

Rect _surface(WidgetTester tester) =>
    tester.getRect(find.byType(CanvasSurface));

void main() {
  testWidgets('full screen on a share keeps the canvas: the camera fits the '
      'tile and no second route opens', (tester) async {
    final (:voice, :container) = await _pump(tester);
    await _focusTheShare(tester);

    expect(container.read(canvasFocusedTileProvider), (
      channelId: 'c1',
      tileKey: _tileKey,
    ));
    expect(container.read(canvasFullscreenProvider), 'c1');
    expect(find.byType(FullscreenVideoView), findsNothing);
    expect(find.byType(CanvasSurface), findsOneWidget);
    expect(find.byKey(_tileKeyValue), findsNothing, reason: 'no tile controls');
    expect(find.byKey(const ValueKey('video:$_tileKey')), findsOneWidget);
    expect(_surface(tester).width, 1280);
  });

  testWidgets('the dock folds behind a handle on screen, and tapping it '
      'brings the tools and the call back', (tester) async {
    await _pump(tester);
    await _focusTheShare(tester);

    expect(_pen, findsNothing);
    final handle = find.byTooltip('Show controls');
    expect(handle, findsOneWidget);
    final pane = _surface(tester);
    final rect = tester.getRect(handle);
    expect(pane.contains(rect.center), isTrue);
    expect(rect.bottom, closeTo(pane.bottom, 16));

    await tester.tap(handle);
    await tester.pumpAndSettle();

    final pen = tester.getRect(_pen);
    expect(pane.contains(pen.center), isTrue, reason: 'reachable on screen');
    expect(find.bySemanticsLabel('Exit fullscreen'), findsOneWidget);
    expect(find.byTooltip('Hide controls'), findsOneWidget);

    await tester.tap(find.byTooltip('Hide controls'));
    await tester.pumpAndSettle();
    expect(_pen, findsNothing);
  });

  testWidgets('moving the mouse toward the bottom edge reveals the dock and '
      'leaving hides it again', (tester) async {
    await _pump(tester);
    final mouse = await _focusTheShare(tester);
    await mouse.moveTo(const Offset(640, 300));
    await tester.pumpAndSettle();
    expect(_pen, findsNothing);

    await mouse.moveTo(const Offset(640, 790));
    await tester.pumpAndSettle();
    expect(_pen, findsOneWidget);

    await mouse.moveTo(const Offset(640, 300));
    await tester.pump(canvasDockHideDelay + const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    expect(_pen, findsNothing);
  });

  testWidgets('exiting restores the chrome and drops the feed', (tester) async {
    final (:voice, :container) = await _pump(tester);
    await _focusTheShare(tester);
    await tester.tap(find.byTooltip('Show controls'));
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('Exit fullscreen'));
    await tester.pumpAndSettle();

    expect(container.read(canvasFocusedTileProvider), isNull);
    expect(container.read(canvasFullscreenProvider), isNull);
    expect(find.byKey(const ValueKey('video:$_tileKey')), findsOneWidget);
    expect(find.byType(CanvasBar), findsOneWidget);
    expect(find.byKey(_tileKeyValue), findsOneWidget);
  });

  testWidgets('the share ending drops the feed and the fullscreen it '
      'brought', (tester) async {
    final (:voice, :container) = await _pump(tester);
    await _focusTheShare(tester);

    voice.become(_call(sharing: false));
    await tester.pumpAndSettle();

    expect(container.read(canvasFocusedTileProvider), isNull);
    expect(container.read(canvasFullscreenProvider), isNull);
    expect(find.byType(CanvasBar), findsOneWidget);
  });

  testWidgets('a canvas that was already fullscreen stays fullscreen when '
      'the share ends', (tester) async {
    final (:voice, :container) = await _pump(tester, fullscreenFirst: true);
    await _focusTheShare(tester);
    expect(container.read(canvasFocusedTileProvider), isNotNull);

    voice.become(_call(sharing: false));
    await tester.pumpAndSettle();

    expect(container.read(canvasFocusedTileProvider), isNull);
    expect(container.read(canvasFullscreenProvider), 'c1');
  });

  testWidgets('at phone width the folded dock is still reachable and its '
      'exit lands on screen', (tester) async {
    await _pump(tester, size: const Size(390, 844));
    expect(find.byType(CanvasCompactDock), findsOneWidget);
    await _focusTheShare(tester);

    expect(_pen, findsNothing);
    final screen = Offset.zero & const Size(390, 844);
    final handle = tester.getRect(find.byTooltip('Show controls'));
    expect(screen.contains(handle.center), isTrue);
    expect(handle.bottom, closeTo(844, 24));

    await tester.tap(find.byTooltip('Show controls'));
    await tester.pumpAndSettle();

    for (final label in const ['Pen', 'Exit fullscreen']) {
      final rect = tester.getRect(find.bySemanticsLabel(label));
      expect(screen.contains(rect.topLeft), isTrue, reason: label);
      expect(screen.contains(rect.bottomRight), isTrue, reason: label);
    }
  });

  testWidgets('at phone width undo and the overflow stay reachable in '
      'fullscreen', (tester) async {
    await _pump(tester, size: const Size(390, 844));
    expect(find.byType(CanvasCompactDock), findsOneWidget);
    await _focusTheShare(tester);
    await tester.tap(find.byTooltip('Show controls'));
    await tester.pumpAndSettle();

    final screen = Offset.zero & const Size(390, 844);
    for (final finder in [
      find.bySemanticsLabel('Undo'),
      find.byTooltip('More canvas actions'),
    ]) {
      expect(finder.hitTestable(), findsOneWidget);
      final rect = tester.getRect(finder);
      expect(screen.contains(rect.topLeft), isTrue);
      expect(screen.contains(rect.bottomRight), isTrue);
    }
    await tester.tap(find.byTooltip('More canvas actions'));
    await tester.pumpAndSettle();
    expect(find.text('Exit fullscreen'), findsWidgets);
  });

  testWidgets('the snackbar reservation follows the folded dock: the handle '
      'alone, then the whole dock once it is shown', (tester) async {
    final (:voice, :container) = await _pump(tester);
    await _focusTheShare(tester);
    expect(
      container.read(bottomDockReservationProvider),
      canvasDockHandleHeight,
    );

    await tester.tap(find.byTooltip('Show controls'));
    await tester.pumpAndSettle();
    final reserved = container.read(bottomDockReservationProvider);
    expect(
      reserved,
      tester.getSize(find.byType(CanvasCallDock)).height +
          canvasDockHandleHeight +
          AppSpacing.s8,
      reason:
          'shown, the dock, its gap and its handle are what the snackbars clear',
    );
    expect(reserved, greaterThan(canvasDockHandleHeight));

    await tester.tap(find.byTooltip('Hide controls'));
    await tester.pumpAndSettle();
    expect(
      container.read(bottomDockReservationProvider),
      canvasDockHandleHeight,
    );
  });

  testWidgets('showing the folded dock in full screen leaves the view where it '
      'was: the dock floats over the board', (tester) async {
    await _pump(tester);
    await _focusTheShare(tester);
    final document = surfaceDocument(tester);
    final before = document.camera;
    final insetBefore = document.bottomInset;

    await tester.tap(find.byTooltip('Show controls'));
    await tester.pumpAndSettle();

    expect(document.bottomInset, insetBefore);
    expect(document.camera.x, before.x);
    expect(document.camera.y, before.y);
    expect(document.camera.zoom, before.zoom);
  });

  testWidgets('focusing a tile holds the OS window fullscreen until the '
      'share ends', (tester) async {
    final port = FakeDesktopWindowPort();
    DesktopWindowShell.debugPort = port;
    DesktopWindowShell.debugActivate(frameless: true);
    addTearDown(DesktopWindowShell.debugReset);
    final (:voice, :container) = await _pump(tester);
    expect(port.fullScreen, isFalse);

    await _focusTheShare(tester);
    expect(port.fullScreen, isTrue);
    expect(container.read(fullscreenVideoActiveProvider), isTrue);

    voice.become(_call(sharing: false));
    await tester.pumpAndSettle();
    expect(port.fullScreen, isFalse);
    expect(container.read(fullscreenVideoActiveProvider), isFalse);
  });

  testWidgets('exiting fullscreen and closing the canvas both release the '
      'OS window', (tester) async {
    final port = FakeDesktopWindowPort();
    DesktopWindowShell.debugPort = port;
    DesktopWindowShell.debugActivate(frameless: true);
    addTearDown(DesktopWindowShell.debugReset);
    await _pump(tester);
    final mouse = await _focusTheShare(tester);
    await tester.tap(find.byTooltip('Show controls'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Exit fullscreen'));
    await tester.pumpAndSettle();
    expect(port.fullScreen, isFalse);

    await _focusTheShare(tester, mouse);
    expect(port.fullScreen, isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(port.fullScreen, isFalse, reason: 'dispose releases it');
  });

  testWidgets('a pane mounting onto a focused tile holds the window without '
      'writing provider state mid-build', (tester) async {
    final port = FakeDesktopWindowPort();
    DesktopWindowShell.debugPort = port;
    DesktopWindowShell.debugActivate(frameless: true);
    addTearDown(DesktopWindowShell.debugReset);

    final (:voice, :container) = await _pump(
      tester,
      fullscreenFirst: true,
      focusFirst: true,
    );

    expect(tester.takeException(), isNull);
    expect(port.fullScreen, isTrue);
    expect(container.read(fullscreenVideoActiveProvider), isTrue);
  });

  testWidgets('returning to a channel whose focused share ended leaves the '
      'window windowed and nothing focused', (tester) async {
    final port = FakeDesktopWindowPort();
    DesktopWindowShell.debugPort = port;
    DesktopWindowShell.debugActivate(frameless: true);
    addTearDown(DesktopWindowShell.debugReset);

    final (:voice, :container) = await _pump(
      tester,
      fullscreenFirst: true,
      focusFirst: true,
      sharing: false,
    );

    expect(container.read(canvasFocusedTileProvider), isNull);
    expect(port.fullScreen, isFalse, reason: 'no feed, so no fullscreen');
    expect(container.read(fullscreenVideoActiveProvider), isFalse);
  });
}
