// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The ceilings every run of a module is held to, and the plain fact that it
/// asks for no access when the access card has nothing to show.
///
/// `command.register` is not listed: it grants nothing, the module's commands
/// are registered whether or not it is declared, so a chip for it read as a
/// power the admin was approving. What can be approved is on the access card.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../widgets/settings_info_line.dart';
import '../../widgets/settings_detail_row.dart';
import '../../widgets/settings_section_header.dart';
import 'dock_host_access_card.dart';

const dockNoAccessNote = 'Needs no access to your space.';

class DockLimitsCard extends StatelessWidget {
  const DockLimitsCard({super.key, required this.manifest});

  final api.DockManifest manifest;

  @override
  Widget build(BuildContext context) {
    final limits = manifest.runtime.limits;
    final asksForAccess = grantableHostCapabilities(
      manifest.capabilities,
    ).isNotEmpty;
    return SettingsSectionCard(
      title: 'Limits on every run',
      children: [
        if (!asksForAccess) const SettingsInfoLine(dockNoAccessNote),
        if (_ungranted(manifest.capabilities) case final names
            when names.isNotEmpty)
          SettingsCardBlock(
            gap: AppSpacing.s8,
            children: [
              Wrap(
                spacing: AppSpacing.s8,
                runSpacing: AppSpacing.s4,
                children: [
                  for (final name in names)
                    AppBadge(variant: AppBadgeVariant.tag, label: name),
                ],
              ),
              Text(
                'Named by the module, but this server grants nothing for it.',
                style: AppText.caption.copyWith(
                  color: Theme.of(
                    context,
                  ).extension<AppTokens>()!.textSecondary,
                ),
              ),
            ],
          ),
        _LimitRow('Memory', _describe(limits.memoryMb, (mb) => '$mb MB')),
        _LimitRow('Time', _describe(limits.wallMs, _duration)),
        _LimitRow('CPU', _describe(limits.fuel, _instructions)),
      ],
    );
  }

  /// Declared names that are neither the no-op registration nor something
  /// the access card can switch on.
  static List<String> _ungranted(List<String> declared) {
    final grantable = grantableHostCapabilities(declared);
    return [
      for (final name in declared)
        if (name != 'command.register' && !grantable.contains(name)) name,
    ];
  }

  /// One sentence for the consent step, from the same wording as the rows.
  static String summary(api.DockLimits limits) {
    final parts = [
      if (limits.memoryMb case final mb?) '$mb MB of memory',
      if (limits.wallMs case final ms?) _duration(ms),
      if (limits.fuel case final fuel?) _instructions(fuel),
    ];
    if (parts.isEmpty) return 'Each run is limited by this server\'s defaults.';
    return 'Each run is limited to ${parts.join(', ')}.';
  }

  static String _describe(int? value, String Function(int value) format) =>
      value == null ? 'host default' : format(value);

  static String _duration(int ms) {
    if (ms < 1000) return '$ms ms';
    final seconds = ms / 1000;
    final text = seconds == seconds.roundToDouble()
        ? seconds.toStringAsFixed(0)
        : seconds.toStringAsFixed(1);
    return '$text ${seconds == 1 ? 'second' : 'seconds'}';
  }

  /// Fuel is about one unit per executed instruction, which is the only thing
  /// about it an admin can weigh.
  static String _instructions(int fuel) {
    if (fuel >= 1000000000) {
      final billions = fuel / 1000000000;
      final text = billions == billions.roundToDouble()
          ? billions.toStringAsFixed(0)
          : billions.toStringAsFixed(1);
      return 'about $text billion instructions';
    }
    return 'about ${(fuel / 1000000).round()} million instructions';
  }
}

class _LimitRow extends StatelessWidget {
  const _LimitRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) =>
      SettingsDetailRow(title: label, detail: value);
}
