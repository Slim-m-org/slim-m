// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The pump-and-capture helper `canvas_assembled_snapshot_test.dart` runs
/// every scene through, split out the same way `ui_snapshot_support.dart`
/// is split from `ui_snapshot_test.dart`: the widths, the themes and the
/// rendering are not what a reader of the test file's scenarios cares about.
///
/// The capture boundary wraps the whole `MaterialApp`, not just the pane.
/// An `OverlayPortal`-based popup - the overflow menu, its own Clear confirm
/// dialog - mounts into the Navigator's own `Overlay`, an *ancestor* of
/// `Scaffold.body` in the tree, as an independent `OverlayEntry` sibling
/// rather than a descendant of anything inside `CanvasPaneBody`. A boundary
/// drawn any narrower than this silently captures the pane underneath the
/// menu instead of the menu itself, confirmed by looking: the first version
/// wrapped only `CanvasPaneBody` and every `interact`-driven menu screenshot
/// came back showing the resting scene with no menu in it at all.
///
/// This is the exact harness whose own images misled five review passes
/// over the floating call dock's shadow (see CLAUDE.md); `_writePng` now
/// captures through `support/real_shadows.dart`'s `withRealShadows`, which
/// closes that at the source rather than only labelling it.
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/avatar_bytes.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/user_profiles.dart';
import 'package:slimm_app/src/providers/voice_controller.dart';
import 'package:slimm_app/src/providers/voice_flags.dart';
import 'package:slimm_app/src/screens/canvas/canvas_activity_log.dart';
import 'package:slimm_app/src/screens/canvas/canvas_call_dock.dart';
import 'package:slimm_app/src/screens/canvas/canvas_pane_body.dart';
import 'package:slimm_app/src/screens/canvas/canvas_pen_style.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../support/real_shadows.dart';
import '../voice_controller_harness.dart';

const canvasAssembledOutDir = 'build/canvas-assembled-snapshots';
bool get _writing => Platform.environment['SLIMM_CANVAS_ASSEMBLED'] == '1';

const canvasAssembledThemes =
    <String, ({Brightness brightness, AppTokens tokens})>{
      'light': (brightness: Brightness.light, tokens: AppTokens.light),
      'dark': (brightness: Brightness.dark, tokens: AppTokens.dark),
      'true-black': (brightness: Brightness.dark, tokens: AppTokens.trueBlack),
    };

/// Widths worth a look: a phone, the exact pixel the dock's own one/two-row
/// branch turns on (`kCompactWidth`, both sides), and a wide desktop pane.
const canvasAssembledWidths = <String, double>{
  'phone-390': 390,
  'compact-599': 599,
  'compact-600': 600,
  'desktop-1400': 1400,
};

const _boundaryKey = Key('canvas_assembled_boundary');

Future<void> _writePng(WidgetTester tester, String name) async {
  if (!_writing) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_boundaryKey),
  );
  await withRealShadows(tester, boundary, () async {
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      Directory(canvasAssembledOutDir).createSync(recursive: true);
      File(
        '$canvasAssembledOutDir/$name.png',
      ).writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  });
}

