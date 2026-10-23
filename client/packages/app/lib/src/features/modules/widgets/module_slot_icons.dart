// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The glyphs a module slot may name, mapped to the app's icon set.
library;

import 'package:flutter/widgets.dart';
import 'package:slimm_design_system/design_system.dart';

/// Null for a name this app does not have, so no icon is drawn at all.
IconData? moduleSlotIcon(String? name) => switch (name) {
  'play' => AppIcons.play,
  'pause' => AppIcons.pause,
  'stop' => AppIcons.callStop,
  'skip_next' => AppIcons.callSkipNext,
  'skip_previous' => AppIcons.callSkipPrevious,
  'volume' => AppIcons.speaker,
  'volume_off' => AppIcons.speakerOff,
  'repeat' => AppIcons.callRepeat,
  'shuffle' => AppIcons.callShuffle,
  'list' => AppIcons.callList,
  'settings' => AppIcons.settings,
  _ => null,
};
