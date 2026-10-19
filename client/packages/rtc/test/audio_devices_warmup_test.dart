// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Windows lists no audio devices until something has opened audio. That
/// warm-up opens a capture the native layer points at the default devices, so
/// it must never run while a call holds the chosen ones.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/rtc.dart';

lk.MediaDevice _mic(String id) => lk.MediaDevice(id, id, 'audioinput', 'g');

HardwareAudioDevices _devices({
  required bool inCall,
  required List<String?> warmed,
  lk.PlatformType platform = lk.PlatformType.windows,
}) {
  var warmedUp = false;
  return HardwareAudioDevices(
    pulse: PulseAudio(run: (_) async => ProcessResult(0, 1, '', '')),
    inCall: () => inCall,
    chosenInput: () => 'mic-1',
    platform: () => platform,
    listInputs: () async => warmedUp ? [_mic('mic-1')] : const [],
    listOutputs: () async => const [],
    warm: (id) async {
      warmed.add(id);
      warmedUp = true;
    },
  );
}

void main() {
  test('an empty list outside a call warms up on the chosen microphone',
      () async {
    final warmed = <String?>[];
    final list = await _devices(inCall: false, warmed: warmed).inputs();

    expect(warmed, ['mic-1']);
    expect(list.map((d) => d.id), ['mic-1']);
  });

  test('an empty list during a call never opens a capture', () async {
    final warmed = <String?>[];
    final list = await _devices(inCall: true, warmed: warmed).inputs();

    expect(warmed, isEmpty);
    expect(list, isEmpty);
  });

  test('other platforms never warm up', () async {
    final warmed = <String?>[];
    await _devices(
      inCall: false,
      warmed: warmed,
      platform: lk.PlatformType.linux,
    ).inputs();

    expect(warmed, isEmpty);
  });
}
