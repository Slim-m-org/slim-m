// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A role preview never outlives the account it was opened in: signing out,
/// signing in as someone else or switching away ends it.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/accounts/providers/account_slot.dart';
import 'package:slimm_app/src/features/role_preview/providers/role_preview_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/fake_api.dart';
import 'role_preview_fixture.dart';

Future<ProviderContainer> _previewing() async {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      mockApiOverride(previewHandler),
    ],
  );
  addTearDown(container.dispose);
  container.read(sessionProvider).set(previewTokens);
  await Future<void>.delayed(Duration.zero);
  container.listen(rolePreviewProvider, (_, _) {});
  await container.read(rolePreviewProvider.notifier).enter(previewRole);
  expect(container.read(rolePreviewProvider)?.roleId, previewRole.id);
  return container;
}

void main() {
  test('signing out ends the preview', () async {
    final container = await _previewing();

    container.read(sessionProvider).clear();
    await Future<void>.delayed(Duration.zero);

    expect(container.read(rolePreviewProvider), isNull);
  });

  test('another account signing in on the same slot sees no preview', () async {
    final container = await _previewing();

    container
        .read(sessionProvider)
        .set(
          const api.TokenPair(
            userId: 'someone-else',
            accessToken: 'a',
            refreshToken: 'r',
            accessExpiresAt: 0,
          ),
        );
    await Future<void>.delayed(Duration.zero);

    expect(container.read(rolePreviewProvider), isNull);
  });

  test('switching to another account ends the preview', () async {
    final container = await _previewing();

    container.read(accountActiveProvider.notifier).state = false;

    expect(container.read(rolePreviewProvider), isNull);
  });

  test('a token refresh for the same account keeps the preview', () async {
    final container = await _previewing();

    container
        .read(sessionProvider)
        .set(
          const api.TokenPair(
            userId: 'self',
            accessToken: 'fresh',
            refreshToken: 'fresh',
            accessExpiresAt: 0,
          ),
        );
    await Future<void>.delayed(Duration.zero);

    expect(container.read(rolePreviewProvider)?.roleId, previewRole.id);
  });
}
