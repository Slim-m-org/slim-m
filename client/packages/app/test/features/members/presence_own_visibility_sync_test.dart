// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A visibility chosen on another device reaches this one without a restart.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/members/providers/presence_controller.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/fake_api.dart';

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

void main() {
  test('an own presence change refetches the stored visibility and drops the '
      'stale echo', () async {
    final events = StreamController<ServerEvent>.broadcast();
    addTearDown(events.close);
    var stored = 'online';
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
        liveEventsProvider.overrideWithValue(events.stream),
        mockApiOverride((request) async {
          return http.Response(
            jsonEncode({
              'id': 'self',
              'username': 'self',
              'display_name': 'Self',
              'created_at': 0,
              'permissions': 0,
              'presence_visibility': stored,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      ],
    );
    addTearDown(container.dispose);
    container.listen(presenceControllerProvider, (_, _) {});
    container.listen(ownVisibilityProvider, (_, _) {});
    container.read(presenceVisibilityDisplayProvider.notifier).state =
        PresenceVisibility.online;

    stored = 'hidden';
    events.add(
      const PresenceChanged(userId: 'self', status: PresenceState.online),
    );
    await pumpEventQueue();

    expect(container.read(ownVisibilityProvider), PresenceVisibility.hidden);
  });
}
