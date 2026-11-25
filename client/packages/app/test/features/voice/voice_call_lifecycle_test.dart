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

import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';

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

  Future<void> systemHangup() => TestDefaultBinaryMessengerBinding
      .instance
      .defaultBinaryMessenger
      .handlePlatformMessage(
        _channelName,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('endCall'),
        ),
        (_) {},
      );

  test('an endCall from the system call UI leaves the room', () async {
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

    unawaited(systemHangup());
    await Future<void>.delayed(Duration.zero);

    expect(session.leaveCalls, 1);
  });

  test('a system hangup leaves an account with no call alone', () async {
    final (:lifecycle, :calls) = iosLifecycle();
    final session = FakeSession();
    harness.controllerWith(session, voiceApi(), callLifecycle: lifecycle);

    unawaited(systemHangup());
    await Future<void>.delayed(Duration.zero);

    expect(session.leaveCalls, 0);
  });

  test('the end names the call it reports, never another account\'s', () async {
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

    expect(calls.single.arguments, {'callId': 'channel-1'});
  });

  Future<void> nativeCall(String method, Object? arguments) =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            _channelName,
            const StandardMethodCodec().encodeMethodCall(
              MethodCall(method, arguments),
            ),
            (_) {},
          );

  Future<VoiceController> connectedCall(
    FakeSession session,
    CallLifecycleChannel lifecycle,
  ) async {
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
    return controller;
  }

  test('muting from the system call screen mutes the microphone', () async {
    final (:lifecycle, :calls) = iosLifecycle();
    final controller = await connectedCall(FakeSession(), lifecycle);
    expect(controller.state.microphoneEnabled, isTrue);

    await nativeCall('muteRequest', {'muted': true});
    await Future<void>.delayed(Duration.zero);

    expect(controller.state.microphoneEnabled, isFalse);
  });

  test('a system unmute while already live changes nothing', () async {
    final (:lifecycle, :calls) = iosLifecycle();
    final controller = await connectedCall(FakeSession(), lifecycle);

    await nativeCall('muteRequest', {'muted': false});
    await Future<void>.delayed(Duration.zero);

    expect(controller.state.microphoneEnabled, isTrue);
  });

  test('a system mute with no call up is ignored', () async {
    final (:lifecycle, :calls) = iosLifecycle();
    final controller = harness.controllerWith(
      FakeSession(),
      voiceApi(),
      callLifecycle: lifecycle,
    );

    await nativeCall('muteRequest', {'muted': true});
    await Future<void>.delayed(Duration.zero);

    expect(controller.state.microphoneEnabled, isTrue);
  });

  test('muting in the app tells the system call screen', () async {
    final (:lifecycle, :calls) = iosLifecycle();
    final controller = await connectedCall(FakeSession(), lifecycle);
    calls.clear();

    await controller.toggleMicrophone();
    await Future<void>.delayed(Duration.zero);

    expect(calls.map((c) => c.method), ['callMuted']);
    expect(calls.single.arguments, {'muted': true});
  });

  test(
    'a mute that came from the system is told back once, not echoed forever',
    () async {
      final (:lifecycle, :calls) = iosLifecycle();
      await connectedCall(FakeSession(), lifecycle);
      calls.clear();

      await nativeCall('muteRequest', {'muted': true});
      await Future<void>.delayed(Duration.zero);

      expect(calls.where((c) => c.method == 'callMuted'), hasLength(1));
    },
  );
}
