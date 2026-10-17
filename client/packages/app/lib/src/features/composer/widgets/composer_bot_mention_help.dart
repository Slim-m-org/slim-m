// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A mentioner-only card naming an `@mentioned` bot's prefix and commands,
/// built client-side from data the composer already has. See
/// docs/decisions/0031-bot-command-registration.md.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

/// Rows beyond this collapse into a "+N more" line, matching the profile
/// section's own cap.
const int _maxShown = 6;

class ComposerBotMentionHelp extends StatelessWidget {
  const ComposerBotMentionHelp({
    super.key,
    required this.commands,
    required this.onDismiss,
  });

  /// One bot's own rows from the channel's discovery list - all sharing the
  /// same [api.ChannelBotCommand.botDisplayName]/`prefix`. Never empty: the
  /// caller only builds this widget for a bot that has something to show.
  final List<api.ChannelBotCommand> commands;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final first = commands.first;
    final shown = commands.take(_maxShown).toList(growable: false);

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s8),
      child: AppCallout(
        tone: AppCalloutTone.info,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${first.botDisplayName} answers to "${first.prefix}" - '
                    'only you can see this',
                    style: AppText.caption.copyWith(
                      color: tokens.textSecondary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                InkWell(
                  onTap: onDismiss,
                  child: Icon(
                    AppIcons.dismiss,
                    size: AppSizes.icon16,
                    color: tokens.textSecondary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.s4),
            for (final command in shown)
              Text(
                '${command.prefix}${command.name} - ${command.description}',
                overflow: TextOverflow.ellipsis,
                style: AppText.caption.copyWith(color: tokens.textSecondary),
              ),
            if (commands.length > _maxShown)
              Text(
                '+${commands.length - _maxShown} more',
                style: AppText.caption.copyWith(color: tokens.textSecondary),
              ),
          ],
        ),
      ),
    );
  }
}

/// One [ComposerBotMentionHelp] per currently-visible username, each fed only
/// its own rows out of [allBotCommands] - the composer's own list stays the
/// single source, so this never re-fetches anything.
class ComposerBotMentionHelpList extends StatelessWidget {
  const ComposerBotMentionHelpList({
    super.key,
    required this.visibleUsernames,
    required this.allBotCommands,
    required this.onDismiss,
  });

  final List<String> visibleUsernames;
  final List<api.ChannelBotCommand> allBotCommands;
  final ValueChanged<String> onDismiss;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final username in visibleUsernames)
        if (allBotCommands.where((c) => c.botUsername == username).toList()
            case final rows when rows.isNotEmpty)
          ComposerBotMentionHelp(
            commands: rows,
            onDismiss: () => onDismiss(username),
          ),
    ],
  );
}
