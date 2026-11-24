// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Native call events exist once per process but every account has its own
/// container: they reach the account that owns the call, never all of them
/// and never just the last one built.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/voice/providers/call_foreground_keeper.dart';
import 'package:slimm_app/src/features/voice/providers/call_owner.dart';
import 'package:slimm_app/src/features/voice/providers/dm_call_ring_controller.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart' show VoiceSessionState;

import '../accounts/account_host_harness.dart';

const _callKit = 'top.npcserver.slimm/callkit_incoming';
const _calls = 'top.npcserver.slimm/calls';
const _a = 'https://first.example';
const _b = 'https://second.example';

final _ownsEvents = Provider<bool Function()>(
  (ref) =>
      () => ownsCallEvents(ref),
);
final _otherInCall = Provider<bool Function()>(
  (ref) =>
      () => otherAccountInCall(ref),
);

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  late AccountHarness h;
  late ProviderContainer first;
  late ProviderContainer second;

  setUp(() async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel(_callKit),
      (call) async => call.method == 'takePending' ? <Object?>[] : null,
    );
    final live = StreamController<api.ServerEvent>.broadcast();
    addTearDown(live.close);
    h = AccountHarness(
      extraOverrides: [
        liveEventsProvider.overrideWithValue(live.stream),
        callKitIncomingChannelProvider.overrideWith((ref) {
          final channel = CallKitIncomingChannel(isIOS: true);
          ref.onDispose(channel.dispose);
          return channel;
        }),
      ],
    );
    await h.seed(_a, user: 'ann', active: true);
    await h.seed(_b, user: 'bea');
    await h.boot();
    first = h.host.runtimeFor(_a)!.container;
    second = h.host.runtimeFor(_b)!.container;
  });

  tearDown(() async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel(_callKit),
      null,
    );
    await h.dispose();
  });

  Future<void> nativeRings() =>
      binding.defaultBinaryMessenger.handlePlatformMessage(
        _callKit,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('onCallKitEvent', {
            'event': 'ringing',
            'id': 'uuid-1',
          }),
        ),
        (_) {},
      );

  CallKitPhase phase(ProviderContainer c) =>
      c.read(dmCallRingControllerProvider).callKit;

  test(
    'a CallKit ring reaches the account on screen once, not the last built',
    () async {
      first.read(dmCallRingControllerProvider);
      second.read(dmCallRingControllerProvider);

      await nativeRings();

      expect(phase(first), CallKitPhase.ringing);
      expect(phase(second), CallKitPhase.none);
    },
  );

  test(
    'a CallKit event goes to the account in a call, on screen or not',
    () async {
      first.read(dmCallRingControllerProvider);
      second.read(dmCallRingControllerProvider);
      second.read(testCallProvider.notifier).state = connectedCall;
      await pumpEventQueueTimes();

      await nativeRings();

      expect(phase(second), CallKitPhase.ringing);
      expect(phase(first), CallKitPhase.none);
    },
  );

  test('only the account in the call owns call events', () async {
    expect(first.read(_ownsEvents)(), isTrue);
    expect(second.read(_ownsEvents)(), isFalse);

    second.read(testCallProvider.notifier).state = connectedCall;
    await pumpEventQueueTimes();

    expect(first.read(_ownsEvents)(), isFalse);
    expect(second.read(_ownsEvents)(), isTrue);
    expect(first.read(_otherInCall)(), isTrue);
    expect(second.read(_otherInCall)(), isFalse);
  });

  test('a keeper that may not update never stops the shared service', () async {
    final sent = <Object?>[];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel(_calls),
      (call) async {
        sent.add(call.arguments);
        return null;
      },
    );
    addTearDown(
      () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel(_calls),
        null,
      ),
    );
    second.read(testCallProvider.notifier).state = connectedCall;
    await pumpEventQueueTimes();
    final idle = CallForegroundKeeper(
      service: CallService(isAndroid: true),
      mayUpdate: () => !first.read(_otherInCall)(),
    );

    idle.sessionState(VoiceSessionState.idle);
    await pumpEventQueueTimes();

    expect(sent, isEmpty);
  });
}
