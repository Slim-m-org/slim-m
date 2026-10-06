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
import 'package:slimm_design_system/design_system.dart';

import '../../providers/providers.dart';
import '../../routing/routes.dart';
import '../settings_screen_scaffold.dart';
import 'channel_permissions_grid.dart';
import 'overwrite_target_picker_sheets.dart';

class ChannelPermissionsScreen extends StatelessWidget {
  const ChannelPermissionsScreen({super.key, this.initialChannel});

  /// Pre-selects a channel when opened from that channel's own context menu,
  /// skipping the picker; null when reached from Space settings.
  final Channel? initialChannel;

  @override
  Widget build(BuildContext context) => SettingsScreenScaffold(
    title: 'Channel permissions',
    backTooltip: 'Back to Space settings',
    backFallback: Routes.spaceSettings,
    scrollable: false,
    child: ChannelPermissionsPane(initialChannel: initialChannel),
  );
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
  Channel? _channel;

  @override
  void initState() {
    super.initState();
    _channel = widget.initialChannel;
  }

  Future<void> _pickChannel() async {
    final store = await ref.read(storeProvider.future);
    final channels = await store.watchChannels().first;
    if (!mounted) return;
    final picked = await showAppSheet<Channel>(
      context,
      builder: (context) => ChannelPickerSheet(channels: channels),
    );
    if (picked == null || !mounted) return;
    setState(() => _channel = picked);
  }

  @override
  Widget build(BuildContext context) {
    final channel = _channel;
    if (channel == null) {
      return Padding(
        padding: const EdgeInsets.all(AppSpacing.s16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppListRow(
              label: 'Choose a channel',
              trailing: const Icon(
                AppIcons.chevronRight,
                size: AppSizes.icon16,
              ),
              onTap: _pickChannel,
            ),
          ],
        ),
      );
    }

    final header = widget.lockChannel
        ? null
        : Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s16,
              AppSpacing.s12,
              AppSpacing.s16,
              AppSpacing.s4,
            ),
            child: Row(
              children: [
                Icon(
                  channel.kind == 'voice' ? AppIcons.voice : AppIcons.hash,
                  size: AppSizes.icon16,
                ),
                const SizedBox(width: AppSpacing.s8),
                Expanded(
                  child: Text(
                    '${channel.name} · Permissions',
                    style: AppText.heading,
                  ),
                ),
                TextButton(
                  onPressed: _pickChannel,
                  child: const Text('Change'),
                ),
              ],
            ),
          );
    final grid = ChannelPermissionsGrid(
      key: ValueKey(channel.id),
      channel: channel,
    );

    // A Column never tells a plain (non-Expanded) child how much height it actually has, so a genuinely bounded ambient (the modal panel, a phone screen) still reached the grid's own MediaQuery-based guess and overflowed a shorter modal; see channel_permissions_grid.dart's own LayoutBuilder for that guess. Expanded restores the real number here, and only here, where this LayoutBuilder can see the ambient is actually bounded; the Space settings pane's own scrolling embed stays unbounded and keeps the guess.
    return LayoutBuilder(
      builder: (context, constraints) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (header != null) header,
          constraints.hasBoundedHeight ? Expanded(child: grid) : grid,
        ],
      ),
    );
  }
}
