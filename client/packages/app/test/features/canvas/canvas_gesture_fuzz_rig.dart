// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The real canvas pane, a call roster, a seeded board and recorders for the ephemeral frames it sends, shared by the gesture fuzz suites.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/members/providers/blocks_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../support/fake_blocks.dart';
import '../../support/fake_sync.dart';
import '../voice/voice_controller_harness.dart';
import 'canvas_pane_harness.dart';

/// Every ephemeral frame the pane tried to send, by what it was for.
class RecordedFrames {
  final strokePreviews = <({String id, bool ended})>[];
  final objectPreviews = <({String id, bool ended})>[];
}

class _RecordingSync extends NoopSyncController {
  _RecordingSync(super.ref, this.frames);

  final RecordedFrames frames;

  @override
  void notifyCanvasStrokePreview(
    String channelId,
    String objectId,
    List<double> points, {
    bool ended = false,
    String? color,
    double? width,
  }) => frames.strokePreviews.add((id: objectId, ended: ended));

  @override
  void notifyCanvasObjectPreview(
    String channelId,
    String objectId,
    ({double x, double y, double w, double h}) box, {
    bool ended = false,
  }) => frames.objectPreviews.add((id: objectId, ended: ended));
}

// Not 'me': the shared fixture answers any path ending in /me with the profile.
const _me = VoiceParticipant(
  identity: 'user-me',
  name: 'Me',
  isSpeaking: false,
  isMuted: false,
  isLocal: true,
  isScreenSharing: false,
  isCameraOn: true,
);

const _noor = VoiceParticipant(
  identity: 'user-noor',
  name: 'Noor',
  // Silent: the dock roster's speaking ring pulses for as long as anyone talks, so pumpAndSettle would never settle.
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
  isCameraOn: true,
);

const _avery = VoiceParticipant(
  identity: 'user-avery',
  name: 'Avery',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: true,
);

const _lee = VoiceParticipant(
  identity: 'user-lee',
  name: 'Lee',
  isSpeaking: false,
  isMuted: true,
  isLocal: false,
  isScreenSharing: false,
);

Map<String, dynamic> _box(
  String id,
  String kind,
  Map<String, dynamic> props, {
  required double x,
  required double y,
  required double w,
  required double h,
  required int seq,
  required String author,
}) => {
  'id': id,
  'kind': kind,
  'z_index': seq,
  'x': x,
  'y': y,
  'w': w,
  'h': h,
  'props': props,
  'author_id': author,
  'seq': seq,
  'created_at': 0,
};

/// A spread of every object kind, mine and other people's, over the board.
List<Map<String, dynamic>> seededBoard() => [
  _box(
    's1',
    'stroke',
    {
      'points': [0.0, 0.0, 150.0, 90.0, 300.0, 0.0],
      'width': 3.0,
      'color': 'annotation',
    },
    x: 200,
    y: 200,
    w: 300,
    h: 90,
    seq: 1,
    author: 'me',
  ),
  _box(
    's2',
    'stroke',
    {
      'points': [0.0, 0.0, 100.0, 100.0, 200.0, 0.0, 300.0, 100.0],
      'width': 3.0,
      'color': 'annotation',
    },
    x: 700,
    y: 650,
    w: 300,
    h: 100,
    seq: 2,
    author: 'other',
  ),
  _box(
    'n1',
    'note',
    {'text': 'first note'},
    x: 900,
    y: 300,
    w: 220,
    h: 140,
    seq: 3,
    author: 'me',
  ),
  _box(
    'n2',
    'note',
    {'text': 'their note'},
    x: 1400,
    y: 150,
    w: 220,
    h: 140,
    seq: 4,
    author: 'other',
  ),
  _box(
    'r1',
    'shape',
    {'shape': 'rectangle'},
    x: 1200,
    y: 600,
    w: 300,
    h: 200,
    seq: 5,
    author: 'me',
  ),
  _box(
    'e1',
    'shape',
    {'shape': 'ellipse'},
    x: 300,
    y: 600,
    w: 240,
    h: 180,
    seq: 6,
    author: 'other',
  ),
  // Legacy content from before the board existed: wholly outside it, so the clip hides it.
  _box(
    'x1',
    'note',
    {'text': 'above the board'},
    x: 800,
    y: -500,
    w: 300,
    h: 150,
    seq: 8,
    author: 'me',
  ),
  _box(
    'x2',
    'stroke',
    {
      'points': [0.0, 0.0, 200.0, 60.0, 400.0, 0.0],
      'width': 3.0,
      'color': 'annotation',
    },
    x: 400,
    y: 1250,
    w: 400,
    h: 60,
    seq: 9,
    author: 'me',
  ),
  _box(
    'i1',
    'image',
    {'attachment': 'sha-i1', 'content_type': 'image/png'},
    x: 500,
    y: 350,
    w: 260,
    h: 200,
    seq: 7,
    author: 'me',
  ),
];

