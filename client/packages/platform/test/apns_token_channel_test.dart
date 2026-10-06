// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the APNs token bridge: the hex-format contract, platform gating,
/// and every ordering the native side can arrive in.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_platform/platform.dart';

const _channelName = 'top.npcserver.slimm/push';

void _mock(Future<Object?> Function(MethodCall call)? handler) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel(_channelName), handler);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('hexEncodeToken', () {
    test('lowercase, zero-padded, and unseparated', () {
      // 0x0f and 0x00 catch the padding bug: a naive toRadixString without
      // padLeft would emit "f" and "" instead of "0f" and "00".
      expect(hexEncodeToken([0x00, 0x0f, 0xff, 0xa1]), '000fffa1');
    });

    test('an empty token is an empty string, not an error', () {
      expect(hexEncodeToken(const []), '');
    });
  });

  group('ApnsTokenChannel.fetch', () {
    test('not iOS is ApnsUnsupported, without touching the channel', () async {
      var touched = false;
      _mock((call) async {
        touched = true;
        return null;
      });
      addTearDown(() => _mock(null));

      final result = await ApnsTokenChannel(isIOS: false).fetch();

      expect(result, isA<ApnsUnsupported>());
      expect(touched, isFalse);
    });

    test('a cached token is ApnsTokenReady', () async {
      _mock((call) async => switch (call.method) {
            'getToken' => 'abcd1234',
            _ => null,
          });
      addTearDown(() => _mock(null));

      final result = await ApnsTokenChannel(isIOS: true).fetch();

      expect(result, isA<ApnsTokenReady>());
      expect((result as ApnsTokenReady).token, 'abcd1234');
    });

    test(
        'a cached registration error is ApnsRegistrationFailed with the '
        'reason preserved', () async {
      _mock((call) async => switch (call.method) {
            'getRegistrationError' => 'no push entitlement',
            _ => null,
          });
      addTearDown(() => _mock(null));

      final result = await ApnsTokenChannel(isIOS: true)
          .fetch(timeout: const Duration(seconds: 30));

      expect(result, isA<ApnsRegistrationFailed>());
      expect(
        (result as ApnsRegistrationFailed).reason,
        'no push entitlement',
      );
    });

    test('nothing arriving within the timeout is ApnsTokenPending', () async {
      _mock((call) async => null);
      addTearDown(() => _mock(null));

      final result = await ApnsTokenChannel(isIOS: true)
          .fetch(timeout: const Duration(milliseconds: 20));

      expect(result, isA<ApnsTokenPending>());
    });

    test('no plugin registered at all is ApnsTokenPending, not a hang',
        () async {
      // Deliberately no handler: nothing answers the channel, the way a
      // desktop build with the wrong isIOS override would behave.
      _mock(null);
      final result = await ApnsTokenChannel(isIOS: true).fetch();

      expect(result, isA<ApnsTokenPending>());
    });

    test('a token arriving mid-probe is not dropped', () async {
      // The native side can deliver in the gap between the getToken and
      // getRegistrationError round trips. See ApnsTokenChannel.fetch.
      late Future<void> deliver;
      _mock((call) async {
        switch (call.method) {
          case 'getToken':
            return null;
          case 'getRegistrationError':
            // Simulate the token landing while this reply is in flight.
            deliver = TestDefaultBinaryMessengerBinding
                .instance.defaultBinaryMessenger
                .handlePlatformMessage(
              _channelName,
              const StandardMethodCodec().encodeMethodCall(
                const MethodCall('onToken', 'abc123'),
              ),
              (_) {},
            );
            return null;
        }
        return null;
      });
      addTearDown(() => _mock(null));

      final channel = ApnsTokenChannel(isIOS: true);
      final result = await channel.fetch(
        timeout: const Duration(milliseconds: 300),
      );
      await deliver;
      expect(result, isA<ApnsTokenReady>());
      expect((result as ApnsTokenReady).token, 'abc123');
    });
  });

  group('ApnsTokenChannel VoIP token', () {
    test('not iOS has none and never touches the channel', () async {
      var touched = false;
      _mock((call) async {
        touched = true;
        return 'voip';
      });
      addTearDown(() => _mock(null));

      expect(await ApnsTokenChannel(isIOS: false).cachedVoipToken(), isNull);
      expect(touched, isFalse);
    });

    test('the cached token is returned as native holds it', () async {
      _mock((call) async => call.method == 'getVoipToken' ? 'ab12' : null);
      addTearDown(() => _mock(null));

      expect(await ApnsTokenChannel(isIOS: true).cachedVoipToken(), 'ab12');
    });

    test('no plugin registered is null, not a throw', () async {
      _mock(null);
      expect(await ApnsTokenChannel(isIOS: true).cachedVoipToken(), isNull);
    });

    test('a token pushed from native reaches onVoipToken', () async {
      _mock((call) async => null);
      addTearDown(() => _mock(null));
      final channel = ApnsTokenChannel(isIOS: true);
      final next = channel.onVoipToken.first;

      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        _channelName,
        const StandardMethodCodec()
            .encodeMethodCall(const MethodCall('onVoipToken', 'cafe')),
        (_) {},
      );

      expect(await next, 'cafe');
    });
  });
}
