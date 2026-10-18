// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the features driven by the live event stream that
/// `SyncController` now broadcasts to anyone watching `liveEventsProvider`:
/// pins and typing. Both are tested against a fake event stream rather than
/// a real socket, since `liveEventsProvider` is just a `Provider<Stream<
/// ServerEvent>>` and is exactly the seam meant for that.
///
/// Both providers under test are `autoDispose`, so every test keeps one
/// alive with an explicit `container.listen(...)` subscription - the same
/// role a widget's own `ref.watch` plays in the real app. A bare
/// `container.read()` does not keep an `autoDispose` provider alive; without
/// a listener it is evicted the moment the read returns, and the next read
/// silently rebuilds a fresh instance with none of the state this file means
/// to observe.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/features/channels/providers/pins_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/messages/providers/typing_controller.dart';
import 'package:slimm_platform/platform.dart';
import 'support/fake_api.dart';

/// Waits several event-loop turns, enough for a mocked HTTP round trip
/// kicked off by a live event's listener to land.
Future<void> _settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Map<String, dynamic> _pinJson(String messageId) => {
  'id': messageId,
  'channel_id': 'c1',
  'author_id': 'author-1',
  'author_display_name': 'Priya',
  'seq': 1,
  'content': 'hello',
  'created_at': 0,
  'edited_at': null,
  'pinned_at': 0,
  'pinned_by': 'author-1',
};

void main() {
  group('pins', () {
    test(
      'the count reflects the server, and a live pin refreshes it',
      () async {
        final events = StreamController<ServerEvent>.broadcast();
        addTearDown(events.close);
        var pinned = <Map<String, dynamic>>[];

        final container = ProviderContainer(
          overrides: [
            keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
            sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
            mockApiOverride((request) async {
              return http.Response(
                jsonEncode(pinned),
                200,
                headers: {'content-type': 'application/json'},
              );
            }),
            liveEventsProvider.overrideWithValue(events.stream),
          ],
        );
        addTearDown(container.dispose);

        final sub = container.listen(pinsControllerProvider('c1'), (_, __) {});
        addTearDown(sub.close);

        await container.read(pinsControllerProvider('c1').notifier).refresh();
        expect(sub.read().pinned, isEmpty);
        expect(sub.read().failed, isFalse);

        // The server now has one pin; a live event is what should notice.
        pinned = [_pinJson('m1')];
        events.add(
          const MessagePinned(
            channelId: 'c1',
            messageId: 'm1',
            pinnedBy: 'author-1',
            pinnedAt: 0,
          ),
        );
        await _settle();

        final state = sub.read().pinned;
        expect(state, isNotNull);
        expect(state!.single.message.id, 'm1');
      },
    );

    test(
      'a failed refresh keeps the last known list and flags the failure',
      () async {
        final events = StreamController<ServerEvent>.broadcast();
        addTearDown(events.close);
        var fail = false;

        final container = ProviderContainer(
          overrides: [
            keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
            sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
            mockApiOverride((request) async {
              if (fail) return http.Response('server error', 500);
              return http.Response(
                jsonEncode([_pinJson('m1')]),
                200,
                headers: {'content-type': 'application/json'},
              );
            }),
            liveEventsProvider.overrideWithValue(events.stream),
          ],
        );
        addTearDown(container.dispose);

        final sub = container.listen(pinsControllerProvider('c1'), (_, __) {});
        addTearDown(sub.close);
        await _settle();
        expect(sub.read().pinned, hasLength(1));
        expect(sub.read().failed, isFalse);

        fail = true;
        await container.read(pinsControllerProvider('c1').notifier).refresh();

        expect(
          sub.read().failed,
          isTrue,
          reason: 'a failed refresh must be visible to the sheet',
        );
        expect(
          sub.read().pinned,
          hasLength(1),
          reason: 'the last known list must survive a failed refresh',
        );
      },
    );

    test('a fresh 403 never gets a retry that could not succeed', () async {
      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
          mockApiOverride((request) async {
            return http.Response('forbidden', 403);
          }),
          liveEventsProvider.overrideWithValue(const Stream.empty()),
        ],
      );
      addTearDown(container.dispose);

      final sub = container.listen(pinsControllerProvider('c1'), (_, __) {});
      addTearDown(sub.close);
      await _settle();

      expect(sub.read().failed, isTrue);
      expect(sub.read().forbidden, isTrue);
      expect(sub.read().pinned, isNull);
    });

    test('an event for a different channel is ignored', () async {
      final events = StreamController<ServerEvent>.broadcast();
      addTearDown(events.close);
      var fetchCount = 0;

      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
          mockApiOverride((request) async {
            // Refetches of the pin list, not every request the app makes.
            if (request.url.path.endsWith('/pins')) fetchCount++;
            return http.Response(
              '[]',
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
          liveEventsProvider.overrideWithValue(events.stream),
        ],
      );
      addTearDown(container.dispose);

      // Listening is what starts (and keeps alive) the controller; its
      // constructor already fires the initial fetch.
      final sub = container.listen(pinsControllerProvider('c1'), (_, __) {});
      addTearDown(sub.close);
      await _settle();
      expect(fetchCount, 1);

      events.add(
        const MessagePinned(
          channelId: 'some-other-channel',
          messageId: 'm2',
          pinnedBy: null,
          pinnedAt: 0,
        ),
      );
      await _settle();

      expect(fetchCount, 1, reason: 'a different channel must not refetch');
    });
  });

  group('typing', () {
    test('a typing event shows the user, and a stop event clears it', () async {
      final events = StreamController<ServerEvent>.broadcast();
      addTearDown(events.close);

      final container = ProviderContainer(
        overrides: [liveEventsProvider.overrideWithValue(events.stream)],
      );
      addTearDown(container.dispose);

      final sub = container.listen(typingControllerProvider('c1'), (_, __) {});
      addTearDown(sub.close);
      expect(sub.read(), isEmpty);

      events.add(const TypingStarted(channelId: 'c1', userId: 'user-1'));
      await _settle();
      expect(sub.read(), {'user-1'});

      events.add(const TypingStopped(channelId: 'c1', userId: 'user-1'));
      await _settle();
      expect(sub.read(), isEmpty);
    });

    test('typing in a different channel does not show here', () async {
      final events = StreamController<ServerEvent>.broadcast();
      addTearDown(events.close);

      final container = ProviderContainer(
        overrides: [liveEventsProvider.overrideWithValue(events.stream)],
      );
      addTearDown(container.dispose);

      final sub = container.listen(typingControllerProvider('c1'), (_, __) {});
      addTearDown(sub.close);

      events.add(const TypingStarted(channelId: 'c2', userId: 'user-1'));
      await _settle();

      expect(sub.read(), isEmpty);
    });
  });
}
