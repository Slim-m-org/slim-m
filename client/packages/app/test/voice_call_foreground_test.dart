// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The controller must keep Android's call foreground service in step with
/// the call and with a screen share, with the capture consent asked first.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/call_foreground_keeper.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart';

import 'features/voice/voice_controller_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final harness = VoiceHarness();
  tearDown(harness.dispose);

  late List<String> events;
  late FakeSession session;
  late bool consent;

  setUp(() {
    events = [];
    consent = true;
    session = FakeSession();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('top.npcserver.slimm/calls'),
          (call) async {
            final a = call.arguments as Map;
            events.add('service call=${a['call']} share=${a['share']}');
            return null;
          },
        );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('top.npcserver.slimm/calls'),
            null,
          ),
    );
  });

  Future<VoiceController> connected() async {
    final controller = harness.controllerWith(
      session,
      voiceApi(),
      foreground: CallForegroundKeeper(
        service: CallService(isAndroid: true),
        requestCapturePermission: () async {
          events.add('consent');
          return consent;
        },
      ),
    );
    unawaited(controller.join('channel-1'));
    await Future<void>.delayed(Duration.zero);
    session.emitState(VoiceSessionState.connecting);
    session.emitState(VoiceSessionState.connected);
    await Future<void>.delayed(Duration.zero);
    return controller;
  }

  test('connecting starts the service and leaving stops it', () async {
    final controller = await connected();
    expect(events, ['service call=true share=false']);
    await controller.leave();
    await Future<void>.delayed(Duration.zero);
    expect(events.last, 'service call=false share=false');
  });

  test(
    'a share asks consent, then starts the service, then captures',
    () async {
      final controller = await connected();
      events.clear();
      await controller.setScreenShare(true);
      expect(events, ['consent', 'service call=true share=true']);
      expect(session.shareCalls, hasLength(1));
    },
  );

  test('refused consent never reaches the capture', () async {
    final controller = await connected();
    consent = false;
    await controller.setScreenShare(true);
    expect(session.shareCalls, isEmpty);
    expect(controller.state.screenSharing, isFalse);
    expect(controller.state.error, isNotNull);
  });
}
