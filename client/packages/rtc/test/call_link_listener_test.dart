// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A listener with no microphone published still learns the call's media path,
/// from what it receives.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_api/api.dart' show LogLevel;
import 'package:slimm_rtc/src/call_link.dart';
import 'package:slimm_rtc/src/voice_health_watch.dart';

import 'support/reconnect_fakes.dart';

class _Receiver extends Fake implements rtc.RTCRtpReceiver {
  @override
  Future<List<rtc.StatsReport>> getStats() async => [
        rtc.StatsReport('t', 'transport', 0, {
          'selectedCandidatePairId': 'p',
        }),
        rtc.StatsReport('p', 'candidate-pair', 0, {
          'state': 'succeeded',
          'currentRoundTripTime': 0.031,
          'localCandidateId': 'l',
          'remoteCandidateId': 'r',
        }),
        rtc.StatsReport('l', 'local-candidate', 0, {
          'candidateType': 'relay',
          'protocol': 'udp',
        }),
        rtc.StatsReport('r', 'remote-candidate', 0, {
          'candidateType': 'host',
          'protocol': 'udp',
        }),
      ];
}

class _Track extends Fake implements lk.RemoteAudioTrack {
  @override
  rtc.RTCRtpReceiver? get receiver => _Receiver();
}

class _Pub extends Fake
    implements lk.RemoteTrackPublication<lk.RemoteAudioTrack> {
  @override
  lk.RemoteAudioTrack? get track => _Track();
}

class _Peer extends FakePeer {
  _Peer(super.identity);

  @override
  List<lk.RemoteTrackPublication<lk.RemoteAudioTrack>>
      get audioTrackPublications => [_Pub()];
}

void main() {
  test('a listener without a microphone reads the path it hears over',
      () async {
    final room = PeopleRoom()..people['ann'] = _Peer('ann');
    final at = DateTime(2026, 11, 18, 20);
    final watch = VoiceHealthWatch(
      VoiceHealthWatchHost(
        room: () => room,
        diag: (_, {level = LogLevel.info}) {},
      ),
      clock: () => at,
    );
    addTearDown(watch.health.dispose);

    expect(await watch.localVoiceStats(), isNull);

    final link = watch.health.link.value!;
    expect(link.media, MediaRoute.relayed);
    expect(link.mediaRttMs, 31);
    expect(link.at, at);
  });
}
