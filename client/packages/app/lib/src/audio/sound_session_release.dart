// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Frees the iOS audio session from every plugin-played sound before a call joins.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_platform/platform.dart' show isIOSHost;

import '../features/settings/providers/notification_sound_controller.dart';

/// audioplayers deactivates the shared session whenever its last player stops, which would cut a call that just claimed it.
final soundSessionReleaseProvider = Provider<Future<void> Function()>(
  (ref) =>
      () => isIOSHost
      ? ref.read(notificationSoundControllerProvider).stopAllForCall()
      : Future<void>.value(),
);
