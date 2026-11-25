// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The canvas bar on a canvas channel: where the facepile sits, no close, Join call through the shared join, and the spectator's line.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_bar.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_engine.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_fullscreen.dart';
import 'package:slimm_app/src/features/channels/providers/channel_by_id_provider.dart';
import 'package:slimm_app/src/features/voice/providers/transcription_notice.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_elsewhere.dart';
import 'package:slimm_app/src/features/voice/providers/voice_roster.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../support/fake_voice.dart';
import 'canvas_pane_harness.dart';

const _settle = Duration(milliseconds: 400);

Channel _channel(String kind, {bool? voiceEnabled}) => Channel(
  id: 'c1',
  name: 'new-designs-MVP',
  kind: kind,
  createdAt: 0,
  position: 0,
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
  voiceEnabled: voiceEnabled,
);

class _Notice implements TranscriptionNoticeActions {
  const _Notice();

  @override
  Future<bool> isDue() async => true;

  @override
  Future<api.TranscriptionNotice?> dueNotice() async =>
      const api.TranscriptionNotice(
        mode: api.CallTranscriptionMode.always,
        acknowledged: false,
      );

  @override
  Future<void> acknowledge() async {}
}

class _Pane {
  _Pane(this.container);

  final ProviderContainer container;

  FakeVoiceController get voice =>
      container.read(voiceControllerProvider.notifier) as FakeVoiceController;
}

