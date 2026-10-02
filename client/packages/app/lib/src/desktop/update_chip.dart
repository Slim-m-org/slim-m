// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The title bar's compact update control: a small "Update" button that shows
/// while a newer build is waiting and runs the same action as the window
/// menu's Update item. The version lives in its tooltip and semantic label so
/// a long version string can never widen the bar.
///
/// Install progress shows in place as the button's busy state; a failure
/// stays in `SelfUpdateFailureBanner`'s persistent `AppErrorState`.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import 'desktop_window_port.dart';
import 'self_update/self_update_controller.dart';
import 'update_action.dart';
import 'update_watch.dart';

class UpdateChip extends ConsumerWidget {
  const UpdateChip({super.key, required this.port});

  final DesktopWindowPort port;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final update = ref.watch(inSessionUpdateProvider);
    final action = ref.watch(updateActionProvider);
    if (update == null || action == null) return const SizedBox.shrink();
    final installing = ref.watch(selfUpdateInstallingProvider);
    final label = updateActionLabel(update, action, installing: installing);
    return Padding(
      padding: const EdgeInsets.only(right: AppSpacing.s4),
      child: Tooltip(
        message: label,
        excludeFromSemantics: true,
        child: AppButton(
          label: installing ? 'Installing' : 'Update',
          semanticLabel: label,
          icon: AppIcons.download,
          variant: AppButtonVariant.soft,
          size: AppButtonSize.sm,
          busy: installing,
          onPressed: () => unawaited(
            runUpdateAction(
              ref,
              port: port,
              update: update,
              action: action,
              context: context,
              isMounted: () => context.mounted,
            ),
          ),
        ),
      ),
    );
  }
}
