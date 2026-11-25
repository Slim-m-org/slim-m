// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the host-OS seam the web build needs, and for the key-store
/// backend it decides.
///
/// These run on the Dart VM, so `kIsWeb` is always false here and only the
/// native half of each guard is reachable. That is the half that ships, and
/// it is the half a "simplification" of the guard would silently change; the
/// browser half is verified by running the built app in a browser, which no
/// VM test can stand in for.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_platform/platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('host platform', () {
    test('reports the same OS dart:io does, rather than inverting it', () {
      expect(isIOSHost, Platform.isIOS);
      expect(isAndroidHost, Platform.isAndroid);
    });

    test('a desktop host is neither mobile platform', () {
      if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
        expect(isIOSHost, isFalse);
        expect(isAndroidHost, isFalse);
      }
    });
  });

  group('deviceDisplayName', () {
    // Guards the bug: every device used to read the literal string 'desktop'.
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('two different platforms produce two different device names', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final android = deviceDisplayName;
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final mac = deviceDisplayName;

      expect(android, isNot(mac));
    });

    test('the same platform is stable across calls', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;

      expect(deviceDisplayName, deviceDisplayName);
    });

    test('never the literal string every device used to share', () {
      for (final platform in TargetPlatform.values) {
        debugDefaultTargetPlatformOverride = platform;
        expect(deviceDisplayName, isNot('desktop'));
        expect(deviceDisplayName, isNotEmpty);
      }
    });
  });

  group('composeDeviceName', () {
    test('desktop reads "<Platform> - <host>" the same on every platform', () {
      expect(
        composeDeviceName(TargetPlatform.linux, host: 'fedora'),
        'Linux - fedora',
      );
      expect(
        composeDeviceName(TargetPlatform.macOS, host: 'studio'),
        'Mac - studio',
      );
      expect(composeDeviceName(TargetPlatform.windows), 'Windows');
    });

    test('the loopback host name is never part of a name', () {
      for (final host in ['localhost', 'Localhost', 'localhost.localdomain']) {
        expect(
          composeDeviceName(TargetPlatform.iOS, host: host),
          isNot(contains('localhost')),
        );
        expect(
          composeDeviceName(TargetPlatform.linux, host: host),
          'Linux',
        );
      }
    });

    test('a phone is named by its model, else by what it is', () {
      expect(composeDeviceName(TargetPlatform.iOS, model: 'iPad'), 'iPad');
      expect(
          composeDeviceName(TargetPlatform.iOS, host: 'localhost'), 'iPhone');
      expect(
        composeDeviceName(TargetPlatform.android, model: 'Pixel 8'),
        'Pixel 8',
      );
      expect(composeDeviceName(TargetPlatform.android), 'Android phone');
    });
  });

  group('createPersistentKeyStore', () {
    test('Linux gets the keyring-or-file store', () {
      if (!Platform.isLinux) return;
      expect(createPersistentKeyStore(), isA<LinuxKeyStore>());
    });

    test('macOS, Windows and Android get the platform keychain', () {
      if (!Platform.isMacOS && !Platform.isWindows && !Platform.isAndroid) {
        return;
      }
      expect(createPersistentKeyStore(), isA<SecureKeyStore>());
    });

    test('iOS gets the first-unlock store that migrates the old one', () {
      if (!Platform.isIOS) return;
      expect(createPersistentKeyStore(), isA<MigratingKeyStore>());
    });
  });
}
