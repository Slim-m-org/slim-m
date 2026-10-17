// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one affordance that starts or opens a DM's call.
///
/// Self-gated on the channel's own kind rather than a caller-supplied flag,
/// the same shape `CanvasOpenButton` could have used: a header that always
/// includes this renders nothing for a text or voice channel, or for a
/// personal space, where calling yourself is not a call.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../features/channels/providers/channel_by_id_provider.dart';
import '../providers/dm_call_ring_controller.dart';
import '../providers/voice_controller.dart';
import 'dm_call_pane.dart';

class DmCallButton extends ConsumerWidget {
  const DmCallButton({super.key, required this.channelId});

  final String channelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final channel = ref.watch(channelByIdProvider(channelId)).valueOrNull;
    if (channel == null || channel.kind != 'dm' || channel.isPersonalSpace) {
      return const SizedBox.shrink();
    }
    final open = ref.watch(dmCallOpenProvider) == channelId;
    return AppIconButton(
      icon: AppIcons.startCall,
      semanticLabel: 'Call',
      tooltip: 'Call',
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
    final startingFresh =
        ref.read(voiceControllerProvider).channelId != channelId;
    ref.read(dmCallOpenProvider.notifier).state = channelId;
    if (startingFresh) {
      unawaited(
        ref
            .read(dmCallRingControllerProvider.notifier)
            .startOutgoingRing(channelId),
      );
    }
  }
}
