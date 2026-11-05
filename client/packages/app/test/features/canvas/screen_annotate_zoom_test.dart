// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Marks stay normalised to the video while it is zoomed, and the sharer's own preview shows them without a pen.
library;

import 'dart:typed_data' show ByteData;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/widgets/screen_annotate_layer.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/screen_annotation_feed.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/screen_annotation_sender.dart';
import 'package:slimm_app/src/features/voice/providers/share_zoom_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../support/fake_sync.dart';
import '../../ui_snapshot_support.dart';

class _Sync extends NoopSyncController {
  _Sync(super.ref);

  final frames = <({String kind, List<double> points})>[];

  @override
  void notifyCanvasScreenAnnotation(
    String channelId,
    String targetUserId,
    String kind, {
    String? annotationId,
    List<double> points = const [],
    String? color,
    String? text,
    bool ended = false,
    bool allowed = false,
    double? aspect,
  }) => frames.add((kind: kind, points: points));
}

const _me = VoiceParticipant(
  identity: 'me',
  name: 'Me',
  isSpeaking: false,
  isMuted: false,
  isLocal: true,
  isScreenSharing: false,
);
const _tile = Rect.fromLTWH(100, 100, 640, 360);

class _Rig {
  _Rig(this.tester);

  final WidgetTester tester;
  final feed = ScreenAnnotationFeed(selfId: () => 'me');
  final zoom = ShareZoomController();
  late _Sync sync;

  void allow() => feed.handle(
    const api.CanvasScreenAnnotation(
      channelId: 'call',
      userId: 'sharer',
      targetUserId: 'sharer',
      kind: 'consent',
      points: [],
      ended: false,
      allowed: true,
    ),
  );

  void mark(List<double> points, {String target = 'sharer'}) => feed.handle(
    api.CanvasScreenAnnotation(
      channelId: 'call',
      userId: 'viewer',
      targetUserId: target,
      kind: 'stroke',
      annotationId: 'm1',
      points: points,
      color: 'annotation',
      ended: true,
      allowed: false,
    ),
  );

  Future<void> pump({bool readOnly = false}) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          screenAnnotationFeedProvider.overrideWithValue(feed),
          voiceParticipantsProvider.overrideWithValue(const [_me]),
          voiceFlagsProvider.overrideWithValue(
            const VoiceFlags(channelId: 'call'),
          ),
          syncControllerProvider.overrideWith((ref) => sync = _Sync(ref)),
        ],
        child: RepaintBoundary(
          key: snapshotBoundary,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: buildTheme(Brightness.dark, AppTokens.dark),
            home: Scaffold(
              body: Stack(
                children: [
                  Positioned.fromRect(
                    rect: _tile,
                    child: const ColoredBox(color: Color(0xFF20252B)),
                  ),
                  ScreenAnnotateLayer(
                    sharerId: readOnly ? 'me' : 'sharer',
                    sharerName: 'Ada',
                    tileRect: _tile,
                    zoom: zoom,
                    readOnly: readOnly,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<ByteData> paint() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(snapshotBoundary),
    );
    late ByteData bytes;
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      bytes = (await image.toByteData())!;
      image.dispose();
    });
    return bytes;
  }
}

int _red(ByteData bytes, double x, double y) =>
    bytes.getUint8((y.round() * 1280 + x.round()) * 4);

void main() {
  setUpAll(loadRealFonts);

  testWidgets('a circle drawn while zoomed lands on the video, not the tile', (
    tester,
  ) async {
    final rig = _Rig(tester)..allow();
    rig.zoom.zoomAt(2, Offset.zero);
    await rig.pump();

    await tester.tap(find.bySemanticsLabel("Circle something on Ada's screen"));
    await tester.pump();
    final gesture = await tester.startGesture(
      _tile.topLeft + const Offset(128, 72),
    );
    await tester.pump();
    await gesture.moveTo(_tile.topLeft + const Offset(640, 360));
    await gesture.up();
    await tester.pump(annotationFlushInterval);

    final shape = rig.sync.frames.lastWhere((f) => f.kind == 'shape');
    expect(shape.points[0], closeTo(0.1, 1e-9));
    expect(shape.points[1], closeTo(0.1, 1e-9));
    expect(shape.points[2], closeTo(0.5, 1e-9));
    expect(shape.points[3], closeTo(0.5, 1e-9));
  });

  testWidgets('a panned view maps through the moved picture', (tester) async {
    final rig = _Rig(tester)..allow();
    rig.zoom
      ..zoomAt(2, Offset.zero)
      ..panBy(const Offset(-0.5, -0.5));
    await rig.pump();

    await tester.tap(find.bySemanticsLabel("Circle something on Ada's screen"));
    await tester.pump();
    final gesture = await tester.startGesture(_tile.topLeft);
    await tester.pump();
    await gesture.moveTo(_tile.topLeft + const Offset(320, 180));
    await gesture.up();
    await tester.pump(annotationFlushInterval);

    final shape = rig.sync.frames.lastWhere((f) => f.kind == 'shape');
    expect(shape.points[0], closeTo(0.25, 1e-9));
    expect(shape.points[1], closeTo(0.25, 1e-9));
    expect(shape.points[2], closeTo(0.5, 1e-9));
    expect(shape.points[3], closeTo(0.5, 1e-9));
  });

  testWidgets('a mark is drawn where the zoomed video shows that point', (
    tester,
  ) async {
    final rig = _Rig(tester)..allow();
    rig.zoom.zoomAt(2, Offset.zero);
    await rig.pump();
    rig.mark([0.1, 0.25, 0.9, 0.25]);
    await tester.pump();

    final bytes = await rig.paint();
    expect(_red(bytes, _tile.left + 320, _tile.top + 180), greaterThan(200));
    expect(_red(bytes, _tile.left + 320, _tile.top + 90), lessThan(80));
    expect(_red(bytes, _tile.right + 20, _tile.top + 180), lessThan(80));
  });

  testWidgets('the sharer previews viewers marks with no pen and no consent', (
    tester,
  ) async {
    final rig = _Rig(tester);
    await rig.pump(readOnly: true);
    rig.mark([0.1, 0.5, 0.9, 0.5], target: 'me');
    await tester.pump();

    expect(find.bySemanticsLabel("Draw on Ada's screen"), findsNothing);
    final bytes = await rig.paint();
    expect(_red(bytes, _tile.left + 320, _tile.top + 180), greaterThan(200));
  });
}
