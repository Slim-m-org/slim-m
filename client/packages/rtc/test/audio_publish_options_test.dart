// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/rtc.dart';

void main() {
  test('the microphone asks livekit_client for redundant audio', () {
    // 2.13.1 sends this field as disableRed, so false is the one that enables RED.
    expect(microphonePublishOptions().red, isFalse);
  });

  test('the microphone does not use DTX', () {
    expect(microphonePublishOptions().dtx, isFalse);
  });

  test('the bitrate is pinned to 48 kbps, not left to the SDK default', () {
    expect(microphonePublishOptions().encoding?.maxBitrate, 48000);
    expect(receiveRoomOptions().defaultAudioPublishOptions.encoding?.maxBitrate,
        48000);
  });

  test('every call starts from the microphone options', () {
    final room = receiveRoomOptions().defaultAudioPublishOptions;
    expect(room.red, microphonePublishOptions().red);
    expect(room.dtx, microphonePublishOptions().dtx);
  });

  test('the red inversion above was verified against the locked livekit_client',
      () {
    final lock = File('../../pubspec.lock').readAsStringSync();
    final locked =
        RegExp(r'  livekit_client:\n(?:    .*\n)*?    version: "([^"]+)"')
            .firstMatch(lock)
            ?.group(1);

    // A newer livekit may fix the disableRed inversion; re-check it, then update this.
    expect(locked, '2.13.1');
  });
}
