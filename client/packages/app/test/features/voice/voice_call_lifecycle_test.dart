// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A call joined from this app's own UI must reach CallKit the same way an
/// inbound VoIP push does, or it gets none of the background execution grant
/// that makes the difference; see `VoipCallHandler.swift`'s doc comment and
/// https://github.com/NC1107/slim-m/issues/212.
///
/// [VoiceController] is the only place that knows both when a call really
/// starts, connects and ends, and when the user asked to leave, so it is
/// what drives [CallLifecycleChannel] rather than `voice_screen.dart` doing
/// it a second time from the UI layer.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

const _channelName = 'top.npcserver.slimm/call_lifecycle';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final harness = VoiceHarness();
  tearDown(harness.dispose);

  /// A [CallLifecycleChannel] with `isIOS: true`, recording every method
  /// call it forwards natively rather than actually reaching for one.
  ({CallLifecycleChannel lifecycle, List<MethodCall> calls}) iosLifecycle() {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(_channelName), (
          call,
        ) async {
          calls.add(call);
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel(_channelName), null),
    );
    return (lifecycle: CallLifecycleChannel(isIOS: true), calls: calls);
  }

  test('joining reports the call starting, then connected', () async {
    final (:lifecycle, :calls) = iosLifecycle();
    final session = FakeSession();
    final controller = harness.controllerWith(
      session,
      voiceApi(),
      callLifecycle: lifecycle,
    );

    unawaited(controller.join('channel-1'));
    await Future<void>.delayed(Duration.zero);
    session.emitState(VoiceSessionState.connecting);
    await Future<void>.delayed(Duration.zero);
    session.emitState(VoiceSessionState.connected);
    await Future<void>.delayed(Duration.zero);

    expect(calls.map((c) => c.method), ['callStarted', 'callConnected']);
    expect(calls.first.arguments, {
      'callId': 'channel-1',
      'displayName': 'Voice call',
    });
  });

  test('leaving a connected call reports it ended', () async {
    final (:lifecycle, :calls) = iosLifecycle();
    final session = FakeSession();
    final controller = harness.controllerWith(
      session,
      voiceApi(),
      callLifecycle: lifecycle,
    );

    unawaited(controller.join('channel-1'));
    await Future<void>.delayed(Duration.zero);
    session.emitState(VoiceSessionState.connecting);
    session.emitState(VoiceSessionState.connected);
    await Future<void>.delayed(Duration.zero);
    calls.clear();

    await controller.leave();
    await Future<void>.delayed(Duration.zero);

    expect(calls.map((c) => c.method), ['callEnded']);
  });

  test('a call the SFU drops reports it ended', () async {
    final (:lifecycle, :calls) = iosLifecycle();
    final session = FakeSession();
    final controller = harness.controllerWith(
      session,
      voiceApi(),
      callLifecycle: lifecycle,
    );

    unawaited(controller.join('channel-1'));
    await Future<void>.delayed(Duration.zero);
    session.emitState(VoiceSessionState.connecting);
    session.emitState(VoiceSessionState.connected);
    await Future<void>.delayed(Duration.zero);
    calls.clear();

    session.dropWith(VoiceDisconnect.removed);
    await Future<void>.delayed(Duration.zero);

    expect(calls.map((c) => c.method), ['callEnded']);
  });

  test('an endCall from the system call UI leaves the room', () async {
    final (:lifecycle, :calls) = iosLifecycle();
    final session = FakeSession();
    harness.controllerWith(session, voiceApi(), callLifecycle: lifecycle);

    unawaited(
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            _channelName,
            const StandardMethodCodec().encodeMethodCall(
              const MethodCall('endCall'),
            ),
            (_) {},
          ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(session.leaveCalls, 1);
  });
}
