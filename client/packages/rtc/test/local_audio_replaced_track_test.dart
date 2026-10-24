// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A listener's volume must reach a track however it arrives: late, replaced
/// under the same Dart object, rejoined, or refused at first by the platform.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_api/api.dart' show LogLevel;
import 'package:slimm_rtc/rtc.dart';

import 'support/fake_audio_track.dart';

class _Remote extends Fake implements lk.RemoteParticipant {
  _Remote(this.identity);

  @override
  final String identity;
}

class _Pub extends Fake implements lk.RemoteTrackPublication {}

class _Trk extends Fake implements lk.RemoteAudioTrack {}

LocalAudioState _state() => LocalAudioState(
      retryDelays: const [
        Duration(milliseconds: 5),
        Duration(milliseconds: 10),
        Duration(milliseconds: 20),
      ],
    );

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 150));

void main() {
  for (final channel in LocalAudioChannel.values) {
    group('${channel.name} audio', () {
      FakeAudioTrack track() => FakeAudioTrack('maya', channel: channel);

      test('a volume set before the track arrives applies when it does',
          () async {
        final state = _state()..setVolumeFor('maya', 0.6, channel: channel);
        await pumpAudioEvents(state, []);
        expect(state.pending, contains(('maya', channel)));

        final arrived = track();
        await pumpAudioEvents(state, [arrived]);

        expect(arrived.volume, closeTo(0.6, 1e-9));
        expect(state.pending, isEmpty);
      });

      test('a native receiver replaced under the same object gets the gain',
          () async {
        final state = _state()..setVolumeFor('maya', 1.5, channel: channel);
        final t = track();
        await pumpAudioEvents(state, [t], times: 3);

        t.replaceNativeKeepingObject();
        state.trackReplaced('maya');
        await pumpAudioEvents(state, [t]);

        expect(t.volume, closeTo(1.5, 1e-9));
      });

      test('a reconnect forgets everyone, not just one person', () async {
        final state = _state()..setVolumeFor('maya', 1.5, channel: channel);
        final t = track();
        await pumpAudioEvents(state, [t]);

        t.replaceNativeKeepingObject();
        state.trackReplaced(everyone);
        await pumpAudioEvents(state, [t]);

        expect(t.volume, closeTo(1.5, 1e-9));
      });

      test('a changed native track id is never trusted as applied', () async {
        final state = _state()..setVolumeFor('maya', 1.5, channel: channel);
        final t = track();
        await pumpAudioEvents(state, [t]);

        t.replaceNativeKeepingObject();
        t.nativeId = 'maya-2';
        await pumpAudioEvents(state, [t]);

        expect(t.volume, closeTo(1.5, 1e-9));
      });

      test('a rejoin under a new sid gets the stored gain', () async {
        final state = _state()..setVolumeFor('maya', 0.4, channel: channel);
        await pumpAudioEvents(state, [track()]);

        final rejoined = track()..nativeId = 'maya-new-sid';
        await pumpAudioEvents(state, [rejoined]);

        expect(rejoined.volume, closeTo(0.4, 1e-9));
      });

      test('moving the slider pushes even when the cache already agrees',
          () async {
        final state = _state()..setVolumeFor('maya', 1.5, channel: channel);
        final t = track();
        await pumpAudioEvents(state, [t]);

        t.replaceNativeKeepingObject();
        state.setVolumeFor('maya', 1.5, channel: channel);
        await pumpAudioEvents(state, [t]);

        expect(t.volume, closeTo(1.5, 1e-9));
      });

      test('a failed push is retried until it lands', () async {
        final state = _state()..setVolumeFor('maya', 1.5, channel: channel);
        final t = track()..failVolumeTimes = 2;

        await pumpAudioEvents(state, [t]);
        expect(state.failureFor('maya', channel: channel), isNotNull);
        await _settle();

        expect(t.volume, closeTo(1.5, 1e-9));
        expect(state.failureFor('maya', channel: channel), isNull);
        state.cancelRetry();
      });
    });
  }

  test('a persistent failure stops retrying and says so in the log', () async {
    final lines = <String>[];
    final state = _state();
    state.log = (message, {LogLevel level = LogLevel.debug}) {
      lines.add('$level $message');
    };
    state.setVolumeFor('maya', 1.5);
    final t = FakeAudioTrack('maya')..failVolumeTimes = 1000;

    await pumpAudioEvents(state, [t]);
    await _settle();
    final calls = t.volumeCalls;
    await _settle();

    expect(calls, 4, reason: 'one pass plus the three scheduled retries');
    expect(t.volumeCalls, calls, reason: 'then it waits for a room event');
    expect(lines.where((l) => l.contains('still failing')), hasLength(1));

    t.failVolumeTimes = 0;
    await pumpAudioEvents(state, [t]);
    expect(t.volume, closeTo(1.5, 1e-9), reason: 'the next event retries');
  });

  group('audioReplacedBy', () {
    test('names the person whose tracks a room event touched', () {
      final maya = _Remote('maya');
      expect(
        audioReplacedBy(lk.TrackSubscribedEvent(
            participant: maya, publication: _Pub(), track: _Trk())),
        'maya',
      );
      expect(
        audioReplacedBy(lk.ParticipantConnectedEvent(participant: maya)),
        'maya',
      );
      expect(
        audioReplacedBy(
            lk.TrackMutedEvent(participant: maya, publication: _Pub())),
        'maya',
      );
      expect(audioReplacedBy(const lk.RoomReconnectedEvent()), everyone);
      expect(audioReplacedBy(const lk.RoomResumingEvent()), everyone);
    });

    test('ignores events that cannot replace audio', () {
      expect(
        audioReplacedBy(lk.ParticipantMetadataUpdatedEvent(
            participant: _Remote('maya'), metadata: 'x')),
        isNull,
      );
    });
  });
}
