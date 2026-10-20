// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
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

  test('every call starts from the microphone options', () {
    final room = receiveRoomOptions().defaultAudioPublishOptions;
    expect(room.red, microphonePublishOptions().red);
    expect(room.dtx, microphonePublishOptions().dtx);
  });
}
