// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// On web a microphone pick must not go through livekit's all-audio restart.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/rtc.dart';

class _Room extends lk.Room {
  int livekitSwitches = 0;

  @override
  Future<void> setAudioInputDevice(lk.MediaDevice device) async {
    livekitSwitches++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const device = lk.MediaDevice('mic-2', 'Desk', 'audioinput', null);

  test('web selects the device without livekit restarting every track',
      () async {
    final room = _Room();
    final selected = <String>[];
    await AudioDeviceSwitching.switchLiveInput(
      room,
      device,
      web: true,
      select: (d) => selected.add(d.deviceId),
    );

    expect(room.livekitSwitches, 0);
    expect(selected, ['mic-2']);
  });
}
