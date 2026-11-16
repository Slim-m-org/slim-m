// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The join check reads every remote voice, including one it cannot hear:
/// not subscribed, muted at the source, or switched off by this listener.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_api/api.dart' show LogLevel;
import 'package:slimm_rtc/src/voice_health_watch.dart';

import 'support/reconnect_fakes.dart';

class _Media extends Fake implements rtc.MediaStreamTrack {
  _Media(this.enabled);

  @override
  bool enabled;
}

class _Track extends Fake implements lk.RemoteAudioTrack {
  _Track({bool enabled = true}) : mediaStreamTrack = _Media(enabled);

  @override
  final rtc.MediaStreamTrack mediaStreamTrack;
}

class _Pub extends Fake
    implements lk.RemoteTrackPublication<lk.RemoteAudioTrack> {
  _Pub({
    this.track,
    this.muted = false,
    this.enabled = true,
    this.source = lk.TrackSource.microphone,
  });

  @override
  final lk.RemoteAudioTrack? track;
  @override
  final bool muted;
  @override
  final bool enabled;
  @override
  final lk.TrackSource source;
}

class _Peer extends FakePeer {
  _Peer(super.identity, this._pubs);

  final List<lk.RemoteTrackPublication<lk.RemoteAudioTrack>> _pubs;

  @override
  List<lk.RemoteTrackPublication<lk.RemoteAudioTrack>>
      get audioTrackPublications => _pubs;
}

void main() {
  test('names why each remote voice can or cannot be heard', () {
    final room = PeopleRoom()
      ..people.addAll({
        'ann': _Peer('ann', [
          _Pub(track: _Track()),
          _Pub(
            track: _Track(),
            muted: true,
            source: lk.TrackSource.screenShareAudio,
          ),
        ]),
        'bob': _Peer('bob', [_Pub()]),
        'cy': _Peer('cy', [_Pub(track: _Track(), muted: true)]),
        'dee': _Peer('dee', [_Pub(track: _Track(), enabled: false)]),
        'eve': _Peer('eve', [_Pub(track: _Track(enabled: false))]),
      });
    final watch = VoiceHealthWatch(
      VoiceHealthWatchHost(
          room: () => room, diag: (_, {level = LogLevel.info}) {}),
    );

    final probes = watch.remoteVoiceProbes();

    expect(probes.keys, ['ann', 'bob', 'cy', 'dee', 'eve']);
    expect((probes['ann']!.blocked, probes['ann']!.playing), (null, true));
    expect(probes['bob']!.blocked, 'not subscribed');
    expect(probes['cy']!.blocked, 'muted by them');
    expect((probes['dee']!.blocked, probes['dee']!.playing), (null, false));
    expect(probes['eve']!.playing, isFalse);
  });
}
