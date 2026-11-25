// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A remote share opened full screen offers the same draw tools as the stage, and its marks reach the sharer.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/screen_overlay/providers/screen_annotation_feed.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/screen_annotation_sender.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/features/voice/widgets/fullscreen_video_overlay.dart';
import 'package:slimm_app/src/features/voice/widgets/screen_share_stage.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../support/fake_sync.dart';
import '../../support/fake_voice.dart';
import 'voice_controller_harness.dart';

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
    bool stamps = false,
  }) => frames.add((kind: kind, target: targetUserId, points: points));
}

const _pen = "Draw on Ada's screen";
const _penOn = 'Stop drawing on the screen';
const _layer = Key('fullscreen-annotate');
const _stage = Key('stage');

const _me = VoiceParticipant(
  identity: 'me',
  name: 'Me',
  isSpeaking: false,
  isMuted: false,
  isLocal: true,
  isScreenSharing: false,
);
const _ada = VoiceParticipant(
  identity: 'u-ada',
  name: 'Ada',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: true,
);

ScreenAnnotationFeed _feed({required bool allowed}) {
  final feed = ScreenAnnotationFeed(
    selfId: () => 'me',
    callChannelId: () => 'call',
    callMembers: () => const ['me', 'u-ada'],
  );
  if (allowed) {
    feed.handle(
      const api.CanvasScreenAnnotation(
        channelId: 'call',
        userId: 'u-ada',
        targetUserId: 'u-ada',
        kind: 'consent',
        points: [],
        ended: false,
        allowed: true,
        aspect: 16 / 9,
      ),
    );
  }
  return feed;
}

Future<void> _enter(WidgetTester tester) async {
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

Future<_Sync> _open(
  WidgetTester tester, {
  bool allowed = true,
  Size size = const Size(1400, 880),
  bool withStage = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  late _Sync sync;
  final container = ProviderContainer(
    overrides: [
      screenAnnotationFeedProvider.overrideWithValue(_feed(allowed: allowed)),
      voiceParticipantsProvider.overrideWithValue(const [_me, _ada]),
      voiceFlagsProvider.overrideWithValue(const VoiceFlags(channelId: 'call')),
      syncControllerProvider.overrideWith((ref) => sync = _Sync(ref)),
      voiceControllerProvider.overrideWith(
        (ref) => FakeVoiceController(
          ref,
          session: FakeSession(),
          initial: const VoiceState(
            channelId: 'call',
            state: VoiceSessionState.connected,
            participants: [_me, _ada],
          ),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  container.read(syncControllerProvider);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Builder(
          builder: (context) => Column(
            children: [
              TextButton(
                onPressed: () => showFullscreenVideo(
                  context,
                  identity: 'u-ada',
                  label: "Ada's screen",
                  kind: FullscreenVideoKind.screenShare,
                ),
                child: const Text('open'),
              ),
              if (withStage)
                const SizedBox(
                  width: 800,
                  height: 450,
                  child: ScreenShareStage(
                    key: _stage,
                    sharerName: 'Ada',
                    annotateSharerId: 'u-ada',
                    child: ColoredBox(color: Color(0xFF20252B)),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  if (!withStage) await _enter(tester);
  return sync;
}

void main() {
  testWidgets('a remote share full screen offers the pen', (tester) async {
    await _open(tester);
    expect(find.bySemanticsLabel(_pen), findsOneWidget);
  });

  testWidgets('without the sharer allowing it nothing is offered', (
    tester,
  ) async {
    await _open(tester, allowed: false);
    expect(find.byKey(_layer), findsOneWidget);
    expect(find.bySemanticsLabel(_pen), findsNothing);
  });

  testWidgets('the layer fills the whole full screen view', (tester) async {
    await _open(tester);
    expect(
      tester.getRect(find.byKey(_layer)),
      const Offset(0, 0) & const Size(1400, 880),
    );
  });

  testWidgets('a stroke in full screen goes to the sharer', (tester) async {
    final sync = await _open(tester);
    await tester.tap(find.bySemanticsLabel(_pen));
    await tester.pump();
    final gesture = await tester.startGesture(const Offset(700, 440));
    await tester.pump();
    await gesture.moveTo(const Offset(780, 485));
    await tester.pump(annotationFlushInterval);
    await gesture.up();
    await tester.pump(annotationFlushInterval);
    final strokes = sync.frames.where((f) => f.kind == 'stroke').toList();
    expect(strokes, isNotEmpty);
    expect(strokes.every((f) => f.target == 'u-ada'), isTrue);
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('at phone width the tools sit inside the screen above the dock', (
    tester,
  ) async {
    await _open(tester, size: const Size(390, 844));
    final pen = tester.getRect(find.bySemanticsLabel(_pen));
    expect(pen.left, greaterThanOrEqualTo(0));
    expect(pen.right, lessThanOrEqualTo(390));
    expect(pen.bottom, lessThanOrEqualTo(844 - 96));
    final close = tester.getRect(find.bySemanticsLabel('Exit full screen'));
    expect(pen.overlaps(close), isFalse);
  });

  testWidgets('the pen picked on the stage is still down in full screen', (
    tester,
  ) async {
    await _open(tester, withStage: true, size: const Size(1400, 1100));
    await tester.tap(find.bySemanticsLabel(_pen));
    await tester.pump();
    await _enter(tester);
    expect(find.bySemanticsLabel(_penOn), findsOneWidget);
  });

  testWidgets('putting the pen down in full screen puts it down on the stage', (
    tester,
  ) async {
    await _open(tester, withStage: true, size: const Size(1400, 1100));
    await tester.tap(find.bySemanticsLabel(_pen));
    await tester.pump();
    await _enter(tester);
    await tester.tap(find.bySemanticsLabel(_penOn));
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('Exit full screen'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.bySemanticsLabel(_pen), findsOneWidget);
    expect(find.bySemanticsLabel(_penOn), findsNothing);
  });
}
