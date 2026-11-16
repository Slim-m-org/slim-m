// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The audio engine's state in the join check, and only where livekit reports it.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/src/audio_engine_line.dart';

// ignore_for_file: experimental_member_use

void main() {
  test('says whether the engine plays out and records', () {
    expect(
      engineLine(const lk.AudioEngineState(
        isPlayoutEnabled: true,
        isRecordingEnabled: false,
      )),
      'engine playout on, recording off',
    );
  });

  test('says nothing where livekit reports no engine state', () {
    expect(currentEngineLine(apple: false), isNull);
    expect(engineChangeLines(apple: false), isNull);
    expect(currentEngineLine(apple: true), 'engine playout off, recording off');
    expect(engineChangeLines(apple: true), isNotNull);
  });
}
