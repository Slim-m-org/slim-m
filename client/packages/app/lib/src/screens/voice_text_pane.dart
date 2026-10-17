// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The voice channel's text surface: `ChannelScreen`'s transcript and
/// composer, docked beside the call at desktop widths and swapped in over
/// the whole screen at compact ones - see `voice_screen.dart`'s own doc for
/// where this is mounted and docs/design/desktop-vs-mobile.md for the
/// surface choice.
///
/// Reuses `ChannelScreen` wholesale rather than a parallel transcript, the
/// same reasoning `thread_screen.dart`'s own doc comment gives: unread
/// state, read marking, drafts and message actions all already live there
/// and nothing else needs to reimplement any of it. `ChannelScreen`
/// registers and unregisters itself into `MountedChannels` from its own
/// `initState`/`dispose`, so mounting or unmounting it here - toggling the
/// desktop pane, or opening/closing the compact chat view - already pairs
/// correctly with no extra wiring.
///
/// The desktop pane reuses `kThreadPaneWidth`/`fitsThreadPane`
/// (`routing/breakpoints.dart`): a chat pane needs the same room a docked
/// thread does (a transcript and a composer, not a list), and a second
/// constant for the identical number would only invite the two to drift.
/// `VoiceScreen` uses `fitsThreadPane` to fall back to the compact tab
/// layout below that width even at a technically non-compact width, per the
/// "width decides, re-checked live on resize" rule
/// (desktop-vs-mobile.md law 1): a narrow medium window has no room to dock
/// the call and a transcript side by side.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../routing/breakpoints.dart';
import '../widgets/app_panel_reveal.dart';
import '../features/channels/screens/channel_screen.dart';

/// Whether the voice channel's docked chat pane is open, at desktop widths.
/// Defaults closed: opening a voice channel keeps the call stage at full
/// width until a member asks for the pane, rather than narrowing every
/// existing call the moment this ships.
final voiceChatPaneVisibleProvider = StateProvider<bool>((ref) => false);

/// The docked pane at desktop widths: [call] full width, or split with the
/// channel's own transcript and composer beside it. Mirrors
/// `_MemberPaneSlot`/`_ThreadPaneSlot` in `home_shell_pane_slots.dart`: an
/// `AnimatedContainer` width that unmounts its content when closed, so a
/// hidden pane's `ChannelScreen` is not sitting behind it still fetching.
class VoiceCallWithChatPane extends ConsumerWidget {
  const VoiceCallWithChatPane({
    required this.channelId,
    required this.call,
    super.key,
  });

  final String channelId;
  final Widget call;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final open = ref.watch(voiceChatPaneVisibleProvider);
    return Row(
      children: [
        Expanded(child: call),
        ClipRect(
          child: AnimatedContainer(
            duration: AppMotion.reduced(context, AppMotion.base),
            curve: AppMotion.entrance,
            width: open ? kThreadPaneWidth : 0,
            child: open
                ? OverflowBox(
                    minWidth: kThreadPaneWidth,
                    maxWidth: kThreadPaneWidth,
                    alignment: Alignment.centerLeft,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border(
                          left: BorderSide(color: tokens.borderSubtle),
                        ),
                      ),
                      child: AppPanelReveal(
                        fromLeft: false,
                        // See ChannelScreen.showHeader's own doc for why this pane omits its own header.
                        child: ChannelScreen(
                          channelId: channelId,
                          showHeader: false,
                        ),
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ],
    );
  }
}

/// The compact equivalent: the call fills the screen until the app bar's
/// [VoiceChatAction] (desktop-vs-mobile.md rule 2, a two-way call/chat choice)
/// swaps the whole body for the channel's own transcript. Swapped, not tabbed
/// alongside a persistent header: an inline header here cost `CallStageLayout`
/// a fixed slice of height on every width, and `ui_snapshot_test.dart`'s
/// `voice-in-call` matrix overflowed by 21px at `phone-landscape` the moment
/// a first version added one. The toggle lives in the app bar, next to
/// members, so nothing floats over the call stage.
class VoiceCallWithChatTabs extends ConsumerWidget {
  const VoiceCallWithChatTabs({
    required this.channelId,
    required this.call,
    super.key,
  });

  final String channelId;
  final Widget call;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chatOpen = ref.watch(voiceChatPaneVisibleProvider);
    return AppFadeIn(
      key: ValueKey('voice-chat-open-$chatOpen'),
      offset: 0,
      // showHeader: false for the same reason the docked pane withholds it - see ChannelScreen's own doc.
      child: chatOpen
          ? ChannelScreen(channelId: channelId, showHeader: false)
          : call,
    );
  }
}

/// The text chat toggle in a voice channel's app bar, lit while the chat is
/// open. It drives [voiceChatPaneVisibleProvider], the same state the desktop
/// header's toggle drives, so a resize across the dock width keeps the choice.
class VoiceChatAction extends ConsumerWidget {
  const VoiceChatAction({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = ref.watch(voiceChatPaneVisibleProvider);
    return AppIconButton(
      icon: AppIcons.chat,
      semanticLabel: 'Toggle text chat',
      tooltip: 'Text chat',
      active: open,
      touch: true,
      onPressed: () =>
          ref.read(voiceChatPaneVisibleProvider.notifier).state = !open,
    );
  }
}
