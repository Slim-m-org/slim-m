// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Every channel under its category, one compact row each, so picking one to
/// edit is a single tap. A DM carries no overwrites and is left out.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../../providers/providers.dart';
import '../../../channels/providers/dms.dart' show dmChannelKind;
import '../../../channels/widgets/channel_grouping.dart';
import '../../../channels/widgets/channel_kind_icon.dart';

const double _rowHeight = 34;

class ChannelPermissionsList extends ConsumerWidget {
  const ChannelPermissionsList({super.key, required this.onPick});

  final ValueChanged<Channel> onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.watch(storeProvider).valueOrNull;
    if (store == null) return const SizedBox.shrink();
    return StreamBuilder<List<ChannelCategoryRow>>(
      stream: store.watchCategories(),
      builder: (context, categories) => StreamBuilder<List<Channel>>(
        stream: store.watchChannels(),
        builder: (context, channels) {
          final groups = _groups([
            for (final c in channels.data ?? const <Channel>[])
              if (c.kind != dmChannelKind && c.parentMessageId == null) c,
          ], categories.data ?? const []);
          final body = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final g in groups)
                _Group(
                  title: groups.length > 1 ? g.title : null,
                  group: g,
                  onPick: onPick,
                ),
            ],
          );
          // The routed screen gives a bounded height; the Space settings pane already scrolls.
          return LayoutBuilder(
            builder: (context, constraints) => constraints.hasBoundedHeight
                ? SingleChildScrollView(child: body)
                : body,
          );
        },
      ),
    );
  }

  static List<_ChannelGroup> _groups(
    List<Channel> channels,
    List<ChannelCategoryRow> categories,
  ) {
    final byCategory = channelsByCategory(channels);
    return [
      if (byCategory[null] case final loose?) _ChannelGroup('Channels', loose),
      for (final category in categories)
        if (byCategory[category.id] case final inside?)
          _ChannelGroup(category.name, inside),
    ];
  }
}

class _ChannelGroup {
  const _ChannelGroup(this.title, this.channels);

  final String title;
  final List<Channel> channels;
}

class _Group extends StatelessWidget {
  const _Group({
    required this.title,
    required this.group,
    required this.onPick,
  });

  final String? title;
  final _ChannelGroup group;
  final ValueChanged<Channel> onPick;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final radius = BorderRadius.circular(AppRadii.card);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s4,
              AppSpacing.s16,
              AppSpacing.s4,
              AppSpacing.s8,
            ),
            child: Semantics(
              header: true,
              child: Text(
                title!,
                style: AppText.caption.copyWith(
                  color: tokens.textSecondary,
                  fontWeight: AppWeights.semi,
                ),
              ),
            ),
          )
        else
          const SizedBox(height: AppSpacing.s12),
        DecoratedBox(
          decoration: BoxDecoration(
            color: tokens.surfaceRaised,
            border: Border.all(color: tokens.borderSubtle),
            borderRadius: radius,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadii.card - 1),
            child: Material(
              type: MaterialType.transparency,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.s8,
                  vertical: AppSpacing.s4,
                ),
                child: Column(
                  children: [
                    for (final c in group.channels)
                      _ChannelPickRow(channel: c, onPick: onPick),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ChannelPickRow extends StatelessWidget {
  const _ChannelPickRow({required this.channel, required this.onPick});

  final Channel channel;
  final ValueChanged<Channel> onPick;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return AppListRow(
      key: ValueKey('perm-channel-${channel.id}'),
      leading: ChannelKindIcon(
        isVoice: channel.kind == 'voice',
        restricted: channel.restricted ?? false,
        color: tokens.textSecondary,
      ),
      label: channel.name,
      height: _rowHeight,
      onTap: () => onPick(channel),
    );
  }
}
