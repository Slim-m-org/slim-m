// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Widget-level coverage for the biometric app lock: an unlocked app shows
/// its content untouched, a locked one is fully covered and prompts on its
/// own, a failed check leaves it covered with a way to retry, and - the
/// recovery path this must never get wrong - a device that can no longer
/// check an owner at all unlocks on its own rather than trapping the user
/// behind a broken lock.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/app_lock_controller.dart';
import 'package:slimm_app/src/providers/app_lock_preference.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/app_lock_gate.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

class _FakeBiometricAuthChannel implements BiometricAuthChannel {
  _FakeBiometricAuthChannel({
    this.available = true,
    this.result = BiometricAuthResult.success,
  });

  bool available;
  BiometricAuthResult result;

  @override
  Future<BiometricSupport> checkSupport() async =>
      available ? BiometricSupport.supported : BiometricSupport.unsupported;

  @override
  Future<BiometricAuthResult> authenticate(String reason) async => result;
}

/// A real `AppLockWindowChannel` calls an unmocked platform channel, which
/// never resolves inside a `testWidgets` fake-async zone (the same trap
/// `testwidgets-fakeasync-blocks-drift-streams` documents for a drift
/// stream) rather than failing fast the way it does under a plain `test()`.
/// Every widget test here overrides it with this no-op instead.
class _NoopAppLockWindowChannel implements AppLockWindowChannel {
  @override
  Future<void> setPrivacyShield(bool enabled) async {}
}

Future<ProviderContainer> _lockedContainer(
  WidgetTester tester,
  _FakeBiometricAuthChannel channel,
) async {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      biometricAuthChannelProvider.overrideWithValue(channel),
      appLockWindowChannelProvider.overrideWithValue(
        _NoopAppLockWindowChannel(),
      ),
    ],
  );
  addTearDown(container.dispose);
  await container.read(appLockPreferenceProvider.notifier).set(true);
  container.read(appLockControllerProvider.notifier).armOnLaunch();

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const AppLockGate(child: Text('app content')),
      ),
    ),
  );
  return container;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('an unlocked app shows nothing extra: the gate is invisible', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [keyStoreProvider.overrideWithValue(InMemoryKeyStore())],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: const AppLockGate(child: Text('app content')),
        ),
      ),
    );

    expect(find.text('app content'), findsOneWidget);
    expect(find.text('slim-m is locked'), findsNothing);
  });

  testWidgets('a locked app covers the screen and prompts on its own', (
    tester,
  ) async {
    final channel = _FakeBiometricAuthChannel(
      result: BiometricAuthResult.failure,
    );
    await _lockedContainer(tester, channel);
    await tester.pump();

    expect(find.text('slim-m is locked'), findsOneWidget);
  });

  testWidgets('a real success unlocks and the cover disappears', (
    tester,
  ) async {
    final channel = _FakeBiometricAuthChannel();
    final container = await _lockedContainer(tester, channel);
    await tester.pumpAndSettle();

    expect(find.text('slim-m is locked'), findsNothing);
    expect(container.read(appLockControllerProvider), isFalse);
  });

  testWidgets('a failed check leaves it locked with a way to try again', (
    tester,
  ) async {
    final channel = _FakeBiometricAuthChannel(
      result: BiometricAuthResult.failure,
    );
    final container = await _lockedContainer(tester, channel);
    await tester.pumpAndSettle();

    expect(find.text('slim-m is locked'), findsOneWidget);
    expect(find.text("Couldn't confirm it was you."), findsOneWidget);
    expect(container.read(appLockControllerProvider), isTrue);

    channel.result = BiometricAuthResult.success;
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();

    expect(find.text('slim-m is locked'), findsNothing);
    expect(container.read(appLockControllerProvider), isFalse);
  });

  testWidgets(
    'never locks someone out: a device that can no longer check an owner '
    'unlocks on its own and turns the setting back off',
    (tester) async {
      final channel = _FakeBiometricAuthChannel(available: false);
      final container = await _lockedContainer(tester, channel);
      await tester.pumpAndSettle();

      expect(find.text('slim-m is locked'), findsNothing);
      expect(container.read(appLockControllerProvider), isFalse);
      expect(container.read(appLockPreferenceProvider), isFalse);
    },
  );
}
