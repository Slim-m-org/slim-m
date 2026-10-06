// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The routed conversation pane, split out of `home_shell.dart` for its line budget.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import '../providers/database_key_store.dart';
import '../providers/last_text_channel.dart';
import '../providers/providers.dart';
import '../providers/sync_controller.dart' show initialSyncCompleteProvider;
import '../providers/channel_search_controller.dart';
import '../routing/breakpoints.dart';
import '../widgets/compact_channel_app_bar.dart';
import '../widgets/channel_header.dart';
import 'canvas/canvas_pane.dart';
import 'unlisted_channel.dart';
import 'channel_screen.dart';
import 'dm_call_pane.dart';
import 'voice_screen.dart';
import 'voice_text_pane.dart';
import 'home_shell.dart';

/// The routed conversation pane: a text channel reads, a voice channel
/// calls, decided from the local store so it needs no round trip to know
/// which to show.
///
/// [ChannelScreen] renders its own full header (search, the pin pill, the
/// member-pane toggle) at any width that shows it. At compact width there is
/// no room for one, and [CompactChannelAppBar] carries the same four
/// affordances instead. Voice channels have no header of their own either
/// way, so this still supplies a minimal one at wide layouts, as before. The
/// canvas replaces all of that: [HomeShell] omits [CompactChannelAppBar]
/// while it is open, and [_VoiceConversationHeader] below is skipped the same
/// way, so [CanvasBar] is the only header at every width. `DmCallPane`
/// follows the identical shape for a DM's call, carrying its own bar.
class ConversationPane extends ConsumerWidget {
  const ConversationPane({
    required this.channelId,
    this.openChat = false,
    super.key,
  });

  final String channelId;

  /// See [VoiceScreen.openChat]; only a voice channel consults it.
  final bool openChat;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final layout = LayoutClass.of(context);
    final storeAsync = ref.watch(storeProvider);

    return storeAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.s16),
          child: AppErrorState(
            message: localStoreErrorMessage(e),
            onRetry: () => ref.invalidate(storeProvider),
          ),
        ),
      ),
      data: (store) => StreamBuilder<List<Channel>>(
        stream: store.watchChannels(),
        builder: (context, snapshot) {
          final channel = snapshot.data
              ?.where((c) => c.id == channelId)
              .cast<Channel?>()
              .firstOrNull;
          // Before the first sync, or before the list has emitted, an unresolved id may just not have arrived yet.
          if (channel == null &&
              snapshot.hasData &&
              ref.watch(initialSyncCompleteProvider)) {
            return UnlistedChannel(channelId: channelId);
          }
          final isVoice = channel?.kind == 'voice';
          final canvasOpen = ref.watch(canvasOpenProvider) == channelId;
          final dmCallOpen =
              channel?.kind == 'dm' &&
              ref.watch(dmCallOpenProvider) == channelId;
          // Keyed by stage, so each pane fades through the one it replaces.
          final stage = canvasOpen
              ? 'canvas'
              : isVoice
              ? 'voice'
              : dmCallOpen
              ? 'dm-call'
              : 'text';
          if (stage == 'text' && channel != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              ref.read(lastTextChannelProvider.notifier).state = channelId;
            });
          }
          final body = AppFadeIn(
            key: ValueKey('pane-$stage'),
            child: canvasOpen
                ? CanvasPane(channelId: channelId)
                : isVoice
                ? VoiceScreen(channelId: channelId, openChat: openChat)
                : dmCallOpen
                ? DmCallPane(channelId: channelId)
                : ChannelScreen(channelId: channelId),
          );

          if (!layout.showsBothPanes || !isVoice || canvasOpen) return body;
          return Column(
            children: [
              _VoiceConversationHeader(
                channelId: channelId,
                name: channel?.name ?? '',
                topic: channel?.topic,
              ),
              Expanded(child: body),
            ],
          );
        },
      ),
    );
  }
}

/// A voice channel's one header: [ChannelHeader] with the toggle for
/// `voice_text_pane.dart`'s chat: docked beside the call where
/// [LayoutClass.fitsThreadPane] allows it, swapped in over the call below
/// that, so the toggle is always offered. The chat passes `showHeader: false`,
/// so this is the only bar.
class _VoiceConversationHeader extends ConsumerWidget {
  const _VoiceConversationHeader({
    required this.channelId,
    required this.name,
    this.topic,
  });

  final String channelId;
  final String name;
  final String? topic;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chatOpen = ref.watch(voiceChatPaneVisibleProvider);
    final search = ref.watch(channelSearchProvider(channelId));
    void setChatOpen(bool open) =>
        ref.read(voiceChatPaneVisibleProvider.notifier).state = open;
    return ChannelHeader(
      channelId: channelId,
      name: name,
      topic: topic,
      isVoice: true,
      searchOpen: search.open,
      // Search lives in the docked chat, so opening it opens the pane it searches.
      onToggleSearch: () {
        if (!chatOpen) setChatOpen(true);
        ref.read(channelSearchProvider(channelId).notifier).toggle();
      },
      textChatOpen: chatOpen,
      onToggleTextChat: () => setChatOpen(!chatOpen),
    );
  }
}

/// The first thing a fresh desktop sign-in lands on, so it carries the same
/// visual weight `ChannelStartHeader` gives the functionally identical
/// "nothing here yet" case, rather than a single small line of grey text.
/// The Ctrl+K hint drops on a touch layout, the same rule the rail's own
/// search field hint already follows - no finger can press it.
