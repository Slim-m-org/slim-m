// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Opens the channel's own text chat from the canvas, a voice channel's or a canvas channel's.
///
/// Where `LayoutClass.fitsThreadPane` has room the chat docks beside the
/// canvas: through the `voiceChatPaneVisibleProvider` the call view uses for a
/// voice channel (`voice_text_pane.dart`), through the channel's own
/// `canvasChannelChatOpenProvider` for a canvas channel. Narrower, it is a sheet over the canvas
/// (desktop-vs-mobile.md rule 3), because swapping the canvas out would drop
/// its camera, tool and any draft. A dot says a message arrived while closed.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../routing/breakpoints.dart';
import '../../channels/providers/channel_by_id_provider.dart';
import '../../channels/screens/channel_screen.dart';
import '../../voice/providers/voice_chat_unread.dart';
import '../../voice/screens/voice_text_pane.dart';
import '../../voice/widgets/voice_chat_unread_dot.dart';
import '../providers/canvas_channel_chat_open.dart';
import '../providers/canvas_open.dart';

/// Whether the canvas's channel is a voice or canvas channel with a chat to
/// open; a DM's own conversation already holds its text.
final canvasHasChatProvider = Provider.autoDispose.family<bool, String>(
  (ref, channelId) => ref.watch(
    channelByIdProvider(channelId).select((c) {
      final row = c.valueOrNull;
      return row != null && (row.kind == 'voice' || row.isCanvasChannel);
    }),
  ),
);

/// Whether the channel's chat is flagged open beside its board, a canvas channel's own or a voice canvas's; false for anything else.
final canvasChatFlaggedOpenProvider = Provider.autoDispose.family<bool, String>(
  (ref, channelId) {
    final row = ref.watch(channelByIdProvider(channelId)).valueOrNull;
    if (row == null) return false;
    if (row.isCanvasChannel) {
      return ref.watch(canvasChannelChatOpenProvider(channelId));
    }
    return row.kind == 'voice' && ref.watch(voiceChatPaneVisibleProvider);
  },
);

/// The flag that docks this channel's chat: its own for a canvas channel, the voice one otherwise.
StateProvider<bool> canvasChatOpenProviderFor(
  String channelId, {
  required bool isCanvasChannel,
}) => isCanvasChannel
    ? canvasChannelChatOpenProvider(channelId)
    : voiceChatPaneVisibleProvider;

/// The chat over the canvas, for a width with no room to dock it.
Future<void> showCanvasChatSheet(
  BuildContext context,
  String channelId,
) => showAppSheet<void>(
  context,
  semanticLabel: 'Text chat',
  // As tall as the chat up to the cap, so a short one opens on its messages, not on empty space.
  builder: (context) => ConstrainedBox(
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * 0.8,
    ),
    child: ChannelScreen(
      channelId: channelId,
      showHeader: false,
      fitContent: true,
    ),
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
    final chatOpen = canvasChatOpenProviderFor(
      widget.channelId,
      isCanvasChannel: ref.watch(canvasIsChannelProvider(widget.channelId)),
    );
    final open = docks ? ref.watch(chatOpen) : _sheetOpen;
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
            ? () => ref.read(chatOpen.notifier).state = !open
            : _openSheet,
      ),
    );
  }
}
