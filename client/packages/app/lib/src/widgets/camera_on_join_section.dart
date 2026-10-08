// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The "before you join" half of the camera pre-toggle.
///
/// There is no lobby to put a pre-toggle in anymore (`voice_screen.dart`'s
/// own doc explains why: the owner asked twice for it gone, and a channel
/// arrival auto-joins). The only "before joining" moment left in this client
/// is Voice Settings, so this is a persisted preference in the same shape as
/// `screenShareQuality` and the sounds toggles, applied to
/// `VoiceController.setCameraPreference` both live (this session, the moment
/// it is flipped) and at the next fresh launch
/// (`VoiceController.restoreCameraPreference`, awaited from bootstrap).
///
/// The toggle's `semanticLabel` is a fixed sentence rather than a
/// state-conditional one, found only by dumping the real semantics tree: an
/// `AppToggle`'s own `Semantics(toggled: ...)` already reports on/off, and a
/// first draft that also flipped this label between "...camera on" and
/// "...camera off" merged with the row's static visible label ("...camera
/// on") into one utterance that said both - contradictory once actually
/// read aloud, not merely redundant. `_SoundsSection`'s sibling toggles never
/// hit this because neither of their labels names a state at all.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/voice_settings_controller.dart';
import 'settings_section_header.dart';
import 'settings_toggle_row.dart';

class CameraOnJoinSection extends ConsumerWidget {
  const CameraOnJoinSection({super.key, this.embedded = false});

  /// Rows only, for a card another section already owns.
  final bool embedded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(voiceSettingsControllerProvider);

    final rows = [
      SettingsToggleRow(
        label: 'Join with camera on',
        description: 'Calls still connect without a camera.',
        value: settings.cameraOnJoin,
        // Fixed, not state-conditional; see the library doc above for why.
        semanticLabel: 'Join calls with your camera on',
        onChanged: (value) => ref
            .read(voiceSettingsControllerProvider.notifier)
            .setCameraOnJoin(value),
      ),
    ];
    if (embedded) return Column(children: rows);
    return SettingsSectionCard(
      title: 'Camera',
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    );
  }
}
