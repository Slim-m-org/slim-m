// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A second account never lands on the first account's last channel.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/last_text_channel.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_platform/platform.dart';
import '../../support/fake_sync.dart';

const _tokens = api.TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

void main() {
  test('signing out forgets the last text channel', () async {
    final session = api.SessionStore(tokens: _tokens);
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(session),
        syncControllerProvider.overrideWith(NoopSyncController.new),
        storeProvider.overrideWith((ref) async => throw StateError('n/a')),
      ],
    );
    addTearDown(container.dispose);

    container.read(syncControllerProvider.notifier);
    container.read(lastTextChannelProvider.notifier).state = 'channel-of-alice';

    session.clear();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(container.read(lastTextChannelProvider), isNull);
  });
}
