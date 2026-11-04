// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Channel permissions: one grid per channel, replacing the old "pick a
/// target, set its allow/inherit/deny one permission at a time" screen.
/// Columns are the principals with (or being given) an overwrite; rows are
/// every permission, grouped. See `channel_permissions_grid.dart` for the
/// grid itself.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_data/data.dart' show Channel;

import '../../../../routing/routes.dart';
import '../../providers/channel_permissions_selection.dart';
import '../settings_screen_scaffold.dart';
import '../../widgets/admin/channel_permissions_grid.dart';
import '../../widgets/admin/channel_permissions_list.dart';

class ChannelPermissionsScreen extends StatelessWidget {
  const ChannelPermissionsScreen({super.key, this.initialChannel});

  /// Pre-selects a channel when opened from that channel's own context menu,
  /// skipping the picker; null when reached from Space settings.
  final Channel? initialChannel;

  @override
  Widget build(BuildContext context) => ProviderScope(
    overrides: [
      channelPermissionsSelectionProvider.overrideWith((ref) => initialChannel),
    ],
    child: _ChannelPermissionsFrame(opensOnList: initialChannel == null),
  );
}

class _ChannelPermissionsFrame extends ConsumerWidget {
  const _ChannelPermissionsFrame({required this.opensOnList});

  final bool opensOnList;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inChannel =
        opensOnList && ref.watch(channelPermissionsSelectionProvider) != null;
    return SettingsScreenScaffold(
      title: 'Channel permissions',
      backTooltip: inChannel ? 'Back to channels' : 'Back to Space settings',
      backFallback: Routes.spaceSettings,
      onBack: inChannel
          ? () => ref.read(channelPermissionsSelectionProvider.notifier).state =
                null
          : null,
      scrollable: false,
      child: const ChannelPermissionsPane(),
    );
  }
}

/// The picker-and-grid pane itself, embeddable as a Space settings pane as
/// well as routed.
class ChannelPermissionsPane extends ConsumerStatefulWidget {
  const ChannelPermissionsPane({
    super.key,
    this.initialChannel,
    this.lockChannel = false,
  }) : assert(
         !lockChannel || initialChannel != null,
         'lockChannel requires an initialChannel',
       );

  /// Only read when [lockChannel]; otherwise the selection provider decides.
  final Channel? initialChannel;

  /// True when embedded in a specific channel's own settings, where the
  /// channel is fixed by context; false (the default) keeps the picker for
  /// the Space settings entry point.
  final bool lockChannel;

  @override
  ConsumerState<ChannelPermissionsPane> createState() =>
      _ChannelPermissionsPaneState();
}

class _ChannelPermissionsPaneState
    extends ConsumerState<ChannelPermissionsPane> {
  @override
  Widget build(BuildContext context) {
    final channel = widget.lockChannel
        ? widget.initialChannel
        : ref.watch(channelPermissionsSelectionProvider);
    if (channel == null) {
      return ChannelPermissionsList(
        onPick: (picked) =>
            ref.read(channelPermissionsSelectionProvider.notifier).state =
                picked,
      );
    }

    final grid = ChannelPermissionsGrid(
      key: ValueKey(channel.id),
      channel: channel,
    );

    // A Column never tells a plain (non-Expanded) child how much height it actually has, so a genuinely bounded ambient (the modal panel, a phone screen) still reached the grid's own MediaQuery-based guess and overflowed a shorter modal; see channel_permissions_grid.dart's own LayoutBuilder for that guess. Expanded restores the real number here, and only here, where this LayoutBuilder can see the ambient is actually bounded; the Space settings pane's own scrolling embed stays unbounded and keeps the guess.
    return LayoutBuilder(
      builder: (context, constraints) =>
          constraints.hasBoundedHeight ? SizedBox.expand(child: grid) : grid,
    );
  }
}
