// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The background-capture status under the push-to-talk key, and the mute
/// shortcut row with the same status.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_platform/platform.dart';

import '../../settings/widgets/settings_info_line.dart';
import '../../settings/widgets/settings_detail_row.dart';
import '../providers/global_hotkeys_controller.dart';
import 'push_to_talk_key_row.dart';

/// Says whether the shortcut above works with another app focused, and why not.
class GlobalHotkeyStatusLine extends ConsumerWidget {
  const GlobalHotkeyStatusLine({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(globalHotkeysProvider);
    if (status == null) return const SizedBox.shrink();
    return SettingsInfoLine(
      status.message,
      tinted: true,
      warn: !status.available,
    );
  }
}

/// The mute shortcut and whether it works in the background, as a full row
/// like its siblings: it is its own setting, not a part of push to talk.
class MuteShortcutRows extends ConsumerWidget {
  const MuteShortcutRows({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final keys = describeAppAction(AppAction.toggleMuteCall);
    final chord = keys.join('+');
    return SettingsDetailRow(
      title: 'Mute shortcut',
      detail: ref.watch(globalHotkeysProvider)?.message,
      trailing: keys.isEmpty
          ? null
          : ShortcutKeyCap(
              label: chord,
              semanticLabel: 'Mute shortcut: $chord',
            ),
    );
  }
}
