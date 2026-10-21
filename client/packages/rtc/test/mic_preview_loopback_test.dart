// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Silencing the loopback's far end must not switch off the capture it reads.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:slimm_rtc/src/mic_preview_loopback.dart';

class _Track implements rtc.MediaStreamTrack {
  final enabledWrites = <bool>[];

  @override
  String get kind => 'audio';

  @override
  String get id => 'shared-track-id';

  @override
  set enabled(bool value) => enabledWrites.add(value);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('silences the received track by volume and never disables it', () async {
    final calls = <MethodCall>[];
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('FlutterWebRTC.Method'),
      (call) async {
        calls.add(call);
        return null;
      },
    );
    addTearDown(() => TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('FlutterWebRTC.Method'), null));
    final track = _Track();

    await silenceLoopbackTrack(track);

    expect(track.enabledWrites, isEmpty,
        reason: 'both ends share the track id, so this would stop the capture');
    expect(calls.map((c) => c.method), contains('setVolume'));
    expect(
      (calls.firstWhere((c) => c.method == 'setVolume').arguments
          as Map)['volume'],
      0.0,
    );
  });
}
