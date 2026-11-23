// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A second microphone publication, which a restart's republish racing a
/// recovery can leave, never stays live behind a mute; nor does a track a
/// failed republish left running with no publication at all.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/rtc.dart';

class _Track extends Fake implements lk.LocalAudioTrack {
  int stops = 0;

  @override
  lk.TrackProcessor? processor = _Processor();

  @override
  Future<bool> stop() async {
    stops++;
    return true;
  }
}

/// The browser's capture chain stands behind a web microphone this way.
class _Processor extends Fake
    implements lk.TrackProcessor<lk.AudioProcessorOptions> {
  int destroys = 0;

  @override
  Future<void> destroy() async => destroys++;
}

class _Publication extends Fake
    implements lk.LocalTrackPublication<lk.LocalAudioTrack> {
  _Publication(this.sid);

  @override
  final String sid;

  @override
  final _Track track = _Track();

  @override
  bool muted = false;

  @override
  lk.TrackSource get source => lk.TrackSource.microphone;

  @override
  Future<void> mute({bool stopOnMute = true}) async => muted = true;
}

class _Me extends Fake implements lk.LocalParticipant {
  final publications = <_Publication>[];
  final removed = <(String, bool)>[];

  @override
  List<lk.LocalTrackPublication<lk.LocalAudioTrack>>
      get audioTrackPublications => List.of(publications);

  /// What livekit does: it acts on the first microphone publication only.
  @override
  Future<lk.LocalTrackPublication?> setMicrophoneEnabled(
    bool enabled, {
    lk.AudioCaptureOptions? audioCaptureOptions,
  }) async {
    final first = publications.isEmpty ? null : publications.first;
    first?.muted = !enabled;
    return first;
  }

  @override
  Future<void> removePublishedTrack(String trackSid,
      {bool notify = true}) async {
    publications.removeWhere((p) => p.sid == trackSid);
    removed.add((trackSid, notify));
  }
}

class _Room extends Fake implements lk.Room {
  _Room(this.localParticipant);

  @override
  final lk.LocalParticipant localParticipant;
}

void main() {
  late _Me me;
  late LiveKitMicPort port;
  late _Publication first;
  late _Publication second;

  setUp(() {
    me = _Me();
    final room = _Room(me);
    port = LiveKitMicPort(() => room);
    first = _Publication('first');
    second = _Publication('second');
    me.publications.addAll([first, second]);
  });

  test('a mute reaches every published microphone', () async {
    await port.setEnabled(false, const lk.AudioCaptureOptions());

    expect(first.muted, isTrue);
    expect(second.muted, isTrue,
        reason: 'a second microphone left unmuted keeps sending while muted');
    expect(port.open, isFalse);
  });

  test('a second microphone publication is removed, keeping the first',
      () async {
    port.onRoomEvent(lk.LocalTrackPublishedEvent(
      participant: me,
      publication: second,
    ));
    await pumpEventQueue();

    expect(me.publications, [first]);
    expect(me.removed, [('second', false)],
        reason: 'the extra is dropped quietly, not reported as a lost mic');
  });

  test('releasing and discarding reach every published microphone', () async {
    await port.release();

    expect(first.track.stops, 1);
    expect(second.track.stops, 1);
    // livekit leaves a processor's output track running after stop.
    expect((first.track.processor! as _Processor).destroys, 1);
    expect((second.track.processor! as _Processor).destroys, 1);

    await port.discard();

    expect(me.publications, isEmpty);
    expect(port.hasTrack, isFalse);
  });

  test('the microphone reads open while any publication is unmuted', () {
    first.muted = true;

    expect(port.open, isTrue);
  });

  group('a track a failed republish left with no publication', () {
    setUp(() {
      me.publications.remove(second);
      port.onRoomEvent(
        lk.LocalTrackPublishedEvent(participant: me, publication: first),
      );
      me.publications.clear();
    });

    test('is stopped before a fresh microphone is published', () async {
      await port.setEnabled(true, const lk.AudioCaptureOptions());

      expect(first.track.stops, 1);
    });

    test('is stopped by a release, a discard and the hang-up', () async {
      await port.release();
      expect(first.track.stops, 1);

      await port.discard();
      await port.stopUnpublished();
      expect(first.track.stops, 1, reason: 'stopped once, then forgotten');
    });

    test('is stopped at the hang-up', () async {
      await port.stopUnpublished();

      expect(first.track.stops, 1);
    });
  });

  test('a published microphone is not stopped as an orphan', () async {
    port.onRoomEvent(
      lk.LocalTrackPublishedEvent(participant: me, publication: first),
    );
    await pumpEventQueue();
    await port.setEnabled(
      true,
      const lk.AudioCaptureOptions(stopAudioCaptureOnMute: false),
    );

    expect(first.track.stops, 0);
  });
}
