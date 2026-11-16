// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What iOS reports around a call (CallKit results, audio session changes)
/// must reach the call's diagnostics, and the session must be able to read
/// the audio session for its join check; [VoiceController] is what wires the
/// call lifecycle channel to the voice session.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_platform/platform.dart';

import 'voice_controller_harness.dart';

const _channel = 'top.npcserver.slimm/call_lifecycle';

void _mockNative(Future<Object?> Function(MethodCall call)? handler) =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(_channel), handler);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final harness = VoiceHarness();
  tearDown(harness.dispose);

  test('a CallKit result from native lands on the call timeline', () async {
    final session = FakeSession();
    final controller = harness.controllerWith(
      session,
      voiceApi(),
      callLifecycle: CallLifecycleChannel(isIOS: true),
    );
    controller.diagnostics.begin();

    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          _channel,
          const StandardMethodCodec().encodeMethodCall(
            const MethodCall('callEvent', {
              'kind': 'callKit',
              'step': 'start',
              'result': 'failed',
              'domain': 'com.apple.CallKit.error.requesttransaction',
              'code': 6,
            }),
          ),
          (_) {},
        );

    expect(
      controller.diagnostics.report(facts: const {}),
      contains('CallKit start request: failed'),
    );
  });

  test('the session reads the audio session through the channel', () async {
    _mockNative(
      (call) async => call.method == 'audioSession'
          ? {
              'category': 'AVAudioSessionCategoryPlayback',
              'mode': 'AVAudioSessionModeDefault',
              'inputs': <String>[],
              'outputs': ['Speaker'],
            }
          : null,
    );
    addTearDown(() => _mockNative(null));
    final session = FakeSession();
    harness.controllerWith(
      session,
      voiceApi(),
      callLifecycle: CallLifecycleChannel(isIOS: true),
    );

    expect(
      await session.audioSessionReader?.call(),
      'session playback/default, in none, out Speaker',
    );
  });
}
