// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A bot's profile section: its prefix and registered commands, so someone
/// can learn a bot without being told. See
/// docs/decisions/0031-bot-command-registration.md.
///
/// Collapsed to [_collapsedShown] rows by default and expandable to every
/// command on tap - reported directly by the owner: "the bot bio should be
/// more compact by default and allowed to expand." A bot with even a modest
/// command set used to run this section, and the whole card with it, to
/// nearly the window's full height.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/bot_commands.dart';

/// Rows shown before collapsing into a "Show N more" toggle.
const int _collapsedShown = 3;

class MemberProfileBotCommands extends ConsumerStatefulWidget {
  const MemberProfileBotCommands({super.key, required this.botId});

  final String botId;

  @override
  ConsumerState<MemberProfileBotCommands> createState() =>
      _MemberProfileBotCommandsState();
}

class _MemberProfileBotCommandsState
    extends ConsumerState<MemberProfileBotCommands> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final registration = ref
        .watch(botCommandRegistrationProvider(widget.botId))
        .valueOrNull;
    final commands = registration?.commands ?? const [];
    if (registration?.prefix == null || commands.isEmpty) {
      return const SizedBox.shrink();
    }
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final collapsible = commands.length > _collapsedShown;
    final shown = _expanded || !collapsible
        ? commands
        : commands.take(_collapsedShown).toList(growable: false);
    final hidden = commands.length - shown.length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s12,
        0,
        AppSpacing.s12,
        AppSpacing.s12,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Commands - answers to ${registration!.prefix}',
            style: AppText.label.copyWith(color: tokens.textSecondary),
          ),
          const SizedBox(height: AppSpacing.s4),
          for (final command in shown)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.s4),
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: '${registration.prefix}${command.name} ',
                      style: AppText.code.copyWith(color: tokens.textPrimary),
                    ),
                    TextSpan(
                      text: command.description,
                      style: AppText.caption.copyWith(
                        color: tokens.textSecondary,
                      ),
                    ),
                  ],
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          if (collapsible)
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: AppTouchTargets.of(context)
                      ? AppSizes.rowTouch
                      : 0,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  widthFactor: 1,
                  child: Text(
                    _expanded ? 'Show less' : 'Show $hidden more',
                    style: AppText.caption.copyWith(color: tokens.accent),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
