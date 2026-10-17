// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Unit tests for the predicate deciding whether a voice channel tap should
/// explicitly ask to (re)join; see `voice_channel_tap.dart`'s own doc for
/// why this cannot be left to `VoiceScreen`'s auto-join alone.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/features/voice/widgets/voice_channel_tap.dart';
import 'package:slimm_rtc/rtc.dart';

void main() {
  test('a fresh navigation elsewhere never double-fires the auto-join', () {
    expect(
      voiceChannelTapShouldRejoin(
        voice: const VoiceFlags(),
        channelId: 'ch-1',
        alreadySelected: false,
      ),
      isFalse,
    );
  });

  test(
    're-clicking the channel already open after a hang-up asks to rejoin',
    () {
      expect(
        voiceChannelTapShouldRejoin(
          voice: const VoiceFlags(
            channelId: 'ch-1',
            state: VoiceSessionState.idle,
          ),
          channelId: 'ch-1',
          alreadySelected: true,
        ),
        isTrue,
      );
    },
  );

  test('re-clicking after a failed join also asks to rejoin', () {
    expect(
      voiceChannelTapShouldRejoin(
        voice: const VoiceFlags(
          channelId: 'ch-1',
          state: VoiceSessionState.failed,
        ),
        channelId: 'ch-1',
        alreadySelected: true,
      ),
      isTrue,
    );
  });

  test(
    're-clicking while already connected there does not restart the call',
    () {
      expect(
        voiceChannelTapShouldRejoin(
          voice: const VoiceFlags(
            channelId: 'ch-1',
            state: VoiceSessionState.connected,
          ),
          channelId: 'ch-1',
          alreadySelected: true,
        ),
        isFalse,
      );
    },
  );

  test('re-clicking mid-connect does not stack a second join', () {
    expect(
      voiceChannelTapShouldRejoin(
        voice: const VoiceFlags(
          channelId: 'ch-1',
          state: VoiceSessionState.connecting,
        ),
        channelId: 'ch-1',
        alreadySelected: true,
      ),
      isFalse,
    );
  });

  test('re-clicking while a join is still awaiting its token does not '
      'restart it either', () {
    expect(
      voiceChannelTapShouldRejoin(
        voice: const VoiceFlags(channelId: 'ch-1', joining: true),
        channelId: 'ch-1',
        alreadySelected: true,
      ),
      isFalse,
    );
  });

  test('selected but connected to a different channel still asks to join '
      'this one', () {
    expect(
      voiceChannelTapShouldRejoin(
        voice: const VoiceFlags(
          channelId: 'ch-2',
          state: VoiceSessionState.connected,
        ),
        channelId: 'ch-1',
        alreadySelected: true,
      ),
      isTrue,
    );
  });
}
