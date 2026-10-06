// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A DM ring reaches an iPhone twice, once as the CallKit call a VoIP push
/// shows and once as the websocket's `call.ringing`. They are one call:
/// answering on the system screen joins it, and the in-app prompt never shows.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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
  Future<void> join(String channelId) async {
    joined.add(channelId);
    state = VoiceState(channelId: channelId);
  }

  void hangUp() => state = const VoiceState();
}

Map<String, Object> _outstanding(String channelId, String ringId) => {
  'channel_id': channelId,
  'ring_id': ringId,
  'caller_id': 'caller-1',
  'remaining_ms': 20000,
};

class _Rig {
  _Rig(this.container, this.events, this.voice, this.router, this.ended);

  final ProviderContainer container;
  final StreamController<api.ServerEvent> events;
  final _RecordingVoice voice;
  final GoRouter router;

  /// Call ids Dart asked the native side to end.
  final List<String> ended;

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

/// [outstanding] is what the server lists as still ringing; null is a server
/// that cannot be reached.
Future<_Rig> _rig({
  List<Map<String, String>> pending = const [],
  List<Map<String, Object>>? outstanding,
}) async {
  final ended = <String>[];
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel(_channelName), (
        call,
      ) async {
        if (call.method == 'endCall') {
          ended.add((call.arguments as Map)['id'] as String);
        }
        return call.method == 'takePending' ? pending : null;
      });
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
      apiProvider.overrideWith((ref) {
        final client = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: api.SessionStore(tokens: _tokens),
          httpClient: MockClient((request) async {
            if (request.url.path != '/voice/rings/incoming' ||
                outstanding == null) {
              return http.Response('', 500);
            }
            return http.Response(
              jsonEncode({'rings': outstanding}),
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        );
        ref.onDispose(client.close);
        return client;
      }),
    ],
  );
  addTearDown(container.dispose);
  container.read(dmCallRingControllerProvider);
  container.read(voiceControllerProvider);
  final rig = _Rig(container, events, voice, router, ended);
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

  group('a cold launch answer with no ring frame', () {
    final answeredAtLaunch = [
      {'event': 'ringing', 'id': 'uuid-1'},
      {'event': 'answered', 'id': 'uuid-1'},
    ];

    test('asks the server for the ring and joins it', () async {
      final rig = await _rig(
        pending: answeredAtLaunch,
        outstanding: [_outstanding('dm-1', 'ring-1')],
      );
      await rig.settle();

      expect(rig.voice.joined, ['dm-1']);
      expect(rig.container.read(dmCallOpenProvider), 'dm-1');
      expect(rig.ring.incoming, isNull);
      expect(rig.ended, isEmpty, reason: 'the call is live, not over');
    });

    test(
      'a late ring frame for the joined ring is not prompted again',
      () async {
        final rig = await _rig(
          pending: answeredAtLaunch,
          outstanding: [_outstanding('dm-1', 'ring-1')],
        );
        await rig.settle();

        rig.events.add(_ringFrame);
        await rig.settle();

        expect(rig.voice.joined, ['dm-1'], reason: 'joined exactly once');
        expect(rig.ring.incoming, isNull);
      },
    );

    test('ends the system call when the ring is already over', () async {
      final rig = await _rig(pending: answeredAtLaunch, outstanding: []);
      await rig.settle();

      expect(rig.voice.joined, isEmpty);
      expect(rig.ended, ['uuid-1']);
      expect(rig.ring.callKit, CallKitPhase.none);
      expect(rig.ring.incoming, isNull);
    });

    test('an unreachable server leaves the ring frame to answer it', () async {
      final rig = await _rig(pending: answeredAtLaunch);
      await rig.settle();
      expect(rig.voice.joined, isEmpty);
      expect(rig.ended, isEmpty);

      rig.events.add(_ringFrame);
      await rig.settle();

      expect(rig.voice.joined, ['dm-1']);
    });

    test('hanging up on the system screen first never joins', () async {
      final rig = await _rig(
        pending: [
          ...answeredAtLaunch,
          {'event': 'ended', 'id': 'uuid-1'},
        ],
        outstanding: [_outstanding('dm-1', 'ring-1')],
      );
      await rig.settle();

      expect(rig.voice.joined, isEmpty);
    });
  });

  group('the system call does not outlive the call', () {
    test('it ends when the in-app call ends', () async {
      final rig = await _rig();
      await rig.nativeSends('ringing');
      rig.events.add(_ringFrame);
      await rig.nativeSends('answered');
      await rig.settle();
      expect(rig.voice.joined, ['dm-1']);
      expect(rig.ended, isEmpty);

      rig.voice.hangUp();
      await rig.settle();

      expect(rig.ended, ['uuid-1']);
    });

    test('it ends when the caller cancels while it rings', () async {
      final rig = await _rig();
      await rig.nativeSends('ringing');
      rig.events.add(_ringFrame);
      await rig.settle();

      rig.events.add(
        const api.CallRingEnded(
          channelId: 'dm-1',
          ringId: 'ring-1',
          outcome: api.CallRingOutcome.canceled,
        ),
      );
      await rig.settle();

      expect(rig.ended, ['uuid-1']);
      expect(rig.ring.callKit, CallKitPhase.none);
    });

    test('it ends when the ring times out before the join lands', () async {
      final rig = await _rig();
      await rig.nativeSends('ringing');
      rig.events.add(_ringFrame);
      await rig.settle();
      rig.events.add(
        const api.CallRingEnded(
          channelId: 'dm-1',
          ringId: 'ring-1',
          outcome: api.CallRingOutcome.timedOut,
        ),
      );
      await rig.settle();

      expect(rig.ended, ['uuid-1']);
    });
  });
}