/// The pane mounted at a desktop or phone width, with handles to everything
/// a fuzz run needs to observe.
class FuzzRig {
  FuzzRig._(this.tester, this.fixture, this.container, this.frames, this.phone);

  final WidgetTester tester;
  final CanvasPaneFixture fixture;
  final ProviderContainer container;
  final RecordedFrames frames;
  final bool phone;

  CanvasDocument get document => surfaceDocument(tester);

  /// Ids a live event may later remove or move.
  final knownIds = <String>[for (final o in seededBoard()) o['id'] as String];

  int liveSeq = seededBoard().length;

  static Future<FuzzRig> start(
    WidgetTester tester, {
    required bool phone,
    List<Map<String, dynamic>>? board,
    Duration placeDelay = Duration.zero,
  }) async {
    tester.view.physicalSize = phone
        ? const Size(390, 844)
        : const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fixture = CanvasPaneFixture(placeDelay: placeDelay)
      ..objects = board ?? seededBoard();
    final frames = RecordedFrames();
    final container = fixture.container(
      extraOverrides: [
        syncControllerProvider.overrideWith(
          (ref) => _RecordingSync(ref, frames),
        ),
        voiceControllerProvider.overrideWith(
          (ref) => FixedVoiceController(
            ref,
            const VoiceState(
              state: VoiceSessionState.connected,
              channelId: 'c1',
              participants: [_me, _noor, _avery, _lee],
            ),
          ),
        ),
        blocksProvider.overrideWith(
          (ref) => FixedBlocksController(ref, const BlocksState()),
        ),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container, board: true, tool: null);
    // Registered after the container's, so it runs first and unmounts the pane while the container is alive.
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpAndSettle();
    return FuzzRig._(tester, fixture, container, frames, phone);
  }

  /// Unmounts the pane while its container is alive, as the app does; disposing the container first makes the engine's dispose throw and hides the failure under test.
  Future<void> close() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 8));
  }

  Rect get surfaceRect => tester.getRect(find.byType(CanvasSurface));

  CanvasTool get tool =>
      tester.widget<CanvasSurface>(find.byType(CanvasSurface)).tool;

  /// Where a world point is on screen under the camera as it is now.
  Offset toScreen(Offset world) {
    final camera = document.camera;
    return surfaceRect.topLeft +
        Offset(
          (world.dx - camera.x) * camera.zoom,
          (world.dy - camera.y) * camera.zoom,
        );
  }

  Rect get boardOnScreen => Rect.fromPoints(
    toScreen(canvasBoard.topLeft),
    toScreen(canvasBoard.bottomRight),
  );

  /// The floating dock cards, which sit above the drawing surface.
  List<Rect> dockRects(Type card) => [
    for (final e in find.byType(card).evaluate())
      tester.getRect(find.byWidget(e.widget)),
  ];

  /// The painters the surface mounts, which the draft checks read.
  Iterable<Object> surfacePainters() => tester
      .widgetList<CustomPaint>(
        find.descendant(
          of: find.byType(CanvasSurface),
          matching: find.byType(CustomPaint),
        ),
      )
      .map((paint) => paint.painter)
      .whereType<Object>();

  NavigatorState get navigator =>
      tester.state<NavigatorState>(find.byType(Navigator).first);
}
