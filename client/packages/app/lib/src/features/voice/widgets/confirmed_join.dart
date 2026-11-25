// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The join both a voice channel's screen and a canvas channel's bar run: the transcription notice, the "open on another device" check, then the join.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_rtc/rtc.dart';

import '../providers/voice_elsewhere.dart';
import '../providers/voice_flags.dart';
import 'transcription_notice.dart';

/// Whether [voice] describes a live call somewhere other than [channelId]:
/// the one case an arrival still has to ask about before joining.
///
/// `voice.joining` covers the window a join has already claimed
/// [VoiceState.channelId] but has not yet moved [VoiceState.state] off
/// whatever it was before (the token round trip in
/// [VoiceController.join] carries no state transition of its own) - without
/// it, an arrival during that window read the controller as idle and
/// auto-joined a second call with no switch prompt at all.
bool callBusyElsewhere(VoiceFlags voice, String channelId) =>
    voice.channelId != null &&
    voice.channelId != channelId &&
    (voice.state == VoiceSessionState.connected ||
        voice.state == VoiceSessionState.connecting ||
        voice.joining);

/// How the screen that asked for a join shows its progress and its one question.
class ConfirmedJoinHost {
  const ConfirmedJoinHost({
    required this.dropped,
    required this.checking,
    required this.askJoinHere,
  });

  /// True once the ask is stale or its screen is gone, which ends the join wherever it stands.
  final bool Function() dropped;

  /// Whether the pre-join check is in flight.
  final ValueChanged<bool> checking;

  /// The call is open on another device, in [elsewhere]; [proceed] moves it here.
  final void Function(String elsewhere, VoidCallback proceed) askJoinHere;
}

/// Runs [join] now, after the one-time transcription notice, or after "Join here" when it would move a call open on another device.
/// A call that came up meanwhile, here or elsewhere, wins over the join.
Future<void> runConfirmedJoin(
  BuildContext context,
  WidgetRef ref, {
  required String channelId,
  required bool isDm,
  required Future<void> Function() join,
  required ConfirmedJoinHost host,
}) async {
  if (!isDm && !await confirmTranscriptionNotice(context, ref)) return;
  if (host.dropped()) return;
  host.checking(true);
  final String? elsewhere;
  try {
    elsewhere = await ref.read(voiceElsewhereCheckProvider)(channelId);
  } finally {
    if (!host.dropped()) host.checking(false);
  }
  final voice = ref.read(voiceFlagsProvider);
  if (host.dropped() || voice.inCallStageFor(channelId)) return;
  if (callBusyElsewhere(voice, channelId)) return;
  if (elsewhere == null) return join();
  host.askJoinHere(elsewhere, () => unawaited(join()));
}

/// The words of the two questions a join can ask, shared by the voice screen's prompts and the canvas bar's dialogs.
const switchCallTitle = 'Already in a call';
const switchCallMessage =
    "You're in a call somewhere else. Switching leaves it and "
    'joins this one instead.';
const switchCallConfirm = 'Switch to this call';

/// Where a call open on another device is, for the prompt that moves it here.
String joinHereMessage(String? name) {
  final where = name == null || name.isEmpty ? 'a call' : name;
  return "You're in $where on another device. Joining here moves your "
      'call to this device.';
}

const joinHereTitle = 'In a call on another device';
const joinHereConfirm = 'Join here';
