// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A transient error asking the platform whether it can check an owner must
/// not be read as "no credentials" and switch the app lock off for good.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/app_lock_controller.dart';
import 'package:slimm_app/src/providers/app_lock_preference.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/platform.dart';

class _ThrowingAuth implements LocalAuthentication {
  @override
  Future<bool> isDeviceSupported() async => throw StateError('channel error');
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'a transient isDeviceSupported error does not turn the lock off',
    () async {
      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          sessionProvider.overrideWithValue(
            SessionStore(
              tokens: const TokenPair(
                userId: 'u',
                accessToken: 'a',
                refreshToken: 'r',
                accessExpiresAt: 0,
              ),
            ),
          ),
          biometricAuthChannelProvider.overrideWithValue(
            BiometricAuthChannel(auth: _ThrowingAuth()),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(appLockPreferenceProvider.notifier).set(true);
      final controller = container.read(appLockControllerProvider.notifier);
      controller.armOnLaunch();
      expect(container.read(appLockControllerProvider), isTrue);

      final unlocked = await controller.unlock();

      expect(unlocked, isFalse, reason: 'an error is not "no credentials"');
      expect(
        container.read(appLockPreferenceProvider),
        isTrue,
        reason: 'the preference must survive a transient error',
      );
    },
  );
}
