// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call control that opens the soundboard.
///
/// Desktop-vs-mobile rule 3, a thing with actions the user just pointed at:
/// [ContextMenuRegion] anchors a popover above the button on a wide layout
/// and presents the same rows as a bottom sheet on a compact one.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../permissions.dart';
import '../../../widgets/context_menu_region.dart';
import '../../channels/providers/channel_permissions.dart';
import 'call_dock_button.dart';
import 'soundboard_picker.dart';

/// Whether this member may play clips in [channelId]'s call.
bool canUseSoundboard(WidgetRef ref, String? channelId) =>
    channelId != null &&
    ref
        .watch(myChannelPermissionsProvider(channelId))
        .hasPermission(Perm.useSoundboard);

class SoundboardButton extends StatefulWidget {
  const SoundboardButton({super.key, required this.channelId});

  final String channelId;

  @override
  State<SoundboardButton> createState() => _SoundboardButtonState();
}

class _SoundboardButtonState extends State<SoundboardButton> {
  final _region = GlobalKey<ContextMenuRegionState>();

  /// Lets the button count as inside the open menu's tap region, so a second press closes it.
  final _group = Object();

  @override
  Widget build(BuildContext context) => ContextMenuRegion(
    key: _region,
    ownsFocusNode: false,
    enableLongPress: false,
    opensAbove: true,
    menuWidth: 280,
    tapRegionGroupId: _group,
    itemsBuilder: (context, close) => [
      const AppMenuLabel('Soundboard'),
      SoundboardPicker(channelId: widget.channelId),
    ],
    child: TapRegion(
      groupId: _group,
      child: CallDockButton(
        icon: AppIcons.music,
        tooltip: 'Soundboard',
        active: false,
        onPressed: () => _region.currentState?.toggle(),
      ),
    ),
  );
}
