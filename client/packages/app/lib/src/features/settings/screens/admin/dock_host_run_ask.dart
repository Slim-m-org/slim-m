// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a host-run connector asks the host to run (decision 0134): its image,
/// the hosts it may reach, the Private network, a data volume and its limits.
/// Shown at consent and on its page.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

/// The ask as plain lines: what runs, where it may connect, what it keeps.
List<(String, String)> dockHostRunLines(api.HostRunAsk ask) => [
  ('Image', ask.image),
  (
    'Can reach',
    ask.egress.isEmpty
        ? 'Only your server'
        : ['Your server', ...ask.egress.map((e) => '$e')].join(', '),
  ),
  if (ask.egressPrivate) ('Home network', 'Can reach devices on your network'),
  ('Ports', 'None open to the outside'),
  ('Storage', ask.volume ? 'Its own data folder' : 'None'),
  ('Limits', dockHostRunLimits(ask)),
];

String dockHostRunLimits(api.HostRunAsk ask) {
  String cpus(double c) => c == c.roundToDouble() ? '${c.round()}' : '$c';
  return [
    '${ask.memoryMib ?? 128} MB memory',
    '${cpus(ask.cpus ?? 0.5)} CPU',
    '${ask.pids ?? 64} processes',
  ].join(', ');
}

/// The ask as label and value rows, wrapping long values such as the image digest.
class DockHostRunAsk extends StatelessWidget {
  const DockHostRunAsk({super.key, required this.ask});

  final api.HostRunAsk ask;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (label, value) in dockHostRunLines(ask))
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.s8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: AppText.caption.copyWith(color: tokens.textSecondary),
                ),
                Text(
                  value,
                  style: (label == 'Image' ? AppText.code : AppText.ui)
                      .copyWith(color: tokens.textPrimary),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// The consent sheet is all or nothing, so an install approves every host and the Private network it asks for.
api.HostRunApproval? dockApproveAll(api.HostRunAsk? ask) => ask == null
    ? null
    : api.HostRunApproval(egress: ask.egress, egressPrivate: ask.egressPrivate);
