// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `/tts`: speak a line into the call you are in, and post it to the call chat.
///
/// The server speaks the line; the composer then sends the same text as an
/// ordinary message, so replies, slow mode and retries behave as they do for any
/// message. A refusal leaves the typed command in the field and reports through
/// `fail`, which the composer shows inline.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart'
    show
        ApiException,
        ForbiddenException,
        NotConfiguredException,
        NotFoundException,
        RateLimitedException;
import 'package:slimm_rtc/rtc.dart' show VoiceSessionState;

import '../../../api_failure.dart';
import '../../voice/providers/voice_controller.dart';
import '../providers/tts_speak.dart';

/// The line a `/tts` message asks to speak (empty for a bare `/tts`), or null
/// when the text is anything else.
String? ttsCommandLine(String text) {
  final match = RegExp(
    r'^/tts(?:\s+(.*))?$',
    dotAll: true,
  ).firstMatch(text.trim());
  return match == null ? null : (match.group(1) ?? '').trim();
}

/// Whether the caller is connected to the call of [channelId], where `/tts` works.
bool inCallOf(WidgetRef ref, String channelId) {
  final voice = ref.read(voiceControllerProvider);
  return voice.state == VoiceSessionState.connected &&
      voice.channelId == channelId;
}

/// Speaks a `/tts` line and leaves just its text in [controller] for the
/// ordinary send that follows. True when the send should go on: the text was
/// not `/tts`, or its line was accepted.
Future<bool> speakComposedTts({
  required WidgetRef ref,
  required String channelId,
  required TextEditingController controller,
  required void Function(String message) fail,
}) async {
  final line = ttsCommandLine(controller.text);
  if (line == null) return true;
  if (line.isEmpty) {
    fail('Type what to say after /tts.');
    return false;
  }
  if (!inCallOf(ref, channelId)) {
    fail('Join the call in this channel to use /tts.');
    return false;
  }
  try {
    await ref.read(ttsSpeakProvider)(channelId, line);
  } on ApiException catch (e) {
    fail(ttsFailureMessage(e));
    return false;
  }
  controller.text = line;
  return true;
}

/// The sentence a refused `/tts` shows.
String ttsFailureMessage(ApiException e) => switch (e) {
  NotConfiguredException() => 'Text to speech is not set up on this server.',
  NotFoundException() => 'This server does not support /tts yet.',
  RateLimitedException() => 'Slow down: /tts takes a line every few seconds.',
  ForbiddenException() =>
    "You cannot speak in this call, so /tts can't either.",
  _ => describeApiFailure('speak that line', e),
};
