// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the biometric app lock's runtime state: armed on launch only
/// when the preference is on and a session exists, re-armed on a resume that
/// followed a long enough background, cleared on sign-out, and - the one
/// case this must never get wrong - never left locked when the platform
/// reports it can no longer check an owner at all.
library;

import 'package:clock/clock.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/app_lock_controller.dart';
import 'package:slimm_app/src/providers/app_lock_preference.dart';
import 'package:slimm_app/src/providers/providers.dart';
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
  int authenticateCalls = 0;

  @override
  Future<BiometricSupport> checkSupport() async =>
      available ? BiometricSupport.supported : BiometricSupport.unsupported;

  @override
  Future<BiometricAuthResult> authenticate(String reason) async {
    authenticateCalls++;
    return result;
  }
}

ProviderContainer _container({
  SessionStore? session,
  _FakeBiometricAuthChannel? channel,
}) {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      if (session != null) sessionProvider.overrideWithValue(session),
      if (channel != null)
        biometricAuthChannelProvider.overrideWithValue(channel),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('arming on launch', () {
    test(
      'locks on launch when the preference is on and a session exists',
      () async {
        final container = _container(session: SessionStore(tokens: _tokens));
        await container.read(appLockPreferenceProvider.notifier).set(true);

        container.read(appLockControllerProvider.notifier).armOnLaunch();

        expect(container.read(appLockControllerProvider), isTrue);
      },
    );

    test('stays unlocked on launch when the preference is off', () async {
      final container = _container(session: SessionStore(tokens: _tokens));

      container.read(appLockControllerProvider.notifier).armOnLaunch();

      expect(container.read(appLockControllerProvider), isFalse);
    });

    test('stays unlocked on launch with no session, even if the preference '
        'is on', () async {
      final container = _container(session: SessionStore());
      await container.read(appLockPreferenceProvider.notifier).set(true);

      container.read(appLockControllerProvider.notifier).armOnLaunch();

      expect(container.read(appLockControllerProvider), isFalse);
    });
  });

  group('sign-out', () {
    test(
      'clears the lock: a real sign-out already asks for a password',
      () async {
        final session = SessionStore(tokens: _tokens);
        final container = _container(session: session);
        await container.read(appLockPreferenceProvider.notifier).set(true);
        container.read(appLockControllerProvider.notifier).armOnLaunch();
        expect(container.read(appLockControllerProvider), isTrue);

        session.clear();
        // SessionStore.changes is a broadcast stream: the listener only sees this after a microtask.
        await Future<void>.value();

        expect(container.read(appLockControllerProvider), isFalse);
      },
    );
  });

  group('resume after backgrounding', () {
    test('a brief trip to the background does not re-lock on resume', () async {
      final session = SessionStore(tokens: _tokens);
      final container = _container(
        session: session,
        channel: _FakeBiometricAuthChannel(),
      );
      await container.read(appLockPreferenceProvider.notifier).set(true);
      final controller = container.read(appLockControllerProvider.notifier);
      controller.armOnLaunch();
      await controller.unlock();
      expect(container.read(appLockControllerProvider), isFalse);

      var now = DateTime(2026, 1, 1, 12, 0, 0);
      withClock(Clock(() => now), () {
        controller.didChangeAppLifecycleState(AppLifecycleState.paused);
      });
      now = now.add(const Duration(seconds: 5));
      withClock(Clock(() => now), () {
        controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      });

      expect(container.read(appLockControllerProvider), isFalse);
    });

    test('a background past the grace window re-locks on resume', () async {
      final session = SessionStore(tokens: _tokens);
      final container = _container(
        session: session,
        channel: _FakeBiometricAuthChannel(),
      );
      await container.read(appLockPreferenceProvider.notifier).set(true);
      final controller = container.read(appLockControllerProvider.notifier);
      controller.armOnLaunch();
      await controller.unlock();
      expect(container.read(appLockControllerProvider), isFalse);

      var now = DateTime(2026, 1, 1, 12, 0, 0);
      withClock(Clock(() => now), () {
        controller.didChangeAppLifecycleState(AppLifecycleState.paused);
      });
      now = now.add(AppLockController.lockGraceDuration * 2);
      withClock(Clock(() => now), () {
        controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      });

      expect(container.read(appLockControllerProvider), isTrue);
    });

    test('iOS inactive (control centre, the app switcher) is not treated as '
        'backgrounded', () async {
      final session = SessionStore(tokens: _tokens);
      final container = _container(
        session: session,
        channel: _FakeBiometricAuthChannel(),
      );
      await container.read(appLockPreferenceProvider.notifier).set(true);
      final controller = container.read(appLockControllerProvider.notifier);
      controller.armOnLaunch();
      await controller.unlock();

      var now = DateTime(2026, 1, 1, 12, 0, 0);
      withClock(Clock(() => now), () {
        controller.didChangeAppLifecycleState(AppLifecycleState.inactive);
      });
      now = now.add(AppLockController.lockGraceDuration * 2);
      withClock(Clock(() => now), () {
        controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      });

      expect(container.read(appLockControllerProvider), isFalse);
    });
  });

  group('unlock()', () {
    test('a real success unlocks and leaves the preference on', () async {
      final channel = _FakeBiometricAuthChannel();
      final container = _container(
        session: SessionStore(tokens: _tokens),
        channel: channel,
      );
      await container.read(appLockPreferenceProvider.notifier).set(true);
      container.read(appLockControllerProvider.notifier).armOnLaunch();

      final unlocked = await container
          .read(appLockControllerProvider.notifier)
          .unlock();

      expect(unlocked, isTrue);
      expect(container.read(appLockControllerProvider), isFalse);
      expect(container.read(appLockPreferenceProvider), isTrue);
      expect(channel.authenticateCalls, 1);
    });

    test('a failed check (wrong fingerprint, a cancel) stays locked and '
        'leaves the preference on, so the next tap can try again', () async {
      final channel = _FakeBiometricAuthChannel(
        result: BiometricAuthResult.failure,
      );
      final container = _container(
        session: SessionStore(tokens: _tokens),
        channel: channel,
      );
      await container.read(appLockPreferenceProvider.notifier).set(true);
      container.read(appLockControllerProvider.notifier).armOnLaunch();

      final unlocked = await container
          .read(appLockControllerProvider.notifier)
          .unlock();

      expect(unlocked, isFalse);
      expect(container.read(appLockControllerProvider), isTrue);
      expect(container.read(appLockPreferenceProvider), isTrue);
    });

    test('never locks someone out: a device with no credentials set up at '
        'all unlocks without even prompting, and turns the setting back '
        'off', () async {
      final channel = _FakeBiometricAuthChannel(available: false);
      final container = _container(
        session: SessionStore(tokens: _tokens),
        channel: channel,
      );
      await container.read(appLockPreferenceProvider.notifier).set(true);
      container.read(appLockControllerProvider.notifier).armOnLaunch();

      final unlocked = await container
          .read(appLockControllerProvider.notifier)
          .unlock();

      expect(unlocked, isTrue);
      expect(container.read(appLockControllerProvider), isFalse);
      expect(
        container.read(appLockPreferenceProvider),
        isFalse,
        reason:
            'the toggle must not keep claiming a protection this '
            'device can no longer provide',
      );
      expect(
        channel.authenticateCalls,
        0,
        reason: 'no prompt to show when there is nothing to check against',
      );
    });

    test(
      'never locks someone out: the platform reporting mid-attempt that '
      'no credentials are set up also unlocks and disables the setting',
      () async {
        final channel = _FakeBiometricAuthChannel(
          result: BiometricAuthResult.unavailable,
        );
        final container = _container(
          session: SessionStore(tokens: _tokens),
          channel: channel,
        );
        await container.read(appLockPreferenceProvider.notifier).set(true);
        container.read(appLockControllerProvider.notifier).armOnLaunch();

        final unlocked = await container
            .read(appLockControllerProvider.notifier)
            .unlock();

        expect(unlocked, isTrue);
        expect(container.read(appLockControllerProvider), isFalse);
        expect(container.read(appLockPreferenceProvider), isFalse);
      },
    );
  });
}
