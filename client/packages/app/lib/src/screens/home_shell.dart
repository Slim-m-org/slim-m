// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The signed-in shell: channel rail beside, or instead of, a conversation,
/// plus the member pane wherever it has room to dock
/// ([LayoutClass.fitsMemberPane]).
library;

export '../features/channels/screens/conversation_pane.dart'
    show ConversationPane;
export 'home_shell_empty_state.dart' show NoChannelSelected;

import 'dart:async';

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart';

import 'package:go_router/go_router.dart';

import '../features/accounts/widgets/account_shortcuts.dart';
import '../features/first_run/widgets/first_run_gate.dart';
import '../features/members/providers/activity_publisher.dart';
import '../features/voice/providers/live_quality_restart.dart';
import '../features/voice/providers/voice_move_follower.dart';
import '../providers/admin_providers.dart';
import '../features/members/providers/blocks_controller.dart';
import '../features/voice/providers/call_shortcut_registry.dart';
import '../features/voice/providers/hold_music_controller.dart';
import '../features/channels/providers/channel_notification_overrides_controller.dart';
import '../features/channels/providers/channel_by_id_provider.dart';
import '../features/composer/providers/composer_focus.dart';
import '../features/auth/providers/database_key_store.dart';
import '../features/members/providers/member_selection.dart';
import '../features/modules/providers/module_sound_settings.dart';
import '../features/settings/providers/notification_schedule_controller.dart';
import '../features/settings/providers/notification_sound_controller.dart';
import '../providers/providers.dart';
import '../features/channels/providers/rail_width_preference.dart';
import '../providers/retention_sweep.dart';
import '../providers/sync_controller.dart' show initialSyncCompleteProvider;
import '../features/channels/providers/threads.dart';
import '../features/voice/providers/voice_controller.dart';
import '../routing/breakpoints.dart';
import '../routing/routes.dart';
import '../widgets/app_panel_reveal.dart';
import '../features/channels/widgets/channel_grouping.dart';
import '../features/voice/widgets/call_mini_player.dart';
import '../features/channels/widgets/channel_rail.dart';
import '../features/channels/widgets/channel_rail_frame.dart';
import '../features/palette/widgets/command_palette.dart';
import '../widgets/compact_drawer_scaffold.dart';
import '../features/members/widgets/member_pane.dart';
import '../widgets/new_device_banner_host.dart';
import '../widgets/rules_gate_banner_host.dart';
import '../features/voice/widgets/push_to_talk_listener.dart';
import '../features/channels/widgets/rail_slot.dart';
import '../downloads/download_failures.dart';
import '../widgets/update_banner_host.dart';
import '../features/voice/providers/push_to_talk_gate.dart';
import '../features/voice/providers/shortcut_overrides.dart';
import '../features/voice/widgets/voice_strip_indicator.dart';
import '../widgets/whats_new_gate.dart';
import '../features/messages/widgets/bot_form_gate.dart';
import '../features/canvas/screens/canvas_fullscreen.dart';
import '../features/canvas/screens/canvas_pane.dart';
import '../features/voice/screens/dm_call_pane.dart';
import '../features/voice/screens/hang_up_recap_toast.dart';
import '../features/messages/widgets/inbox_sheet.dart';
import '../features/messages/screens/thread_screen.dart';

