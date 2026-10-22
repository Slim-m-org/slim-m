// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether the grid, every call tile and real ink composite in decision 0086's order (grid, tile video, ink), read back from a raster of the assembled `CanvasPaneBody`.
/// An ordering assertion on `Stack.children` cannot see a widget that is positioned correctly but paints nothing.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_activity_log.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_pane_body.dart';
import 'package:slimm_app/src/features/canvas/providers/canvas_pen_style.dart';
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
    'the grid sits under every tile and real ink sits over every tile - read '
    'from the actual pixels, not from Stack.children order',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final document = CanvasDocument();
      addTearDown(document.dispose);
      // One opaque stroke crosses both tiles, answering all four samples.
      document.applyPlaced(
        const CanvasStrokeInput(
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
                  onBringIntoBoard: () {},
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
                  onShapePlace: (_, __, {flipX = false, flipY = false}) {},
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
        reason: 'a tile paints above the grid, not behind it',
      );
      // x = 128 sits exactly on a grid line here, unlike an off-lattice point.
      expect(
        _closeTo(at(128, 100), _backColor),
        isTrue,
        reason: 'a grid line crossing a tile must lose to its content',
      );
      expect(
        _closeTo(at(600, 100), _frontColor),
        isTrue,
        reason: 'the second tile paints above the grid too',
      );
      for (final x in [150.0, 600.0]) {
        expect(
          _closeTo(at(x, _inkY), _inkColor),
          isTrue,
          reason: 'real ink composites over the tile at $x, never under it',
        );
      }
    },
  );
}
