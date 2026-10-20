// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The mounted canvas surface the interaction benchmarks drive, and the
/// pointer helpers that drive it.
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'board_fixture.dart';

const String benchFontFamily = 'IBM Plex Sans';

/// Registers the product's UI font, so note text is shaped with a real face
/// and not the test harness's block glyphs.
Future<void> loadBenchFont() async {
  final file = File('../design_system/fonts/IBMPlexSans-Regular.ttf');
  if (!file.existsSync()) return;
  final bytes = file.readAsBytesSync();
  final loader = FontLoader(benchFontFamily)
    ..addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
  await loader.load();
}

/// What the pane around the surface would do with a committed stroke.
void commitLikeThePane(CanvasDocument doc, List<Offset> world, int id) {
  var part = 0;
  for (final segment in splitStroke(world)) {
    doc.applyPlaced(
      CanvasStrokeInput(
        id: 'drawn-$id-${part++}',
        seq: 0,
        zIndex: provisionalLocalZIndex + id,
        x: segment.x,
        y: segment.y,
        w: segment.w,
        h: segment.h,
        points: segment.points,
        width: 3,
        colorKey: 'ink',
        authorId: 'me',
      ),
    );
  }
  doc.refresh();
}

/// A mounted surface plus the remote-activity sources it listens to.
class SurfaceRig {
  SurfaceRig(this.tester, this.doc);

  final WidgetTester tester;
  final CanvasDocument doc;
  final CanvasCursors cursors = CanvasCursors();
  final RemoteStrokeDrafts drafts = RemoteStrokeDrafts();
  int _drawn = 0;

  Future<void> mount({CanvasTool tool = CanvasTool.pen}) async {
    tester.view
      ..physicalSize = const ui.Size(1600, 900)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(size: ui.Size(1600, 900)),
          child: Stack(
            children: [
              CanvasGridLayer(
                document: doc,
                line: const Color(0x14000000),
                letterbox: const Color(0x0A000000),
              ),
              CanvasSurface(
                document: doc,
                ink: const Color(0xFF202124),
                inkColors: benchInkColors,
                tool: tool,
                cursors: cursors,
                remoteDrafts: drafts,
                cursorColors: const [
                  Color(0xFFD93025),
                  Color(0xFF1A73E8),
                  Color(0xFF188038),
                ],
                cursorLabelFontFamily: benchFontFamily,
                selectionOutline: const Color(0xFF1A73E8),
                selectionHandleFill: const Color(0xFFFFFFFF),
                selectionHandleBorder: const Color(0xFF1A73E8),
                onStroke: (points) => commitLikeThePane(doc, points, _drawn++),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  /// One frame, timed in microseconds.
  Future<double> frame() async {
    final sw = Stopwatch()..start();
    await tester.pump();
    return sw.elapsedMicroseconds.toDouble();
  }

  /// Runs [action] and returns how long it took in microseconds.
  Future<double> timed(FutureOr<void> Function() action) async {
    final sw = Stopwatch()..start();
    await action();
    return sw.elapsedMicroseconds.toDouble();
  }

  /// A scale (trackpad pinch or ctrl-wheel on web) event about [focal].
  void pinch(Offset focal, double scale) {
    tester.binding.handlePointerEvent(
      PointerScaleEvent(
        position: focal,
        scale: scale,
        kind: PointerDeviceKind.mouse,
        device: 7,
      ),
    );
  }
}
