// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The rail as one role sees it: the categories and channels the server's preview lists, in the
/// real rail's order, with no menus, unread state or drag. Tapping a channel opens its summary.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart' show ChannelCategoryRow;
import 'package:slimm_design_system/design_system.dart';

import '../../channels/widgets/category_tree.dart';
import '../../channels/widgets/channel_kind_icon.dart';
import '../../channels/widgets/channel_rail_reorder.dart' show kRailRowInset;
import '../../channels/widgets/channel_rail_section_label.dart';

class RolePreviewRail extends StatelessWidget {
  const RolePreviewRail({
    super.key,
    required this.preview,
    required this.selectedId,
    required this.onOpen,
  });

  final api.RolePreview preview;
  final String? selectedId;
  final ValueChanged<String> onOpen;

  /// Says the role sees nothing, in place of an empty list.
  static const emptyMessage = 'This role cannot see any channels.';

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    if (preview.channels.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(AppSpacing.s16),
        child: Text(
          emptyMessage,
          style: AppText.ui.copyWith(color: tokens.textSecondary),
        ),
      );
    }
    final tree = CategoryTree([
      for (final c in preview.categories)
        ChannelCategoryRow(
          id: c.id,
          name: c.name,
          position: c.position,
          parentId: c.parentId,
        ),
    ]);
    final byCategory = <String?, List<api.RolePreviewChannel>>{};
    for (final channel in [
      ...preview.channels,
    ]..sort((a, b) => a.position.compareTo(b.position))) {
      (byCategory[channel.categoryId] ??= []).add(channel);
    }
    final uncategorised = byCategory[null] ?? const <api.RolePreviewChannel>[];
    return ListView(
      padding: const EdgeInsets.only(bottom: AppSpacing.s16),
      children: [
        if (uncategorised.isNotEmpty) ...[
          const SectionLabel('Channels'),
          for (final channel in uncategorised) _row(channel, 0),
        ],
        for (final category in tree.ordered) ...[
          Padding(
            padding: EdgeInsets.only(
              left: kRailRowInset * tree.depthOf(category),
            ),
            child: SectionLabel(category.name),
          ),
          for (final channel
              in byCategory[category.id] ?? const <api.RolePreviewChannel>[])
            _row(channel, tree.depthOf(category)),
        ],
      ],
    );
  }

  Widget _row(api.RolePreviewChannel channel, int depth) {
    final selected = channel.id == selectedId;
    return Padding(
      padding: EdgeInsets.only(left: kRailRowInset * (1 + depth)),
      child: Builder(
        builder: (context) {
          final tokens = Theme.of(context).extension<AppTokens>()!;
          return AppListRow(
            key: ValueKey('role-preview-channel-${channel.id}'),
            label: channel.name,
            selected: selected,
            leading: ChannelKindIcon(
              isVoice: channel.isVoice,
              restricted: channel.restricted,
              color: selected ? tokens.accent : tokens.textSecondary,
            ),
            onTap: () => onOpen(channel.id),
          );
        },
      ),
    );
  }
}
