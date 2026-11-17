// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An incoming ring for the call this device is already in is no ring at all:
/// it never shows, and one already showing goes away on joining.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/voice/providers/dm_call_ring_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/testing.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

import '../../support/fake_voice.dart';

const _tokens = api.TokenPair(
  userId: 'me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 4102444800000,
);

const _ring = api.CallRinging(
  channelId: 'dm-1',
  ringId: 'ring-1',
  callerId: 'caller-1',
);

class _Rig {
  _Rig(this.container, this.events, this.voice);

  final ProviderContainer container;
  final StreamController<api.ServerEvent> events;
  final FakeVoiceController voice;

  DmCallRingState get state => container.read(dmCallRingControllerProvider);

  Future<void> rung() async {
    events.add(_ring);
    await Future<void>.delayed(Duration.zero);
  }
}

_Rig _rig({String? inCall}) {
  final events = StreamController<api.ServerEvent>.broadcast();
  addTearDown(events.close);
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      liveEventsProvider.overrideWithValue(events.stream),
      voiceControllerProvider.overrideWith(
        (ref) => FakeVoiceController(
          ref,
          recording: true,
          initial: inCall == null
              ? null
              : VoiceState(
                  state: VoiceSessionState.connected,
                  channelId: inCall,
                ),
        ),
      ),
      apiProvider.overrideWith(
        (ref) => testApi(
          (request) async => http.Response('[]', 200),
          session: api.SessionStore(tokens: _tokens),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  container.read(dmCallRingControllerProvider);
  final voice =
      container.read(voiceControllerProvider.notifier) as FakeVoiceController;
  return _Rig(container, events, voice);
}

void main() {
  test('a ring for the call this device is already in never shows', () async {
    final rig = _rig(inCall: 'dm-1');

    await rig.rung();

    expect(rig.state.visibleIncoming, isNull);
  });

  test('a ring for another call still shows while in a call', () async {
    final rig = _rig(inCall: 'voice-lounge');

    await rig.rung();

    expect(rig.state.visibleIncoming?.ringId, 'ring-1');
  });

  test('a showing ring goes away once this device joins that call', () async {
    final rig = _rig();
    await rig.rung();
    expect(rig.state.visibleIncoming?.ringId, 'ring-1');

    rig.voice.connect(channelId: 'dm-1');
    await Future<void>.delayed(Duration.zero);

    expect(rig.state.visibleIncoming, isNull);
  });

  test('a join that fails before connecting leaves the ring showing', () async {
    final rig = _rig();
    await rig.rung();

    rig.voice.set(
      const VoiceState(state: VoiceSessionState.connecting, channelId: 'dm-1'),
    );
    await Future<void>.delayed(Duration.zero);
    expect(rig.state.visibleIncoming?.ringId, 'ring-1');

    rig.voice.hangUp();
    await Future<void>.delayed(Duration.zero);
    expect(rig.state.visibleIncoming?.ringId, 'ring-1');
  });
}
