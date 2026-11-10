// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Flips "Show call overlay" for the shortcut, in the window or from another app.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../voice/providers/voice_settings_controller.dart';
import 'screen_overlay_controller.dart';

/// Does nothing where this desktop cannot host the overlay, since there is no setting to flip.
final toggleCallOverlayProvider = Provider<void Function()>(
  (ref) => () {
    if (!ref.read(screenOverlaySupportedProvider)) return;
    final settings = ref.read(voiceSettingsControllerProvider);
    unawaited(
      ref
          .read(voiceSettingsControllerProvider.notifier)
          .setCallOverlayEnabled(!settings.callOverlayEnabled),
    );
  },
);
