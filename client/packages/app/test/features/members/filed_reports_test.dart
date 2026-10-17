// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the "reports filed from this device" list: it persists per
/// account, caps its length, and must never leak across a sign-out or
/// between two accounts signed into the same running process, the same
/// property `personal_space_visibility_test.dart` holds for its own
/// per-account flag.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/filed_reports.dart';
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
ProviderContainer _relaunch(api.SessionStore session) {
  final container = _containerFor(session);
  container.read(filedReportsProvider.notifier);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('starts empty for a freshly signed-in account with nothing stored', () {
    final container = _containerFor(api.SessionStore(tokens: _selfTokens));
    expect(container.read(filedReportsProvider), isEmpty);
  });

  test('record() puts the new id first, and a later launch for the same '
      'account reads it back', () async {
    final first = _containerFor(api.SessionStore(tokens: _selfTokens));
    await first.read(filedReportsProvider.notifier).record('report-1');
    await first.read(filedReportsProvider.notifier).record('report-2');
    expect(first.read(filedReportsProvider), ['report-2', 'report-1']);

    final relaunch = _relaunch(api.SessionStore(tokens: _selfTokens));
    await pumpEventQueue();
    expect(relaunch.read(filedReportsProvider), ['report-2', 'report-1']);
  });

  test('re-recording an id already in the list moves it to the front '
      'instead of duplicating it', () async {
    final container = _containerFor(api.SessionStore(tokens: _selfTokens));
    final notifier = container.read(filedReportsProvider.notifier);
    await notifier.record('report-1');
    await notifier.record('report-2');
    await notifier.record('report-1');
    expect(container.read(filedReportsProvider), ['report-1', 'report-2']);
  });

  test('caps at the newest 20 ids', () async {
    final container = _containerFor(api.SessionStore(tokens: _selfTokens));
    final notifier = container.read(filedReportsProvider.notifier);
    for (var i = 0; i < 25; i++) {
      await notifier.record('report-$i');
    }
    final ids = container.read(filedReportsProvider);
    expect(ids, hasLength(20));
    expect(ids.first, 'report-24');
    expect(ids.contains('report-4'), isFalse);
  });

  test('signing out reads as empty immediately, never the account that just '
      'left', () async {
    final session = api.SessionStore(tokens: _selfTokens);
    final container = _containerFor(session);
    await container.read(filedReportsProvider.notifier).record('report-1');
    expect(container.read(filedReportsProvider), isNotEmpty);

    session.clear();
    await pumpEventQueue();
    expect(
      container.read(filedReportsProvider),
      isEmpty,
      reason: 'a signed-out screen must not read the last account\'s list',
    );
  });

  test('a second account signing in on the same device never inherits the '
      'first account\'s filed reports', () async {
    final session = api.SessionStore(tokens: _selfTokens);
    final container = _containerFor(session);
    await container.read(filedReportsProvider.notifier).record('report-1');

    session.clear();
    session.set(_otherTokens);
    await pumpEventQueue();

    expect(
      container.read(filedReportsProvider),
      isEmpty,
      reason: 'the second account must not see the first account\'s reports',
    );
  });

  test('signing the first account back in restores its own list', () async {
    final session = api.SessionStore(tokens: _selfTokens);
    final container = _containerFor(session);
    await container.read(filedReportsProvider.notifier).record('report-1');

    session.clear();
    session.set(_otherTokens);
    await pumpEventQueue();
    session.clear();
    session.set(_selfTokens);
    await pumpEventQueue();

    expect(container.read(filedReportsProvider), ['report-1']);
  });

  test('a sign-out landing while record() is suspended on preferences must '
      "not wipe the signed-out account's stored list", () async {
    // Seeds self's list directly, keeping the resolved prefs so the completer below controls when record() sees them.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(filedReportsKey('self'), ['old-report']);

    final prefsCompleter = Completer<SharedPreferences>();
    final session = api.SessionStore(tokens: _selfTokens);
    final container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWithValue(session),
        preferencesProvider.overrideWith((ref) => prefsCompleter.future),
      ],
    );
    addTearDown(container.dispose);

    final notifier = container.read(filedReportsProvider.notifier);
    // Suspends on the completer having already set state; nothing is written to prefs yet.
    final recordFuture = notifier.record('new-report');

    // A sign-out lands and fully resolves while that call is still suspended.
    session.clear();
    await pumpEventQueue();

    prefsCompleter.complete(prefs);
    await recordFuture;

    expect(
      prefs.getStringList(filedReportsKey('self')),
      ['old-report'],
      reason:
          'record() resumed after the sign-out and must not persist an '
          "empty list under the account it captured before it - that "
          "account's own list must be untouched",
    );

    session.set(_selfTokens);
    await pumpEventQueue();
    expect(container.read(filedReportsProvider), ['old-report']);
  });
}
