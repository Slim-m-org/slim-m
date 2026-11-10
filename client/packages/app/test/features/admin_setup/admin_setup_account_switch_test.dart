// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The admin setup is decided again for each account signed in on a container,
/// so one person's overlay is never painted over the next person's shell.
library;

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/admin_setup/providers/admin_setup_controller.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_platform/testing.dart';

import 'admin_setup_harness.dart' show SetupFacts;

api.TokenPair _tokens(String userId) => api.TokenPair(
  userId: userId,
  accessToken: 'a',
  refreshToken: 'r',
  accessExpiresAt: 0,
);

Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// The offer waits on the welcome check and the server, which take real time.
Future<void> _untilShowing(bool Function() showing) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!showing() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late ProviderContainer container;
  late SlimmDatabase db;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = SlimmDatabase(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        storeProvider.overrideWith((ref) => MessageStore(db)),
        meProvider.overrideWith((ref) {
          final id = ref.watch(sessionProvider.select((s) => s.tokens?.userId));
          return api.Me(
            id: '$id',
            username: '$id',
            displayName: '$id',
            createdAt: 0,
            permissions: id == 'admin' ? Perm.manageServer : 0,
          );
        }),
        spaceSetupProvider.overrideWith(
          (ref) async => api.SpaceSetup.fromJson(SetupFacts().json()),
        ),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  bool setupShowing() => container.read(adminSetupControllerProvider).active;

  Future<api.SessionStore> signInThenWatch(String userId) async {
    final session = container.read(sessionProvider)..set(_tokens(userId));
    container.listen(adminSetupControllerProvider, (_, _) {});
    await _settle();
    return session;
  }

  test(
    'a member signing in after the admin does not inherit the overlay',
    () async {
      final session = await signInThenWatch('admin');
      await _untilShowing(setupShowing);
      expect(setupShowing(), isTrue);

      session.clear();
      session.set(_tokens('member'));
      await _settle();

      expect(setupShowing(), isFalse);
    },
  );

  test('an admin signing in after a member is offered the setup', () async {
    final session = await signInThenWatch('member');
    expect(setupShowing(), isFalse);

    session.clear();
    session.set(_tokens('admin'));
    await _untilShowing(setupShowing);

    expect(setupShowing(), isTrue);
  });
}
