// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The palette's result list: its sections in order, the keyboard
/// highlight, and what shows when a search found nothing or failed.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../emoji/providers/emoji_catalog_provider.dart';
import '../../members/providers/known_mention_names.dart';
import '../../members/providers/member_presence.dart' show membersProvider;
import 'command_palette_items.dart';
import 'command_palette_rows.dart';
import 'palette_reveal.dart';

/// One titled run of rows; [count] is what its header shows, when not the row count.
typedef PaletteSection = ({
  String label,
  List<PaletteResultItem> items,
  int? count,
});

/// How the message search stands, for what the list says besides its rows.
typedef PaletteSearchNotice = ({
  bool forbidden,
  bool failed,
  VoidCallback? retry,
  String announcement,
});

class PaletteResultsList extends ConsumerWidget {
  const PaletteResultsList({
    super.key,
    required this.sections,
    required this.highlighted,
    required this.query,
    required this.compact,
    required this.maxHeight,
    required this.onRun,
    required this.notice,
  });

  final List<PaletteSection> sections;
  final int highlighted;

  /// The free text, which rows mark where it matched.
  final String query;
  final bool compact;
  final double maxHeight;
  final ValueChanged<PaletteResultItem> onRun;
  final PaletteSearchNotice notice;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    // A hit's mentions and custom emoji resolve as they do in the transcript.
    final lookups = (
      usernames: ref.watch(membersProvider.select(knownUsernamesFrom)),
      roles: ref.watch(membersProvider.select(knownRoleNamesFrom)),
      emoji: ref.watch(customEmojiIndexProvider),
    );
    final empty = sections.isEmpty && !notice.forbidden;
    final Widget body;
    if (empty && notice.failed) {
      body = Padding(
        padding: const EdgeInsets.all(AppSpacing.s8),
        child: AppErrorState(message: 'Search failed.', onRetry: notice.retry),
      );
    } else if (empty) {
      body = Padding(
        padding: const EdgeInsets.all(AppSpacing.s16),
        child: Text(
          'No matches.',
          style: AppText.body.copyWith(color: tokens.textSecondary),
        ),
      );
    } else {
      body = ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ..._rows(lookups),
              if (notice.forbidden) ..._forbidden(tokens),
              if (notice.failed && !empty)
                AppErrorState(message: 'Search failed.', onRetry: notice.retry),
            ],
          ),
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Invisible: the one place a screen reader hears how a search came out.
        Semantics(
          liveRegion: true,
          label: notice.announcement,
          child: const SizedBox.shrink(),
        ),
        body,
      ],
    );
  }

  List<Widget> _rows(
    ({Set<String> usernames, Set<String> roles, Map<String, String> emoji})
    lookups,
  ) {
    final rows = <Widget>[];
    var index = 0;
    for (final section in sections) {
      final header = PaletteSectionHeader(
        label: section.label,
        count:
            section.count ??
            section.items.last.showsAllOf ??
            section.items.length,
      );
      for (final (i, item) in section.items.indexed) {
        final at = index++;
        rows.add(
          PaletteReveal(
            active: at == highlighted,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (i == 0) header,
                PaletteResultRow(
                  item: item,
                  query: query,
                  highlighted: at == highlighted,
                  touch: compact,
                  onTap: () => onRun(item),
                  knownUsernames: lookups.usernames,
                  knownRoleNames: lookups.roles,
                  customEmoji: lookups.emoji,
                ),
              ],
            ),
          ),
        );
      }
    }
    return rows;
  }

  List<Widget> _forbidden(AppTokens tokens) => [
    const PaletteSectionHeader(label: 'Messages', count: 0),
    Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s16,
        vertical: AppSpacing.s8,
      ),
      child: Text(
        'You do not have permission to search this channel.',
        style: AppText.micro.copyWith(color: tokens.textSecondary),
      ),
    ),
  ];
}
