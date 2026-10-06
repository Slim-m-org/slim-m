// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A DM ring reaches an iPhone twice, once as the CallKit call a VoIP push
/// shows and once as the websocket's `call.ringing`. They are one call:
/// answering on the system screen joins it, and the in-app prompt never shows.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/dm_call.dart';
import 'package:slimm_app/src/providers/dm_call_ring_controller.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/voice_controller.dart';
import 'package:slimm_app/src/routing/router.dart';
import 'package:slimm_platform/platform.dart';

const _channelName = 'top.npcserver.slimm/callkit_incoming';

const _tokens = api.TokenPair(
  userId: 'me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 4102444800000,
);

const _ringFrame = api.CallRinging(
  channelId: 'dm-1',
  ringId: 'ring-1',
  callerId: 'caller-1',
);

class _RecordingVoice extends VoiceController {
  _RecordingVoice(super.ref);

  final joined = <String>[];

  @override
  Future<void> join(String channelId) async => joined.add(channelId);
}

class _Rig {
  _Rig(this.container, this.events, this.voice, this.router);

  final ProviderContainer container;
  final StreamController<api.ServerEvent> events;
  final _RecordingVoice voice;
  final GoRouter router;

  DmCallRingState get ring => container.read(dmCallRingControllerProvider);

  Future<void> nativeSends(String event) {
    return TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          _channelName,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('onCallKitEvent', {'event': event, 'id': 'uuid-1'}),
          ),
          (_) {},
        );
  }

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 20));
}

Future<_Rig> _rig({List<Map<String, String>> pending = const []}) async {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel(_channelName),
        (call) async => call.method == 'takePending' ? pending : null,
      );
  addTearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(_channelName), null),
  );
  final events = StreamController<api.ServerEvent>.broadcast();
  addTearDown(events.close);
  final router = GoRouter(
    routes: [GoRoute(path: '/', builder: (_, __) => throw 0)],
  );
  late _RecordingVoice voice;
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      liveEventsProvider.overrideWithValue(events.stream),
      routerProvider.overrideWithValue(router),
      callKitIncomingChannelProvider.overrideWithValue(
        CallKitIncomingChannel(isIOS: true),
      ),
      voiceControllerProvider.overrideWith(
        (ref) => voice = _RecordingVoice(ref),
      ),
      storeProvider.overrideWith((ref) async => throw StateError('no store')),
    ],
  );
  addTearDown(container.dispose);
  container.read(dmCallRingControllerProvider);
  container.read(voiceControllerProvider);
  final rig = _Rig(container, events, voice, router);
  await rig.settle();
  return rig;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('answering on CallKit before the ring frame joins on arrival', () async {
    final rig = await _rig();
    await rig.nativeSends('ringing');
    await rig.nativeSends('answered');
    expect(rig.voice.joined, isEmpty, reason: 'no channel is known yet');

    rig.events.add(_ringFrame);
    await rig.settle();

    expect(rig.voice.joined, ['dm-1']);
    expect(rig.container.read(dmCallOpenProvider), 'dm-1');
    expect(rig.ring.visibleIncoming, isNull);
    expect(rig.ring.incoming, isNull, reason: 'the ring was consumed');
  });

  test('answering on CallKit after the ring frame joins at once', () async {
    final rig = await _rig();
    await rig.nativeSends('ringing');
    rig.events.add(_ringFrame);
    await rig.settle();
    expect(rig.voice.joined, isEmpty);

    await rig.nativeSends('answered');
    await rig.settle();

    expect(rig.voice.joined, ['dm-1']);
    expect(rig.ring.incoming, isNull);
  });

  test('an answer made before Dart started is replayed', () async {
    final rig = await _rig(
      pending: [
        {'event': 'ringing', 'id': 'uuid-1'},
        {'event': 'answered', 'id': 'uuid-1'},
      ],
    );
    rig.events.add(_ringFrame);
    await rig.settle();

    expect(rig.voice.joined, ['dm-1']);
  });

  test('while CallKit rings, the in-app ring stays hidden', () async {
    final rig = await _rig();
    await rig.nativeSends('ringing');
    rig.events.add(_ringFrame);
    await rig.settle();

    expect(rig.ring.incoming, isNotNull);
    expect(rig.ring.visibleIncoming, isNull);
  });

  test('without CallKit the in-app ring shows as before', () async {
    final rig = await _rig();
    rig.events.add(_ringFrame);
    await rig.settle();

    expect(rig.ring.visibleIncoming?.channelId, 'dm-1');
    expect(rig.voice.joined, isEmpty);
  });

  test('declining on CallKit ends the in-app ring too', () async {
    final rig = await _rig();
    await rig.nativeSends('ringing');
    rig.events.add(_ringFrame);
    await rig.settle();

    await rig.nativeSends('ended');
    await rig.settle();

    expect(rig.ring.incoming, isNull);
    expect(rig.ring.callKit, CallKitPhase.none);
  });

  test(
    'a finished CallKit call does not swallow the next in-app ring',
    () async {
      final rig = await _rig();
      await rig.nativeSends('ringing');
      await rig.nativeSends('ended');
      rig.events.add(_ringFrame);
      await rig.settle();

      expect(rig.ring.visibleIncoming?.ringId, 'ring-1');
    },
  );
}
