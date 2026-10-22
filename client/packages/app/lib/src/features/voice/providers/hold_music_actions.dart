// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What pressing play or picking a style does to hold music, shared by the
/// floating badge, the dock button and the narrow dock's mic-menu rows.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../audio/lounge_tracks.dart';
import 'hold_music_controller.dart';
import 'voice_settings_controller.dart';

/// Whether the music controls live in the floating badge rather than the dock.
///
/// Width decides (desktop-vs-mobile.md, the one rule): a compact window keeps the dock and mic-menu entries.
bool holdMusicBadgeFits(BuildContext context) =>
    MediaQuery.sizeOf(context).width >= kCompactWidth;

void toggleHoldMusic(WidgetRef ref) {
  final on = ref.read(voiceSettingsControllerProvider).holdMusicEnabled;
  unawaited(
    ref.read(voiceSettingsControllerProvider.notifier).setHoldMusicEnabled(!on),
  );
  if (!on) ref.read(holdMusicControllerProvider).startNow();
}

/// Switches style, and starts the music when it was off: picking one means wanting to hear it.
void pickHoldMusicTrack(WidgetRef ref, LoungeTrack track) {
  final settings = ref.read(voiceSettingsControllerProvider.notifier);
  final on = ref.read(voiceSettingsControllerProvider).holdMusicEnabled;
  unawaited(settings.setHoldMusicTrack(track));
  if (on) return;
  unawaited(settings.setHoldMusicEnabled(true));
  ref.read(holdMusicControllerProvider).startNow();
}
