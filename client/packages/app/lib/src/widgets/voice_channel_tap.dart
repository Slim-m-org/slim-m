// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether tapping a voice channel row should explicitly ask
/// [VoiceController] to (re)join, rather than leaving it to
/// `VoiceScreen`'s own arrival-triggered auto-join.
///
/// `VoiceScreen` auto-joins only on a genuinely fresh arrival
/// (`voice_screen.dart`'s own doc comment), and its "already attempted"
/// guard resets only when the channel id it is showing changes - never on a
/// rebuild that leaves the id the same, since most such rebuilds are
/// incidental (an unrelated channel renamed elsewhere) rather than a real
/// return visit, and resetting on every one of those would silently
/// reconnect a call the caller had explicitly left. That leaves a real gap:
/// re-clicking the exact channel already open, after hanging up or a failed
/// join, is indistinguishable from an incidental rebuild to `VoiceScreen`
/// itself, so it never re-attempts and the caller is stuck looking at the
/// rejoin screen - which reads exactly like the join lobby this client no
/// longer has. A tap is unambiguous intent in a way a rebuild is not, so the
/// row asks directly instead of depending on one.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_rtc/rtc.dart';

import '../providers/voice_controller.dart';
import '../providers/voice_flags.dart';
import '../routing/routes.dart';

/// What opening a voice channel from the rail does: navigate, then rejoin on
/// a re-click. Shared by the row's tap and its menu's "Open channel", which
/// otherwise diverge on a channel that is already the open one.
void openVoiceChannel(
  BuildContext context,
  ProviderContainer container,
  String channelId, {
  required bool alreadySelected,
}) {
  context.go(Routes.channel(channelId));
  if (voiceChannelTapShouldRejoin(
    voice: container.read(voiceFlagsProvider),
    channelId: channelId,
    alreadySelected: alreadySelected,
  )) {
    container.read(voiceControllerProvider.notifier).join(channelId);
  }
}

/// [alreadySelected] is whether this row's channel was already the one on
/// screen the instant it was tapped - a re-click, not a fresh navigation
/// elsewhere, which `VoiceScreen`'s own auto-join already covers and this
/// must not duplicate into a redundant second join.
///
/// Takes [VoiceFlags], not the full state: every field this reads
/// (`channelId`, `state`, `joining`) already lives there, and the roster has
/// nothing to say about whether a re-click should rejoin.
bool voiceChannelTapShouldRejoin({
  required VoiceFlags voice,
  required String channelId,
  required bool alreadySelected,
}) {
  if (!alreadySelected) return false;
  if (voice.channelId != channelId) return true;
  return voice.state != VoiceSessionState.connected &&
      voice.state != VoiceSessionState.connecting &&
      !voice.joining;
}
