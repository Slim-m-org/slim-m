// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The app lock is one per process: an account opened after the lock engaged,
/// by a switch, a link or an add flow, meets the same lock state.
library;

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/default_server.dart';
import 'package:slimm_app/src/desktop/desktop_window_shell.dart';
import 'package:slimm_app/src/features/accounts/providers/account_host.dart';
import 'package:slimm_app/src/features/accounts/providers/account_host_factory.dart';
import 'package:slimm_app/src/features/accounts/providers/account_slot.dart';
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

class _Biometric implements BiometricAuthChannel {
  @override
  Future<BiometricSupport> checkSupport() async => BiometricSupport.supported;

  @override
  Future<BiometricAuthResult> authenticate(String reason) async =>
      BiometricAuthResult.success;
}

Future<({AccountHost host, ProviderContainer first})> _signedInHost() async {
  final host = createAccountHost(
    DesktopWindowShell(),
    Uri.parse(officialServer),
  );
  final first = host.createFirst();
  addTearDown(first.dispose);
  first.read(sessionProvider).set(_tokens);
  await first.read(appLockPreferenceProvider.notifier).set(true);
  return (host: host, first: first);
}

ProviderContainer _another(AccountHost host) {
  final container = host.createContainer(
    AccountSlot(chooseServer: (_, _) => throw UnimplementedError()),
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('an account opened after the lock engaged finds it engaged', () async {
    final s = await _signedInHost();
    s.first.read(appLockControllerProvider.notifier).armOnLaunch();

    final other = _another(s.host);

    expect(other.read(appLockControllerProvider), isTrue);
  });

  testWidgets('switching to an account not yet opened shows the lock screen', (
    tester,
  ) async {
    final s = await _signedInHost();
    s.first.read(appLockControllerProvider.notifier).armOnLaunch();
    final other = _another(s.host);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: other,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: const AppLockGate(child: Text('second account messages')),
        ),
      ),
    );

    expect(find.text('slim-m is locked'), findsOneWidget);
  });

  test('unlocking in one account unlocks every account', () async {
    final s = await _signedInHost();
    final other = _another(s.host);
    other.read(appLockControllerProvider.notifier).armOnLaunch();
    expect(s.first.read(appLockControllerProvider), isTrue);

    s.first.read(appLockControllerProvider.notifier).state = false;

    expect(other.read(appLockControllerProvider), isFalse);
  });

  test('the lock outlives the container that first read it', () async {
    final s = await _signedInHost();
    final other = _another(s.host);
    other.read(appLockControllerProvider.notifier).armOnLaunch();

    other.dispose();

    expect(s.first.read(appLockControllerProvider), isTrue);
    s.first.read(appLockControllerProvider.notifier).state = false;
    expect(s.first.read(appLockControllerProvider), isFalse);
  });

  group('session lock', () {
    late AppLockController lock;
    late bool enabled;
    late bool signedIn;

    setUp(() {
      enabled = true;
      signedIn = true;
      lock = AppLockController.shared(
        AppLockHost(
          enabled: () => enabled,
          signedIn: () => signedIn,
          signedInChanges: const Stream.empty(),
          channel: _Biometric.new,
          disable: () async {},
        ),
      );
      addTearDown(lock.closeShared);
    });

    test('Win+L longer than the grace window locks on the way back', () {
      var now = DateTime(2026, 1, 1, 12);
      withClock(Clock(() => now), lock.markAway);
      now = now.add(AppLockController.lockGraceDuration * 2);
      withClock(Clock(() => now), lock.markBack);

      expect(lock.state, isTrue);
    });

    test('a short lock inside the grace window does not', () {
      var now = DateTime(2026, 1, 1, 12);
      withClock(Clock(() => now), lock.markAway);
      now = now.add(const Duration(seconds: 5));
      withClock(Clock(() => now), lock.markBack);

      expect(lock.state, isFalse);
    });

    test('nothing locks with the setting off', () {
      enabled = false;
      var now = DateTime(2026, 1, 1, 12);
      withClock(Clock(() => now), lock.markAway);
      now = now.add(const Duration(minutes: 5));
      withClock(Clock(() => now), lock.markBack);

      expect(lock.state, isFalse);
    });

    test('the channel forwards away and back from the runner', () async {
      final calls = <String>[];
      const channel = MethodChannel('test/session_lock');
      SessionLockChannel(
        channel: channel,
        isWindows: true,
      ).listen(away: () => calls.add('away'), back: () => calls.add('back'));
      for (final method in ['away', 'back']) {
        await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
              channel.name,
              channel.codec.encodeMethodCall(MethodCall(method)),
              (_) {},
            );
      }

      expect(calls, ['away', 'back']);
    });
  });
}
