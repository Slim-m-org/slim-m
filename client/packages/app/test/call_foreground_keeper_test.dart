// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/call_foreground_keeper.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<Map<Object?, Object?>> sent;
  late bool consent;
  late int notificationAsks;
  late CallForegroundKeeper keeper;

  setUp(() {
    sent = [];
    consent = true;
    notificationAsks = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('top.npcserver.slimm/calls'),
          (call) async {
            sent.add(Map<Object?, Object?>.from(call.arguments as Map));
            return null;
          },
        );
    keeper = CallForegroundKeeper(
      service: CallService(isAndroid: true),
      requestCapturePermission: () async => consent,
      requestNotifications: () async => notificationAsks++,
    );
  });

  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('top.npcserver.slimm/calls'),
          null,
        ),
  );

  Map<String, bool> state({
    bool call = false,
    bool camera = false,
    bool share = false,
  }) => {'call': call, 'camera': camera, 'share': share};

  test('starts on connect, not while connecting', () async {
    keeper.sessionState(VoiceSessionState.connecting);
    expect(sent, isEmpty);
    keeper.sessionState(VoiceSessionState.connected);
    await Future<void>.delayed(Duration.zero);
    expect(sent.single, state(call: true));
    expect(notificationAsks, 1);
  });

  test('stops on leave and on a drop', () async {
    keeper.sessionState(VoiceSessionState.connected);
    keeper.sessionState(VoiceSessionState.idle);
    keeper.sessionState(VoiceSessionState.connected);
    keeper.sessionState(VoiceSessionState.failed);
    await Future<void>.delayed(Duration.zero);
    expect(sent.map((s) => s['call']), [true, false, true, false]);
    expect(notificationAsks, 1);
  });

  test('camera joins and leaves the service type', () async {
    keeper.sessionState(VoiceSessionState.connected);
    keeper.media(camera: true, sharing: false);
    keeper.media(camera: false, sharing: false);
    await Future<void>.delayed(Duration.zero);
    expect(sent.map((s) => s['camera']), [false, true, false]);
  });

  test('a share starts the service before capture, after consent', () async {
    keeper.sessionState(VoiceSessionState.connected);
    expect(await keeper.beforeShare(), isTrue);
    expect(sent.last, state(call: true, share: true));
    keeper.media(camera: false, sharing: false);
    expect(sent.last['share'], isTrue, reason: 'roster lag must not stop it');
    keeper.shareSettled(started: true);
    keeper.media(camera: false, sharing: false);
    await Future<void>.delayed(Duration.zero);
    expect(sent.last, state(call: true));
  });

  test('refused consent starts nothing', () async {
    keeper.sessionState(VoiceSessionState.connected);
    consent = false;
    final before = sent.length;
    expect(await keeper.beforeShare(), isFalse);
    expect(sent.length, before);
  });

  test('a share that fails to start releases the service', () async {
    keeper.sessionState(VoiceSessionState.connected);
    await keeper.beforeShare();
    keeper.shareSettled(started: false);
    await Future<void>.delayed(Duration.zero);
    expect(sent.last, state(call: true));
  });

  test('off Android nothing is sent and a share needs no consent', () async {
    final plain = CallForegroundKeeper(
      service: CallService(isAndroid: false),
      requestCapturePermission: () async => false,
    );
    plain.sessionState(VoiceSessionState.connected);
    expect(await plain.beforeShare(), isTrue);
    expect(sent, isEmpty);
  });
}
