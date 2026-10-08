// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether the grid, a sent-to-back tile and real ink actually composite in
/// the order `canvas_presence_depth_test.dart`'s own structural test only
/// infers from `Stack.children`'s list order.
///
/// That is the exact weak-test shape PR #515's canvas-grid fix names
/// as the reason the grid painted over a sent-to-back tile for weeks with a
/// green suite the whole time: a widget correctly *positioned* in the tree
/// can still paint nothing, or paint the wrong thing, and an ordering
/// assertion cannot see either. This renders the real, assembled
/// `CanvasPaneBody` to a raster and reads pixels back - the same technique
/// `presence_desaturation_test.dart` uses for exactly this reason - so the
/// claim under test is "what a viewer's eye would actually see," not "what
/// order the widgets were constructed in."
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/screens/canvas/canvas_activity_log.dart';
import 'package:slimm_app/src/screens/canvas/canvas_pane_body.dart';
import 'package:slimm_app/src/screens/canvas/canvas_pen_style.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

const _backColor = Color(0xFF00CC44);
const _frontColor = Color(0xFF2255FF);
const _inkColor = AppCanvasColors.annotation;

const _backTile = Rect.fromLTWH(80, 80, 260, 200);
const _frontTile = Rect.fromLTWH(500, 80, 260, 200);

// Wide and thick, so a sample well inside it clears any anti-aliased edge.
const _inkY = 180.0;
const _inkHalfWidth = 20.0;

const _backParticipant = VoiceParticipant(
  identity: 'user-back',
  name: 'Back',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
  isCameraOn: true,
);

const _frontParticipant = VoiceParticipant(
  identity: 'user-front',
  name: 'Front',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
  isCameraOn: true,
);

const _boundaryKey = Key('depth_paint_boundary');

Color _pixelAt(ByteData rgba, int imageWidth, Offset point) {
  final x = point.dx.round();
  final y = point.dy.round();
  final i = (y * imageWidth + x) * 4;
  return Color.fromARGB(
    rgba.getUint8(i + 3),
    rgba.getUint8(i),
    rgba.getUint8(i + 1),
    rgba.getUint8(i + 2),
  );
}

bool _closeTo(Color a, Color b, {int tolerance = 24}) =>
    (a.r * 255 - b.r * 255).abs() <= tolerance &&
    (a.g * 255 - b.g * 255).abs() <= tolerance &&
    (a.b * 255 - b.b * 255).abs() <= tolerance;

void main() {
  testWidgets(
    'the grid sits under a sent-to-back tile, real ink sits over it, and a '
    'tile still in front sits over the ink - read from the actual pixels, '
    'not from Stack.children order',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final document = CanvasDocument();
      addTearDown(document.dispose);
      // One opaque stroke crosses both tiles, answering all four samples.
      document.applyPlaced(
        CanvasStrokeInput(
          id: 'crossbar',
          seq: 1,
          zIndex: 1,
          x: 40,
          y: _inkY - _inkHalfWidth,
          w: 760,
          h: _inkHalfWidth * 2,
          points: [0, _inkHalfWidth, 760, _inkHalfWidth],
          width: _inkHalfWidth * 2,
          colorKey: 'annotation',
          authorId: 'someone-else',
        ),
      );
      document.refresh();

      final overrides = CanvasPresenceTileOverrides()
        ..setRect('camera:user-back', _backTile)
        ..setSentToBack('camera:user-back', true)
        ..setRect('camera:user-front', _frontTile);
      addTearDown(overrides.dispose);

      final activityLog = CanvasActivityLog(isBlocked: (_) => false);
      addTearDown(activityLog.dispose);

      await tester.pumpWidget(
        ProviderScope(
          child: RepaintBoundary(
            key: _boundaryKey,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: buildTheme(Brightness.dark, AppTokens.dark),
              home: Scaffold(
                body: CanvasPaneBody(
                  channelId: 'c1',
                  onClose: () {},
                  tool: CanvasTool.pen,
                  onToolChanged: (_) {},
                  canUndo: false,
                  onUndo: () {},
                  canRedo: false,
                  onRedo: () {},
                  canManage: false,
                  document: document,
                  onClear: () async {},
                  onPasteImage: () {},
                  onPasteImageAt: (_) {},
                  onRecenter: () {},
                  error: null,
                  onDismissError: () {},
                  truncated: false,
                  loading: false,
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
                  callParticipants: const [_backParticipant, _frontParticipant],
                  cameraViewFor: (identity) => ColoredBox(
                    color: identity == 'user-back' ? _backColor : _frontColor,
                  ),
                  screenShareViewFor: (_) => const SizedBox(),
                  tileOverrides: overrides,
                  onCommitTile: (_, __) {},
                  onVideoInterest: (_) {},
                  selfBubbleHidden: false,
                  onToggleSelfBubbleHidden: () {},
                  fullscreen: false,
                  onToggleFullscreen: () {},
                ),
              ),
            ),
          ),
        ),
      );
      // Two pumps: presence visibility hysteresis, then a real layout pass.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(tester.takeException(), isNull);

      // World (0, 0) is CanvasSurface's top-left, offset below CanvasBar.
      final origin = tester.getTopLeft(find.byType(CanvasSurface));
      final boundaryOrigin = tester.getTopLeft(find.byKey(_boundaryKey));
      Offset atWorld(double x, double y) =>
          origin + Offset(x, y) - boundaryOrigin;

      late ByteData bytes;
      late int imageWidth;
      await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(_boundaryKey),
        );
        final image = await boundary.toImage();
        imageWidth = image.width;
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        image.dispose();
        bytes = data!;
      });

      Color at(double x, double y) =>
          _pixelAt(bytes, imageWidth, atWorld(x, y));

      expect(
        _closeTo(at(150, 100), _backColor),
        isTrue,
        reason:
            'a sent-to-back tile\'s own content must still paint above the '
            'grid, not vanish behind it',
      );
      // x = 128 sits exactly on a grid line here, unlike an off-lattice point.
      expect(
        _closeTo(at(128, 100), _backColor),
        isTrue,
        reason:
            'a grid line crossing a sent-to-back tile must still lose to '
            'the tile\'s own content, not draw over it',
      );
      expect(
        _closeTo(at(150, _inkY), _inkColor),
        isTrue,
        reason: 'real ink must composite over a sent-to-back tile\'s content',
      );
      expect(
        _closeTo(at(600, 100), _frontColor),
        isTrue,
        reason: 'a tile still in front paints above the grid, trivially',
      );
      expect(
        _closeTo(at(600, _inkY), _frontColor),
        isTrue,
        reason:
            'a tile still in front must stay above the ink too - depth is '
            'per-tile, sending one tile back must not affect another',
      );
    },
  );
}