part 'home_shell_pane_slots.dart';

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
    final facts = _shellFacts(
      ref,
      layout,
      MediaQuery.sizeOf(context),
      selected,
    );
    final scaffold = _scaffold(context, ref, layout, facts);

    final shell = WhatsNewGate(
      child: BotFormGate(
        child: PushToTalkListener(
          child: CallbackShortcuts(
            bindings: _shortcutBindings(context, ref),
            // CallbackShortcuts only fires for a focused descendant, so this
            // default makes the shortcut work the instant the app opens.
            child: Focus(
              autofocus: true,
              child: _LayoutBridge(
                layout: layout,
                child: NewDeviceBannerHost(
                  child: RulesGateBannerHost(
                    child: UpdateBannerHost(
                      child: DownloadFailureHost(
                        child: DatabaseResetNotice(child: scaffold),
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
    return FirstRunGate(child: shell);
  }

  void _holdSessionProviders(WidgetRef ref) {
    // Loaded with the shell so the first surface to consult it filters against none; selecting a constant keeps this mounted without rebuilding the whole shell on every block/unblock.
    ref.watch(blocksProvider.select((_) => null));
    // Same reasoning, including the constant select: a channel mute must not rebuild the whole shell either.
    ref.watch(channelNotificationOverridesProvider.select((_) => null));
    // Session-lifetime, or permission invalidation only ran with RolesScreen open.
    ref.watch(roleChangeWatcherProvider);
    // Forces creation for the session; nothing here reads its own state.
    ref.watch(notificationSoundControllerProvider);
    // Session-lifetime, so hold music reacts to the call without a screen mounting it.
    ref.watch(holdMusicControllerProvider);
    ref.watch(activityPublisherProvider);
    ref.watch(voiceMoveFollowerProvider);
    ref.watch(liveQualityRestartProvider);
    // Same reasoning: read lazily, its first read would race a module's own sound trigger against this provider's async load from disk.
    ref.watch(moduleSoundSettingsProvider);
    // Same reasoning as the channel-mute watch above: session-lifetime, for the sound and desktop-notifier paths.
    ref.watch(notificationScheduleProvider.select((_) => null));
    // Same reasoning: the periodic local-store/extras sweep only needs to run for the session.
    ref.watch(retentionSweepControllerProvider);
  }

  _ShellFacts _shellFacts(
    WidgetRef ref,
    LayoutClass layout,
    Size size,
    String? selected,
  ) {
    final width = size.width;
    // CanvasBar is the only header while open (ConversationPane's doc); the compact app bar below would otherwise stack a second one above it.
    final canvasOpen =
        selected != null && ref.watch(canvasOpenProvider) == selected;
    // DmCallBar is the same: a DM's call pane replaces the header too.
    final dmCallOpen =
        selected != null && ref.watch(dmCallOpenProvider) == selected;
    // The canvas asked for the whole pane; the rail and the roster are exactly the chrome it asked to be rid of, and both unmount rather than sitting at zero width, so neither keeps polling behind it.
    final fullscreenChannel = ref.watch(canvasFullscreenProvider);
    final canvasFullscreen = canvasOpen && fullscreenChannel == selected;
    // Whatever the header toggle says: it can only hide the pane, not summon
    // room for it that is not there (see LayoutClass.fitsMemberPane's doc).
    final membersFit = layout.fitsMemberPane(width);
    // The thread pane and the roster share the one third-pane slot; a docked
    // thread takes it, so the roster yields while a thread is open (UX1, and
    // see fitsThreadPane's doc). Below the width that fits a docked pane the
    // thread stays the pushed modal route instead.
    final openThread = ref.watch(openThreadProvider);
    final threadFits = layout.fitsThreadPane(width);
    final showThread = openThread != null && threadFits && !canvasFullscreen;
    // Once synced, a channel the store lacks is one the viewer cannot see: ChannelNotFound owns the pane, with no roster or members control.
    final channelRow = selected == null
        ? null
        : ref.watch(channelByIdProvider(selected));
    final synced = ref.watch(initialSyncCompleteProvider);
    final notFound =
        channelRow is AsyncData<Channel?> && channelRow.value == null && synced;
    final showMembers =
        membersFit &&
        !notFound &&
        !canvasFullscreen &&
        !showThread &&
        memberPaneWanted(ref, size);
    final dockedPane = switch ((showThread, showMembers)) {
      (true, _) => kThreadPaneWidth,
      (_, true) => AppMemberPane.width,
      _ => 0.0,
    };
    return _ShellFacts(
      selected: selected,
      canvasOpen: canvasOpen,
      dmCallOpen: dmCallOpen,
      canvasFullscreen: canvasFullscreen,
      membersFit: membersFit,
      openThread: openThread,
      threadFits: threadFits,
      showThread: showThread,
      showMembers: showMembers,
      notFound: notFound,
      rosterPending: channelRow != null && !channelRow.hasValue && synced,
      railWidth: _railWidth(ref, layout, width, dockedPane),
    );
  }

  double _railWidth(
    WidgetRef ref,
    LayoutClass layout,
    double width,
    double dockedPane,
  ) {
    final defaultRailWidth = layout == LayoutClass.expanded
        ? ChannelRail.expandedWidth
        : ChannelRail.mediumWidth;
    // A dragged width wins, but never squeezes the conversation below its floor beside a docked pane.
    final railRoom =
        width - AppSizes.rowPointer - dockedPane - kMinTranscriptWidth;
    return math.min(
      ref.watch(railWidthControllerProvider) ?? defaultRailWidth,
      math.max(defaultRailWidth, railRoom),
    );
  }

  Widget _scaffold(
    BuildContext context,
    WidgetRef ref,
    LayoutClass layout,
    _ShellFacts facts,
  ) {
    final selected = facts.selected;
    if (layout.showsBothPanes) {
      Widget wide(bool isDm) => _wideScaffold(context, ref, facts, isDm);
      return selected == null
          ? wide(false)
          : _withChannelKind(ref, selected, wide);
    }
    if (selected == null) return const Scaffold(body: ChannelRail());
    return _compactScaffold(context, ref, facts, selected);
  }

  Widget _wideScaffold(
    BuildContext context,
    WidgetRef ref,
    _ShellFacts facts,
    bool isDm,
  ) {
    final selected = facts.selected;
    return Scaffold(
      // Where no pane docks, the roster is the same end drawer compact uses.
      onEndDrawerChanged: (open) => endSelectionOnDrawerClose(ref, open),
      endDrawerEnableOpenDragGesture: !facts.canvasOpen,
      endDrawer: isDm || facts.membersFit || selected == null
          ? null
          : Drawer(
              width: AppMemberPane.width,
              child: SafeArea(child: AppMemberPane(channelId: selected)),
            ),
      body: Row(
        children: [
          // The rail at full or compact width, or neither, plus its handle; see railSlot's own doc.
          ...railSlot(
            context: context,
            expanded: ref.watch(channelRailExpandedProvider),
            canvasFullscreen: facts.canvasFullscreen,
            railWidth: facts.railWidth,
            dragging: ref.watch(railDraggingProvider),
          ),
          // Its own semantics node, or the modal barrier inside this pane's
          // navigator blocks everything painted before it, which is the
          // whole rail: no channel row, section or search field reached a
          // screen reader at all. The member pane paints after it and so
          // was never affected, which is what made this look like a rail bug.
          Expanded(
            child: Semantics(
              container: true,
              child: CallMiniPlayerHost(child: child),
            ),
          ),
          // Between the transcript and the roster (the Discord/Slack order); it and the roster never both take width, so the transcript loses at most one third pane.
          if (facts.threadFits)
            _ThreadPaneSlot(
              channelId: facts.openThread,
              requested: facts.showThread,
            ),
          // The pane comes from the edge it lives on: the slot's width
          // animates while the content slides in and fades (motion spec
          // 05). Hidden, the pane itself unmounts rather than sitting at
          // opacity zero - it fetches while built, and home_shell_test pins
          // exactly that - so the exit is the gap closing over the panel
          // duration while the entrance gets the full slide.
          if (facts.membersFit)
            // Once synced, unscoped until the row resolves, so no request names a channel not yet known to be visible.
            _MemberPaneSlot(
              channelId: facts.rosterPending ? null : selected,
              requested: facts.showMembers,
            ),
        ],
      ),
    );
  }

  Widget _compactScaffold(
    BuildContext context,
    WidgetRef ref,
    _ShellFacts facts,
    String channelId,
  ) {
    // No rail here to carry the strip, so a call elsewhere gets its own row.
    final (voiceState, voiceChannelId) = ref.watch(
      voiceControllerProvider.select((s) => (s.state, s.channelId)),
    );
    final showVoiceStrip =
        voiceState == VoiceSessionState.connected &&
        voiceChannelId != channelId;
    // Above the transcript while typing, so the composer sits on the keyboard.
    final keyboardUp = MediaQuery.viewInsetsOf(context).bottom > 0;
    return _withChannelKind(ref, channelId, (isDm) {
      // Only a DM's call pane replaces the header; the call-return affordances also set the provider for voice channels.
      final replacesHeader = facts.canvasOpen || (facts.dmCallOpen && isDm);
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
        body: Column(
          children: [
            const RailConnectionBar(),
            if (showVoiceStrip && keyboardUp)
              const VoiceStripIndicator(atTop: true),
            // Its own semantics node for the same reason the wide layout gives the pane one: the modal barrier inside this pane's navigator drops everything painted before it, which here is the connection bar.
            Expanded(
              child: Semantics(
                container: true,
                child: CallMiniPlayerHost(keyboardUp: keyboardUp, child: child),
              ),
            ),
            if (showVoiceStrip && !keyboardUp) const VoiceStripIndicator(),
          ],
        ),
      );
    });
  }

  // Binds the shared shortcut table's own keys, so a future remap reaches every one of these.
  Map<ShortcutActivator, VoidCallback> _shortcutBindings(
    BuildContext context,
    WidgetRef ref,
  ) {
    final quickSwitch = activatorFor(AppAction.quickSwitch);
    final focusComposer = activatorFor(AppAction.focusComposer);
    final openSettings = activatorFor(AppAction.openSettings);
    final openInbox = activatorFor(AppAction.openInbox);
    final nextChannel = activatorFor(AppAction.nextChannel);
    final previousChannel = activatorFor(AppAction.previousChannel);
    final muteCall = activatorFor(AppAction.toggleMuteCall);
    final deafenCall = activatorFor(AppAction.toggleDeafenCall);
    final cameraCall = activatorFor(AppAction.toggleCameraCall);
    final shareCall = activatorFor(AppAction.toggleShareCall);
    final leaveCall = activatorFor(AppAction.leaveCall);
    // Reads the row's handlers when a key arrives, so these are live only while a call row is on screen.
    CallShortcutHandlers? call() => ref.read(callShortcutHandlersProvider);
    return {
      if (quickSwitch != null) quickSwitch: () => openCommandPalette(context),
      if (focusComposer != null)
        focusComposer: () =>
            ref.read(composerFocusNodeProvider)?.requestFocus(),
      if (openSettings != null)
        openSettings: () => context.push(Routes.personalSettings),
      if (openInbox != null) openInbox: () => showInboxSheet(context),
      if (nextChannel != null)
        nextChannel: () => unawaited(_cycleChannel(context, ref, 1)),
      if (previousChannel != null)
        previousChannel: () => unawaited(_cycleChannel(context, ref, -1)),
      if (muteCall != null)
        muteCall: () => ref
            .read(pushToTalkGateProvider)
            .toggleMute(HoldSource.inWindow, () => call()?.toggleMute()),
      if (deafenCall != null)
        deafenCall: () => ref
            .read(pushToTalkGateProvider)
            .toggleDeafen(HoldSource.inWindow, () => call()?.toggleDeafen()),
      if (cameraCall != null) cameraCall: () => call()?.toggleCamera(),
      if (shareCall != null) shareCall: () => call()?.toggleShare(),
      if (leaveCall != null) leaveCall: () => call()?.leave(),
      ...serverSwitchBindings(ref),
    };
  }

  /// Moves selection to the channel [direction] (1 or -1) away from the one
  /// currently open, in [orderedChannels]' order, wrapping at either end.
  Future<void> _cycleChannel(
    BuildContext context,
    WidgetRef ref,
    int direction,
  ) async {
    final store = ref.read(storeProvider).valueOrNull;
    if (store == null) return;
    final ordered = orderedChannels(
      await store.allChannels(),
      await store.allCategories(),
    );
    if (ordered.isEmpty || !context.mounted) return;
    final current = selectedChannelId(context);
    final index = ordered.indexWhere((c) => c.id == current);
    final target = index == -1
        ? ordered.first
        : ordered[(index + direction) % ordered.length];
    context.go(Routes.channel(target.id));
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

/// What one build of the shell resolved once, shared by its scaffolds.
class _ShellFacts {
  const _ShellFacts({
    required this.selected,
    required this.canvasOpen,
    required this.dmCallOpen,
    required this.canvasFullscreen,
    required this.membersFit,
    required this.openThread,
    required this.threadFits,
    required this.showThread,
    required this.showMembers,
    required this.notFound,
    required this.rosterPending,
    required this.railWidth,
  });

  final String? selected;
  final bool canvasOpen;
  final bool dmCallOpen;
  final bool canvasFullscreen;
  final bool membersFit;
  final String? openThread;
  final bool threadFits;
  final bool showThread;
  final bool showMembers;
  final bool notFound;
  final bool rosterPending;
  final double railWidth;
}
