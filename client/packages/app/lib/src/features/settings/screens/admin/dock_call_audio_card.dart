// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// "Calls it can hear": the voice channels an admin lets a module listen in
/// on (decision 0105). The list starts empty, so approving the power alone
/// lets the module hear nothing. A section of the module's own settings page,
/// which is a `modalPage` (desktop-vs-mobile.md rule 5), so a channel is a
/// switch in place rather than a dialog of its own.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../channels/providers/channel_permissions.dart'
    show myVisibleChannelsProvider;
import '../../providers/dock_call_audio_channels.dart';
import '../../widgets/settings_info_line.dart';
import '../../widgets/settings_section_header.dart';
import '../../widgets/settings_toggle_row.dart';

class DockCallAudioCard extends ConsumerWidget {
  const DockCallAudioCard({
    super.key,
    required this.moduleId,
    required this.moduleName,
    this.enabled = true,
  });

  final String moduleId;
  final String moduleName;
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final armed = ref.watch(dockCallAudioChannelsProvider(moduleId));
    final channels = [
      for (final c
          in ref.watch(myVisibleChannelsProvider).valueOrNull ??
              const <api.Channel>[])
        if (c.kind == 'voice') c,
    ];
    final ids = armed.valueOrNull?.ids ?? const <String>[];
    return SettingsSectionCard(
      title: 'Calls it can hear',
      children: [
        SettingsInfoLine(
          ids.isEmpty
              ? 'It hears nothing until you pick a call. Everyone in a call '
                    'is still asked first.'
              : 'Everyone in a call is asked before it hears anything.',
          warn: ids.isEmpty,
        ),
        if (channels.isEmpty)
          const SettingsInfoLine('There are no voice channels yet.'),
        for (final channel in channels)
          SettingsToggleRow(
            label: channel.name,
            value: ids.contains(channel.id),
            onChanged: enabled && armed.hasValue
                ? (on) => ref
                      .read(dockCallAudioChannelsProvider(moduleId).notifier)
                      .toggle(channel.id, armed: on)
                : null,
            semanticLabel: '${channel.name} for $moduleName',
          ),
        if (armed.valueOrNull?.error case final message?)
          AppErrorState(message: message),
        if (armed.hasError)
          const AppErrorState(message: 'Could not load the calls it can hear.'),
      ],
    );
  }
}