Future<_Pane> _pump(
  WidgetTester tester, {
  String kind = 'canvas',
  Size size = const Size(1280, 800),
  bool? voiceEnabled,
  int permissions = Perm.viewChannel | Perm.useCanvas,
  String? elsewhere,
  bool notice = false,
  bool withPeople = true,
  VoiceState? joinOutcome,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final fixture = CanvasPaneFixture(channelPermissions: permissions);
  final container = fixture.container(
    extraOverrides: [
      channelByIdProvider('c1').overrideWith(
        (ref) => Stream.value(_channel(kind, voiceEnabled: voiceEnabled)),
      ),
      voiceControllerProvider.overrideWith(
        (ref) =>
            FakeVoiceController(ref, recording: true, joinOutcome: joinOutcome),
      ),
      voiceElsewhereCheckProvider.overrideWithValue((_) async => elsewhere),
      if (notice)
        transcriptionNoticeActionsProvider.overrideWithValue(const _Notice()),
      voiceRosterProvider.overrideWith(
        (ref, id) => Stream.value(const [
          api.VoiceRosterParticipant(userId: 'u2', displayName: 'Ada'),
          api.VoiceRosterParticipant(userId: 'u3', displayName: 'Bo'),
        ]),
      ),
    ],
  );
  addTearDown(container.dispose);
  addTearDown(fixture.events.close);
  await pumpCanvasPane(tester, container);
  if (withPeople) {
    container.read(canvasEngineProvider('c1').notifier).cursors
      ..upsert(id: 'u2', x: 500, y: 300, label: 'Ada', colorIndex: 1)
      ..upsert(id: 'u3', x: 900, y: 500, label: 'Bo', colorIndex: 2);
  }
  await tester.pump(_settle);
  return _Pane(container);
}

Rect _bar(WidgetTester tester) => tester.getRect(_of<CanvasBar>());

Finder get _facepile => find.byTooltip('People here');

/// Every screen-reader announcement made while the test runs.
List<String> _announcements(WidgetTester tester) {
  final heard = <String>[];
  tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<Object?>(
    SystemChannels.accessibility,
    (message) async {
      final map = message as Map<Object?, Object?>?;
      if (map?['type'] == 'announce') {
        heard.add(
          (map!['data'] as Map<Object?, Object?>)['message']! as String,
        );
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger
        .setMockDecodedMessageHandler<Object?>(
          SystemChannels.accessibility,
          null,
        ),
  );
  return heard;
}

/// A widget located by its type through a predicate, the repo's way past the find.byType ceiling.
Finder _of<T extends Widget>() => find.byWidgetPredicate((w) => w is T);

void main() {
  group('the facepile', () {
    for (final (kind, noun) in [
      ('canvas', 'canvas channel'),
      ('voice', 'voice canvas'),
    ]) {
      for (final width in [900.0, 1280.0]) {
        testWidgets('sits in the bar of a $noun at $width', (tester) async {
          await _pump(tester, kind: kind, size: Size(width, 800));

          final pill = tester.getRect(_facepile);
          expect(_bar(tester).contains(pill.center), isTrue);
          expect(find.byTooltip('People here'), findsOneWidget);
        });
      }

      testWidgets('stays in the readout of a $noun at 390', (tester) async {
        await _pump(tester, kind: kind, size: const Size(390, 844));

        expect(
          tester.getRect(_facepile).top,
          greaterThanOrEqualTo(_bar(tester).bottom),
        );
      });

      testWidgets('returns to the readout of a $noun in fullscreen', (
        tester,
      ) async {
        final pane = await _pump(tester, kind: kind);
        expect(_bar(tester).contains(tester.getRect(_facepile).center), isTrue);

        pane.container.read(canvasFullscreenProvider.notifier).state = 'c1';
        await tester.pump(_settle);

        expect(_of<CanvasBar>(), findsNothing);
        expect(tester.getRect(_facepile).top, lessThan(120));
        expect(find.byTooltip('People here'), findsOneWidget);
      });
    }

    testWidgets('its list opens inside the window from the right of the bar', (
      tester,
    ) async {
      await _pump(tester);

      await tester.tap(_facepile);
      await tester.pump(_settle);

      final list = tester.getRect(find.text('Ada'));
      expect(list.right, lessThanOrEqualTo(tester.view.physicalSize.width));
      expect(list.left, greaterThanOrEqualTo(0));
      expect(find.text('Ada'), findsOneWidget);
    });

    testWidgets('moves to the readout when a short window hides the bar', (
      tester,
    ) async {
      await _pump(tester, size: const Size(1280, 420));

      expect(_of<CanvasBar>(), findsNothing);
      expect(find.byTooltip('People here'), findsOneWidget);
    });
  });

  group('no way to close a canvas channel', () {
    for (final width in [390.0, 1280.0]) {
      testWidgets('at $width a canvas channel has no close', (tester) async {
        await _pump(tester, size: Size(width, 844));
        expect(find.bySemanticsLabel('Close canvas'), findsNothing);
        expect(find.byTooltip('Close canvas'), findsNothing);
      });

      testWidgets('at $width a voice canvas still closes', (tester) async {
        await _pump(tester, kind: 'voice', size: Size(width, 844));
        expect(find.bySemanticsLabel('Close canvas'), findsOneWidget);
      });
    }
  });

  group('Join call', () {
    testWidgets('shows in the bar only for a canvas channel with a call', (
      tester,
    ) async {
      await _pump(tester, voiceEnabled: true);
      final join = tester.getRect(find.text('Join call'));
      expect(_bar(tester).contains(join.center), isTrue);
    });

    testWidgets('is absent without a call, and on a voice canvas', (
      tester,
    ) async {
      await _pump(tester, voiceEnabled: false);
      expect(find.text('Join call'), findsNothing);
    });

    testWidgets('a voice canvas has the call stage, not this button', (
      tester,
    ) async {
      await _pump(tester, kind: 'voice');
      expect(find.text('Join call'), findsNothing);
    });

    testWidgets('is gone once in the call', (tester) async {
      final pane = await _pump(tester, voiceEnabled: true);
      pane.voice.connect();
      await tester.pump(_settle);
      expect(find.text('Join call'), findsNothing);
    });

    testWidgets('joins and stays on the board', (tester) async {
      final pane = await _pump(tester, voiceEnabled: true);

      await tester.tap(find.text('Join call'));
      await tester.pump(_settle);

      expect(pane.voice.joins, ['c1']);
      expect(_of<CanvasBar>(), findsOneWidget);
      expect(find.text('Join call'), findsNothing);
    });

    testWidgets('announces the join once it is up, on a plain join', (
      tester,
    ) async {
      final heard = _announcements(tester);
      await _pump(tester, voiceEnabled: true);

      await tester.tap(find.text('Join call'));
      await tester.pump(_settle);

      expect(heard, ['Joined the call']);
    });

    testWidgets('announces the join after Join here, not before', (
      tester,
    ) async {
      final heard = _announcements(tester);
      final pane = await _pump(tester, voiceEnabled: true, elsewhere: 'other');

      await tester.tap(find.text('Join call'));
      await tester.pump(_settle);
      expect(heard, isEmpty);

      await tester.tap(find.text('Join here'));
      await tester.pump(_settle);
      expect(pane.voice.joins, ['c1']);
      expect(heard, ['Joined the call']);
    });

    testWidgets('says nothing when Join here is declined', (tester) async {
      final heard = _announcements(tester);
      final pane = await _pump(tester, voiceEnabled: true, elsewhere: 'other');

      await tester.tap(find.text('Join call'));
      await tester.pump(_settle);
      await tester.tap(find.text('Cancel'));
      await tester.pump(_settle);

      expect(pane.voice.joins, isEmpty);
      expect(heard, isEmpty);
    });

    testWidgets('says nothing when the join fails', (tester) async {
      final heard = _announcements(tester);
      final pane = await _pump(
        tester,
        voiceEnabled: true,
        elsewhere: 'other',
        joinOutcome: const VoiceState(
          state: VoiceSessionState.failed,
          channelId: 'c1',
          error: 'Connection lost.',
        ),
      );

      await tester.tap(find.text('Join call'));
      await tester.pump(_settle);
      await tester.tap(find.text('Join here'));
      await tester.pump(_settle);

      expect(pane.voice.joins, ['c1']);
      expect(heard, isEmpty);
    });

    testWidgets('leaving the call keeps the board', (tester) async {
      final pane = await _pump(tester, voiceEnabled: true);
      await tester.tap(find.text('Join call'));
      await tester.pump(_settle);

      pane.voice.hangUp();
      await tester.pump(_settle);

      expect(_of<CanvasBar>(), findsOneWidget);
      expect(find.text('Join call'), findsOneWidget);
    });

    testWidgets('asks first when the call is open on another device', (
      tester,
    ) async {
      final pane = await _pump(tester, voiceEnabled: true, elsewhere: 'other');

      await tester.tap(find.text('Join call'));
      await tester.pump(_settle);
      expect(pane.voice.joins, isEmpty);
      expect(find.text('Join here'), findsOneWidget);

      await tester.tap(find.text('Join here'));
      await tester.pump(_settle);
      expect(pane.voice.joins, ['c1']);
    });

    testWidgets('shows the transcription notice before joining', (
      tester,
    ) async {
      final pane = await _pump(tester, voiceEnabled: true, notice: true);

      await tester.tap(find.text('Join call'));
      await tester.pump(_settle);
      expect(find.text('Calls in this Space are transcribed'), findsOneWidget);
      expect(pane.voice.joins, isEmpty);

      await tester.tap(find.text('Join'));
      await tester.pump(_settle);
      expect(pane.voice.joins, ['c1']);
    });

    testWidgets('a phone gets a touch-sized icon naming who is in the call', (
      tester,
    ) async {
      final pane = await _pump(
        tester,
        size: const Size(390, 844),
        voiceEnabled: true,
      );

      final join = find.bySemanticsLabel('Join call, 2 in the call');
      expect(join, findsOneWidget);
      final rect = tester.getRect(join);
      expect(rect.width, greaterThanOrEqualTo(44));
      expect(rect.height, greaterThanOrEqualTo(44));
      expect(_bar(tester).contains(rect.center), isTrue);

      await tester.tap(join);
      await tester.pump(_settle);
      expect(pane.voice.joins, ['c1']);
    });
  });

  group('a spectator', () {
    testWidgets(
      'gets no tools and one line saying the board is theirs to watch',
      (tester) async {
        await _pump(tester, permissions: Perm.viewChannel);

        expect(find.text('You can view this canvas.'), findsOneWidget);
        expect(find.bySemanticsLabel('Pen'), findsNothing);

        await tester.pump(const Duration(seconds: 7));
        expect(find.text('You can view this canvas.'), findsNothing);
      },
    );

    testWidgets('a member who may draw is not told', (tester) async {
      await _pump(tester);
      expect(find.text('You can view this canvas.'), findsNothing);
    });

    testWidgets('a voice canvas viewer is not told either', (tester) async {
      await _pump(tester, kind: 'voice', permissions: Perm.viewChannel);
      expect(find.text('You can view this canvas.'), findsNothing);
    });
  });
}
