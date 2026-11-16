// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one affordance that starts or opens a DM's call.
///
/// Self-gated on the channel's own kind rather than a caller-supplied flag,
/// the same shape `CanvasOpenButton` could have used: a header that always
/// includes this renders nothing for a text or voice channel, or for a
/// personal space, where calling yourself is not a call.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/header_icon_action.dart';
import '../../channels/providers/channel_by_id_provider.dart';
import '../providers/dm_call_start.dart';
import '../screens/dm_call_pane.dart';

class DmCallButton extends ConsumerWidget {
  const DmCallButton({super.key, required this.channelId});

  final String channelId;

  /// For a header that leaves an absent button out rather than spacing around it.
  static bool shows({required bool isDm, required bool isPersonalSpace}) =>
      isDm && !isPersonalSpace;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final channel = ref.watch(channelByIdProvider(channelId)).valueOrNull;
    if (channel == null ||
        !shows(
          isDm: channel.kind == 'dm',
          isPersonalSpace: channel.isPersonalSpace,
        )) {
      return const SizedBox.shrink();
    }
    final open = ref.watch(dmCallOpenProvider) == channelId;
    return HeaderIconAction(
      icon: AppIcons.startCall,
      label: 'Call',
      active: open,
      onPressed: () => _toggle(ref, open),
    );
  }

  /// Closing only ever hides the pane - a call already joined keeps running,
  /// see `dm_call_pane.dart`'s own doc - so only opening can ever be the
  /// start of something to ring about, and only when nothing is already
  /// connected (or connecting) here: reopening the pane on an ongoing call
  /// must not ring a second time.
  void _toggle(WidgetRef ref, bool open) {
    if (open) {
      ref.read(dmCallOpenProvider.notifier).state = null;
      return;
    }
    startDmCall(ref.read, channelId);
  }
}
