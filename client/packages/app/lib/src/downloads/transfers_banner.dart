// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The strip that shows attachment downloads, wherever the user navigates.
///
/// A banner that pushes content (rule 6 of `docs/design/desktop-vs-mobile.md`)
/// mounted above the routed tree, so switching channels neither hides nor
/// stops a download. A running one carries percent, speed, time left and a
/// Cancel; a failure stays red on its own row until dismissed.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/app_lifecycle.dart' show isSeenNow;
import '../widgets/banner_host_layout.dart';
import '../widgets/transfer_meter.dart';
import 'downloads_controller.dart';

/// How often the rows repaint while something runs, so a stalled transfer's
/// decaying rate shows even though no bytes arrive to trigger a rebuild.
final transfersTickProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 1),
);

class TransfersBannerHost extends ConsumerStatefulWidget {
  const TransfersBannerHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<TransfersBannerHost> createState() =>
      _TransfersBannerHostState();
}

class _TransfersBannerHostState extends ConsumerState<TransfersBannerHost> {
  Timer? _tick;

  void _syncTicker(bool running) {
    if (running && _tick == null) {
      _tick = Timer.periodic(ref.read(transfersTickProvider), (_) {
        if (mounted && isSeenNow(context)) setState(() {});
      });
    } else if (!running) {
      _tick?.cancel();
      _tick = null;
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tasks = ref.watch(downloadsProvider);
    _syncTicker(tasks.any((t) => t.running));
    return BannerHostLayout(
      banner: tasks.isEmpty
          ? null
          : SafeArea(
              bottom: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [for (final t in tasks) _TransferRow(task: t)],
              ),
            ),
      child: widget.child,
    );
  }
}

class _TransferRow extends ConsumerWidget {
  const _TransferRow({required this.task});

  final DownloadTask task;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final downloads = ref.read(downloadsProvider.notifier);
    final name = task.attachment.filename;
    if (task.phase == DownloadPhase.failed) {
      return AppErrorState(
        message: task.message ?? 'Could not save $name.',
        onRetry: () => downloads.start(task.attachment),
        onDismiss: () => downloads.dismiss(task.id),
      );
    }
    if (task.phase == DownloadPhase.done) {
      return AppCallout(
        tone: AppCalloutTone.info,
        icon: AppIcons.download,
        child: Row(
          children: [
            Expanded(
              child: Text(
                'Saved $name',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            AppIconButton(
              icon: AppIcons.dismiss,
              semanticLabel: 'Dismiss',
              size: AppIconButtonSize.sm,
              onPressed: () => downloads.dismiss(task.id),
            ),
          ],
        ),
      );
    }
    final total = task.total;
    final fraction = total == null || total <= 0
        ? null
        : (task.received / total).clamp(0.0, 1.0);
    final percent = fraction == null ? null : (fraction * 100).floor();
    return AppCallout(
      tone: AppCalloutTone.info,
      icon: AppIcons.download,
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.caption.copyWith(
                    color: Theme.of(
                      context,
                    ).extension<AppTokens>()!.textPrimary,
                  ),
                ),
                Text(
                  formatTransferLine(
                    sent: task.received,
                    total: total,
                    meter: task.meter,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: AppSpacing.s4),
                LinearProgressIndicator(
                  value: fraction,
                  minHeight: 3,
                  semanticsLabel: 'Downloading $name',
                  semanticsValue: percent == null ? null : '$percent%',
                ),
              ],
            ),
          ),
          AppButton(
            label: 'Cancel',
            variant: AppButtonVariant.ghost,
            size: AppButtonSize.sm,
            semanticLabel: 'Cancel download of $name',
            onPressed: () => downloads.cancel(task.id),
          ),
        ],
      ),
    );
  }
}
