// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The bounded auto-rejoin's own feedback, laid over the call stage instead
/// of replacing it wholesale; see `voice_screen.dart`'s stage comment.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/status_banner.dart';

/// While the media path is rebuilt, or the call is being joined again.
const reconnectingMediaLine =
    "Reconnecting to the call. You can't hear or be heard right now.";

/// While only the signalling socket is repaired and audio keeps flowing.
const reconnectingSignalLine =
    'Reconnecting to the call. You can still hear everyone, '
    'but who is here may be out of date.';

/// Shown while [VoiceState.rejoining] or [VoiceState.reconnecting] is true,
/// in the call stage's own column under the header - the grid, filmstrip and
/// dock stay put and usable around it, unlike the full-screen spinner a first
/// connection still gets.
class VoiceReconnectBanner extends StatelessWidget {
  const VoiceReconnectBanner({super.key, this.mediaDown = false});

  /// No audio either way: the media path is rebuilt, the app is joining
  /// again, or the server lost this device.
  final bool mediaDown;

  @override
  Widget build(BuildContext context) {
    return StatusBanner(
      severity: BannerSeverity.warning,
      sticky: true,
      icon: AppIcons.retry,
      message: mediaDown ? reconnectingMediaLine : reconnectingSignalLine,
      margin: const EdgeInsets.only(top: AppSpacing.s12),
    );
  }
}
