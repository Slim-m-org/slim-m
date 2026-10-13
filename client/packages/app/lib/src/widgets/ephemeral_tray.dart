// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A bot's private answers, stacked above the composer until dismissed.
///
/// Above the composer rather than inside the transcript: a private answer has
/// no `seq`, so it has no place in a list ordered by one, and a tray stays in
/// view when the reader is scrolled back in history. See
/// docs/decisions/0037-ephemeral-bot-messages.md.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../providers/ephemeral_messages.dart';
import 'attachment_gallery.dart';
import 'embed_card.dart';
import 'ephemeral_report.dart';

/// Tall enough for a few lines; a long answer scrolls inside its own card.
const double _maxBodyHeight = 96;

/// Room for an embed or a file, which a line of text never needs.
const double _maxRichBodyHeight = 240;

class EphemeralTray extends ConsumerWidget {
  const EphemeralTray({super.key, required this.channelId});

  final String channelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final messages = ref.watch(channelEphemeralMessagesProvider(channelId));
    return AppRevealBand(
      child: messages.isEmpty
          ? null
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final message in messages)
                  EphemeralMessageCard(
                    key: ValueKey(message.id),
                    message: message,
                    onReport: () =>
                        unawaited(reportEphemeralMessage(context, message)),
                    onDismiss: () => ref
                        .read(ephemeralMessagesProvider.notifier)
                        .dismiss(channelId, message.id),
                  ),
              ],
            ),
    );
  }
}

class EphemeralMessageCard extends StatelessWidget {
  const EphemeralMessageCard({
    super.key,
    required this.message,
    required this.onDismiss,
    required this.onReport,
  });

  final api.EphemeralMessage message;
  final VoidCallback onDismiss;
  final VoidCallback onReport;

  bool get _hasRichContent =>
      message.embeds.isNotEmpty || message.attachments.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s8,
        AppSpacing.s8,
        AppSpacing.s8,
        AppSpacing.s4,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tokens.surfaceSunken,
          borderRadius: BorderRadius.circular(AppRadii.control),
          border: Border.all(color: tokens.borderSubtle),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.s12,
            AppSpacing.s4,
            AppSpacing.s4,
            AppSpacing.s8,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    AppIcons.privateReply,
                    size: AppSizes.icon16,
                    color: tokens.textSecondary,
                  ),
                  const SizedBox(width: AppSpacing.s8),
                  Expanded(
                    child: Row(
                      children: [
                        Text(
                          'Only you can see this',
                          maxLines: 1,
                          style: AppText.caption.copyWith(
                            color: tokens.textPrimary,
                            fontWeight: AppWeights.semi,
                          ),
                        ),
                        const SizedBox(width: AppSpacing.s8),
                        Flexible(
                          child: Text(
                            'from ${message.authorDisplayName}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.caption.copyWith(
                              color: tokens.textSecondary,
                            ),
                          ),
                        ),
                        // Fixed size beside a name that ellipsizes: a bot may call itself "System".
                        const SizedBox(width: AppSpacing.s4),
                        const AppBadge(
                          variant: AppBadgeVariant.tag,
                          label: 'Bot',
                        ),
                      ],
                    ),
                  ),
                  AppIconButton(
                    icon: AppIcons.report,
                    semanticLabel: 'Report private message',
                    tooltip: 'Report',
                    size: AppIconButtonSize.sm,
                    onPressed: onReport,
                  ),
                  AppIconButton(
                    icon: AppIcons.dismiss,
                    semanticLabel: 'Dismiss private message',
                    tooltip: 'Dismiss',
                    size: AppIconButtonSize.sm,
                    onPressed: onDismiss,
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(right: AppSpacing.s8),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: _hasRichContent
                        ? _maxRichBodyHeight
                        : _maxBodyHeight,
                  ),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (message.content.isNotEmpty)
                          SelectableText(
                            message.content,
                            style: AppText.ui.copyWith(
                              color: tokens.textPrimary,
                            ),
                          ),
                        EmbedList(embeds: message.embeds),
                        if (message.attachments.isNotEmpty)
                          MessageAttachments(attachments: message.attachments),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
