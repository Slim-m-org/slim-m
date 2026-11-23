// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The shell's keyboard shortcuts, bound from the shared shortcut table's own
/// keys so a remap reaches every one of them.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_platform/platform.dart';

import '../features/accounts/widgets/account_shortcuts.dart';
import '../features/channels/widgets/channel_grouping.dart';
import '../features/channels/widgets/channel_rail.dart' show selectedChannelId;
import '../features/channels/widgets/rail_notes_button.dart';
import '../features/composer/providers/composer_focus.dart';
import '../features/messages/widgets/inbox_sheet.dart';
import '../features/palette/widgets/command_palette.dart';
import '../features/screen_overlay/widgets/call_overlay_shortcut.dart';
import '../features/voice/providers/call_mark_actions.dart';
import '../features/voice/providers/call_shortcut_registry.dart';
import '../features/voice/providers/push_to_talk_gate.dart';
import '../providers/providers.dart';
import '../routing/routes.dart';

/// While [previewing] a role, nothing that navigates or shows the caller's own content is bound.
Map<ShortcutActivator, VoidCallback> shellShortcutBindings(
  BuildContext context,
  WidgetRef ref, {
  required bool previewing,
}) {
  final quickSwitch = activatorFor(AppAction.quickSwitch);
  final focusComposer = activatorFor(AppAction.focusComposer);
  final openSettings = activatorFor(AppAction.openSettings);
  final openInbox = activatorFor(AppAction.openInbox);
  final notes = activatorFor(AppAction.openNotes);
  final nextChannel = activatorFor(AppAction.nextChannel);
  final previousChannel = activatorFor(AppAction.previousChannel);
  final muteCall = activatorFor(AppAction.toggleMuteCall);
  final deafenCall = activatorFor(AppAction.toggleDeafenCall);
  final cameraCall = activatorFor(AppAction.toggleCameraCall);
  final shareCall = activatorFor(AppAction.toggleShareCall);
  final leaveCall = activatorFor(AppAction.leaveCall);
  final markCall = activatorFor(AppAction.markCallMoment);
  // Reads the row's handlers when a key arrives, so these are live only while a call row is on screen.
  CallShortcutHandlers? call() => ref.read(callShortcutHandlersProvider);
  return {
    if (!previewing) ...{
      if (quickSwitch != null) quickSwitch: () => openCommandPalette(context),
      if (focusComposer != null)
        focusComposer: () =>
            ref.read(composerFocusNodeProvider)?.requestFocus(),
      if (openInbox != null) openInbox: () => showInboxSheet(context),
      if (notes != null)
        notes: () => unawaited(
          openNotes(
            ProviderScope.containerOf(context, listen: false),
            GoRouter.of(context),
          ),
        ),
      if (nextChannel != null)
        nextChannel: () => unawaited(_cycleChannel(context, ref, 1)),
      if (previousChannel != null)
        previousChannel: () => unawaited(_cycleChannel(context, ref, -1)),
    },
    if (openSettings != null)
      openSettings: () => context.push(Routes.personalSettings),
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
    if (markCall != null)
      markCall: () => ref
          .read(pushToTalkGateProvider)
          .markCall(
            HoldSource.inWindow,
            () => unawaited(ref.read(callMarkActionsProvider).mark()),
          ),
    ...serverSwitchBindings(ref),
    ...callOverlayShortcutBindings(ref),
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
  // From a channel the rail does not list (Notes), next starts at the top and previous at the bottom.
  final target = index == -1
      ? (direction > 0 ? ordered.first : ordered.last)
      : ordered[(index + direction) % ordered.length];
  context.go(Routes.channel(target.id));
}
