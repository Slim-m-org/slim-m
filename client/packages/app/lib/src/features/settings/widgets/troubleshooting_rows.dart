// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Troubleshooting card's own rows besides the debug log: the live call
/// numbers and a replay of first-run setup, both things a person reaches for
/// when something is not working as expected.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../routing/routes.dart';
import '../../first_run/providers/first_run_controller.dart';
import 'settings_detail_row.dart';

class CallStatsRow extends StatelessWidget {
  const CallStatsRow({super.key});

  @override
  Widget build(BuildContext context) {
    return SettingsDetailRow(
      icon: AppIcons.requestLatency,
      title: 'Call stats',
      detail: 'Live video numbers for a call.',
      trailing: const Icon(AppIcons.chevronRight, size: AppSizes.icon16),
      onTap: () => unawaited(context.push(Routes.callStats)),
    );
  }
}

class RunSetupAgainRow extends ConsumerWidget {
  const RunSetupAgainRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SettingsDetailRow(
      icon: AppIcons.redo,
      title: 'Run setup again',
      detail: 'Profile, notifications and voice, one step at a time.',
      trailing: const Icon(AppIcons.chevronRight, size: AppSizes.icon16),
      onTap: () {
        ref.read(firstRunControllerProvider.notifier).replay();
        context.go(Routes.channels);
      },
    );
  }
}
