// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Opens the voice channel's own text chat from the canvas.
///
/// Where `LayoutClass.fitsThreadPane` has room the chat docks beside the
/// canvas, through the same `voiceChatPaneVisibleProvider` the call view uses
/// (`voice_text_pane.dart`). Narrower, it is a sheet over the canvas
/// (desktop-vs-mobile.md rule 3), because swapping the canvas out would drop
/// its camera, tool and any draft. A dot says a message arrived while closed.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../routing/breakpoints.dart';
import '../../channels/providers/channel_by_id_provider.dart';
import '../../channels/providers/channel_notification_overrides_controller.dart';
import '../../channels/screens/channel_screen.dart';
import '../../messages/providers/unread_indicator_rules.dart';
import '../../voice/screens/voice_text_pane.dart';

const canvasChatUnreadKey = Key('canvas-chat-unread');
const _dot = 8.0;

/// Whether the canvas's channel is a voice channel with a chat to open; a
/// DM's own conversation already holds its text.
final canvasHasChatProvider = Provider.autoDispose.family<bool, String>(
  (ref, channelId) =>
      ref.watch(channelByIdProvider(channelId)).valueOrNull?.kind == 'voice',
);

/// Whether the voice channel has text, or a mention, this device has not read.
final canvasChatUnreadProvider = Provider.autoDispose.family<bool, String>((
  ref,
  channelId,
) {
  final channel = ref.watch(channelByIdProvider(channelId)).valueOrNull;
  if (channel == null) return false;
  final override = ref.watch(
    channelNotificationOverridesProvider.select((s) => s.effectiveFor(channel)),
  );
  final indicator = unreadIndicatorForChannel(
    channel,
    channelOverride: override,
    isDm: false,
  );
  return indicator.unread || indicator.mentioned;
});

/// The chat over the canvas, for a width with no room to dock it.
Future<void> showCanvasChatSheet(BuildContext context, String channelId) =>
    showAppSheet<void>(
      context,
      semanticLabel: 'Text chat',
      builder: (context) => SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.8,
        child: ChannelScreen(channelId: channelId, showHeader: false),
      ),
    );

/// The small accent dot that says something is waiting.
class CanvasUnreadDot extends StatelessWidget {
  const CanvasUnreadDot({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return IgnorePointer(
      child: DecoratedBox(
        key: canvasChatUnreadKey,
        decoration: BoxDecoration(
          color: tokens.accent,
          shape: BoxShape.circle,
          border: Border.all(color: tokens.surfaceBase, width: 1.5),
        ),
        child: const SizedBox.square(dimension: _dot),
      ),
    );
  }
}

/// Whether this width docks the chat beside the canvas instead of sheeting it.
bool canvasChatDocks(BuildContext context) =>
    LayoutClass.of(context).fitsThreadPane(MediaQuery.sizeOf(context).width);

class CanvasChatToggle extends ConsumerStatefulWidget {
  const CanvasChatToggle({super.key, required this.channelId});

  final String channelId;

  @override
  ConsumerState<CanvasChatToggle> createState() => _CanvasChatToggleState();
}

class _CanvasChatToggleState extends ConsumerState<CanvasChatToggle> {
  bool _sheetOpen = false;

  Future<void> _openSheet() async {
    setState(() => _sheetOpen = true);
    await showCanvasChatSheet(context, widget.channelId);
    if (mounted) setState(() => _sheetOpen = false);
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(canvasHasChatProvider(widget.channelId))) {
      return const SizedBox.shrink();
    }
    final docks = canvasChatDocks(context);
    final open = docks ? ref.watch(voiceChatPaneVisibleProvider) : _sheetOpen;
    final unread =
        !open && ref.watch(canvasChatUnreadProvider(widget.channelId));
    return Stack(
      clipBehavior: Clip.none,
      children: [
        AppIconButton(
          icon: AppIcons.chat,
          semanticLabel: unread
              ? 'Toggle text chat, new messages'
              : 'Toggle text chat',
          tooltip: 'Text chat',
          active: open,
          onPressed: docks
              ? () => ref.read(voiceChatPaneVisibleProvider.notifier).state =
                    !open
              : _openSheet,
        ),
        if (unread)
          const Positioned(
            top: AppSpacing.s4,
            right: AppSpacing.s4,
            child: CanvasUnreadDot(),
          ),
      ],
    );
  }
}
