// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The signed-in shell: channel rail beside, or instead of, a conversation,
/// plus the member pane wherever it has room to dock
/// ([LayoutClass.fitsMemberPane]).
library;

export '../features/channels/screens/conversation_pane.dart'
    show ConversationPane;
export 'home_shell_empty_state.dart' show NoChannelPage, NoChannelSelected;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show OrdinalSortKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../features/modules/widgets/module_panel_slot.dart';
import '../features/admin_setup/screens/admin_setup_gate.dart';
import '../features/first_run/widgets/first_run_gate.dart';
import '../features/members/providers/activity_publisher.dart';
import '../features/screen_overlay/providers/screen_overlay_controller.dart';
import '../features/voice/providers/live_quality_restart.dart';
import '../features/voice/providers/voice_move_follower.dart';
import '../features/voice/providers/voice_server_presence.dart';
import '../features/voice/providers/voice_notice_controller.dart';
import '../features/voice/widgets/call_restore_gate.dart';
import '../features/voice/widgets/voice_notice_banner_host.dart';
import '../providers/admin_providers.dart';
import '../features/members/providers/blocks_controller.dart';
import '../features/voice/providers/hold_music_controller.dart';
import '../features/channels/providers/channel_notification_overrides_controller.dart';
import '../features/composer/widgets/voice_recording_marker.dart';
import '../features/auth/providers/database_key_store.dart';
import '../features/members/providers/member_presence.dart'
    show memberModerationWatcherProvider;
import '../features/members/providers/member_selection.dart';
import '../features/modules/providers/module_sound_settings.dart';
import '../features/settings/providers/notification_schedule_controller.dart';
import '../features/settings/providers/notification_sound_controller.dart';
import '../features/channels/providers/rail_width_preference.dart';
import '../features/messages/providers/retention_sweep.dart';
import '../features/voice/providers/voice_controller.dart';
import '../routing/breakpoints.dart';
import '../features/voice/widgets/call_mini_player.dart';
import '../features/channels/widgets/channel_rail.dart';
import '../features/channels/widgets/channel_rail_frame.dart';
import '../features/home/widgets/compact_drawer_scaffold.dart';
import '../features/members/widgets/member_pane.dart';
import '../features/admin_alerts/widgets/admin_alert_banner_host.dart';
import '../features/auth/widgets/new_device_banner_host.dart';
import '../features/settings/widgets/rules_gate_banner_host.dart';
import '../features/voice/widgets/push_to_talk_listener.dart';
import '../features/channels/widgets/rail_slot.dart';
import '../downloads/download_failures.dart';
import '../widgets/pane_reading_order.dart';
import '../widgets/shell_focus_anchor.dart';
import '../widgets/update_banner_host.dart';
import '../features/voice/providers/shortcut_overrides.dart';
import '../features/voice/widgets/call_keyboard_pill.dart' show ShellKeyboard;
import '../features/voice/widgets/voice_strip_indicator.dart';
import '../widgets/whats_new_gate.dart';
import '../features/messages/widgets/bot_form_gate.dart';
import '../features/canvas/screens/canvas_fullscreen.dart';
import '../features/canvas/screens/canvas_pane.dart';
import '../features/voice/screens/hang_up_recap_toast.dart';
import '../features/background/widgets/app_background_host.dart';
import '../features/role_preview/providers/role_preview_controller.dart';
import '../features/role_preview/screens/role_preview_shell.dart';
import 'home_shell_facts.dart';
import 'home_shell_pane_slots.dart';
import 'home_shell_shortcuts.dart';

/// The shell. One widget handles every width: at compact widths it shows one
/// pane at a time, and above that both at once. The panes themselves are the
/// same widgets either way, so behaviour cannot drift between layouts.
/// An incoming DM call is not this shell's concern any more: `IncomingCallOverlay`
/// is mounted by `appChromeBuilder`, above the routed tree this shell is part
/// of, rather than in flow here - see its own doc comment for why.
class HomeShell extends ConsumerWidget {
  const HomeShell({required this.child, super.key});

  /// The routed pane: either the empty state or a conversation.
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final layout = LayoutClass.of(context);
    final selected = selectedChannelId(context);
    // Rebuilds the key bindings when a shortcut is remapped.
    ref.watch(shortcutOverridesProvider);
    listenForHangUpRecap(context, ref, selectedChannelId: selected);
    _holdSessionProviders(ref);
    final facts = resolveShellFacts(
      ref,
      layout,
      MediaQuery.sizeOf(context),
      selected,
    );
    final preview = ref.watch(rolePreviewProvider);
    final scaffold = preview == null
        ? _scaffold(context, ref, layout, facts)
        : RolePreviewShell(session: preview);

