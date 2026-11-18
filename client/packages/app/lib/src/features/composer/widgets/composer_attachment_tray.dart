// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The staged-attachment tiles above the action bar, capped in height and
/// scrolled past it, with a line saying why Send is waiting when it is.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'composer_attachments.dart';
import 'staged_attachment_tile.dart';

/// Why a send would be refused by what is staged, or null when nothing
/// staged is in the way. The failed case wins: retrying is the one step
/// that is the sender's to take.
String? attachmentSendBlockReason(AttachmentStagingController attachments) {
  final failed = attachments.failedCount;
  if (failed > 0) {
    return failed == 1
        ? 'A file did not upload. Retry or remove it to send.'
        : '$failed files did not upload. Retry or remove them to send.';
  }
  final uploading = attachments.uploadingCount;
  if (uploading > 0) {
    return uploading == 1
        ? 'Send waits for the upload to finish.'
        : 'Send waits for $uploading uploads to finish.';
  }
  return null;
}

/// How many rows of tiles show before the tray scrolls.
const _visibleRows = 3;

/// One row: a tile is its 40 px thumbnail, 4 px padding each side and a
/// 1 px border, or the 44 px touch target at touch density.
double _rowExtent(BuildContext context) =>
    (AppTouchTargets.of(context) ? AppSizes.rowTouch : AppSpacing.s40) +
    AppSpacing.s8 +
    2;

/// Never more than this share of the window, so a phone keeps its timeline.
const _maxWindowShare = 0.25;

class ComposerAttachmentTray extends StatefulWidget {
  const ComposerAttachmentTray({super.key, required this.attachments});

  final AttachmentStagingController attachments;

  @override
  State<ComposerAttachmentTray> createState() => _ComposerAttachmentTrayState();
}

class _ComposerAttachmentTrayState extends State<ComposerAttachmentTray> {
  final _scroll = ScrollController();
  int _shown = 0;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// A new file lands at the end, so the end is brought into view.
  void _followNewest(int count) {
    final grew = count > _shown;
    _shown = count;
    if (!grew) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  double _maxHeight(BuildContext context) {
    final row = _rowExtent(context);
    final rows = _visibleRows * row + (_visibleRows - 1) * AppSpacing.s8;
    final window =
        MediaQuery.sizeOf(context).height -
        MediaQuery.viewInsetsOf(context).bottom;
    // Half a row of the next one peeks out, so the tray reads as scrollable.
    return math.max(row, math.min(rows + row / 2, window * _maxWindowShare));
  }

  @override
  Widget build(BuildContext context) {
    final staging = widget.attachments;
    final items = staging.items;
    _followNewest(items.length);
    final reason = attachmentSendBlockReason(staging);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: _maxHeight(context)),
            child: Scrollbar(
              controller: _scroll,
              child: SingleChildScrollView(
                key: const Key('composer-attachment-tray'),
                controller: _scroll,
                child: Wrap(
                  spacing: AppSpacing.s8,
                  runSpacing: AppSpacing.s8,
                  children: [
                    for (final attachment in items) _tile(staging, attachment),
                  ],
                ),
              ),
            ),
          ),
          if (reason != null)
            _BlockedLine(
              reason: reason,
              failed: staging.failedCount > 0,
              onRemoveFailed: staging.removeFailed,
            ),
        ],
      ),
    );
  }

  Widget _tile(AttachmentStagingController staging, StagedAttachment a) {
    final canSpoil = looksLikeImage(a.filename) || looksLikeVideo(a.filename);
    return StagedAttachmentTile(
      key: ValueKey(a.localId),
      attachment: a,
      onRemove: () => staging.remove(a.localId),
      onRetry: () => staging.retry(a.localId),
      spoiler: staging.isSpoiler(a.localId),
      onToggleSpoiler: canSpoil ? () => staging.toggleSpoiler(a.localId) : null,
    );
  }
}

/// The reason under the tray, plus one control to clear every failed file.
class _BlockedLine extends StatelessWidget {
  const _BlockedLine({
    required this.reason,
    required this.failed,
    required this.onRemoveFailed,
  });

  final String reason;
  final bool failed;
  final VoidCallback onRemoveFailed;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.s8),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              liveRegion: true,
              child: Text(
                reason,
                style: AppText.caption.copyWith(
                  color: failed ? tokens.dangerText : tokens.textSecondary,
                ),
              ),
            ),
          ),
          if (failed) ...[
            const SizedBox(width: AppSpacing.s8),
            AppButton(
              label: 'Remove failed',
              variant: AppButtonVariant.ghost,
              size: AppButtonSize.sm,
              onPressed: onRemoveFailed,
            ),
          ],
        ],
      ),
    );
  }
}
