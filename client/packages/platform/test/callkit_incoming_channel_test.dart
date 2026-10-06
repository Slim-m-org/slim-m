// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// CallKit events held by the native side are taken once, and later ones
/// arrive live.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_platform/platform.dart';

const _channelName = 'top.npcserver.slimm/callkit_incoming';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  test('pending events come back in order and bad rows are dropped', () async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel(_channelName),
      (call) async => [
        {'event': 'ringing', 'id': 'a'},
        {'event': 'nonsense', 'id': 'a'},
        {'event': 'answered', 'id': 'a'},
      ],
    );
    addTearDown(
      () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel(_channelName),
        null,
      ),
    );
    final channel = CallKitIncomingChannel(isIOS: true);
    addTearDown(channel.dispose);

    final pending = await channel.takePending();
    expect(pending.map((e) => e.kind), [
      CallKitIncomingKind.ringing,
      CallKitIncomingKind.answered,
    ]);
  });

  test('a live event reaches the stream', () async {
    final channel = CallKitIncomingChannel(isIOS: true);
    addTearDown(channel.dispose);
    final seen = <CallKitIncomingKind>[];
    channel.events.listen((e) => seen.add(e.kind));

    await binding.defaultBinaryMessenger.handlePlatformMessage(
      _channelName,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('onCallKitEvent', {'event': 'ended', 'id': 'a'}),
      ),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);
    expect(seen, [CallKitIncomingKind.ended]);
  });

  test('off iOS nothing is pending', () async {
    expect(await CallKitIncomingChannel(isIOS: false).takePending(), isEmpty);
  });
}