    final shell = WhatsNewGate(
      child: CallRestoreGate(
        child: BotFormGate(
          child: PushToTalkListener(
            child: CallbackShortcuts(
              bindings: shellShortcutBindings(
                context,
                ref,
                previewing: preview != null,
              ),
              child: ShellFocusAnchor(
                child: _LayoutBridge(
                  layout: layout,
                  child: NewDeviceBannerHost(
                    child: VoiceNoticeBannerHost(
                      child: AdminAlertBannerHost(
                        child: RulesGateBannerHost(
                          child: UpdateBannerHost(
                            child: DownloadFailureHost(
                              child: DatabaseResetNotice(
                                child: AppBackgroundHost(child: scaffold),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return FirstRunGate(child: AdminSetupGate(child: shell));
  }

  void _holdSessionProviders(WidgetRef ref) {
    // Loaded with the shell so the first surface to consult it filters against none; selecting a constant keeps this mounted without rebuilding the whole shell on every block/unblock.
    ref.watch(blocksProvider.select((_) => null));
    // Same reasoning, including the constant select: a channel mute must not rebuild the whole shell either.
    ref.watch(channelNotificationOverridesProvider.select((_) => null));
    // Session-lifetime, or permission invalidation only ran with RolesScreen open.
    ref.watch(roleChangeWatcherProvider);
    // Session-lifetime, or someone who joined stayed out of every picker until a member pane opened.
    ref.watch(memberModerationWatcherProvider);
    // Forces creation for the session; nothing here reads its own state.
    ref.watch(notificationSoundControllerProvider);
    // Session-lifetime, so hold music reacts to the call without a screen mounting it.
    ref.watch(holdMusicControllerProvider);
    ref.watch(activityPublisherProvider);
    ref.watch(voiceMoveFollowerProvider);
    ref.watch(voiceServerPresenceProvider);
    // The notice's state is for its banner host; held here without rebuilding the shell per notice.
    ref.watch(voiceNoticeProvider.select((_) => null));
    ref.watch(liveQualityRestartProvider);
    // Session-lifetime, so the overlay follows the share without a call screen mounted.
    ref.watch(screenOverlayControllerProvider.select((_) => null));
    // Same reasoning: read lazily, its first read would race a module's own sound trigger against this provider's async load from disk.
    ref.watch(moduleSoundSettingsProvider.select((_) => null));
    // Same reasoning as the channel-mute watch above: session-lifetime, for the sound and desktop-notifier paths.
    ref.watch(notificationScheduleProvider.select((_) => null));
    // Same reasoning: the periodic local-store/extras sweep only needs to run for the session.
    ref.watch(retentionSweepControllerProvider);
  }

  Widget _scaffold(
    BuildContext context,
    WidgetRef ref,
    LayoutClass layout,
    ShellFacts facts,
  ) {
    final selected = facts.selected;
    if (layout.showsBothPanes) {
      Widget wide(bool isDm) => _wideScaffold(context, ref, facts, isDm);
      return selected == null
          ? wide(false)
          : withChannelKind(ref, selected, wide);
    }
    if (selected == null) return _compactList(child);
    return _compactScaffold(context, ref, facts, selected);
  }

  /// The list has no use for the routed child, but go_router's system-back lookup dereferences this shell's navigator, so it stays mounted out of sight.
  Widget _compactList(Widget child) => Stack(
    fit: StackFit.expand,
    children: [
      Offstage(
        child: ExcludeFocus(
          child: Material(type: MaterialType.transparency, child: child),
        ),
      ),
      const Scaffold(backgroundColor: Colors.transparent, body: ChannelRail()),
    ],
  );

  Widget _wideScaffold(
    BuildContext context,
    WidgetRef ref,
    ShellFacts facts,
    bool isDm,
  ) {
    final selected = facts.selected;
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final rail = railSlot(
      context: context,
      expanded: ref.watch(channelRailExpandedProvider),
      canvasFullscreen: facts.canvasFullscreen,
      railWidth: facts.railWidth,
      dragging: ref.watch(railDraggingProvider),
    );
    return Scaffold(
      backgroundColor: Colors.transparent,
      // Where no pane docks, the roster is the same end drawer compact uses.
      onEndDrawerChanged: (open) => endSelectionOnDrawerClose(ref, open),
      endDrawerEnableOpenDragGesture: !facts.canvasOpen,
      endDrawer: isDm || facts.membersFit || selected == null
          ? null
          : OpaquePanes(
              child: Drawer(
                width: AppMemberPane.width,
                child: SafeArea(child: AppMemberPane(channelId: selected)),
              ),
            ),
      body: Row(
        children: [
          // The rail at full or compact width, or neither, plus its handle; see railSlot's own doc.
          PaneReadingOrder(order: 0, child: rail.first),
          // Unwrapped: the handle's hit region reaches outside its own box, which a wrapper would clip.
          ...rail.skip(1),
          // Its own semantics node, or the modal barrier inside this pane's
          // navigator blocks everything painted before it, which is the
          // whole rail: no channel row, section or search field reached a
          // screen reader at all. The member pane paints after it and so
          // was never affected, which is what made this look like a rail bug.
          Expanded(
            child: PaneSurface(
              color: tokens.surfaceBase,
              child: Semantics(
                container: true,
                sortKey: const OrdinalSortKey(1),
                child: videoStripAbove(
                  CallMiniPlayerHost(child: child),
                  show: facts.videoStrip,
                ),
              ),
            ),
          ),
          if (facts.panelSide)
            const PaneReadingOrder(order: 2, child: ModulePanelSlot()),
          if (facts.videoSide)
            PaneReadingOrder(
              order: 2,
              child: VideoPaneSlot(
                channelId: facts.rosterPending ? null : selected,
                withMembers: facts.membersUnderVideo,
              ),
            ),
          // Between the transcript and the roster (the Discord/Slack order); it and the roster never both take width, so the transcript loses at most one third pane.
          if (facts.threadFits)
            PaneReadingOrder(
              order: 3,
              child: ThreadPaneSlot(
                channelId: facts.openThread,
                besideChannelId: selected,
                requested: facts.showThread,
              ),
            ),
          // The pane comes from the edge it lives on: the slot's width
          // animates while the content slides in and fades (motion spec
          // 05). Hidden, the pane itself unmounts rather than sitting at
          // opacity zero - it fetches while built, and home_shell_test pins
          // exactly that - so the exit is the gap closing over the panel
          // duration while the entrance gets the full slide.
          if (facts.membersFit)
            // Once synced, unscoped until the row resolves, so no request names a channel not yet known to be visible.
            PaneReadingOrder(
              order: 4,
              child: MemberPaneSlot(
                channelId: facts.rosterPending ? null : selected,
                requested: facts.showMembers,
              ),
            ),
        ],
      ),
    );
  }

  Widget _compactScaffold(
    BuildContext context,
    WidgetRef ref,
    ShellFacts facts,
    String channelId,
  ) {
    // No rail here to carry the strip, so a call not on screen gets its own row.
    final voiceChannelId = ref.watch(
      voiceControllerProvider.select((s) => s.channelId),
    );
    final chatOverCall = voiceChatOverCall(ref, channelId);
    // The composer area carries the slim call pill while typing, so the composer sits on the keyboard.
    final keyboardUp = MediaQuery.viewInsetsOf(context).bottom > 0;
    return withChannelKind(ref, channelId, (isDm) {
      // Only a DM's call pane replaces the header; the call-return affordances also set the provider for voice channels.
      final replacesHeader = facts.canvasOpen || (facts.dmCallOpen && isDm);
      // The call's own UI is on screen only on its channel's call stage; a DM's chat or a voice channel's chat has none.
      final callOnScreen =
          voiceChannelId == channelId &&
          !chatOverCall &&
          (!isDm || facts.dmCallOpen);
      return CompactDrawerScaffold(
        channelId: channelId,
        onBack: facts.canvasFullscreen
            ? () {
                ref.read(canvasFullscreenFromFocusProvider.notifier).state =
                    null;
                ref.read(canvasFullscreenProvider.notifier).state = null;
              }
            : facts.canvasOpen
            ? () => ref.read(canvasOpenProvider.notifier).state = null
            : null,
        showAppBar: !(replacesHeader || facts.notFound),
        // Only the canvas (a drawing surface of its own) also claims the rail; see DmCallPane's own doc for why a DM call keeps it.
        showRail: !facts.canvasOpen,
        showMembers: !(isDm || facts.notFound),
        membersByEdgeDrag: !facts.canvasOpen,
        body: ShellKeyboard(
          up: keyboardUp,
          child: Column(
            children: [
              const RailConnectionBar(),
              // Its own semantics node for the same reason the wide layout gives the pane one: the modal barrier inside this pane's navigator drops everything painted before it, which here is the connection bar.
              Expanded(
                child: Semantics(
                  container: true,
                  child: videoStripAbove(
                    CallMiniPlayerHost(keyboardUp: keyboardUp, child: child),
                    show: facts.videoStrip,
                  ),
                ),
              ),
              if (!keyboardUp) VoiceRecordingStrip(activeChannelId: channelId),
              // The strip decides if a call is live, here or in another community.
              if (!callOnScreen && !keyboardUp) const VoiceStripIndicator(),
            ],
          ),
        ),
      );
    });
  }
}

/// Bridges the 599/600 chrome swap with a short fade, so a resize across
/// the breakpoint reads as reflow rather than a one-frame interface swap.
///
/// Deliberately [AppFadeIn] keyed on the layout class rather than an
/// `AnimatedSwitcher`: a switcher keeps the outgoing scaffold mounted
/// through the crossfade, and both copies would then hold the shell's one
/// routed child - a Navigator whose GlobalKeys cannot exist twice.
class _LayoutBridge extends StatelessWidget {
  const _LayoutBridge({required this.layout, required this.child});

  final LayoutClass layout;
  final Widget child;

  @override
  Widget build(BuildContext context) => AppFadeIn(
    key: ValueKey('shell-${layout.name}'),
    duration: AppMotion.fast,
    offset: 0,
    child: child,
  );
}
