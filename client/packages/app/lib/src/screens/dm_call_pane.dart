// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A DM's call, as a mode of that channel's pane rather than a route.
///
/// Mirrors `canvas_pane.dart`'s `canvasOpenProvider`: opening a call swaps
/// the whole conversation body, header included, the same way a real voice
/// channel's kind always does. The difference is a DM is a call only while
/// this state says so, since most of the time it is a text conversation;
/// closing this pane only stops showing it, the same way leaving a real
/// voice channel's screen does not hang up - a call already joined keeps
/// running via `voiceControllerProvider` (see `VoiceStripIndicator`)
/// regardless of whether this pane is what is on screen.
///
/// `_DmCallBar` carries `CanvasOpenButton` at every width, unlike a voice
/// channel's own in-call header which only wraps the call where
/// `LayoutClass.showsBothPanes`: a DM call has no such wide-only header of
/// its own to lean on, so this is the one place a DM call reaches the
/// canvas without hanging up first (`voice_call_dock.dart` covers why its
/// floating in-call toggle stays off for a DM call instead of duplicating
/// this).
///
/// At compact width `HomeShell` keeps the channel rail's drawer attached
/// behind this bar (unlike the canvas, which claims the edge outright), and
/// `_DmCallBar` carries its own leading back button to the channel list -
/// `CompactChannelAppBar`'s own affordance, since this bar replaces that one
/// rather than sitting under it. Closing the call pane is one way out, back
/// to a different channel entirely is another, and neither one hangs up a
/// call already joined.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/dm_call.dart';
import '../routing/breakpoints.dart';
import '../routing/routes.dart';
import '../widgets/voice_strip_indicator.dart' show CallChannelName;
import '../features/canvas/screens/canvas_open_button.dart';
import 'voice_screen.dart';

export '../providers/dm_call.dart' show dmCallOpenProvider;

class DmCallPane extends ConsumerWidget {
  const DmCallPane({super.key, required this.channelId});

  final String channelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Container(
      color: tokens.surfaceBase,
      // No AppBar sits above this bar; see ConversationPane's doc.
      child: SafeArea(
        left: false,
        child: Column(
          children: [
            _DmCallBar(
              channelId: channelId,
              onClose: () => ref.read(dmCallOpenProvider.notifier).state = null,
            ),
            Expanded(child: VoiceScreen(channelId: channelId, isDm: true)),
          ],
        ),
      ),
    );
  }
}

class _DmCallBar extends StatelessWidget {
  const _DmCallBar({required this.channelId, required this.onClose});

  final String channelId;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    // Wide keeps the rail visible beside this pane already; see this class's own doc comment.
    final compact = !LayoutClass.of(context).showsBothPanes;
    return Container(
      height: AppSizes.headerBar,
      padding: const EdgeInsets.symmetric(horizontal: AppSizes.paneGutter),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: tokens.borderSubtle)),
      ),
      child: Row(
        children: [
          if (compact) ...[
            IconButton(
              icon: const Icon(AppIcons.back),
              tooltip: 'Back to channels',
              onPressed: () => context.go(Routes.channels),
            ),
            const SizedBox(width: AppSpacing.s4),
          ],
          Icon(
            AppIcons.startCall,
            size: AppSizes.icon16,
            color: tokens.textSecondary,
          ),
          const SizedBox(width: AppSpacing.s8),
          Expanded(
            // The same widget the collapsed call strip uses; see its own doc.
            child: CallChannelName(
              channelId: channelId,
              style: AppText.body.copyWith(
                color: tokens.textPrimary,
                fontWeight: AppWeights.medium,
              ),
            ),
          ),
          CanvasOpenButton(channelId: channelId, isVoice: false, isDm: true),
          const SizedBox(width: AppSpacing.s4),
          AppIconButton(
            icon: AppIcons.dismiss,
            semanticLabel: 'Back to messages',
            tooltip: 'Back to messages',
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}
