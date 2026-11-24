// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A previous account's `Me` must never feed the permission gates of the next one.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/providers.dart';

const _bob = api.TokenPair(
  userId: 'bob',
  accessToken: 'b-access',
  refreshToken: 'b-refresh',
  accessExpiresAt: 0,
);

const _alice = api.Me(
  id: 'alice',
  username: 'alice',
  displayName: 'Alice',
  createdAt: 0,
  permissions: 1,
);

void main() {
  test('permissions and ladder ignore a Me that is not the session user', () {
    final container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _bob)),
        meProvider.overrideWith((ref) async => _alice),
      ],
    );
    addTearDown(container.dispose);

    container.listen(myPermissionsProvider, (_, _) {});
    container.listen(roleLadderProvider, (_, _) {});
    return container.read(meProvider.future).then((_) {
      expect(container.read(myPermissionsProvider), 0);
      expect(container.read(roleLadderProvider).isOwner, isFalse);
    });
  });
}
