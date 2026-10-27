// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The composer's smaller pieces: the text field itself, its markdown key
/// bindings, and the banners above the action bar.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_design_system/design_system.dart';

import 'composer_attachments.dart';
import 'staged_attachment_tile.dart';

export 'composer_field.dart';

/// How many characters past [kMessageMaxChars] the given [length] sits, or
/// null when it is within the limit. Runs before the send goes out, so the
/// composer can refuse a doomed request rather than let it fail on the wire.
int? messageLengthOverage(int length) =>
    length > kMessageMaxChars ? length - kMessageMaxChars : null;

/// Below this margin a count is not worth showing at all: an ordinary short
/// message generates no counter.
const _counterWarnMargin = 500;

/// Whether the composer's live character counter is worth showing [length].
bool messageCounterVisible(int length) =>
    length >= kMessageMaxChars - _counterWarnMargin;

/// The composer's live character count, shown only once close enough to
/// [kMessageMaxChars] to matter, so the limit is learned while typing rather
/// than only from the failure a send past it would otherwise be.
class MessageLengthCounter extends StatelessWidget {
  const MessageLengthCounter({super.key, required this.length});

  final int length;

  @override
  Widget build(BuildContext context) {
    if (!messageCounterVisible(length)) return const SizedBox.shrink();
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final over = length > kMessageMaxChars;
    return Text(
      '$length / $kMessageMaxChars',
      style: AppText.code.copyWith(
        color: over ? tokens.dangerText : tokens.textSecondary,
      ),
    );
  }
}

/// dismiss to, since editing the text back under the limit is what clears it.
class ComposerInlineError extends StatelessWidget {
  const ComposerInlineError({
    super.key,
    required this.message,
    this.onDismiss,
    this.autoDismissAfter,
  });

  final String message;
  final VoidCallback? onDismiss;

  /// Set for a transient action failure (a gif that would not attach) so it
  /// clears itself; left null for a live state like the over-limit band,
  /// which clears when the text is edited back under the limit. See
  /// `AppErrorState.autoDismissAfter`.
  final Duration? autoDismissAfter;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpacing.s8),
    child: AppErrorState(
      message: message,
      onDismiss: onDismiss,
      autoDismissAfter: autoDismissAfter,
    ),
  );
}

/// The composer's two optional bands above the action bar: an attachment
/// failure (a picker that would not open, or a clipboard paste that failed),
/// if there is one to show, and the staged-attachment tiles.
///
/// One widget rather than two calls at the build site, since both are
/// "nothing, unless" content and `composer.dart` has no line budget left to
/// spend on laying them out itself.
class ComposerBanners extends StatelessWidget {
  const ComposerBanners({
    super.key,
    required this.attachmentError,
    required this.onDismissAttachmentError,
    required this.overLimitBy,
    required this.slowModeRemainingSeconds,
    required this.stagedAttachments,
    required this.onRemoveAttachment,
    required this.onRetryAttachment,
    this.isSpoiler,
    this.onToggleSpoiler,
    this.commandError,
    this.onDismissCommandError,
  });

  final String? attachmentError;
  final VoidCallback onDismissAttachmentError;

  /// A slash command that would not run (a 403, or the module's own error).
  /// Transient like [attachmentError]: the `/command` text stays in the field
  /// so it can be retried, and the band clears itself after a beat.
  final String? commandError;
  final VoidCallback? onDismissCommandError;

  /// How many characters over [kMessageMaxChars] the composed text sits, or
  /// null when it is within the limit. Non-null both disables the send
  /// button and shows this band, so the refusal is never silent.
  final int? overLimitBy;

  /// Seconds left before the channel's slow mode allows another send, or 0
  /// while it is off, this device is exempt, or the interval has already
  /// elapsed - see `slow_mode_controller.dart`. Non-zero both disables the
  /// send button and shows this band, the same "never silent" rule
  /// [overLimitBy] follows.
  final int slowModeRemainingSeconds;
  final List<StagedAttachment> stagedAttachments;
  final ValueChanged<String> onRemoveAttachment;
  final ValueChanged<String> onRetryAttachment;

  /// Whether a staged item is marked as a spoiler; null offers no spoilers.
  final bool Function(String localId)? isSpoiler;
  final ValueChanged<String>? onToggleSpoiler;

