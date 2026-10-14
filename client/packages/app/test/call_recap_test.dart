// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for [CallActivityTracker] and [CallRecap] in isolation: nothing
/// here drives a [VoiceController] or a real session, only the arithmetic
/// over a participant roster that a call recap is built from.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/call_recap.dart';
import 'package:slimm_rtc/rtc.dart';

VoiceParticipant _p(
  String identity,
  String name, {
  bool isLocal = false,
  bool isScreenSharing = false,
  bool isCameraOn = false,
}) => VoiceParticipant(
  identity: identity,
  name: name,
  isLocal: isLocal,
  isSpeaking: false,
  isMuted: false,
  isScreenSharing: isScreenSharing,
  isCameraOn: isCameraOn,
);

void main() {
  group('CallActivityTracker', () {
    test('a participant present throughout has no departure', () {
      final start = DateTime(2026, 1, 1, 12);
      var now = start;
      final tracker = CallActivityTracker(now: () => now);

      tracker.observe([_p('me', 'Me', isLocal: true), _p('alice', 'Alice')]);
      now = now.add(const Duration(minutes: 2));
      tracker.observe([_p('me', 'Me', isLocal: true), _p('alice', 'Alice')]);

      final recap = tracker.summary(
        channelId: 'channel-1',
        startedAt: start,
        endedAt: now,
      );

      expect(recap.others, hasLength(1));
      expect(recap.others.single.name, 'Alice');
      expect(recap.others.single.leftAt, isNull);
    });

    test('a participant who left before hang-up is recorded with when', () {
      final start = DateTime(2026, 1, 1, 12);
      var now = start;
      final tracker = CallActivityTracker(now: () => now);

      tracker.observe([_p('me', 'Me', isLocal: true), _p('bob', 'Bob')]);
      now = now.add(const Duration(minutes: 1));
      tracker.observe([_p('me', 'Me', isLocal: true)]);

      final recap = tracker.summary(
        channelId: 'channel-1',
        startedAt: start,
        endedAt: now.add(const Duration(minutes: 1)),
      );

      expect(recap.others.single.leftAt, now);
    });

    test('the local participant is never counted as "another" participant', () {
      final tracker = CallActivityTracker(now: DateTime.now);
      tracker.observe([_p('me', 'Me', isLocal: true)]);

      final recap = tracker.summary(
        channelId: 'channel-1',
        startedAt: DateTime.now(),
        endedAt: DateTime.now(),
      );

      expect(recap.others, isEmpty);
      expect(recap.wasAlone, isTrue);
    });

    test('reappearing after a departure clears it rather than duplicating', () {
      final start = DateTime(2026, 1, 1, 12);
      var now = start;
      final tracker = CallActivityTracker(now: () => now);

      tracker.observe([_p('me', 'Me', isLocal: true), _p('carol', 'Carol')]);
      now = now.add(const Duration(seconds: 30));
      tracker.observe([_p('me', 'Me', isLocal: true)]);
      now = now.add(const Duration(seconds: 30));
      tracker.observe([_p('me', 'Me', isLocal: true), _p('carol', 'Carol')]);

      final recap = tracker.summary(
        channelId: 'channel-1',
        startedAt: start,
        endedAt: now,
      );

      expect(recap.others, hasLength(1));
      expect(recap.others.single.leftAt, isNull);
    });

    test('screen sharing and camera use are cumulative, not a snapshot', () {
      final tracker = CallActivityTracker(now: DateTime.now);
      tracker.observe([_p('me', 'Me', isLocal: true, isScreenSharing: true)]);
      tracker.observe([_p('me', 'Me', isLocal: true, isScreenSharing: false)]);
      tracker.observe([_p('me', 'Me', isLocal: true, isCameraOn: true)]);

      final recap = tracker.summary(
        channelId: 'channel-1',
        startedAt: DateTime.now(),
        endedAt: DateTime.now(),
      );

      expect(
        recap.sharedScreen,
        isTrue,
        reason: 'shared at any point, even if stopped before hang-up',
      );
      expect(recap.usedCamera, isTrue);
    });

    test('reset clears every span, screen share and camera flag', () {
      final tracker = CallActivityTracker(now: DateTime.now);
      tracker.observe([
        _p('me', 'Me', isLocal: true, isScreenSharing: true, isCameraOn: true),
        _p('dan', 'Dan'),
      ]);

      tracker.reset();

      final recap = tracker.summary(
        channelId: 'channel-2',
        startedAt: DateTime.now(),
        endedAt: DateTime.now(),
      );
      expect(recap.others, isEmpty);
      expect(recap.sharedScreen, isFalse);
      expect(recap.usedCamera, isFalse);
    });
  });

  group('CallRecap.isWorthShowing', () {
    CallRecap recapOf({required Duration duration, required bool alone}) {
      final start = DateTime(2026, 1, 1);
      return CallRecap(
        channelId: 'channel-1',
        startedAt: start,
        endedAt: start.add(duration),
        others: alone
            ? const []
            : [
                CallParticipantActivity(
                  identity: 'alice',
                  name: 'Alice',
                  joinedAt: start,
                ),
              ],
        sharedScreen: false,
        usedCamera: false,
      );
    }

    test('a long call with someone else in it is worth showing', () {
      final recap = recapOf(duration: const Duration(minutes: 5), alone: false);
      expect(recap.isWorthShowing, isTrue);
    });

    test(
      'four minutes fifty-nine seconds is too short, five minutes is not',
      () {
        expect(
          recapOf(
            duration: const Duration(minutes: 4, seconds: 59),
            alone: false,
          ).isWorthShowing,
          isFalse,
        );
        expect(
          recapOf(
            duration: const Duration(minutes: 5),
            alone: false,
          ).isWorthShowing,
          isTrue,
        );
      },
    );

    test('a four-second mis-click is not worth showing', () {
      final recap = recapOf(duration: const Duration(seconds: 4), alone: false);
      expect(recap.isWorthShowing, isFalse);
    });

    test('a four-second solo mis-click is not worth showing either', () {
      final recap = recapOf(duration: const Duration(seconds: 4), alone: true);
      expect(recap.isWorthShowing, isFalse);
    });

    test('a long call spent entirely alone is still worth showing', () {
      final recap = recapOf(duration: const Duration(minutes: 10), alone: true);
      expect(
        recap.isWorthShowing,
        isTrue,
        reason:
            'testing a screen share or camera alone is a real use of '
            'the call, and its duration is worth reporting on its own',
      );
    });

    test('exactly the minimum duration counts as worth showing', () {
      final recap = recapOf(
        duration: CallRecap.minWorthwhileDuration,
        alone: false,
      );
      expect(recap.isWorthShowing, isTrue);
    });
  });
}
