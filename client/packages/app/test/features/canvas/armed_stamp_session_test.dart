// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The stamp in hand and the recent pictures belong to the account that picked
/// them: signing out, or someone else signing in, starts empty.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/providers/armed_stamp.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/stamp_content.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/testing.dart';

Future<ProviderContainer> _armed() async {
  final container = ProviderContainer(
    overrides: [keyStoreProvider.overrideWithValue(InMemoryKeyStore())],
  );
  addTearDown(container.dispose);
  container
      .read(sessionProvider)
      .set(
        const api.TokenPair(
          userId: 'self',
          accessToken: 'a',
          refreshToken: 'r',
          accessExpiresAt: 0,
        ),
      );
  await Future<void>.delayed(Duration.zero);
  container.listen(armedStampProvider, (_, _) {});
  container.read(armedStampProvider.notifier).arm(const PictureStamp('att-1'));
  expect(container.read(armedStampProvider).recentPictures, hasLength(1));
  return container;
}

void main() {
  test('signing out drops the armed stamp and the recent pictures', () async {
    final container = await _armed();

    container.read(sessionProvider).clear();
    await Future<void>.delayed(Duration.zero);

    final stamp = container.read(armedStampProvider);
    expect(stamp.content, isNull);
    expect(stamp.recentPictures, isEmpty);
  });

  test('another account signing in starts with nothing armed', () async {
    final container = await _armed();

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

    expect(container.read(armedStampProvider).content, isNull);
  });
}
