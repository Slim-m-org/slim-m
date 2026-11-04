// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A viewer in a plain voice channel draws on the share stage, not only on a canvas tile.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/screen_overlay/providers/screen_annotation_feed.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/screen_annotation_sender.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/features/voice/widgets/screen_share_stage.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../support/fake_sync.dart';

class _Sync extends NoopSyncController {
  _Sync(super.ref);

  final frames = <({String kind, String target, List<double> points})>[];

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
  }) => frames.add((kind: kind, target: targetUserId, points: points));
}

const _stageKey = Key('stage');
const _pen = "Draw on Ada's screen";

const _me = VoiceParticipant(
  identity: 'me',
  name: 'Me',
  isSpeaking: false,
  isMuted: false,
  isLocal: true,
  isScreenSharing: false,
);

Future<_Sync> _pump(
  WidgetTester tester, {
  required bool allowed,
  String? sharerId = 'sharer',
}) async {
  final feed = ScreenAnnotationFeed(selfId: () => 'me');
  if (allowed) {
    feed.handle(
      const api.CanvasScreenAnnotation(
        channelId: 'call',
        userId: 'sharer',
        targetUserId: 'sharer',
        kind: 'consent',
        points: [],
        ended: false,
        allowed: true,
        aspect: 16 / 9,
      ),
    );
  }
  late _Sync sync;
  final container = ProviderContainer(
    overrides: [
      screenAnnotationFeedProvider.overrideWithValue(feed),
      voiceParticipantsProvider.overrideWithValue(const [_me]),
      voiceFlagsProvider.overrideWithValue(const VoiceFlags(channelId: 'call')),
      syncControllerProvider.overrideWith((ref) => sync = _Sync(ref)),
    ],
  );
  addTearDown(container.dispose);
  container.read(syncControllerProvider);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 800,
              height: 450,
              child: ScreenShareStage(
                key: _stageKey,
                sharerName: 'Ada',
                annotateSharerId: sharerId,
                child: const ColoredBox(color: Color(0xFF20252B)),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return sync;
}

void main() {
  testWidgets('with the sharer allowing it the stage offers the pen', (
    tester,
  ) async {
    await _pump(tester, allowed: true);
    expect(find.bySemanticsLabel(_pen), findsOneWidget);
  });

  testWidgets('without consent the stage offers nothing', (tester) async {
    await _pump(tester, allowed: false);
    expect(find.bySemanticsLabel(_pen), findsNothing);
  });

  testWidgets('a local share never offers the pen', (tester) async {
    await _pump(tester, allowed: true, sharerId: null);
    expect(find.bySemanticsLabel(_pen), findsNothing);
  });

  testWidgets('a stroke on the stage goes to the sharer', (tester) async {
    final sync = await _pump(tester, allowed: true);
    await tester.tap(find.bySemanticsLabel(_pen));
    await tester.pump();
    final stage = tester.getRect(find.byKey(_stageKey));
    final gesture = await tester.startGesture(stage.center);
    await tester.pump();
    await gesture.moveTo(stage.center + const Offset(80, 45));
    await tester.pump(annotationFlushInterval);
    await gesture.up();
    await tester.pump(annotationFlushInterval);

    final strokes = sync.frames.where((f) => f.kind == 'stroke').toList();
    expect(strokes, isNotEmpty);
    expect(strokes.every((f) => f.target == 'sharer'), isTrue);
    expect(strokes.expand((f) => f.points).last, closeTo(0.6, 1e-9));
    await tester.pump(const Duration(seconds: 6));
  });
}
