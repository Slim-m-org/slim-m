// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The strip above the composer while a reply is staged: who it targets, a
/// one-line snippet, and a way to cancel back to an ordinary send.
///
/// Unlike `reply_quote.dart`, this never has a resolution problem to render
/// honestly: the message it names is always one this session just fetched
/// and is looking straight at, since the only way to start a reply is
/// tapping "Reply" on a row already on screen.
///
/// One flat row, no card border: its height is the close control's hit target
/// (44dp on touch, 30dp on a pointer; `docs/design/desktop-vs-mobile.md`
/// law 2) and nothing more. A text-less parent swaps the leading reply arrow
/// for a thumbnail or kind glyph, so a reply to a photo shows the photo.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../message_preview.dart';
import '../providers/message_extras.dart';
import '../providers/user_profiles.dart';
import 'author_label.dart';
import 'reply_target_summary.dart';

/// Small enough that the banner stays one row at the close control's height.
const double _thumbnailEdge = AppSpacing.s24;

class ReplyBanner extends ConsumerWidget {
  const ReplyBanner({super.key, required this.message, required this.onCancel});

  final Message message;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final label = authorLabelResolved(
      authorId: message.authorId,
      cachedDisplayName: message.authorDisplayName,
      resolution: ref.watch(
        batchProfilesControllerProvider.select(
          (m) => authorResolution(m, message.authorId ?? ''),
        ),
      ),
    );
    final attachments = ref.watch(
      messageExtrasProvider.select(
        (extras) => extras[message.id]?.attachments ?? const [],
      ),
    );
    // A text-less parent is named by what it carried, not left blank.
    final text = plainPreview(message.content);
    final snippet = previewLine(message.content, attachments);
    final showThumb = text.isEmpty && attachments.length == 1;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s8,
        AppSpacing.s4,
        AppSpacing.s8,
        0,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tokens.surfaceSunken,
          borderRadius: BorderRadius.circular(AppRadii.control),
        ),
        child: Padding(
          padding: const EdgeInsets.only(left: AppSpacing.s12),
          child: Row(
            children: [
              showThumb
                  ? ReplyAttachmentThumb(
                      attachments: attachments,
                      edge: _thumbnailEdge,
                    )
                  : Icon(AppIcons.reply, size: 14, color: tokens.textSecondary),
              const SizedBox(width: AppSpacing.s8),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: 'Replying to $label',
                        style: AppText.caption.copyWith(
                          color: tokens.textPrimary,
                          fontWeight: AppWeights.semi,
                        ),
                      ),
                      if (snippet.isNotEmpty)
                        TextSpan(
                          text: '  $snippet',
                          style: AppText.caption.copyWith(
                            color: tokens.textSecondary,
                          ),
                        ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              AppIconButton(
                icon: AppIcons.dismiss,
                semanticLabel: 'Cancel reply',
                tooltip: 'Cancel reply',
                size: AppIconButtonSize.sm,
                onPressed: onCancel,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
