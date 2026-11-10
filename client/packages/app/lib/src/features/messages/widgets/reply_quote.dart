// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one-line context a reply shows above its own avatar: the parent's
/// author and a snippet of its content, tappable to jump to it.
///
/// Deliberately resolves nothing itself. The parent's content, author and
/// liveness all come from [ReplyQuote.resolved], which the transcript
/// already looked up against whatever it currently has loaded - and that
/// lookup is where blocking and deletion are already handled, so this
/// widget cannot leak either: a blocked author's message is absent from it
/// exactly as it is absent from its own row, and a deleted message was
/// discarded from the local store entirely rather than merely marked. Both
/// causes, and a parent simply not paged in yet, collapse into the same
/// null and the same honest placeholder - never a guess at which one it was.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../message_preview.dart';
import '../providers/message_extras.dart';
import '../../members/providers/user_profiles.dart';
import '../../members/widgets/user_avatar.dart';
import 'author_label.dart';
import 'reply_target_summary.dart';

/// How much of a quoted message's own text is shown before it is cut off - a
/// compact quote, not a second copy of the message.
const int _quoteMaxRunes = 120;

/// Whether [message] draws its reply context at all.
///
/// A bot answering a command it was just sent drops the echo: the command is
/// already the line above it.
bool showsReplyQuote({
  required Message message,
  required Message? parent,
  required bool authorIsBot,
  required bool parentAdjacent,
}) =>
    message.replyToId != null &&
    !(authorIsBot && parentAdjacent && _isCommand(parent));

bool _isCommand(Message? parent) {
  final text = parent?.content.trimLeft() ?? '';
  return text.startsWith('!') || text.startsWith('/');
}

class ReplyQuote extends ConsumerWidget {
  const ReplyQuote({
    super.key,
    required this.resolved,
    required this.onTap,
    this.pinged = false,
  });

  /// The reply mentioned this viewer, so the author is shown as "@Name".
  final bool pinged;

  /// The parent message, if this client currently holds it locally. See this
  /// file's own doc comment for what null does and does not mean.
  final Message? resolved;

  /// Jumps to the parent. Wired even when [resolved] is null: the
  /// transcript's own loaded window is not the only place a message can be
  /// found, and the jump this calls pages further history in on its own.
  final VoidCallback onTap;

  /// Keys for tests that measure the quote and the avatar inside it.
  static const Key quoteKey = Key('reply_quote');
  static const Key avatarKey = Key('reply_quote_avatar');

  /// The focus ring's reserved margin on each side, which the caller takes
  /// back out of the space around the quote so its content stays on the grid.
  static const double ringInset = focusRingGap + focusRingWidth;

  /// One line: the avatar, or one caption line at the reader's text scale
  /// when that is taller.
  static double lineHeightOf(BuildContext context) => math.max(
    AppAvatarSize.s16,
    MediaQuery.textScalerOf(context).scale(AppText.caption.fontSize!) *
        AppText.caption.height!,
  );

  /// The quote's whole box: its line and the focus ring's margin around it.
  static double heightOf(BuildContext context) =>
      lineHeightOf(context) + 2 * ringInset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final resolved = this.resolved;
    final resolution = resolved == null
        ? null
        : ref.watch(
            batchProfilesControllerProvider.select(
              (m) => authorResolution(m, resolved.authorId ?? ''),
            ),
          );
    final name = _nameFor(resolved, resolution);
    final label = name == null || !pinged ? name : '@$name';
    final attachments = resolved == null
        ? const <api.Attachment>[]
        : ref.watch(
            messageExtrasProvider.select(
              (extras) => extras[resolved.id]?.attachments ?? const [],
            ),
          );
    final hasText =
        resolved != null && plainPreview(resolved.content).isNotEmpty;
    final showThumb = resolved != null && !hasText && attachments.length == 1;
    final snippet = switch (resolved) {
      null => 'Message unavailable',
      _ when !hasText && attachments.isNotEmpty => attachmentKindLabel(
        attachments,
      ),
      _ => previewSnippet(resolved.content, maxRunes: _quoteMaxRunes),
    };
    return AppTouchHitArea(
      key: quoteKey,
      alignment: Alignment.topLeft,
      child: Semantics(
        button: true,
        label: label == null
            ? 'Reply to a message that is not available'
            : 'Reply to $label: $snippet',
        child: AppFocusRing(
          radius: AppRadii.control,
          builder: (context, onFocusChange) => InkWell(
            onTap: onTap,
            // AppFocusRing replaces this overlay; see its own doc comment.
            focusColor: Colors.transparent,
            onFocusChange: onFocusChange,
            borderRadius: BorderRadius.circular(AppRadii.control),
            child: SizedBox(
              height: lineHeightOf(context),
              child: _quoteRow(
                tokens,
                resolved: resolved,
                label: label,
                name: name,
                snippet: snippet,
                profile: resolution?.profile,
                thumb: showThumb ? attachments : null,
              ),
            ),
          ),
        ),
      ),
    );
  }

  String? _nameFor(Message? resolved, AuthorResolution? resolution) {
    if (resolved == null) return null;
    return authorLabelResolved(
      authorId: resolved.authorId,
      cachedDisplayName: resolved.authorDisplayName,
      resolution: resolution!,
    );
  }

  Widget _quoteRow(
    AppTokens tokens, {
    required Message? resolved,
    required String? label,
    required String? name,
    required String snippet,
    required api.UserProfile? profile,
    required List<api.Attachment>? thumb,
  }) {
    final snippetStyle = AppText.caption.copyWith(
      color: tokens.textSecondary,
      fontStyle: resolved == null ? FontStyle.italic : null,
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (resolved == null)
          const _UnavailableMark()
        else
          // The label above already names this author.
          ExcludeSemantics(
            key: avatarKey,
            child: UserAvatar(
              userId: resolved.authorId,
              name: name!,
              size: AppAvatarSize.s16,
            ),
          ),
        const SizedBox(width: AppSpacing.s4),
        if (label == null)
          // A long snippet alone would overflow the row otherwise.
          Flexible(
            child: Text(
              snippet,
              style: snippetStyle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          )
        else
          Flexible(
            child: AuthorNameLine(
              name: label,
              profile: profile,
              style: snippetStyle.copyWith(
                color: tokens.textPrimary,
                fontWeight: AppWeights.semi,
              ),
              secondary: snippet,
              secondaryStyle: snippetStyle,
              secondaryLeading: thumb == null
                  ? null
                  : ReplyAttachmentThumb(
                      attachments: thumb,
                      edge: AppAvatarSize.s16,
                    ),
            ),
          ),
      ],
    );
  }
}

/// Stands where the parent's avatar would, for a parent there is nobody to
/// draw for.
class _UnavailableMark extends StatelessWidget {
  const _UnavailableMark();

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return SizedBox.square(
      dimension: AppAvatarSize.s16,
      child: Icon(
        AppIcons.reply,
        size: AppSizes.icon12,
        color: tokens.textSecondary,
      ),
    );
  }
}
