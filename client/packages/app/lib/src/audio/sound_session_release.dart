// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Frees the iOS audio session from every plugin-played sound before a call joins.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_platform/platform.dart' show isIOSHost;

import '../features/messages/providers/voice_playback.dart';
import '../features/settings/providers/notification_sound_controller.dart';

/// audioplayers deactivates the shared session whenever its last player stops, which would cut a call that just claimed it.
final soundSessionReleaseProvider = Provider<Future<void> Function()>(
  (ref) => () async {
    await ref.read(voicePlaybackProvider.notifier).stopForCall();
    if (isIOSHost) {
      await ref.read(notificationSoundControllerProvider).stopAllForCall();
    }
  },
);
