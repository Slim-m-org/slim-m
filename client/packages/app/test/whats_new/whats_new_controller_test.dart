// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the three design constraints the what's-new sheet is built
/// around: it shows once after an upgrade, never on a fresh install, and
/// never again for a version already seen.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/whats_new/providers/whats_new_controller.dart';

void _mockVersion(String version) {
  PackageInfo.setMockInitialValues(
    appName: 'slim-m',
    packageName: 'top.npcserver.slimm',
    version: version,
    buildNumber: '1',
    buildSignature: '',
  );
}

/// [fresh] models what `restoreSession` would already have decided by the
/// time anything reads the controller: true only for a genuinely first
/// launch (or an indistinguishable wipe), matching
/// [isFreshInstallProvider]'s own doc.
///
/// Reads [whatsNewControllerProvider] once before returning: it is a lazy
/// `StateNotifierProvider`, so nothing runs its constructor, and therefore
/// nothing starts the async check, until something reads it. A real launch
/// gets that read from `WhatsNewGate`; here it is this helper.
ProviderContainer _container({
  required bool fresh,
  bool justRegistered = false,
}) {
  final container = ProviderContainer(
    overrides: [
      isFreshInstallProvider.overrideWith((ref) => fresh),
      justRegisteredProvider.overrideWith((ref) => justRegistered),
    ],
  );
  addTearDown(container.dispose);
  container.read(whatsNewControllerProvider);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'a fresh install never shows anything and records the current version',
    () async {
      _mockVersion('0.17.2');
      final container = _container(fresh: true);
      await pumpEventQueue();

      expect(container.read(whatsNewControllerProvider), isEmpty);

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(lastSeenWhatsNewVersionKey),
        '0.17.2',
        reason:
            'a first launch must record a baseline, or the next real '
            'upgrade would replay every entry ever written as if all of it '
            'were new',
      );
    },
  );

  test('a brand-new account on a device that launched before sees nothing '
      'and records the current version', () async {
    _mockVersion('0.89.0');
    final container = _container(fresh: false, justRegistered: true);
    await pumpEventQueue();

    expect(container.read(whatsNewControllerProvider), isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(lastSeenWhatsNewVersionKey), '0.89.0');
  });

  test(
    'the same device without a registration still owes the backlog',
    () async {
      _mockVersion('0.89.0');
      final container = _container(fresh: false);
      await pumpEventQueue();

      expect(container.read(whatsNewControllerProvider), isNotEmpty);
    },
  );

  test('an upgrade with no prior what\'s-new record shows the entries up to '
      'the current version', () async {
    // An existing (not fresh) install with no what's-new key ever written.
    _mockVersion('0.17.2');
    final container = _container(fresh: false);
    await pumpEventQueue();

    final pending = container.read(whatsNewControllerProvider);
    expect(
      pending,
      isNotEmpty,
      reason:
          'the 0.17.2 message-reconciliation note must reach existing '
          'installs, not only fresh ones',
    );
  });

  test('once shown and marked seen, a relaunch on the same version shows '
      'nothing again', () async {
    _mockVersion('0.17.2');
    final first = _container(fresh: false);
    await pumpEventQueue();
    expect(first.read(whatsNewControllerProvider), isNotEmpty);

    await first.read(whatsNewControllerProvider.notifier).markSeen();
    expect(first.read(whatsNewControllerProvider), isEmpty);

    // Models a relaunch: only what was persisted carries forward.
    final relaunch = _container(fresh: false);
    await pumpEventQueue();
    expect(relaunch.read(whatsNewControllerProvider), isEmpty);
  });

  test(
    'a device that recorded the pre-fix frozen version (backlog item 56) is '
    're-baselined silently rather than flooded with the whole backlog',
    () async {
      SharedPreferences.setMockInitialValues({
        lastSeenWhatsNewVersionKey: '0.1.0',
      });
      _mockVersion('0.26.0');
      final container = _container(fresh: false);
      await pumpEventQueue();

      expect(
        container.read(whatsNewControllerProvider),
        isEmpty,
        reason:
            'every real build before the version-source fix reported 0.1.0, '
            'so this device never really saw any of the backlog and must '
            'not be shown all of it at once now that the version is real',
      );

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(lastSeenWhatsNewVersionKey), '0.26.0');
    },
  );

  test('a device re-baselined by that fix still gets the releases that came '
      'after it', () async {
    // 0.28.0 shipped that fix, so it is what the re-baseline above wrote.
    SharedPreferences.setMockInitialValues({
      lastSeenWhatsNewVersionKey: '0.28.0',
    });
    _mockVersion('0.38.0');
    final container = _container(fresh: false);
    await pumpEventQueue();

    expect(
      container.read(whatsNewControllerProvider),
      isNotEmpty,
      reason:
          'the re-baseline is meant to skip a backlog nobody really saw, '
          'once, not to leave the sheet silent for every release after it; '
          'if this is empty the entries stopped being written again',
    );
  });

  test('marking seen before anything is shown is a no-op, so a stray call '
      'cannot advance the recorded version early', () async {
    _mockVersion('0.17.2');
    final container = _container(fresh: true);
    await pumpEventQueue();

    await container.read(whatsNewControllerProvider.notifier).markSeen();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(lastSeenWhatsNewVersionKey), '0.17.2');
  });
}
