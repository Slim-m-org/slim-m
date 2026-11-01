// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The CI bundle-check the roadmap named: a missing notification sound must
/// fail a build, never fall back to silently playing nothing.
///
/// Every [NotificationSound] is loaded straight out of `rootBundle` by its
/// real asset key, the same one `pubspec.yaml` declares and
/// `AudioPlayersSoundPlayer` plays from - so a symlink that stopped
/// resolving, an asset entry dropped from `pubspec.yaml`, or a file deleted
/// from `assets/audio/notifications/` all fail here rather than only at
/// runtime on a real device.
library;

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/audio/notification_sound.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final sound in NotificationSound.values) {
    test('${sound.name} is bundled and non-empty', () async {
      final bytes = await rootBundle.load(sound.assetKey);
      expect(bytes.lengthInBytes, greaterThan(0));
    });
  }
}
