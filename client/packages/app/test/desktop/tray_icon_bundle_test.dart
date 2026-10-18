// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [trayIconAssetPath] is a git symlink out to `packaging/linux/icons/`, the
/// same fix this project already applied once for the notification sounds
/// (`notification_sound_bundle_test.dart`) after a `../../../` asset path
/// silently bundled nothing. Loading it for real here is what would have
/// caught that class of failure before `DesktopTrayController.start()` ever
/// reached it on a real desktop.
library;

import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/tray/desktop_tray_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the tray icon asset is bundled and non-empty', () async {
    final bytes = await rootBundle.load(trayIconAssetPath);
    expect(bytes.lengthInBytes, greaterThan(0));
  });

  test(
    'the windows tray icon is a bundled .ico and the others stay png',
    () async {
      final path = trayIconPathFor(windows: true);
      expect(path, endsWith('.ico'));
      expect((await rootBundle.load(path)).lengthInBytes, greaterThan(0));
      expect(trayIconPathFor(windows: false), endsWith('.png'));
    },
  );

  test(
    'the windows .ico holds the five sizes tray_manager can pick from',
    () async {
      final data = await rootBundle.load(trayIconWindowsAssetPath);
      final length = data.lengthInBytes;
      expect(data.getUint16(0, Endian.little), 0, reason: 'reserved');
      expect(data.getUint16(2, Endian.little), 1, reason: 'type: icon');
      final count = data.getUint16(4, Endian.little);
      expect(count, 5);
      final sizes = <int>[];
      for (var i = 0; i < count; i++) {
        final entry = 6 + i * 16;
        final width = data.getUint8(entry);
        sizes.add(width == 0 ? 256 : width);
        final size = data.getUint32(entry + 8, Endian.little);
        final offset = data.getUint32(entry + 12, Endian.little);
        expect(offset + size, lessThanOrEqualTo(length), reason: 'entry $i');
      }
      expect(sizes, [16, 20, 24, 32, 48]);
    },
  );
}
