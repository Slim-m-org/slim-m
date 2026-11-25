// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Leaving a call while sharing desktop audio on Linux: winding the share mix
/// down can take seconds on a slow sound server, and the microphone must not
/// stay published for that long after the person hung up.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/rtc.dart';

import 'support/fake_share_audio_graph.dart';
import 'support/no_audio_devices.dart';

class _WatchedRoom extends lk.Room {
  _WatchedRoom(this.onDisconnect);
  final void Function() onDisconnect;

  @override
  Future<void> connect(
    String url,
    String token, {
    lk.ConnectOptions? connectOptions,
    lk.RoomOptions? roomOptions,
    lk.FastConnectOptions? fastConnectOptions,
  }) async {}

  @override
  Future<void> disconnect() async {
    onDisconnect();
    await super.disconnect();
  }
}

void main() {
  test('the room is disconnected before the share mix is wound down', () async {
    final graph = FakeShareAudioGraph();
    final isolation = ShareAudioIsolation(graph: graph);
    int? destroysWhenDisconnected;
    final session = VoiceSession(
      audioDevices: const NoAudioDevices(),
      roomFactory: () =>
          _WatchedRoom(() => destroysWhenDisconnected = graph.destroys),
      shareAudioIsolation: isolation,
    );
    addTearDown(session.dispose);
    await session.join(url: 'wss://a.invalid', token: 't');
    expect(await isolation.begin(), isTrue);

    await session.leave();

    expect(destroysWhenDisconnected, 0,
        reason: 'the mix must still be up when the room disconnects');
    expect(graph.destroys, 1);
    expect(isolation.active, isFalse);
  });
}
