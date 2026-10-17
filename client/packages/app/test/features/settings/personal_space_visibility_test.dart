// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the personal space's "removed from list" flag: it persists
/// per account, and it must never leak across a sign-out or between two
/// accounts signed into the same running process. `blocksProvider` shipped
/// exactly this bug once (see its own doc comment); these are the tests
/// that would have caught it here.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/providers/personal_space_visibility.dart';
import 'package:slimm_app/src/providers/providers.dart';

const _selfTokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _otherTokens = api.TokenPair(
  userId: 'other',
  accessToken: 'access-2',
  refreshToken: 'refresh-2',
  accessExpiresAt: 0,
);

/// A container wired to [session] alone: the controller under test reads
/// only `sessionProvider` and `preferencesProvider`, so nothing else needs
/// overriding.
ProviderContainer _containerFor(api.SessionStore session) {
  final container = ProviderContainer(
    overrides: [sessionProvider.overrideWithValue(session)],
  );
  addTearDown(container.dispose);
  return container;
}

/// A second container over the same mocked prefs store, modelling a
/// relaunch: nothing carries state forward except what was written to
/// (mocked) disk.
///
/// The provider is lazy, so it has to be read once here to construct it and
/// start its own load before the caller pumps past that load - reading it
/// only after pumping would construct it fresh with nothing yet to pump,
/// and the assertion that followed would see only the pre-load default
/// rather than what got persisted.
ProviderContainer _relaunch(api.SessionStore session) {
  final container = _containerFor(session);
  container.read(personalSpaceVisibilityProvider.notifier);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'starts visible for a freshly signed-in account with nothing stored',
    () async {
      final container = _containerFor(api.SessionStore(tokens: _selfTokens));
      expect(container.read(personalSpaceVisibilityProvider), isFalse);
    },
  );

  test('hide() persists, and a later launch for the same account reads it '
      'back', () async {
    final first = _containerFor(api.SessionStore(tokens: _selfTokens));
    await first.read(personalSpaceVisibilityProvider.notifier).hide();
    expect(first.read(personalSpaceVisibilityProvider), isTrue);

    final relaunch = _relaunch(api.SessionStore(tokens: _selfTokens));
    await pumpEventQueue();
    expect(relaunch.read(personalSpaceVisibilityProvider), isTrue);
  });

  test('show() reverses it, and that also persists', () async {
    final container = _containerFor(api.SessionStore(tokens: _selfTokens));
    await container.read(personalSpaceVisibilityProvider.notifier).hide();
    await container.read(personalSpaceVisibilityProvider.notifier).show();
    expect(container.read(personalSpaceVisibilityProvider), isFalse);

    final relaunch = _relaunch(api.SessionStore(tokens: _selfTokens));
    await pumpEventQueue();
    expect(relaunch.read(personalSpaceVisibilityProvider), isFalse);
  });

  test('signing out reads as visible immediately, never the account that just '
      'left', () async {
    final session = api.SessionStore(tokens: _selfTokens);
    final container = _containerFor(session);
    await container.read(personalSpaceVisibilityProvider.notifier).hide();
    expect(container.read(personalSpaceVisibilityProvider), isTrue);

    session.clear();
    await pumpEventQueue();
    expect(
      container.read(personalSpaceVisibilityProvider),
      isFalse,
      reason:
          'a signed-out screen must not read the last account\'s '
          'choice',
    );
  });

  test('a second account signing in on the same device never inherits the '
      'first account\'s hidden flag', () async {
    final session = api.SessionStore(tokens: _selfTokens);
    final container = _containerFor(session);
    await container.read(personalSpaceVisibilityProvider.notifier).hide();
    expect(container.read(personalSpaceVisibilityProvider), isTrue);

    session.clear();
    session.set(_otherTokens);
    await pumpEventQueue();

    expect(
      container.read(personalSpaceVisibilityProvider),
      isFalse,
      reason:
          'the second account\'s own notes must not open pre-hidden '
          'by the first account\'s choice',
    );
  });

  test(
    'signing the first account back in restores its own hidden flag',
    () async {
      final session = api.SessionStore(tokens: _selfTokens);
      final container = _containerFor(session);
      await container.read(personalSpaceVisibilityProvider.notifier).hide();

      session.clear();
      session.set(_otherTokens);
      await pumpEventQueue();
      session.clear();
      session.set(_selfTokens);
      await pumpEventQueue();

      expect(container.read(personalSpaceVisibilityProvider), isTrue);
    },
  );

  test('an access-token rotation for the same account does not reload or '
      'reset the flag', () async {
    final session = api.SessionStore(tokens: _selfTokens);
    final container = _containerFor(session);
    await container.read(personalSpaceVisibilityProvider.notifier).hide();

    // Same userId, a new access token: an ordinary refresh, not a switch.
    session.set(
      const api.TokenPair(
        userId: 'self',
        accessToken: 'access-rotated',
        refreshToken: 'refresh',
        accessExpiresAt: 999,
      ),
    );
    await pumpEventQueue();

    expect(container.read(personalSpaceVisibilityProvider), isTrue);
  });
}
