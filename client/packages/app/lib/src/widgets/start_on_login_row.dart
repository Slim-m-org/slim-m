// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The desktop setting that starts the app in the tray at sign-in.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/autostart_setting.dart';
import 'settings_toggle_row.dart';

class StartOnLoginRow extends ConsumerStatefulWidget {
  const StartOnLoginRow({super.key});

  @override
  ConsumerState<StartOnLoginRow> createState() => _StartOnLoginRowState();
}

class _StartOnLoginRowState extends ConsumerState<StartOnLoginRow> {
  bool _failed = false;

  Future<void> _set(bool on) async {
    final autostart = await ref.read(autostartProvider.future);
    if (autostart == null) return;
    try {
      await autostart.setEnabled(on);
      if (mounted) setState(() => _failed = false);
    } on Object {
      if (mounted) setState(() => _failed = true);
    }
    ref.invalidate(autostartEnabledProvider);
  }

  @override
  Widget build(BuildContext context) {
    // Absent where the system offers no login launch, rather than a switch that does nothing.
    if (ref.watch(autostartProvider).valueOrNull == null) {
      return const SizedBox.shrink();
    }
    final enabled = ref.watch(autostartEnabledProvider).valueOrNull ?? false;
    return SettingsToggleRow(
      label: 'Start on login',
      description: _failed
          ? 'Could not change this, try again.'
          : 'Opens slim-m in the tray when you sign in.',
      semanticLabel: 'Start on login',
      value: enabled,
      onChanged: _set,
    );
  }
}
