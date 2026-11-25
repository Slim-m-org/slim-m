// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The iOS privacy cover outlives the resume until a frame has been drawn.
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
import 'package:slimm_platform/testing.dart';

class _RecordingWindow implements AppLockWindowChannel {
  int releases = 0;

  @override
  Future<void> setPrivacyShield(bool enabled) async {}

  @override
  Future<void> releasePrivacyShield() async => releases++;
}

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the cover is released after the frame that follows a resume', (
    tester,
  ) async {
    final window = _RecordingWindow();
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
        appLockWindowChannelProvider.overrideWithValue(window),
      ],
    );
    addTearDown(container.dispose);
    await container.read(appLockPreferenceProvider.notifier).set(true);
    container.read(appLockControllerProvider);
    await tester.pumpWidget(const SizedBox());
    final binding = tester.binding;
    var now = DateTime(2026);

    await withClock(Clock(() => now), () async {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      now = now.add(const Duration(minutes: 1));
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(container.read(appLockControllerProvider), isTrue);
      expect(window.releases, 0);

      await tester.pump();

      expect(window.releases, 1);
    });
  });
}
