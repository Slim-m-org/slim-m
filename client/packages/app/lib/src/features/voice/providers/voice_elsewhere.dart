// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether this account is already in a call on another device.
///
/// The SFU identity is the account's user id, not a device, so the roster
/// cannot say which device is in the call; it can only say the account is.
/// That is enough to warn before a join moves the call here.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_rtc/rtc.dart';

import '../../../providers/providers.dart';
import 'voice_flags.dart';
import 'voice_roster.dart';
import 'voice_state.dart';

/// How long a rail roster's sighting of this account stays believable.
const voiceSelfSeenTtl = Duration(seconds: 90);

/// The channel this account is in on another device, or null when joining
/// would not move a call.
///
/// Null whenever this device has a call of its own or only just hung up: the
/// SFU reaps a dead connection lazily, so the roster can still list this
/// device itself for a moment.
typedef ElsewhereCheck = Future<String?> Function(String channelId);

final voiceElsewhereCheckProvider = Provider<ElsewhereCheck>((ref) {
  return (channelId) async {
    final voice = ref.read(voiceFlagsProvider);
    if (_hasCallHere(voice) || _justLeft(voice)) return null;
    final now = DateTime.now();
    final seen = ref.read(voiceSelfSeenProvider);
    final polled = seen.entries.where(
      (e) => now.difference(e.value) < voiceSelfSeenTtl,
    );
    if (polled.any((e) => e.key == channelId)) return channelId;
    final target = await _targetListsSelf(ref, channelId);
    if (target) return channelId;
    return polled.isEmpty ? null : polled.first.key;
  };
});

bool _hasCallHere(VoiceFlags voice) =>
    voice.channelId != null &&
    (voice.joining ||
        voice.rejoining ||
        voice.state == VoiceSessionState.connected ||
        voice.state == VoiceSessionState.connecting);

bool _justLeft(VoiceFlags voice) {
  final at = voice.justLeftAt;
  return at != null &&
      DateTime.now().difference(at) < VoiceState.rejoinGuardWindow;
}

Future<bool> _targetListsSelf(Ref ref, String channelId) async {
  final client = ref.read(apiProvider);
  final selfId = client.session.tokens?.userId;
  if (selfId == null) return false;
  try {
    final roster = await client.voiceRoster(channelId);
    return roster.any((p) => p.userId == selfId);
  } on api.ApiException catch (error, stack) {
    api.AppLog.swallowed(
      api.LogTag.voice,
      'Could not check for a call on another device',
      error,
      stack,
    );
    return false;
  }
}

/// A re-click on the open voice channel, for its screen to act on so the
/// join goes through the same confirmation as an arrival.
final voiceRejoinRequestProvider = StateProvider<({String channelId, int n})?>(
  (ref) => null,
);
