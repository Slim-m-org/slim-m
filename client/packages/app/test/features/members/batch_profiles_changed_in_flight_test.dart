// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A `profile.changed` frame that lands while that profile is being fetched
/// must not leave the older answer cached for everyone who reads it.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/members/providers/user_profiles.dart';
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

http.Response _named(String name) => http.Response(
  jsonEncode([
    {'id': 'u1', 'username': 'u1', 'display_name': name, 'created_at': 0},
  ]),
  200,
  headers: {'content-type': 'application/json'},
);

/// A server whose first answer for `u1` is held until [firstAnswer] is
/// completed, then says "Old"; every later answer says "New".
class _Rig {
  _Rig() {
    container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
        liveEventsProvider.overrideWithValue(events.stream),
        mockApiOverride((request) async {
          requests++;
          if (requests == 1) {
            await firstAnswer.future;
            return _named('Old');
          }
          return _named('New');
        }),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(events.close);
  }

  final events = StreamController<ServerEvent>.broadcast();
  final firstAnswer = Completer<void>();
  late final ProviderContainer container;
  int requests = 0;

  BatchProfilesController get profiles =>
      container.read(batchProfilesControllerProvider.notifier);
}

void main() {
  test('a rename that lands mid-fetch is asked for again, not cached '
      'stale', () async {
    final rig = _Rig();
    final answer = rig.profiles.profile('u1');
    await pumpEventQueue();
    expect(rig.requests, 1);

    rig.events.add(const ProfileChanged(userId: 'u1'));
    await pumpEventQueue();
    rig.firstAnswer.complete();

    expect((await answer)?.displayName, 'New');
    expect(rig.requests, 2);
    expect(
      rig.container.read(batchProfilesControllerProvider)['u1']?.displayName,
      'New',
    );
  });

  test('a fresh connect clears what a request in flight is about to '
      'write', () async {
    final rig = _Rig();
    final answer = rig.profiles.profile('u1');
    await pumpEventQueue();

    rig.profiles.clear();
    rig.firstAnswer.complete();

    expect((await answer)?.displayName, 'New');
    expect(rig.requests, 2);
  });
}