  @override
  Widget build(BuildContext context) {
    final error = attachmentError;
    final command = commandError;
    final overBy = overLimitBy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppRevealBand(
          child: error == null
              ? null
              : ComposerInlineError(
                  message: error,
                  onDismiss: onDismissAttachmentError,
                  // A gif/attachment action failure is transient and self-correcting - clear it after a beat, unlike the over-limit band below which is a live state.
                  autoDismissAfter: const Duration(seconds: 6),
                ),
        ),
        AppRevealBand(
          child: command == null
              ? null
              : ComposerInlineError(
                  message: command,
                  onDismiss: onDismissCommandError,
                  autoDismissAfter: const Duration(seconds: 6),
                ),
        ),
        AppRevealBand(
          child: overBy == null
              ? null
              : ComposerInlineError(
                  message:
                      'Message is $overBy characters over the '
                      '$kMessageMaxChars-character limit.',
                ),
        ),
        AppRevealBand(
          child: slowModeRemainingSeconds <= 0
              ? null
              : ComposerInlineError(
                  message:
                      'Slow mode: wait ${slowModeRemainingSeconds}s '
                      'before sending again.',
                ),
        ),
        AppRevealBand(
          child: stagedAttachments.isEmpty
              ? null
              : Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.s8),
                  child: Wrap(
                    spacing: AppSpacing.s8,
                    runSpacing: AppSpacing.s8,
                    children: [
                      for (final attachment in stagedAttachments)
                        StagedAttachmentTile(
                          key: ValueKey(attachment.localId),
                          attachment: attachment,
                          onRemove: () =>
                              onRemoveAttachment(attachment.localId),
                          onRetry: () => onRetryAttachment(attachment.localId),
                          spoiler: isSpoiler?.call(attachment.localId) ?? false,
                          onToggleSpoiler:
                              onToggleSpoiler != null &&
                                  (looksLikeImage(attachment.filename) ||
                                      looksLikeVideo(attachment.filename))
                              ? () => onToggleSpoiler!(attachment.localId)
                              : null,
                        ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}

/// The composer's secondary actions, off the row rather than on it.
///
/// At touch density five 44pt controls plus their gaps leave a 390pt phone
/// about 90pt of text field, measured, which is not a composer any longer.
/// Attach, poll and code move behind the one button that already means "add
/// something"; emoji and send stay on the row because both are used mid-
/// sentence, where a sheet would cost the caret.
///
/// Attaching splits into two rows rather than one, because a single "Attach
/// a file" hid a choice `file_picker` actually requires on iOS and Android;
/// see `attachment_picker.dart` for why the two cannot share one request.
///
/// [canPasteImage] decides whether the "Paste image" row is worth offering
/// (see `composer_clipboard_paste.dart`'s `composerClipboardPasteAvailable`)
/// and is resolved here, after the sheet is already open, rather than
/// awaited by the caller first: the row simply appears a moment later
/// rather than the whole sheet waiting on a platform-channel round trip to
/// open at all. Deliberate, not an oversight - awaiting it first was tried
/// and reverted; see this file's neighbour for why.
Future<void> showComposerActionsSheet(
  BuildContext context, {
  required VoidCallback onPhotoLibrary,
  required VoidCallback onBrowseFiles,
  required Future<bool> canPasteImage,
  required VoidCallback onPasteImage,
  required VoidCallback onPoll,
  required VoidCallback onCode,
  VoidCallback? onGif,
  VoidCallback? onApps,
}) {
  return showAppSheet<void>(
    context,
    builder: (sheetContext) => FutureBuilder<bool>(
      future: canPasteImage,
      builder: (context, snapshot) {
        final tokens = Theme.of(context).extension<AppTokens>()!;
        final actions = <(IconData, String, VoidCallback)>[
          (AppIcons.image, 'Photo library', onPhotoLibrary),
          (AppIcons.attachFile, 'Browse files', onBrowseFiles),
          if (snapshot.data == true)
            (AppIcons.clipboardPaste, 'Paste image', onPasteImage),
          (AppIcons.poll, 'Create a poll', onPoll),
          (AppIcons.code, 'Insert code', onCode),
          if (onGif != null) (AppIcons.gif, 'GIF', onGif),
          if (onApps != null) (AppIcons.dock, 'Launch an app', onApps),
        ];
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s12,
              0,
              AppSpacing.s12,
              AppSpacing.s12,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final (icon, label, action) in actions)
                  AppListRow(
                    label: label,
                    leading: Icon(
                      icon,
                      size: AppSizes.icon16,
                      color: tokens.textSecondary,
                    ),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      action();
                    },
                  ),
              ],
            ),
          ),
        );
      },
    ),
  );
}
