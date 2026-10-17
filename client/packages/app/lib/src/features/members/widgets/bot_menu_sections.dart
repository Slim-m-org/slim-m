// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The rows bots add to a message's context menu, kept in sections of their
/// own so a bot's entry can never pass for one of the app's. See
/// docs/decisions/0045-bot-contributed-ui.md.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

/// Most bot rows one menu shows in all. The server caps a bot at 5, so this
/// only bites when several bots each add some.
const int kMaxBotMenuEntries = 10;

class BotMenuEntry {
  const BotMenuEntry({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;
}

/// One bot's rows under its own name.
class BotMenuSection {
  const BotMenuSection({required this.botName, required this.entries});

  final String botName;
  final List<BotMenuEntry> entries;
}

/// Turns what the channel's bots registered into sections, keeping at most
/// [kMaxBotMenuEntries] rows in all and dropping a bot left with none.
List<BotMenuSection> botMenuSections(
  List<api.ChannelBotUi> bots, {
  required void Function(api.ChannelBotUi bot, api.BotUiEntry entry) onUse,
}) {
  final sections = <BotMenuSection>[];
  var room = kMaxBotMenuEntries;
  for (final bot in bots) {
    if (room <= 0) break;
    final entries = [
      for (final entry in bot.messageMenu.take(room))
        BotMenuEntry(label: entry.label, onTap: () => onUse(bot, entry)),
    ];
    if (entries.isEmpty) continue;
    room -= entries.length;
    sections.add(BotMenuSection(botName: bot.botDisplayName, entries: entries));
  }
  return sections;
}

/// The divider, the header naming the bot, and its rows. [close] runs before
/// an entry does, like every other row in the menu.
List<Widget> botMenuItems(List<BotMenuSection> sections, VoidCallback close) =>
    [
      for (final section in sections) ...[
        const AppMenuDivider(),
        _BotSectionHeader(name: section.botName),
        for (final entry in section.entries)
          AppMenuItem(
            label: entry.label,
            leading: AppIcons.botAction,
            onTap: () {
              close();
              entry.onTap();
            },
          ),
      ],
    ];

class _BotSectionHeader extends StatelessWidget {
  const _BotSectionHeader({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Semantics(
      header: true,
      label: '$name, a bot',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
        child: Row(
          children: [
            Flexible(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.label.copyWith(color: tokens.textSecondary),
              ),
            ),
            const SizedBox(width: AppSpacing.s8),
            const AppBadge(variant: AppBadgeVariant.tag, label: 'Bot'),
          ],
        ),
      ),
    );
  }
}
