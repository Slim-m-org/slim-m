// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The filename-and-size chip for an attachment this app cannot render
/// inline: anything outside `inlineImageTypes` and outside `isVideo`, most
/// commonly a PDF, an archive, or plain text. Split out of
/// `attachment_view.dart` to keep that file within its size budget; see its
/// own doc comment for the full picture of what renders where.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../downloads/downloads_controller.dart';
import 'attachment_format.dart';
import '../../../widgets/run_guarded.dart';

class AttachmentChip extends ConsumerStatefulWidget {
  const AttachmentChip({super.key, required this.attachment});

  final api.Attachment attachment;

  @override
  ConsumerState<AttachmentChip> createState() => _AttachmentChipState();
}

class _AttachmentChipState extends ConsumerState<AttachmentChip>
    with GuardedActionState<AttachmentChip> {
  api.Attachment get attachment => widget.attachment;

  /// Hands the download to the app-scoped controller, which outlives this
  /// chip; progress and Cancel live in the transfers banner.
  void _save() {
    clearActionError();
    unawaited(ref.read(downloadsProvider.notifier).start(attachment));
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final saving = ref.watch(
      downloadsProvider.select(
        (tasks) =>
            tasks.any((t) => t.running && t.attachment.id == attachment.id),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          button: true,
          label: 'Save ${attachment.filename}',
          onTap: _save,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: _save,
              child: SelectionContainer.disabled(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.s12,
                    vertical: AppSpacing.s8,
                  ),
                  decoration: BoxDecoration(
                    color: tokens.surfaceRaised,
                    border: Border.all(color: tokens.borderSubtle),
                    borderRadius: BorderRadius.circular(AppRadii.control),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Flexible, not a bare Text: a long real filename would otherwise overflow the row.
                      Flexible(
                        child: Text(
                          attachment.filename,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.ui.copyWith(color: tokens.textPrimary),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.s8),
                      Text(
                        formatByteSize(attachment.size),
                        style: AppText.caption.copyWith(
                          color: tokens.textSecondary,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.s8),
                      saving
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(
                              AppIcons.download,
                              size: AppSizes.icon16,
                              color: tokens.textSecondary,
                            ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        if (actionError != null) ...[
          const SizedBox(height: AppSpacing.s4),
          AppErrorState(message: actionError!, onDismiss: clearActionError),
        ],
      ],
    );
  }
}
