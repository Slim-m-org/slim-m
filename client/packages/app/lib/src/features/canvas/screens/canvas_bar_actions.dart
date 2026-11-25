// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The canvas bar's pointer-width actions, left to right: who is here, the chat, Join call, the member list.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../members/widgets/member_list_toggle.dart';
import '../widgets/canvas_join_call.dart';
import '../providers/canvas_open.dart';
import 'canvas_chat_toggle.dart';
import 'canvas_people_cluster.dart';

class CanvasBarActions extends ConsumerWidget {
  const CanvasBarActions({
    super.key,
    required this.channelId,
    required this.isDm,
  });

  final String channelId;

  /// A DM's own conversation holds its text and its roster, so neither toggle shows.
  final bool isDm;

  /// The list yields to a docked chat, so the toggle reads off then and a press swaps the chat out for it.
  Widget _membersToggle(BuildContext context, WidgetRef ref) {
    final yielded =
        canvasChatDocks(context) &&
        ref.watch(canvasChatFlaggedOpenProvider(channelId));
    final chatOpen = canvasChatOpenProviderFor(
      channelId,
      isCanvasChannel: ref.watch(canvasIsChannelProvider(channelId)),
    );
    return MemberListToggle(
      yielded: yielded,
      onReveal: () => ref.read(chatOpen.notifier).state = false,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chat = !isDm && ref.watch(canvasHasChatProvider(channelId));
    // The member list docks beside the canvas too, so its toggle lives here as it does on the channel header.
    final members = !isDm && MemberListToggle.fits(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: AppSpacing.s8,
      children: [
        const CanvasPeopleCluster(),
        if (chat) CanvasChatToggle(channelId: channelId),
        CanvasJoinCall(channelId: channelId),
        if (members) _membersToggle(context, ref),
      ],
    );
  }
}
