// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [trayIconAssetPath] is a git symlink out to `packaging/linux/icons/`, the
/// same fix this project already applied once for the notification sounds
/// (`notification_sound_bundle_test.dart`) after a `../../../` asset path
/// silently bundled nothing. Loading it for real here is what would have
/// caught that class of failure before `DesktopTrayController.start()` ever
/// reached it on a real desktop.
library;

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
}
