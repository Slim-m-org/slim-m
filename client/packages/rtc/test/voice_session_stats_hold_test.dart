// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A sender who watches nobody still gets stats: the sampler runs while we publish video and a summary lands when it stops.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_api/api.dart' show LogLevel;
import 'package:slimm_rtc/rtc.dart';

import 'support/session_fakes.dart';

class _Sender extends Fake implements rtc.RTCRtpSender {
  @override
  Future<List<rtc.StatsReport>> getStats() async => [
        rtc.StatsReport('o1', 'outbound-rtp', 5e6, {
          'kind': 'video',
          'frameWidth': 1920,
          'frameHeight': 1080,
          'framesPerSecond': 30.0,
          'bytesSent': 1000,
          'qualityLimitationReason': 'bandwidth',
          'encoderImplementation': 'libvpx',
        }),
      ];
}

class _Track extends Fake implements lk.LocalVideoTrack {
  @override
  rtc.RTCRtpSender? get sender => _Sender();
}

class _Publication extends Fake
    implements lk.LocalTrackPublication<lk.LocalVideoTrack> {
  _Publication(this.source);

  @override
  final lk.TrackSource source;

  @override
  bool get muted => false;

  @override
  lk.LocalVideoTrack? get track => _Track();
}

Future<void> _roomEvent(lk.Room room) async {
  // ignore: invalid_use_of_internal_member, a room cannot be made to emit otherwise
  room.events.emit(const lk.ActiveSpeakersChangedEvent(speakers: []));
  await Future<void>.delayed(const Duration(milliseconds: 50));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late InstantRoom room;
  late List<String> logged;
  late VoiceSession session;

  setUp(() async {
    room = InstantRoom();
    logged = [];
    session = instantSession(
      mic: CountingMic(),
      room: room,
      audioLog: (line, {level = LogLevel.info}) => logged.add(line),
    );
    addTearDown(session.dispose);
    await session.join(url: 'wss://a.invalid', token: 't');
  });

  test('a call with no video of ours samples nothing', () async {
    await _roomEvent(room);

    expect(session.callStats.held, isFalse);
    expect(session.callStats.running, isFalse);
  });

  test('publishing a share holds the sampler and its numbers are kept',
      () async {
    room.videos.add(_Publication(lk.TrackSource.screenShareVideo));
    await _roomEvent(room);

    expect(session.callStats.held, isTrue);
    expect(session.callStats.running, isTrue);
    expect(
      session.diagnostics.report(facts: const {}),
      contains('[call-stats] out screenShare me 1920x1080@30'),
    );
  });

  test('stopping the share releases the sampler and logs its summary',
      () async {
    room.videos.add(_Publication(lk.TrackSource.screenShareVideo));
    await _roomEvent(room);

    room.videos.clear();
    await _roomEvent(room);

    expect(session.callStats.held, isFalse);
    expect(session.callStats.running, isFalse);
    final summary =
        logged.singleWhere((l) => l.contains('[call-stats] summary'));
    expect(summary, contains('out screenShare me'));
    expect(summary, contains('libvpx'));
    expect(summary, contains('first frame'));
  });

  test('leaving mid-share reports the summary and releases the sampler',
      () async {
    room.videos.add(_Publication(lk.TrackSource.camera));
    await _roomEvent(room);

    await session.leave();

    expect(session.callStats.running, isFalse);
    expect(logged.where((l) => l.contains('[call-stats] summary out camera')),
        hasLength(1));
  });

  test('a join that replaces a live call closes the old share', () async {
    room.videos.add(_Publication(lk.TrackSource.screenShareVideo));
    await _roomEvent(room);
    room.videos.clear();

    await session.join(url: 'wss://a.invalid', token: 't');

    expect(session.callStats.held, isFalse);
    expect(
        logged.where((l) => l.contains('[call-stats] summary')), hasLength(1));
  });

  test('closing the session mid-share still reports the summary', () async {
    room.videos.add(_Publication(lk.TrackSource.camera));
    await _roomEvent(room);

    await session.dispose();

    expect(logged.where((l) => l.contains('[call-stats] summary out camera')),
        hasLength(1));
  });

  test('the report says the call is over once it ends', () async {
    expect(session.diagnostics.active, isTrue);

    await session.leave();

    expect(session.diagnostics.active, isFalse);
    expect(
      session.diagnostics.report(facts: const {}),
      contains('No call is active. Showing the last call'),
    );
  });
}
