// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/presence_activity.dart';
import 'package:slimm_app/src/providers/presence_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = TokenPair(
  userId: 'me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

void main() {
  test('a live presence.changed that lands while GET /presence is in flight '
      'is not overwritten by the older snapshot', () async {
    final events = StreamController<ServerEvent>.broadcast();
    addTearDown(events.close);
    final response = Completer<http.Response>();
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
        liveEventsProvider.overrideWithValue(events.stream),
        apiProvider.overrideWith((ref) {
          final api = SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: MockClient((request) => response.future),
          );
          ref.onDispose(api.close);
          return api;
        }),
      ],
    );
    addTearDown(container.dispose);
    container.listen(presenceControllerProvider, (_, __) {});
    final controller = container.read(presenceControllerProvider.notifier);

    final refresh = controller.refresh(['u1']);
    await pumpEventQueue();

    // u1 goes offline after the server built its snapshot but before we read it.
    events.add(
      const PresenceChanged(userId: 'u1', status: PresenceState.offline),
    );
    await pumpEventQueue();
    expect(
      container.read(presenceControllerProvider)['u1'],
      PresenceState.offline,
    );

    response.complete(
      http.Response(
        jsonEncode([
          {
            'user_id': 'u1',
            'status': 'online',
            'activity': {'kind': 'listening', 'title': 'Old song'},
          },
        ]),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    await refresh;

    expect(
      container.read(presenceControllerProvider)['u1'],
      PresenceState.offline,
      reason: 'the older snapshot put u1 back online',
    );
    expect(
      container.read(presenceActivityProvider)['u1'],
      isNull,
      reason: 'the live event cleared the activity; the snapshot restored it',
    );
  });
}
