// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The real session's microphone and speaker lists, through the plugin channel
/// the app tests replace with fakes, so a swapped input and output cannot pass.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/rtc.dart';

const _channel = MethodChannel('FlutterWebRTC.Method');

Map<String, Object> _source(String id, String kind) => {
      'deviceId': id,
      'label': id,
      'groupId': 'g-$id',
      'kind': kind,
    };

void _mockSources(Object Function() respond) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
    if (call.method == 'getSources') return respond();
    return null;
  });
  addTearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('microphones and speakers are listed from their own kind', () async {
    _mockSources(
      () => {
        'sources': [
          _source('default', 'audioinput'),
          _source('mic-1', 'audioinput'),
          _source('spk-1', 'audiooutput'),
          _source('cam-1', 'videoinput'),
        ],
      },
    );
    final session = VoiceSession();

    expect([
      for (final d in await session.audioInputDevices()) d.id
    ], [
      'mic-1',
    ]);
    expect([
      for (final d in await session.audioOutputDevices()) d.id
    ], [
      'spk-1',
    ]);
    await session.dispose();
  });

  test('a platform failure lists nothing instead of throwing', () async {
    _mockSources(() => throw PlatformException(code: 'boom'));
    final session = VoiceSession();

    expect(await session.audioInputDevices(), isEmpty);
    expect(await session.audioOutputDevices(), isEmpty);
    expect(session.lastError, isNotNull);
    await session.dispose();
  });
}
