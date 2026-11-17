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
import '../../channels/screens/channel_screen.dart';
import '../../voice/providers/voice_chat_unread.dart';
import '../../voice/screens/voice_text_pane.dart';
import '../../voice/widgets/voice_chat_unread_dot.dart';

/// Whether the canvas's channel is a voice channel with a chat to open; a
/// DM's own conversation already holds its text.
final canvasHasChatProvider = Provider.autoDispose.family<bool, String>(
  (ref, channelId) =>
      ref.watch(channelByIdProvider(channelId)).valueOrNull?.kind == 'voice',
);

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
        !open && ref.watch(voiceChatUnreadProvider(widget.channelId));
    return VoiceChatToggleDot(
      unread: unread,
      toggle: AppIconButton(
        icon: AppIcons.chat,
        semanticLabel: unread
            ? 'Toggle text chat, new messages'
            : 'Toggle text chat',
        tooltip: 'Text chat',
        active: open,
        onPressed: docks
            ? () =>
                  ref.read(voiceChatPaneVisibleProvider.notifier).state = !open
            : _openSheet,
      ),
    );
  }
}
