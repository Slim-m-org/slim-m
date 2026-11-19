// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Silences every plugin-played sound on iOS before a call joins.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_platform/platform.dart' show isIOSHost;

import '../features/settings/providers/notification_sound_controller.dart';

/// A ring or chime still sounding would play over the call that just took the shared session.
final soundSessionReleaseProvider = Provider<Future<void> Function()>(
  (ref) => () async {
    if (isIOSHost) {
      await ref.read(notificationSoundControllerProvider).stopAllForCall();
    }
  },
);
