// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Troubleshooting row that shows how this device reaches the server right now.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../connection/providers/connection_report.dart';
import '../../connection/widgets/connection_details.dart';
import 'settings_detail_row.dart';
import 'settings_result_inset.dart';

class ConnectionRouteRow extends ConsumerWidget {
  const ConnectionRouteRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SettingsDetailRow(
        icon: AppIcons.connectionRoute,
        title: 'Connection',
        detail: 'How this device reaches the server right now.',
        trailing: AppButton(
          size: AppButtonSize.sm,
          label: 'Check',
          onPressed: () =>
              unawaited(ref.read(connectionStatusProvider.notifier).refresh()),
        ),
      ),
      const SettingsResultInset(child: ConnectionDetailsBody(inline: true)),
    ],
  );
}
