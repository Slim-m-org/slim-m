// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A viewer's pen over a shared screen tile: offered only with the sharer's
/// consent, mapped to the shared screen past the letterbox, and faded on the
/// same clock the sharer's overlay uses. PNGs under SLIMM_UI_SNAPSHOTS=1.
library;

import 'dart:typed_data' show ByteData;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/widgets/screen_annotate_layer.dart';
import 'package:slimm_app/src/features/canvas/widgets/screen_annotate_toolbar.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/screen_annotation_board.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/screen_annotation_feed.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/screen_annotation_sender.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../support/fake_sync.dart';
import '../../ui_snapshot_support.dart';

class _Sync extends NoopSyncController {
  _Sync(super.ref);

  final frames =
      <
        ({
          String kind,
          List<double> points,
          String? text,
          bool ended,
          String target,
        })
      >[];

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
  }) => frames.add((
    kind: kind,
    points: points,
    text: text,
    ended: ended,
    target: targetUserId,
  ));
}

const _me = VoiceParticipant(
  identity: 'me',
  name: 'Me',
  isSpeaking: false,
  isMuted: false,
  isLocal: true,
  isScreenSharing: false,
);
const _sharer = VoiceParticipant(
  identity: 'sharer',
  name: 'Ada',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: true,
);

class _Rig {
  _Rig(this.tester);

  final WidgetTester tester;
  var now = DateTime(2026, 10, 28, 12);
  late final feed = ScreenAnnotationFeed(selfId: () => 'me', clock: () => now);
  late _Sync sync;

  void allow({double? aspect = 16 / 9}) => feed.handle(
    api.CanvasScreenAnnotation(
      channelId: 'call',
      userId: 'sharer',
      targetUserId: 'sharer',
      kind: 'consent',
      points: const [],
      ended: false,
      allowed: true,
      aspect: aspect,
    ),
  );

  void mark(
    String kind,
    List<double> points, {
    String id = 'm1',
    String? text,
    bool ended = true,
  }) => feed.handle(
    api.CanvasScreenAnnotation(
      channelId: 'call',
      userId: 'viewer-2',
      targetUserId: 'sharer',
      kind: kind,
      annotationId: id,
      points: points,
      color: 'annotation',
      text: text,
      ended: ended,
      allowed: false,
    ),
  );

