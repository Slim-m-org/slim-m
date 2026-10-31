// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The real session provider wired to a fake browser: a storage event from
/// another tab brings its rotation or sign-out in, and a refresh runs under
/// the tabs' lock.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_platform/testing.dart';

class _FakeTabs implements CrossTab {
  final changes = StreamController<void>.broadcast(sync: true);
  final locks = <String>[];

  @override
  Future<T> exclusive<T>(String name, Future<T> Function() body) {
    locks.add(name);
    return body();
  }

  @override
  Stream<void> get storageChanges => changes.stream;
}

const _mine = TokenPair(
  userId: 'user-1',
  accessToken: 'access-1',
  refreshToken: 'refresh-1',
  accessExpiresAt: 0,
);

const _theirs = TokenPair(
  userId: 'user-1',
  accessToken: 'access-2',
  refreshToken: 'refresh-2',
  accessExpiresAt: 0,
);

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  late InMemoryKeyStore keys;
  late _FakeTabs tabs;
  late ProviderContainer container;

  setUp(() {
    keys = InMemoryKeyStore();
    tabs = _FakeTabs();
    container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(keys),
        crossTabProvider.overrideWithValue(tabs),
      ],
    );
    addTearDown(container.dispose);
    container.read(sessionProvider).set(_mine);
  });

  test(
    'another tab rotating the pair is adopted on its storage event',
    () async {
      final session = container.read(sessionProvider);
      await session.settled;
      await keys.put(sessionTokenHandle, jsonEncode(_theirs.toJson()));

      tabs.changes.add(null);
      await _settle();

      expect(session.tokens?.refreshToken, 'refresh-2');
    },
  );

  test(
    'another tab signing out ends this one without touching storage',
    () async {
      final session = container.read(sessionProvider);
      await session.settled;
      await keys.delete(sessionTokenHandle);
      final ended = session.endings.first;

      tabs.changes.add(null);
      await _settle();

      expect(session.isSignedIn, isFalse);
      expect(await ended, 'signed out in another tab');
    },
  );

  test(
    'a storage event that changes nothing leaves the session alone',
    () async {
      final session = container.read(sessionProvider);
      await session.settled;

      tabs.changes.add(null);
      await _settle();

      expect(session.tokens?.refreshToken, 'refresh-1');
    },
  );

  test('the session reads the shared lock through the tabs seam', () async {
    final sync = container.read(sessionProvider).sync!;

    final ran = await sync.exclusive(() async => 7);

    expect(ran, 7);
    expect(tabs.locks, [TabSessionSync.lockName]);
  });
}
