// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The background-capture status under the voice shortcuts.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../settings/widgets/settings_info_line.dart';
import '../providers/global_hotkeys_controller.dart';

/// Says whether the shortcuts above work with another app focused, and why not.
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
