// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A [CanvasCallDock] wrapped for a widget test: a real [VoiceController]
/// over a hand-driven [FakeSession] (so the call section's mic/camera/leave
/// buttons reach something real), and the same
/// `support/canvas_tools_row_fixtures.dart` fill-in-the-blanks shape for the
/// canvas section, reused rather than duplicated.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/voice_controller.dart';
import 'package:slimm_app/src/providers/voice_flags.dart';
import 'package:slimm_app/src/screens/canvas/canvas_call_dock.dart';
import 'package:slimm_app/src/screens/canvas/canvas_pen_style.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../voice_controller_harness.dart';
import 'canvas_tools_row_fixtures.dart';

/// A connected [VoiceFlags] with sensible defaults, matching what
/// `callDockDataFor` would hand this dock for an ordinary active call.
const connectedVoiceState = VoiceFlags(state: VoiceSessionState.connected);

/// Pumps a [CanvasCallDock]. When [withCall] is true, the dock's call
/// section is wired to a real [VoiceController] over a [FakeSession] built
/// and owned by this function - the same "one container, read its own
/// controller back out" shape `voice_call_controls_test.dart`'s own
/// `pumpControls` already uses, so a tap really lands on the controller (and
/// session) this function returns rather than on an unrelated ambient one.
Future<
  ({
    ProviderContainer container,
    VoiceController? controller,
    FakeSession? session,
  })
>
pumpCanvasCallDock(
  WidgetTester tester, {
  bool withCall = false,
  VoiceFlags callVoice = connectedVoiceState,
  CanvasDockData? canvas,
  double width = 800,
  bool? touch,
  bool hug = false,
  bool compact = false,
  Brightness brightness = Brightness.dark,
  Key? boundaryKey,
}) async {
  final session = withCall ? FakeSession() : null;
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      if (session != null)
        voiceControllerProvider.overrideWith(
          (ref) => VoiceController(ref, session: session),
        ),
    ],
  );
  addTearDown(container.dispose);
  final controller = withCall
      ? container.read(voiceControllerProvider.notifier)
      : null;
  final dock = CanvasCallDock(
    call: controller == null
        ? null
        : CallDockData(voice: callVoice, controller: controller),
    canvas: canvas,
    compact: compact,
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(
        key: boundaryKey,
        child: MaterialApp(
          theme: buildTheme(
            brightness,
            brightness == Brightness.dark ? AppTokens.dark : AppTokens.light,
          ),
          home: Scaffold(
            // Bottom-aligned: see `canvas_tools_row_fixtures.dart`'s own doc for why this dock needs to sit there.
            body: Align(
              alignment: Alignment.bottomCenter,
              child: ConstrainedBox(
                constraints: hug
                    ? BoxConstraints(maxWidth: width)
                    : BoxConstraints.tightFor(width: width),
                // A bare SizedBox does not force touch density; see the same doc.
                child: touch == null
                    ? dock
                    : AppTouchTargets(enabled: touch, child: dock),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return (container: container, controller: controller, session: session);
}

/// A [CanvasDockData] with every callback filled in with a no-op, exactly
/// `buildCanvasToolsRow`'s own defaults, plus a real [VoiceState] and the
/// controller the call side needs already wired.
CanvasDockData buildCanvasDockData({
  VoidCallback? onClose,
  bool activityLogOpen = false,
  VoidCallback? onUndo,
  bool canUndo = false,
  ValueChanged<CanvasTool>? onToolChanged,
  CanvasTool tool = CanvasTool.pen,
  CanvasPenStyle pen = const CanvasPenStyle(),
  ValueChanged<CanvasPenStyle>? onPenChanged,
  CanvasShapeKind shapeKind = CanvasShapeKind.rectangle,
  ValueChanged<CanvasShapeKind>? onShapeKindChanged,
  bool fullscreen = false,
  VoidCallback? onToggleFullscreen,
}) {
  final row = buildCanvasToolsRow(
    activityLogOpen: activityLogOpen,
    onUndo: onUndo,
    canUndo: canUndo,
    onToolChanged: onToolChanged,
    tool: tool,
    pen: pen,
    onPenChanged: onPenChanged,
    shapeKind: shapeKind,
    onShapeKindChanged: onShapeKindChanged,
  );
  return CanvasDockData(
    tool: row.tool,
    onToolChanged: row.onToolChanged,
    canDraw: row.canDraw,
    canUndo: row.canUndo,
    onUndo: row.onUndo,
    canManage: row.canManage,
    onClear: row.onClear,
    onPasteImage: row.onPasteImage,
    onRecenter: row.onRecenter,
    selection: row.selection,
    onBringToFront: row.onBringToFront,
    onSendToBack: row.onSendToBack,
    onDeleteSelected: row.onDeleteSelected,
    activityLogOpen: row.activityLogOpen,
    onToggleActivityLog: row.onToggleActivityLog,
    shapeKind: row.shapeKind,
    onShapeKindChanged: row.onShapeKindChanged,
    pen: row.pen,
    onPenChanged: row.onPenChanged,
    onClose: onClose ?? () {},
    hasSelfBubble: row.hasSelfBubble,
    selfBubbleHidden: row.selfBubbleHidden,
    onToggleSelfBubbleHidden: row.onToggleSelfBubbleHidden,
    hiddenTiles: row.hiddenTiles,
    onShowTile: row.onShowTile,
    fullscreen: fullscreen,
    onToggleFullscreen: onToggleFullscreen ?? () {},
  );
}
