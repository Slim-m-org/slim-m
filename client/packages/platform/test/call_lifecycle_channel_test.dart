// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the CallKit lifecycle bridge: a non-iOS platform never touches
/// the channel, an iOS one forwards the right calls, and an `endCall` from
/// the native side surfaces as [CallLifecycleChannel.endCallRequests].
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_platform/platform.dart';

const _pluginChannelName = 'top.npcserver.slimm/call_lifecycle';

void _mockPlugin(Future<Object?> Function(MethodCall call)? handler) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel(_pluginChannelName),
    handler,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CallLifecycleChannel', () {
    test('a non-iOS platform never touches the channel', () async {
      // A recording mock: "does it throw" cannot tell a guard from a swallowed exception.
      final calls = <MethodCall>[];
      _mockPlugin((call) async {
        calls.add(call);
        return null;
      });
      addTearDown(() => _mockPlugin(null));

      final lifecycle = CallLifecycleChannel(isIOS: false);
      await lifecycle.callStarted(callId: 'call-1', displayName: 'Voice call');
      await lifecycle.callConnected();
      await lifecycle.callEnded();

      expect(calls, isEmpty);
    });

    test('forwards callStarted with the call id and display name', () async {
      final calls = <MethodCall>[];
      _mockPlugin((call) async {
        calls.add(call);
        return null;
      });
      addTearDown(() => _mockPlugin(null));

      final lifecycle = CallLifecycleChannel(isIOS: true);
      await lifecycle.callStarted(
          callId: 'channel-1', displayName: 'Voice call');

      expect(calls, hasLength(1));
      expect(calls.single.method, 'callStarted');
      expect(calls.single.arguments, {
        'callId': 'channel-1',
        'displayName': 'Voice call',
      });
    });

    test('callConnected and callEnded name the call that was started',
        () async {
      final calls = <MethodCall>[];
      _mockPlugin((call) async {
        calls.add(call);
        return null;
      });
      addTearDown(() => _mockPlugin(null));

      final lifecycle = CallLifecycleChannel(isIOS: true);
      await lifecycle.callStarted(
          callId: 'channel-1', displayName: 'Voice call');
      await lifecycle.callConnected();
      await lifecycle.callEnded();

      expect(calls.map((c) => c.method),
          ['callStarted', 'callConnected', 'callEnded']);
      expect(calls[1].arguments, {'callId': 'channel-1'});
      expect(calls[2].arguments, {'callId': 'channel-1'});
    });

    test('an instance that reported no call sends no end or connect', () async {
      final calls = <MethodCall>[];
      _mockPlugin((call) async {
        calls.add(call);
        return null;
      });
      addTearDown(() => _mockPlugin(null));

      final lifecycle = CallLifecycleChannel(isIOS: true);
      await lifecycle.callConnected();
      await lifecycle.callEnded();

      expect(calls, isEmpty);
    });

    test('every instance hears a native hangup and a disposed one drops it',
        () async {
      final first = CallLifecycleChannel(isIOS: true);
      final second = CallLifecycleChannel(isIOS: true);
      addTearDown(first.dispose);
      var firstHeard = 0;
      var secondHeard = 0;
      final firstSub = first.endCallRequests.listen((_) => firstHeard++);
      final secondSub = second.endCallRequests.listen((_) => secondHeard++);
      addTearDown(firstSub.cancel);
      addTearDown(secondSub.cancel);

      Future<void> nativeHangup() =>
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .handlePlatformMessage(
            _pluginChannelName,
            const StandardMethodCodec().encodeMethodCall(
              const MethodCall('endCall'),
            ),
            (_) {},
          );

      await nativeHangup();
      expect([firstHeard, secondHeard], [1, 1]);

      second.dispose();
      await nativeHangup();
      expect([firstHeard, secondHeard], [2, 1]);
    });

    test('a platform exception from the channel is swallowed', () async {
      _mockPlugin((call) async {
        throw PlatformException(code: 'nope');
      });
      addTearDown(() => _mockPlugin(null));

      final lifecycle = CallLifecycleChannel(isIOS: true);

      await expectLater(
        lifecycle.callStarted(callId: 'call-1', displayName: 'Voice call'),
        completes,
      );
    });

    test('an endCall from native surfaces as an endCallRequests event',
        () async {
      final lifecycle = CallLifecycleChannel(isIOS: true);
      addTearDown(lifecycle.dispose);

      final events = <void>[];
      final sub = lifecycle.endCallRequests.listen(events.add);
      addTearDown(sub.cancel);

      // Drives the handler the channel itself installed, as native code would.
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        _pluginChannelName,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('endCall'),
        ),
        (_) {},
      );

      expect(events, hasLength(1));
    });
  });
}
