// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where a download that went wrong stays visible, wherever the user navigates.
///
/// A download just saves: progress shows on the attachment itself and success
/// is a toast. Only a failure needs to persist, so it floats over the shell's
/// bottom edge and never moves the content or the title bar around it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import 'downloads_controller.dart';

/// The widest a failure card grows, so it reads as a card rather than a bar.
const double _maxWidth = 420;

class DownloadFailureHost extends ConsumerWidget {
  const DownloadFailureHost({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final failed = ref.watch(
      downloadsProvider.select(
        (tasks) => [
          for (final t in tasks)
            if (t.phase == DownloadPhase.failed) t,
        ],
      ),
    );
    final downloads = ref.read(downloadsProvider.notifier);
    return Stack(
      children: [
        Positioned.fill(child: child),
        if (failed.isNotEmpty)
          Positioned(
            left: AppSpacing.s16,
            right: AppSpacing.s16,
            bottom: AppSpacing.s16,
            child: SafeArea(
              top: false,
              child: Align(
                alignment: Alignment.bottomLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: _maxWidth),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    spacing: AppSpacing.s8,
                    children: [
                      for (final task in failed)
                        AppErrorState(
                          message:
                              task.message ??
                              'Could not save ${task.attachment.filename}.',
                          onRetry: () => downloads.start(task.attachment),
                          onDismiss: () => downloads.dismiss(task.id),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
