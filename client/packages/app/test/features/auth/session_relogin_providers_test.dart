// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/first_run/providers/first_run_controller.dart';
import 'package:slimm_app/src/features/members/providers/presence_view.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

api.TokenPair _tokens(String userId) => api.TokenPair(
  userId: userId,
  accessToken: 'a',
  refreshToken: 'r',
  accessExpiresAt: 0,
);

ProviderContainer _container() {
  final container = ProviderContainer(
    overrides: [keyStoreProvider.overrideWithValue(InMemoryKeyStore())],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  test(
    'own presence follows a sign-out then a sign-in as someone else',
    () async {
      final container = _container();
      final session = container.read(sessionProvider);
      container.listen(ownPresenceProvider, (_, _) {});

      session.set(_tokens('alice'));
      session.clear();
      await _settle();
      expect(container.read(ownPresenceProvider), AppPresence.unknown);
      session.set(_tokens('bob'));
      await _settle();

      expect(container.read(ownPresenceProvider).word, 'online');
    },
  );

  test('first-run setup is decided again for the next account', () async {
    final container = _container();
    final session = container.read(sessionProvider);
    session.set(_tokens('alice'));
    container.listen(firstRunControllerProvider, (_, _) {});
    final forAlice = container.read(firstRunControllerProvider.notifier);

    session.clear();
    await _settle();
    session.set(_tokens('bob'));
    await _settle();

    expect(
      container.read(firstRunControllerProvider.notifier),
      isNot(same(forAlice)),
    );
  });

  test(
    'a token rotation for the same account does not notify watchers',
    () async {
      final container = _container();
      final session = container.read(sessionProvider);
      session.set(_tokens('alice'));
      await _settle();
      var notified = 0;
      container.listen(sessionProvider, (_, _) => notified++);

      session.set(_tokens('alice'));
      await _settle();

      expect(notified, 0);
    },
  );
}
