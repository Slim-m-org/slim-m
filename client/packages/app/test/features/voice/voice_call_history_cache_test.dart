// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A voice channel's call history outlives the visit: coming back shows it at
/// once, and a change made while away refetches behind the old history.
library;

import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/voice/providers/voice_call_history.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';

import '../../support/fake_api.dart';

typedef _Rig = ({
  ProviderContainer container,
  StreamController<api.ServerEvent> events,
  List<String> requests,
});

_Rig _rig({int status = 200}) {
  final events = StreamController<api.ServerEvent>.broadcast();
  final requests = <String>[];
  final container = ProviderContainer(
    overrides: [
      sessionProvider.overrideWithValue(
        api.SessionStore(
          tokens: const api.TokenPair(
            userId: 'nick',
            accessToken: 'a',
            refreshToken: 'r',
            accessExpiresAt: 0,
          ),
        ),
      ),
      liveEventsProvider.overrideWithValue(events.stream),
      mockApiOverride((request) async {
        requests.add(request.url.path);
        return http.Response(
          jsonEncode({
            'retention_days': 30,
            'canvas_object_count': requests.length,
            'calls': const <Object>[],
          }),
          status,
          headers: const {'content-type': 'application/json'},
        );
      }),
    ],
  );
  return (container: container, events: events, requests: requests);
}

ProviderSubscription<AsyncValue<api.VoiceCallHistory>> _visit(_Rig rig) =>
    rig.container.listen(voiceCallHistoryProvider('voice-1'), (_, _) {});

void _settle(FakeAsync async) => async.elapse(const Duration(milliseconds: 50));

void _leave(FakeAsync async, ProviderSubscription<Object?> visit) {
  visit.close();
  _settle(async);
}

void main() {
  test('a second visit shows the history it already has', () {
    fakeAsync((async) {
      final rig = _rig();
      addTearDown(rig.container.dispose);
      final first = _visit(rig);
      _settle(async);
      expect(first.read().hasValue, isTrue);
      _leave(async, first);

      final second = _visit(rig);
      expect(second.read().valueOrNull?.retentionDays, 30, reason: 'no wait');
      _settle(async);
      expect(rig.requests, hasLength(1));
    });
  });

  test('a change while away refetches on return, behind the old history', () {
    fakeAsync((async) {
      final rig = _rig();
      addTearDown(rig.container.dispose);
      final first = _visit(rig);
      _settle(async);
      _leave(async, first);
      rig.events.add(
        const api.VoiceParticipantJoined(channelId: 'voice-1', userId: 'kiki'),
      );
      async.elapse(voiceCallHistoryRefreshDelay * 2);
      expect(rig.requests, hasLength(1), reason: 'nobody is looking');

      final second = _visit(rig);
      expect(second.read().valueOrNull?.canvasObjectCount, 1);
      _settle(async);
      expect(rig.requests, hasLength(2));
      expect(second.read().valueOrNull?.canvasObjectCount, 2);
    });
  });

  test('a failed load is not kept for the next visit', () {
    fakeAsync((async) {
      final rig = _rig(status: 500);
      addTearDown(rig.container.dispose);
      final first = _visit(rig);
      _settle(async);
      expect(first.read().hasError, isTrue);
      _leave(async, first);

      _visit(rig);
      _settle(async);
      expect(rig.requests, hasLength(2));
    });
  });
}
