// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A bot's private answer, drawn in the transcript as a bot's message row
/// with a tint and an "Only you can see this" line. See
/// docs/decisions/0037-ephemeral-bot-messages.md.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../routing/breakpoints.dart';
import 'attachment_gallery.dart';
import 'embed_card.dart';
import 'message_row_identity.dart';
import 'message_text.dart';

const String ephemeralNotice = 'Only you can see this';

class EphemeralRow extends StatelessWidget {
  const EphemeralRow({
    super.key,
    required this.message,
    required this.knownUsernames,
    required this.knownRoleNames,
    required this.customEmoji,
    required this.onDismiss,
    required this.onReport,
  });

  final api.EphemeralMessage message;
  final Set<String> knownUsernames;
  final Set<String> knownRoleNames;
  final Map<String, String> customEmoji;
  final VoidCallback onDismiss;
  final VoidCallback onReport;

  /// The row widgets read a stored message; this one is never stored.
  Message get _asMessage => Message(
    id: message.id,
    channelId: message.channelId,
    authorId: message.authorId,
    authorDisplayName: message.authorDisplayName,
    seq: 0,
    content: message.content,
    createdAt: message.createdAt,
    pending: false,
    failed: false,
  );

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final asMessage = _asMessage;
    final gutter = paneGutterOf(context);
    return Semantics(
      container: true,
      label: ephemeralNotice,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tokens.surfaceSunken,
          border: Border(
            left: BorderSide(color: tokens.borderStrong, width: 2),
          ),
        ),
        child: _RowLayout(
          gutter: gutter,
          leading: MessageRowLeading(
            grouped: false,
            message: asMessage,
            hovered: false,
          ),
          children: [
            MessageRowHeader(message: asMessage, assumeBot: true),
            if (message.content.isNotEmpty)
              MessageBody(
                content: message.content,
                messageId: message.id,
                knownUsernames: knownUsernames,
                knownRoleNames: knownRoleNames,
                customEmoji: customEmoji,
              ),
            EmbedList(embeds: message.embeds),
            if (message.attachments.isNotEmpty)
              MessageAttachments(attachments: message.attachments),
            _Footer(onDismiss: onDismiss, onReport: onReport),
          ],
        ),
      ),
    );
  }
}

class _RowLayout extends StatelessWidget {
  const _RowLayout({
    required this.gutter,
    required this.leading,
    required this.children,
  });

  final double gutter;
  final Widget leading;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(gutter, AppSpacing.s8, gutter, AppSpacing.s8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        leading,
        const SizedBox(width: AppSpacing.s12),
        Expanded(
          child: Align(
            alignment: Alignment.topLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: kMessageColumnMax),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: children,
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class _Footer extends StatelessWidget {
  const _Footer({required this.onDismiss, required this.onReport});

  final VoidCallback onDismiss;
  final VoidCallback onReport;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final caption = AppText.caption.copyWith(color: tokens.textSecondary);
    final dot = ExcludeSemantics(child: Text('\u00B7', style: caption));
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.s4),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: AppSpacing.s8,
        runSpacing: AppSpacing.s4,
        children: [
          ExcludeSemantics(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: AppSpacing.s4,
              children: [
                Icon(
                  AppIcons.privateReply,
                  size: AppSizes.icon16,
                  color: tokens.textSecondary,
                ),
                Text(ephemeralNotice, style: caption),
              ],
            ),
          ),
          dot,
          _FooterLink(label: 'Dismiss', onTap: onDismiss),
          dot,
          _FooterLink(label: 'Report', onTap: onReport),
        ],
      ),
    );
  }
}

/// A text action sized to the notice beside it; a ghost button there sat taller
/// than the caption and wrapped onto a line of its own.
class _FooterLink extends StatelessWidget {
  const _FooterLink({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.s4),
            child: SelectionContainer.disabled(
              child: Text(
                label,
                style: AppText.caption.copyWith(
                  color: tokens.textPrimary,
                  fontWeight: AppWeights.medium,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
