// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which screen the call overlay goes on, offered only with more than one.
library;

import 'package:flutter/material.dart';
import 'package:slimm_platform/platform.dart' show OverlayMonitor;

import '../../screen_overlay/providers/call_overlay_panel.dart';
import '../../settings/widgets/settings_segmented_row.dart';
import '../../settings/widgets/settings_select_row.dart' show SettingsChoice;

class OverlayScreenRow extends StatelessWidget {
  const OverlayScreenRow({
    super.key,
    required this.monitors,
    required this.value,
    required this.onChanged,
  });

  final List<OverlayMonitor> monitors;

  /// An [overlayScreenKey], or null to follow the app window.
  final String? value;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    if (monitors.length < 2) return const SizedBox.shrink();
    final keys = [for (final m in monitors) overlayScreenKey(m)];
    // A chosen screen that is unplugged reads as automatic, which is what the overlay does with it.
    final selected = keys.contains(value) ? value : null;
    return SettingsSegmentedRow<String?>(
      label: 'Overlay screen',
      description: 'Automatic uses the screen slim-m is on.',
      value: selected,
      choices: [
        const SettingsChoice(value: null, label: 'Automatic'),
        for (var i = 0; i < monitors.length; i++)
          SettingsChoice(value: keys[i], label: 'Screen ${i + 1}'),
      ],
      onChanged: onChanged,
    );
  }
}
