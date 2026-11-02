// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The voice quality harness entry point must stay out of every ordinary build.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/diagnostics/voice_harness.dart';
import 'package:slimm_app/src/diagnostics/voice_harness_media.dart';
import 'package:slimm_app/src/features/voice/providers/voice_state.dart';
import 'package:slimm_rtc/rtc.dart'
    show CameraQuality, ScreenShareQuality, VoiceSessionState;

void main() {
  test('the harness is compiled out unless the define is passed', () {
    expect(kVoiceHarness, isFalse);
  });

  test('the channel comes from its flag and nowhere else', () {
    expect(harnessChannel(const ['--voice-harness-channel=abc']), 'abc');
    expect(
      harnessChannel(const ['--autostart', '--voice-harness-channel=x-1']),
      'x-1',
    );
    expect(harnessChannel(const ['--autostart']), isNull);
    expect(harnessChannel(const []), isNull);
  });

  test('the volume file flag is read from the arguments', () {
    expect(
      harnessVolumeFile(const ['--voice-harness-volume-file=/tmp/v']),
      '/tmp/v',
    );
    expect(harnessVolumeFile(const ['--voice-harness-channel=abc']), isNull);
  });

  test('only a call that ended in failure is a failed join', () {
    expect(
      failedJoin(const VoiceState(state: VoiceSessionState.connected)),
      isNull,
    );
    expect(
      failedJoin(const VoiceState(state: VoiceSessionState.connecting)),
      isNull,
    );
    expect(
      failedJoin(
        const VoiceState(state: VoiceSessionState.failed, error: 'forbidden'),
      ),
      'state=failed error=forbidden',
    );
  });

  test(
    'a sign-in timeout carries the marker the Python harness retries on',
    () {
      expect(joinFailedMarker, 'SLIMM_HARNESS join-failed');
    },
  );

  test('the share tier, ceiling and camera setting come from their flags', () {
    expect(
      harnessShareQuality(const ['--voice-harness-share=1080p30']),
      ScreenShareQuality.standard,
    );
    expect(harnessShareQuality(const ['--voice-harness-share=999p30']), isNull);
    expect(harnessShareQuality(const []), isNull);
    expect(
      harnessShareCeiling(const ['--voice-harness-share-ceiling=1440']),
      1440,
    );
    expect(harnessShareCeiling(const []), isNull);
    expect(
      harnessCameraQuality(const ['--voice-harness-camera=high']),
      CameraQuality.high,
    );
    expect(harnessCameraQuality(const ['--voice-harness-camera=x']), isNull);
  });
}
