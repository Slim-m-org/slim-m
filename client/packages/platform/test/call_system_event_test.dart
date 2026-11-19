// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What iOS reports around a call, as the lines a call report carries, and
/// how those reports cross the call lifecycle channel.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_platform/src/call_system_event.dart';

const _channel = 'top.npcserver.slimm/call_lifecycle';

const _session = {
  'category': 'AVAudioSessionCategoryPlayAndRecord',
  'mode': 'AVAudioSessionModeVoiceChat',
  'inputs': ['MicrophoneBuiltIn'],
  'outputs': ['Receiver'],
  'otherAudioPlaying': false,
  'inputAvailable': true,
};

Future<void> _fromNative(MethodCall call) =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      _channel,
      const StandardMethodCodec().encodeMethodCall(call),
      (_) {},
    );

void _mockNative(Future<Object?> Function(MethodCall call)? handler) =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(_channel), handler);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('describeAudioSession', () {
    test('names the category, mode and route by port type', () {
      expect(
        describeAudioSession(_session),
        'session playAndRecord/voiceChat, in MicrophoneBuiltIn, out Receiver',
      );
    });

    test('says when another app holds audio or no input exists', () {
      final line = describeAudioSession({
        'category': 'AVAudioSessionCategoryPlayback',
        'mode': 'AVAudioSessionModeDefault',
        'inputs': <String>[],
        'outputs': ['Speaker', 'BluetoothA2DPOutput'],
        'otherAudioPlaying': true,
        'inputAvailable': false,
      });

      expect(
        line,
        'session playback/default, in none, out Speaker+BluetoothA2DPOutput, '
        'other audio playing, no input available',
      );
    });
  });

  group('describeCallSystemEvent', () {
    test('a refused CallKit start names the transaction error', () {
      expect(
        describeCallSystemEvent({
          'kind': 'callKit',
          'step': 'start',
          'result': 'failed',
          'domain': 'com.apple.CallKit.error.requesttransaction',
          'code': 6,
        }),
        'CallKit start request: failed '
        '(com.apple.CallKit.error.requesttransaction 6 callUUIDAlreadyExists)',
      );
    });

    test('a start skipped for a call still reported says so', () {
      expect(
        describeCallSystemEvent(
            {'kind': 'callKit', 'step': 'start', 'result': 'skipped'}),
        'CallKit start request: skipped, a call is already reported',
      );
    });

    test('CallKit taking and handing back the audio session reads as such', () {
      expect(
        describeCallSystemEvent(
            {..._session, 'kind': 'callKitAudio', 'active': true}),
        'CallKit activated the audio session: session playAndRecord/voiceChat, '
        'in MicrophoneBuiltIn, out Receiver',
      );
      expect(
        describeCallSystemEvent(
            {..._session, 'kind': 'callKitAudio', 'active': false}),
        startsWith('CallKit deactivated the audio session: '),
      );
    });

    test('an end from the system call screen says where it came from', () {
      expect(
        describeCallSystemEvent(
            {'kind': 'callKit', 'step': 'endAction', 'result': 'system'}),
        'CallKit end action: from the system call screen',
      );
    });

    test('an interruption names its reason and whether it may resume', () {
      expect(
        describeCallSystemEvent(
            {'kind': 'interruption', 'type': 1, 'reason': 2}),
        'Audio interruption began (built-in mic muted)',
      );
      expect(
        describeCallSystemEvent(
            {'kind': 'interruption', 'type': 0, 'options': 1}),
        'Audio interruption ended, may resume',
      );
    });

    test('a route change carries its reason and the session after it', () {
      expect(
        describeCallSystemEvent(
            {..._session, 'kind': 'routeChange', 'reason': 3}),
        'Audio route changed (category change): '
        'session playAndRecord/voiceChat, in MicrophoneBuiltIn, out Receiver',
      );
    });

    test('a media services reset is named', () {
      expect(describeCallSystemEvent({'kind': 'mediaServicesReset'}),
          'Audio media services were reset');
    });

    test('an unknown kind is dropped', () {
      expect(describeCallSystemEvent({'kind': 'somethingNew'}), isNull);
    });
  });

  group('CallLifecycleChannel', () {
    test('a callEvent from native surfaces as a systemEvents line', () async {
      final lifecycle = CallLifecycleChannel(isIOS: true);
      addTearDown(lifecycle.dispose);
      final lines = <String>[];
      final sub = lifecycle.systemEvents.listen(lines.add);
      addTearDown(sub.cancel);

      await _fromNative(const MethodCall('callEvent', {
        'kind': 'callKit',
        'step': 'start',
        'result': 'ok',
      }));
      await _fromNative(const MethodCall('callEvent', {'kind': 'unknown'}));

      expect(lines, ['CallKit start request: ok']);
    });

    test('reads the audio session on iOS', () async {
      _mockNative(
          (call) async => call.method == 'audioSession' ? _session : null);
      addTearDown(() => _mockNative(null));

      final line = await CallLifecycleChannel(isIOS: true).audioSessionLine();

      expect(line, startsWith('session playAndRecord/voiceChat'));
    });

    test('reads nothing off iOS or without a native reader', () async {
      final calls = <MethodCall>[];
      _mockNative((call) async {
        calls.add(call);
        throw MissingPluginException();
      });
      addTearDown(() => _mockNative(null));

      expect(
          await CallLifecycleChannel(isIOS: false).audioSessionLine(), isNull);
      expect(calls, isEmpty);
      expect(
          await CallLifecycleChannel(isIOS: true).audioSessionLine(), isNull);
      expect(calls.single.method, 'audioSession');
    });
  });
}