  Future<void> pump({
    required Rect tile,
    Size view = const Size(1280, 800),
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.physicalSize = view;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final tokens = brightness == Brightness.light
        ? AppTokens.light
        : AppTokens.dark;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          screenAnnotationFeedProvider.overrideWithValue(feed),
          voiceParticipantsProvider.overrideWithValue(const [_me, _sharer]),
          voiceFlagsProvider.overrideWithValue(
            const VoiceFlags(channelId: 'call'),
          ),
          syncControllerProvider.overrideWith((ref) => sync = _Sync(ref)),
        ],
        child: RepaintBoundary(
          key: snapshotBoundary,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: buildTheme(brightness, tokens),
            home: Scaffold(
              body: Stack(
                children: [
                  Positioned.fromRect(
                    rect: tile,
                    child: const ColoredBox(color: Color(0xFF20252B)),
                  ),
                  ScreenAnnotateLayer(
                    sharerId: 'sharer',
                    sharerName: 'Ada',
                    tileRect: tile,
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
}

void main() {
  setUpAll(loadRealFonts);

  testWidgets('without the sharer allowing it there is no pen', (tester) async {
    final rig = _Rig(tester);
    await rig.pump(tile: const Rect.fromLTWH(100, 100, 640, 360));
    expect(find.byType(ScreenAnnotateToolbar), findsNothing);
  });

  testWidgets('an idle layer does not shrink the stack it sits in', (
    tester,
  ) async {
    final rig = _Rig(tester);
    await rig.pump(tile: const Rect.fromLTWH(100, 100, 640, 360));
    final stack = tester.getSize(
      find
          .descendant(of: find.byType(Scaffold), matching: find.byType(Stack))
          .first,
    );
    expect(stack, const Size(1280, 800));
  });

  testWidgets('with consent the pill offers pen, circle and note', (
    tester,
  ) async {
    final rig = _Rig(tester)..allow();
    await rig.pump(tile: const Rect.fromLTWH(100, 100, 640, 360));
    expect(find.byType(ScreenAnnotateToolbar), findsOneWidget);
    expect(find.bySemanticsLabel("Draw on Ada's screen"), findsOneWidget);
    expect(
      find.bySemanticsLabel("Circle something on Ada's screen"),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel("Put a note on Ada's screen"), findsOneWidget);
  });

  testWidgets('a tile too narrow for the pill leaves it out', (tester) async {
    final rig = _Rig(tester)..allow();
    await rig.pump(
      tile: const Rect.fromLTWH(10, 100, screenAnnotateMinTileWidth - 1, 120),
    );
    expect(find.byType(ScreenAnnotateToolbar), findsNothing);
  });

  testWidgets('the pen sends normalised points of the shared screen', (
    tester,
  ) async {
    final rig = _Rig(tester)..allow();
    const tile = Rect.fromLTWH(100, 100, 640, 360);
    await rig.pump(tile: tile);

    await tester.tap(find.bySemanticsLabel("Draw on Ada's screen"));
    await tester.pump();
    final gesture = await tester.startGesture(tile.center);
    await tester.pump();
    await gesture.moveTo(tile.center + const Offset(64, 36));
    await tester.pump(annotationFlushInterval);
    await gesture.up();
    await tester.pump(annotationFlushInterval);

    final strokes = rig.sync.frames.where((f) => f.kind == 'stroke').toList();
    final points = strokes.expand((f) => f.points).toList();
    expect(points.take(2), [0.5, 0.5]);
    expect(points[points.length - 2], closeTo(0.6, 1e-9));
    expect(points.last, closeTo(0.6, 1e-9));
    expect(strokes.last.ended, isTrue);
    expect(strokes.every((f) => f.target == 'sharer'), isTrue);
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('a tile taller than the screen maps through the letterbox', (
    tester,
  ) async {
    final rig = _Rig(tester)..allow();
    const tile = Rect.fromLTWH(100, 50, 640, 640);
    await rig.pump(tile: tile);

    await tester.tap(find.bySemanticsLabel("Draw on Ada's screen"));
    await tester.pump();
    // The 16:9 screen fills the middle 360 px of this square tile, from 140.
    final gesture = await tester.startGesture(
      tile.topLeft + const Offset(0, 140),
    );
    await tester.pump();
    await gesture.moveTo(tile.topLeft + const Offset(640, 500));
    await gesture.up();
    await tester.pump(annotationFlushInterval);

    final points = rig.sync.frames
        .where((f) => f.kind == 'stroke')
        .expand((f) => f.points)
        .toList();
    expect(points.take(2), [0.0, 0.0]);
    expect(points.skip(points.length - 2), [1.0, 1.0]);
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('a circle goes out as its two corners', (tester) async {
    final rig = _Rig(tester)..allow();
    const tile = Rect.fromLTWH(100, 100, 640, 360);
    await rig.pump(tile: tile);

    await tester.tap(find.bySemanticsLabel("Circle something on Ada's screen"));
    await tester.pump();
    final gesture = await tester.startGesture(
      tile.topLeft + const Offset(64, 36),
    );
    await tester.pump();
    await gesture.moveTo(tile.topLeft + const Offset(320, 180));
    await gesture.up();
    await tester.pump(annotationFlushInterval);

    final shape = rig.sync.frames.lastWhere((f) => f.kind == 'shape');
    expect(shape.ended, isTrue);
    expect(shape.points[0], closeTo(0.1, 1e-9));
    expect(shape.points[1], closeTo(0.1, 1e-9));
    expect(shape.points[2], closeTo(0.5, 1e-9));
    expect(shape.points[3], closeTo(0.5, 1e-9));
  });

  testWidgets('a note is typed where the tile was tapped', (tester) async {
    final rig = _Rig(tester)..allow();
    const tile = Rect.fromLTWH(100, 100, 640, 360);
    await rig.pump(tile: tile);

    await tester.tap(find.bySemanticsLabel("Put a note on Ada's screen"));
    await tester.pump();
    await tester.tapAt(tile.topLeft + const Offset(320, 180));
    await tester.pump();
    await tester.enterText(find.byType(EditableText), 'over here');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    final note = rig.sync.frames.single;
    expect(note.kind, 'note');
    expect(note.text, 'over here');
    expect(note.points, [0.5, 0.5]);
    expect(find.text('over here'), findsOneWidget);
  });

  testWidgets('marks from others fade out on the shared clock', (tester) async {
    final rig = _Rig(tester)..allow();
    await rig.pump(tile: const Rect.fromLTWH(100, 100, 640, 360));
    rig.mark('note', [0.2, 0.2], text: 'hello', id: 'n1');
    await tester.pump();
    expect(find.text('hello'), findsOneWidget);
    expect(
      tester
          .widget<Opacity>(
            find
                .ancestor(
                  of: find.text('hello'),
                  matching: find.byType(Opacity),
                )
                .first,
          )
          .opacity,
      1,
    );

    rig.now = rig.now.add(annotationNoteHold + annotationFade * 0.5);
    await tester.pump(const Duration(milliseconds: 16));
    expect(
      tester
          .widget<Opacity>(
            find
                .ancestor(
                  of: find.text('hello'),
                  matching: find.byType(Opacity),
                )
                .first,
          )
          .opacity,
      closeTo(0.5, 1e-6),
    );

    rig.now = rig.now.add(annotationFade);
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.text('hello'), findsNothing);
  });

  testWidgets('ink is painted where the screen point maps on the tile', (
    tester,
  ) async {
    final rig = _Rig(tester)..allow();
    const tile = Rect.fromLTWH(100, 100, 640, 360);
    await rig.pump(tile: tile);
    rig.mark('stroke', [0.1, 0.5, 0.9, 0.5]);
    await tester.pump();

    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(snapshotBoundary),
    );
    late ByteData bytes;
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      bytes = (await image.toByteData())!;
      image.dispose();
    });
    int alphaAt(double x, double y) {
      final index = (y.round() * 1280 + x.round()) * 4;
      return bytes.getUint8(index + 3);
    }

    int redAt(double x, double y) =>
        bytes.getUint8((y.round() * 1280 + x.round()) * 4);
    // Half way along the stroke, on the tile's middle row.
    expect(redAt(tile.left + 320, tile.top + 180), greaterThan(200));
    expect(alphaAt(tile.left + 320, tile.top + 180), 255);
    // Off the stroke, the tile's own backdrop shows.
    expect(redAt(tile.left + 320, tile.top + 120), lessThan(80));
  });

  testWidgets('losing the sharer consent puts the pen down', (tester) async {
    final rig = _Rig(tester)..allow();
    await rig.pump(tile: const Rect.fromLTWH(100, 100, 640, 360));
    await tester.tap(find.bySemanticsLabel("Draw on Ada's screen"));
    await tester.pump();
    expect(find.bySemanticsLabel('Stop drawing on the screen'), findsOneWidget);

    rig.feed.handle(
      const api.CanvasScreenAnnotation(
        channelId: 'call',
        userId: 'sharer',
        targetUserId: 'sharer',
        kind: 'consent',
        points: [],
        ended: false,
        allowed: false,
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byType(ScreenAnnotateToolbar), findsNothing);
  });

  const viewports = {
    'phone': (Size(390, 800), Rect.fromLTWH(15, 120, 360, 202)),
    'desktop': (Size(1280, 800), Rect.fromLTWH(160, 100, 800, 450)),
  };
  for (final viewport in viewports.entries) {
    for (final brightness in Brightness.values) {
      testWidgets(
        'pill and marks at ${viewport.key} ${brightness.name} lay out',
        (tester) async {
          final rig = _Rig(tester)..allow();
          await rig.pump(
            tile: viewport.value.$2,
            view: viewport.value.$1,
            brightness: brightness,
          );
          rig.mark('stroke', [
            0.1,
            0.8,
            0.3,
            0.3,
            0.5,
            0.7,
            0.7,
            0.2,
            0.9,
            0.6,
          ]);
          rig.mark('shape', [0.55, 0.45, 0.85, 0.9], id: 'm2');
          rig.mark('note', [0.1, 0.1], id: 'm3', text: 'look at this one');
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          final name = 'screen-annotate-${viewport.key}-${brightness.name}';
          await writeSnapshot(tester, name);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
