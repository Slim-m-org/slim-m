// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Coverage for `BatchProfilesController`'s two reconciliation halves: a
/// live `ProfileChanged` frame evicts the renamed id while the app stays
/// open, and `clear()` forgets everything on a reconnect that may have
/// missed one.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/members/providers/user_profiles.dart';
import '../../support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Map<String, dynamic> _userJson(String id, String name) => {
  'id': id,
  'username': id,
  'display_name': name,
  'created_at': 0,
};

void main() {
  test('a profile.changed frame evicts only the id it names', () async {
    final events = StreamController<api.ServerEvent>.broadcast();
    addTearDown(events.close);
    var callCount = 0;

    final container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        liveEventsProvider.overrideWithValue(events.stream),
        mockApiOverride((request) async {
          callCount++;
          return http.Response(
            jsonEncode([
              _userJson('u1', 'Dave $callCount'),
              _userJson('u2', 'Priya'),
            ]),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      ],
    );
    addTearDown(container.dispose);

    final notifier = container.read(batchProfilesControllerProvider.notifier);
    await notifier.resolve(['u1', 'u2']);
    expect(callCount, 1);
    expect(
      container.read(batchProfilesControllerProvider)['u1']!.displayName,
      'Dave 1',
    );

    events.add(const api.ProfileChanged(userId: 'u1'));
    await Future<void>.delayed(Duration.zero);

    expect(
      container.read(batchProfilesControllerProvider).containsKey('u1'),
      isFalse,
      reason:
          'the renamed id must be forgotten so the next resolve refetches it',
    );
    expect(
      container.read(batchProfilesControllerProvider)['u2']!.displayName,
      'Priya',
      reason: 'an uninvolved id must not be evicted alongside it',
    );

    await notifier.resolve(['u1', 'u2']);
    expect(callCount, 2, reason: 'only the evicted id needed a fresh fetch');
    expect(
      container.read(batchProfilesControllerProvider)['u1']!.displayName,
      'Dave 2',
    );
  });

  test('clear() forgets every cached profile', () async {
    final events = StreamController<api.ServerEvent>.broadcast();
    addTearDown(events.close);

    final container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        liveEventsProvider.overrideWithValue(events.stream),
        mockApiOverride((request) async {
          return http.Response(
            jsonEncode([_userJson('u1', 'Dave')]),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      ],
    );
    addTearDown(container.dispose);

    final notifier = container.read(batchProfilesControllerProvider.notifier);
    await notifier.resolve(['u1']);
    expect(container.read(batchProfilesControllerProvider), isNotEmpty);

    notifier.clear();
    expect(container.read(batchProfilesControllerProvider), isEmpty);
  });
}
