// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The first seconds of a call, as the timeline lines a call report carries.
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' show LogLevel;
import 'package:slimm_rtc/src/audio_glitch_watch.dart';
import 'package:slimm_rtc/src/join_audio_probe.dart';
import 'package:slimm_rtc/src/voice_models.dart';

class _Rig {
  final lines = <String>[];
  bool micWanted = true;
  bool deafened = false;
  String? engine = 'engine playout on, recording on';
  AudioSendSample? sent =
      const AudioSendSample(packetsSent: 142, audioLevel: 0.0312);
  Map<String, RemoteVoiceProbe> remotes = {
    'Ann': (
      blocked: null,
      playing: true,
      stats: () async =>
          const AudioReceiveSample(packetsReceived: 150, audioLevel: 0.012),
    ),
  };
  final engineChanges = StreamController<String>.broadcast();

  late final probe = JoinAudioProbe(
    JoinAudioProbeHost(
      local: () async => sent,
      remotes: () => remotes,
      micWanted: () => micWanted,
      deafened: () => deafened,
      engine: () => engine,
      note: (line, {level = LogLevel.info}) => lines.add(line),
    ),
    engineChanges: engineChanges.stream,
  );

  List<String> get checks =>
      lines.where((l) => l.startsWith('Audio check')).toList();
}

void main() {
  test('reads the audio 3s, 10s and 30s after connecting', () {
    fakeAsync((async) {
      final rig = _Rig()..probe.audioSession = () async => 'session x/y';
      rig.probe
        ..sync(VoiceSessionState.connecting)
        ..sync(VoiceSessionState.connected);

      async.elapse(const Duration(seconds: 2));
      expect(rig.checks, isEmpty);
      async.elapse(const Duration(seconds: 29));

      expect(rig.lines.take(2), ['Joining', 'Connected']);
      expect(rig.checks, [
        'Audio check (3s after connect): mic on | engine playout on, '
            'recording on | session x/y | sent 142 packets, level 0.031 | '
            'Ann: 150 packets in, level 0.012',
        startsWith('Audio check (10s after connect)'),
        startsWith('Audio check (30s after connect)'),
      ]);
    });
  });

  test('leaving stops the schedule and says so', () {
    fakeAsync((async) {
      final rig = _Rig();
      rig.probe
        ..sync(VoiceSessionState.connecting)
        ..sync(VoiceSessionState.connected);
      async.elapse(const Duration(seconds: 4));
      rig.probe.sync(VoiceSessionState.idle);

      expect(async.pendingTimers, isEmpty);
      async.elapse(const Duration(seconds: 60));
      expect(rig.checks, hasLength(1));
      expect(rig.lines.last, 'Left');
    });
  });

  test('an event is filed and the audio read right after it', () {
    fakeAsync((async) {
      final rig = _Rig()..probe.sync(VoiceSessionState.connecting);

      rig.probe.noteEvent('Audio route changed (category change)');
      async.flushMicrotasks();

      expect(rig.lines, [
        'Joining',
        'Audio route changed (category change)',
        startsWith('Audio check (after an event): mic on'),
      ]);
    });
  });

  test('a burst of events while one read runs collapses into one more', () {
    fakeAsync((async) {
      final gate = Completer<AudioSendSample?>();
      final rig = _Rig()..probe.sync(VoiceSessionState.connecting);
      var reads = 0;
      rig.probe.audioSession = () async {
        reads++;
        if (reads == 1) await gate.future;
        return null;
      };

      rig.probe
        ..noteEvent('one')
        ..noteEvent('two')
        ..noteEvent('three');
      async.flushMicrotasks();
      gate.complete(null);
      async.flushMicrotasks();

      expect(rig.checks, hasLength(2));
      expect(reads, 2);
    });
  });

  test('nothing is read before a call or after it ends', () {
    fakeAsync((async) {
      var reads = 0;
      final rig = _Rig()
        ..probe.audioSession = () async {
          reads++;
          return null;
        };
      rig.probe.noteEvent('before');
      async.flushMicrotasks();
      rig.probe
        ..sync(VoiceSessionState.connecting)
        ..sync(VoiceSessionState.failed)
        ..noteEvent('after');
      async.flushMicrotasks();

      expect(rig.checks, isEmpty);
      expect(reads, 0);
      expect(rig.lines, ['before', 'Joining', 'Failed', 'after']);
    });
  });

  test('says why a remote voice cannot be read, and when it is not played', () {
    fakeAsync((async) {
      final rig = _Rig()
        ..micWanted = false
        ..deafened = true
        ..engine = null
        ..sent = null
        ..remotes = {
          'Ann': (
            blocked: 'not subscribed',
            playing: false,
            stats: () async => null
          ),
          'Bob': (
            blocked: null,
            playing: false,
            stats: () async => const AudioReceiveSample(packetsReceived: 0),
          ),
          'Cy': (blocked: null, playing: true, stats: () async => null),
        };
      rig.probe
        ..sync(VoiceSessionState.connecting)
        ..noteEvent('x');
      async.flushMicrotasks();

      expect(
        rig.checks.single,
        'Audio check (after an event): mic off, deafened | no mic track | '
        'Ann: not subscribed | Bob: 0 packets in, level ?, playback off | '
        'Cy: no stats',
      );
    });
  });

  test('a stats read that throws leaves a gap, not a lost line', () {
    fakeAsync((async) {
      final rig = _Rig()
        ..remotes = {
          'Ann': (
            blocked: null,
            playing: true,
            stats: () async => throw StateError('closed'),
          ),
        };
      rig.probe
        ..sync(VoiceSessionState.connecting)
        ..noteEvent('x');
      async.flushMicrotasks();

      expect(rig.checks.single, endsWith('| Ann: no stats'));
    });
  });

  test('engine changes are filed only while a call is up', () {
    fakeAsync((async) {
      final rig = _Rig();
      rig.engineChanges.add('Audio engine playout on, recording off');
      async.flushMicrotasks();
      rig.probe.sync(VoiceSessionState.connecting);
      rig.engineChanges.add('Audio engine playout on, recording on');
      async.flushMicrotasks();
      rig.probe.sync(VoiceSessionState.idle);
      rig.engineChanges.add('Audio engine playout off, recording off');
      async.flushMicrotasks();

      expect(
        rig.lines.where((l) => l.startsWith('Audio engine')),
        ['Audio engine playout on, recording on'],
      );
    });
  });

  test('a toggle that did not take says so', () {
    fakeAsync((async) {
      final rig = _Rig()..probe.sync(VoiceSessionState.connecting);
      bool? result;
      unawaited(rig.probe
          .noteToggle('Deafen off', Future.value(false))
          .then((ok) => result = ok));
      async.flushMicrotasks();

      expect(result, isFalse);
      expect(rig.lines, contains('Deafen off did not take'));
    });
  });

  test('a toggle between calls is not filed on the last one', () {
    fakeAsync((async) {
      final rig = _Rig();
      rig.probe
        ..sync(VoiceSessionState.connecting)
        ..sync(VoiceSessionState.idle);
      unawaited(rig.probe.noteToggle('Mic off', Future.value(true)));
      async.flushMicrotasks();

      expect(rig.lines, ['Joining', 'Left']);
    });
  });
}
