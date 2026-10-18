// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The caller's own profile refreshes when they edit it somewhere else.
///
/// `meProvider` is fetched once per session, and other people's profiles have
/// two controllers watching `ProfileChanged` for them, but nothing watched it
/// for the caller. So a picture, name or status set on a phone left the
/// desktop drawing the old one until the app was quit and reopened - the
/// avatar cache is keyed by `avatarUpdatedAt`, which only a refetch changes.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

/// One `/me` body whose `avatar_updated_at` moves on every fetch, standing in
/// for a picture that changed on another device.
Map<String, dynamic> _meJson(int fetch) => {
  'id': 'self',
  'username': 'nick',
  'display_name': 'Nick',
  'created_at': 0,
  'avatar_updated_at': 1000 + fetch,
  'permissions': 0,
};

void main() {
  test(
    'a profile.changed for the caller refetches their own profile',
    () async {
      final events = StreamController<api.ServerEvent>.broadcast();
      addTearDown(events.close);
      var fetches = 0;

      final container = ProviderContainer(
        overrides: [
          sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
          liveEventsProvider.overrideWithValue(events.stream),
          mockApiOverride((request) async {
            fetches++;
            return http.Response(
              jsonEncode(_meJson(fetches)),
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        ],
      );
      addTearDown(container.dispose);

      final sub = container.listen(effectiveMeProvider, (_, _) {});
      addTearDown(sub.close);
      await container.read(meProvider.future);
      final first = container.read(effectiveMeProvider)!.avatarUpdatedAt;
      expect(fetches, 1);

      // Somebody else's edit is not the caller's, and must not cost a refetch.
      events.add(const api.ProfileChanged(userId: 'someone-else'));
      await pumpEventQueue();
      expect(fetches, 1);

      events.add(const api.ProfileChanged(userId: 'self'));
      await pumpEventQueue();
      await container.read(meProvider.future);
      expect(fetches, 2, reason: 'the caller\'s own edit must refetch /me');
      expect(
        container.read(effectiveMeProvider)!.avatarUpdatedAt,
        isNot(first),
        reason: 'the new avatar key is what makes the picture reload',
      );
    },
  );
}