/// Builds and pumps a [CanvasPaneBody] filling a real [width]x[height]
/// viewport, with a real [VoiceController] wired for the dock's call
/// section whenever [participants] is non-empty. Everything interactive is
/// a no-op: this is a look, not a drive.
Future<void> renderCanvasAssembledPane(
  WidgetTester tester, {
  required String name,
  required double width,
  required String theme,
  required CanvasDocument document,
  List<VoiceParticipant> participants = const [],
  CanvasCursors? cursors,
  bool truncated = false,
  String? selectedObjectId,
  double height = 844,
  CanvasPresenceTileOverrides? tileOverrides,
  CanvasTool tool = CanvasTool.pen,
  bool canManage = false,
  String? error,
  bool loading = false,
  bool fullscreen = false,
  Future<void> Function(WidgetTester tester)? interact,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final session = participants.isEmpty ? null : FakeSession();
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      userProfileProvider.overrideWith((ref, id) async => null),
      avatarBytesProvider.overrideWith((ref, key) async => null),
      if (session != null)
        voiceControllerProvider.overrideWith(
          (ref) => FixedVoiceController(
            ref,
            VoiceState(
              channelId: 'c1',
              state: VoiceSessionState.connected,
              participants: participants,
            ),
          ),
        ),
    ],
  );
  addTearDown(container.dispose);
  final controller = session == null
      ? null
      : container.read(voiceControllerProvider.notifier);

  final activityLog = CanvasActivityLog(isBlocked: (_) => false);
  addTearDown(activityLog.dispose);
  if (selectedObjectId != null) {
    document.selectedObjectId.value = selectedObjectId;
  }
  final overrides = tileOverrides ?? CanvasPresenceTileOverrides();
  if (tileOverrides == null) addTearDown(overrides.dispose);

  final themeSpec = canvasAssembledThemes[theme]!;
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      // See this file's own doc comment for why the boundary is here, not narrower.
      child: RepaintBoundary(
        key: _boundaryKey,
        child: MaterialApp(
          // Otherwise visible now the boundary wraps this whole widget.
          debugShowCheckedModeBanner: false,
          theme: buildTheme(themeSpec.brightness, themeSpec.tokens),
          home: Scaffold(
            body: CanvasPaneBody(
              channelId: 'c1',
              onClose: () {},
              tool: tool,
              onToolChanged: (_) {},
              canUndo: false,
              onUndo: () {},
              canRedo: false,
              onRedo: () {},
              canManage: canManage,
              document: document,
              onClear: () async {},
              onPasteImage: () {},
              onPasteImageAt: (_) {},
              onRecenter: () {},
              error: error,
              onDismissError: () {},
              truncated: truncated,
              loading: loading,
              onStroke: (_) {},
              onErase: (_) {},
              onEraseEnd: () {},
              onSelectStart: (_) {},
              onSelectDrag: (_) {},
              onSelectEnd: () {},
              onNotePlace: (_) {},
              onShapePlace: (_, __) {},
              shapeKind: CanvasShapeKind.rectangle,
              onShapeKindChanged: (_) {},
              pen: const CanvasPenStyle(),
              onPenChanged: (_) {},
              onBringToFront: (_) {},
              onSendToBack: (_) {},
              onDeleteSelected: (_) {},
              selfId: 'me',
              activityLog: activityLog,
              cursors: cursors,
              cursorColors: AppCanvasColors.cursors,
              callParticipants: participants,
              cameraViewFor: (identity) => ColoredBox(
                color: const Color(0xFF223344),
                child: Center(
                  child: Text(
                    identity,
                    style: const TextStyle(color: Colors.white70),
                  ),
                ),
              ),
              screenShareViewFor: (identity) => ColoredBox(
                color: const Color(0xFF1D3A2E),
                child: Center(
                  child: Text(
                    "$identity's screen",
                    style: const TextStyle(color: Colors.white70),
                  ),
                ),
              ),
              tileOverrides: overrides,
              onCommitTile: (_, __) {},
              onVideoInterest: (_) {},
              selfBubbleHidden: false,
              onToggleSelfBubbleHidden: () {},
              fullscreen: fullscreen,
              onToggleFullscreen: () {},
              callDock: controller == null
                  ? null
                  : CallDockData(
                      voice: const VoiceFlags(
                        channelId: 'c1',
                        state: VoiceSessionState.connected,
                      ),
                      controller: controller,
                    ),
            ),
          ),
        ),
      ),
    ),
  );
  // Two pumps settle the presence layer's own visibility hysteresis - see ui_snapshot_test.dart's identical reasoning.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));

  // A state past the resting one - a menu open, a dialog confirmed - is driven here, on the mounted, settled pane.
  if (interact != null) await interact(tester);

  await _writePng(tester, name);
  expect(tester.takeException(), isNull);
}

/// Opens the dock's "More canvas actions" overflow, the one route to the
/// activity log toggle and Clear canvas - both live behind a menu item, not
/// a bare icon, per `canvas_overflow_menu.dart`'s own doc on the deliberate
/// extra tap. A plain `pump()` is enough: `OverlayPortal` mounts its child
/// synchronously on `_controller.toggle`, with no animation to settle.
Future<void> openCanvasOverflowMenu(WidgetTester tester) async {
  await tester.tap(find.byTooltip('More canvas actions'));
  await tester.pump();
}

/// Taps a menu item by its exact visible [label] - the overflow menu's own
/// `AppMenuItem`s, found the same way a real tap would find them.
Future<void> tapCanvasMenuItem(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pump();
}
