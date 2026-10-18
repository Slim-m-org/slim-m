// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [voiceRosterProvider]'s polling contract: a text-only deployment stops
/// asking, a transient failure keeps the last known roster rather than
/// clearing it, and an interval governs the real network cost rather than
/// however often something happens to watch it.
library;

import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/app_lifecycle.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/voice/providers/voice_roster.dart';

const _tokens = api.TokenPair(
  userId: 'u-me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 4102444800000,
);

final _focus = StateProvider<bool>((ref) => true);
final _socketLive = StateProvider<bool>((ref) => false);

ProviderContainer _containerWith(
  http.Client httpClient, {
  Stream<api.ServerEvent>? liveEvents,
}) {
  final apiClient = api.SlimmApi(
    baseUrl: Uri.parse('http://localhost:8080'),
    session: api.SessionStore(tokens: _tokens),
    httpClient: httpClient,
  );
  addTearDown(apiClient.close);
  final container = ProviderContainer(
    overrides: [
      apiProvider.overrideWithValue(apiClient),
      appFocusedProvider.overrideWith((ref) => ref.watch(_focus)),
      voiceRosterSocketLiveProvider.overrideWith(
        (ref) => ref.watch(_socketLive),
      ),
      if (liveEvents != null) liveEventsProvider.overrideWithValue(liveEvents),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

http.Response _roster(List<Map<String, String>> participants) =>
    http.Response(jsonEncode({'participants': participants}), 200);

void main() {
  test('a successful fetch surfaces the roster it was given', () {
    fakeAsync((async) {
      final container = _containerWith(
        MockClient(
          (_) async => _roster([
            {'user_id': 'u1', 'display_name': 'Alice'},
          ]),
        ),
      );
      final sub = container.listen(voiceRosterProvider('general'), (_, __) {});
      async.flushMicrotasks();

      final value = container.read(voiceRosterProvider('general')).value;
      expect(value, hasLength(1));
      expect(value!.single.displayName, 'Alice');
      sub.close();
    });
  });

  test(
    'a deployment with no voice ends the poll instead of retrying forever',
    () {
      fakeAsync((async) {
        var calls = 0;
        final container = _containerWith(
          MockClient((_) async {
            calls++;
            return http.Response('{"error":"no voice"}', 501);
          }),
        );
        final sub = container.listen(
          voiceRosterProvider('general'),
          (_, __) {},
        );
        async.flushMicrotasks();
        expect(calls, 1);
        expect(
          container.read(voiceRosterProvider('general')).isLoading,
          isTrue,
          reason: 'unknown forever, never a false empty list',
        );

        async.elapse(const Duration(hours: 1));
        expect(
          calls,
          1,
          reason: 'a text-only deployment is not worth asking again',
        );
        sub.close();
      });
    },
  );

  test(
    'a transient failure keeps the last known roster rather than clearing it',
    () {
      fakeAsync((async) {
        var calls = 0;
        final container = _containerWith(
          MockClient((_) async {
            calls++;
            if (calls == 1) {
              return _roster([
                {'user_id': 'u1', 'display_name': 'Alice'},
              ]);
            }
            return http.Response('{"error":"busy"}', 503);
          }),
        );
        final sub = container.listen(
          voiceRosterProvider('general'),
          (_, __) {},
        );
        async.flushMicrotasks();
        expect(
          container
              .read(voiceRosterProvider('general'))
              .value
              ?.single
              .displayName,
          'Alice',
        );

        async.elapse(voiceRosterPollInterval);
        expect(calls, 2, reason: 'the poll retried on schedule');
        expect(
          container
              .read(voiceRosterProvider('general'))
              .value
              ?.single
              .displayName,
          'Alice',
          reason: 'a transient failure must not erase a roster already known',
        );
        sub.close();
      });
    },
  );

  test("a fresh relaunch does not resurrect this client's own stale entry", () {
    fakeAsync((async) {
      final container = _containerWith(
        MockClient(
          (_) async => _roster([
            // What the server still answers moments after a force-quit.
            {'user_id': 'u-me', 'display_name': 'Me'},
            {'user_id': 'u1', 'display_name': 'Alice'},
          ]),
        ),
      );
      final sub = container.listen(voiceRosterProvider('general'), (_, __) {});
      async.flushMicrotasks();

      final value = container.read(voiceRosterProvider('general')).value;
      expect(
        value?.map((p) => p.userId),
        ['u1'],
        reason:
            'a client that never rejoined must not see itself listed as '
            'though it were already in the call',
      );
      sub.close();
    });
  });

  test(
    'the poll interval, not the caller, governs how often the SFU is hit',
    () {
      fakeAsync((async) {
        var calls = 0;
        final container = _containerWith(
          MockClient((_) async {
            calls++;
            return _roster(const []);
          }),
        );
        final sub = container.listen(
          voiceRosterProvider('general'),
          (_, __) {},
        );
        async.flushMicrotasks();
        expect(calls, 1);

        async.elapse(voiceRosterPollInterval * 3);
        expect(calls, 4, reason: 'one fetch plus three ticks of the interval');
        sub.close();
      });
    },
  );

  test('a voice.activity event for this channel refetches immediately, '
      'well before the poll interval would', () {
    fakeAsync((async) {
      var calls = 0;
      final events = StreamController<api.ServerEvent>.broadcast();
      addTearDown(events.close);
      final container = _containerWith(
        MockClient((_) async {
          calls++;
          return _roster(const []);
        }),
        liveEvents: events.stream,
      );
      final sub = container.listen(voiceRosterProvider('general'), (_, __) {});
      async.flushMicrotasks();
      expect(calls, 1);

      events.add(const api.VoiceActivityChanged(channelId: 'general'));
      async.flushMicrotasks();
      expect(
        calls,
        2,
        reason: 'a join or hangup must not wait out the poll interval',
      );
      sub.close();
    });
  });

  test('the named webhook-sourced voice events also refetch immediately', () {
    fakeAsync((async) {
      var calls = 0;
      final events = StreamController<api.ServerEvent>.broadcast();
      addTearDown(events.close);
      final container = _containerWith(
        MockClient((_) async {
          calls++;
          return _roster(const []);
        }),
        liveEvents: events.stream,
      );
      final sub = container.listen(voiceRosterProvider('general'), (_, __) {});
      async.flushMicrotasks();
      expect(calls, 1);

      events.add(
        const api.VoiceParticipantJoined(channelId: 'general', userId: 'u1'),
      );
      async.flushMicrotasks();
      expect(calls, 2, reason: 'voice.participant_joined refetches too');

      events.add(
        const api.VoiceParticipantLeft(channelId: 'general', userId: 'u1'),
      );
      async.flushMicrotasks();
      expect(calls, 3, reason: 'voice.participant_left refetches too');

      events.add(
        const api.VoiceScreenShareChanged(
          channelId: 'general',
          userId: 'u1',
          isSharingScreen: true,
        ),
      );
      async.flushMicrotasks();
      expect(calls, 4, reason: 'voice.screen_share_changed refetches too');
      sub.close();
    });
  });

  test('a short run of failures stays quiet, matching the transient case', () {
    fakeAsync((async) {
      final container = _containerWith(
        MockClient((_) async => http.Response('{"error":"busy"}', 503)),
      );
      final sub = container.listen(voiceRosterProvider('general'), (_, __) {});
      async.flushMicrotasks();

      // One tick short of the threshold: still ordinary "not known yet" loading, never an error.
      async.elapse(voiceRosterPollInterval);
      expect(
        container.read(voiceRosterProvider('general')).hasError,
        isFalse,
        reason: 'a short run of bad ticks is not yet a broken poll',
      );
      sub.close();
    });
  });

  test('a sustained run of failures surfaces as a distinct error state, '
      'not silence', () {
    fakeAsync((async) {
      final container = _containerWith(
        MockClient((_) async => http.Response('{"error":"busy"}', 503)),
      );
      final sub = container.listen(voiceRosterProvider('general'), (_, __) {});
      async.flushMicrotasks();

      async.elapse(const Duration(seconds: 45));
      final state = container.read(voiceRosterProvider('general'));
      expect(
        state.hasError,
        isTrue,
        reason:
            '$persistentRosterFailureThreshold unbroken failures is a '
            'broken poll, not this tick\'s bad luck',
      );
      expect(
        state.valueOrNull,
        isNull,
        reason: 'nothing was ever fetched, so there is no roster to keep',
      );
      sub.close();
    });
  });

  test('a success after a sustained failure clears the error, not just adds '
      'a value beside it', () {
    fakeAsync((async) {
      var calls = 0;
      final container = _containerWith(
        MockClient((_) async {
          calls++;
          if (calls <= persistentRosterFailureThreshold) {
            return http.Response('{"error":"busy"}', 503);
          }
          return _roster([
            {'user_id': 'u1', 'display_name': 'Alice'},
          ]);
        }),
      );
      final sub = container.listen(voiceRosterProvider('general'), (_, __) {});
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 45));
      expect(container.read(voiceRosterProvider('general')).hasError, isTrue);

      async.elapse(const Duration(seconds: 60));
      final state = container.read(voiceRosterProvider('general'));
      expect(state.hasError, isFalse);
      expect(state.value?.single.displayName, 'Alice');
      sub.close();
    });
  });

  test('a voice.activity event for a different channel is ignored', () {
    fakeAsync((async) {
      var calls = 0;
      final events = StreamController<api.ServerEvent>.broadcast();
      addTearDown(events.close);
      final container = _containerWith(
        MockClient((_) async {
          calls++;
          return _roster(const []);
        }),
        liveEvents: events.stream,
      );
      final sub = container.listen(voiceRosterProvider('general'), (_, __) {});
      async.flushMicrotasks();
      expect(calls, 1);

      events.add(const api.VoiceActivityChanged(channelId: 'other'));
      async.flushMicrotasks();
      expect(
        calls,
        1,
        reason: 'this provider only cares about its own channel id',
      );
      sub.close();
    });
  });

  test('a hidden window stops polling and refetches once on focus', () {
    fakeAsync((async) {
      var calls = 0;
      final container = _containerWith(
        MockClient((_) async {
          calls++;
          return _roster(const []);
        }),
      );
      final sub = container.listen(voiceRosterProvider('general'), (_, __) {});
      async.flushMicrotasks();
      expect(calls, 1);

      container.read(_focus.notifier).state = false;
      async.flushMicrotasks();
      async.elapse(const Duration(hours: 1));
      expect(calls, 1, reason: 'a window in the tray must not poll');

      container.read(_focus.notifier).state = true;
      async.elapse(const Duration(milliseconds: 1));
      expect(calls, 2, reason: 'one refresh on focus');
      async.elapse(voiceRosterPollInterval);
      expect(calls, 3, reason: 'and the poll resumes');
      sub.close();
    });
  });

  test('a live socket slows the poll to the backstop interval', () {
    fakeAsync((async) {
      var calls = 0;
      final container = _containerWith(
        MockClient((_) async {
          calls++;
          return _roster(const []);
        }),
      );
      container.read(_socketLive.notifier).state = true;
      final sub = container.listen(voiceRosterProvider('general'), (_, __) {});
      async.flushMicrotasks();
      async.elapse(const Duration(minutes: 5));
      expect(calls, 1 + 5, reason: 'one a minute, not one every 15 seconds');
      sub.close();
    });
  });

  test('failures back off exponentially up to the cap', () {
    fakeAsync((async) {
      var calls = 0;
      final container = _containerWith(
        MockClient((_) async {
          calls++;
          return http.Response('{"error":"busy"}', 503);
        }),
      );
      final sub = container.listen(voiceRosterProvider('general'), (_, __) {});
      async.flushMicrotasks();
      async.elapse(const Duration(minutes: 10));
      expect(calls, lessThan(10), reason: 'a flat 15 seconds would be 41');
      expect(
        voiceRosterDelay(live: false, failures: 20),
        voiceRosterMaxBackoff,
      );
      sub.close();
    });
  });
}
