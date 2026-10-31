// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The rail must not reshape itself when the connection drops.
///
/// `GET /me` carries the permission bitmask the rail reads to decide whether
/// to render empty categories, a manage kebab per row, and a reorderable
/// list at all. Offline that request fails, and a failed fetch used to read
/// as "this member holds nothing" - so losing signal silently rewrote the
/// rail's whole shape. Reported 2026-08-13 as "channels format weird, colors
/// change" with no connection to the server.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';

const _tokens = api.TokenPair(
  userId: 'me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _other = api.TokenPair(
  userId: 'somebody-else',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

api.Me _me(int permissions) => api.Me(
  id: 'me',
  username: 'me',
  displayName: 'Me',
  createdAt: 0,
  permissions: permissions,
);

void main() {
  test(
    'a dropped connection keeps the last permissions that resolved',
    () async {
      final container = ProviderContainer(
        overrides: [
          sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
          meProvider.overrideWith((ref) async => _me(8)),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(effectiveMeProvider), isNull);
      container.listen(effectiveMeProvider, (_, _) {});
      await Future<void>.delayed(Duration.zero);
      expect(container.read(effectiveMeProvider)?.permissions, 8);

      container.updateOverrides([
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        meProvider.overrideWith((ref) async => throw Exception('offline')),
      ]);
      await Future<void>.delayed(Duration.zero);

      expect(
        container.read(effectiveMeProvider)?.permissions,
        8,
        reason:
            'a failed fetch is not evidence the member lost every permission, '
            'and treating it that way reshapes the rail',
      );
    },
  );

  test(
    'signing in as somebody else never inherits the cached answer',
    () async {
      final container = ProviderContainer(
        overrides: [
          sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
          meProvider.overrideWith((ref) async => _me(8)),
        ],
      );
      addTearDown(container.dispose);
      container.listen(effectiveMeProvider, (_, _) {});
      await Future<void>.delayed(Duration.zero);
      expect(container.read(effectiveMeProvider)?.permissions, 8);

      container.updateOverrides([
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _other)),
        meProvider.overrideWith((ref) async => throw Exception('offline')),
      ]);
      await Future<void>.delayed(Duration.zero);

      expect(
        container.read(effectiveMeProvider),
        isNull,
        reason: 'permissions are per account, never carried across one',
      );
    },
  );
}
