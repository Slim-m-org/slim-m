// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A DM's call pane: the caller waiting on a ring, the call itself, the pane
/// after a decline, and the transcript that keeps the record of an unanswered
/// call.
///
/// PNGs are written only under SLIMM_UI_SNAPSHOTS=1; otherwise this asserts
/// each pane lays out without overflow.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/voice/providers/dm_call_ring_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/screens/dm_call_pane.dart'
    show dmCallOpenProvider;
import 'package:slimm_rtc/rtc.dart';

import '../features/voice/voice_snapshot_fixtures.dart'
    show AttemptedJoinVoiceController, dmChannelId;
import '../ui_snapshot_support.dart';
import 'ui_review_voice_support.dart';

VoiceState _call(String channel, List<VoiceParticipant> people) => VoiceState(
  channelId: channel,
  state: VoiceSessionState.connected,
  connectedAt: callStartedAgo(const Duration(minutes: 6, seconds: 12)),
  participants: people,
);

final _dmAlone = _call(dmChannelId, [
  reviewPerson('user-nick', 'Nick', local: true),
]);

final _dmTogether = _call(dmChannelId, [
  reviewPerson('user-nick', 'Nick', local: true),
  reviewPerson('user-ada', 'Ada Lovelace', speaking: true),
]);

api.Message _record(int seq, api.CallOutcome outcome, {String? by, int? ms}) =>
    api.Message(
      id: 'mrec-$seq',
      channelId: dmChannelId,
      authorId: by ?? 'user-nick',
      authorDisplayName: by == 'user-ada' ? 'Ada Lovelace' : 'Nick',
      seq: 10 + seq,
      content: '',
      createdAt: 1753600000000 + (300 + seq) * 60000,
      editedAt: null,
      call: api.CallRecord(
        outcome: outcome,
        callerId: by ?? 'user-nick',
        durationMs: ms,
      ),
    );

final _records = [
  ...fixtureMessages,
  _record(1, api.CallOutcome.answered, ms: 252000),
  _record(2, api.CallOutcome.declined),
  _record(3, api.CallOutcome.timedOut),
  _record(4, api.CallOutcome.timedOut, by: 'user-ada'),
];

void main() {
  setUpAll(loadRealFonts);

  for (final viewport in reviewViewports) {
    testWidgets('dm call pane, ringing, at $viewport', (tester) async {
      await renderReview(
        tester,
        surface: 'voice-dm-call-pane',
        state: 'ringing',
        viewport: viewport,
        route: '/channels/$dmChannelId',
        overrides: [
          dmCallOpenProvider.overrideWith((ref) => dmChannelId),
          reviewVoice(_dmAlone),
          dmCallRingControllerProvider.overrideWith(
            (ref) => PinnedRing(
              ref,
              const DmCallRingState(
                outgoing: OutgoingDmCallRing(
                  channelId: dmChannelId,
                  ringId: 'ring-1',
                ),
              ),
            ),
          ),
        ],
      );
    });

    testWidgets('dm call pane, connected, at $viewport', (tester) async {
      await renderReview(
        tester,
        surface: 'voice-dm-call-pane',
        state: 'connected',
        viewport: viewport,
        route: '/channels/$dmChannelId',
        overrides: [
          dmCallOpenProvider.overrideWith((ref) => dmChannelId),
          reviewVoice(_dmTogether),
        ],
      );
    });

    testWidgets('dm call pane, declined, at $viewport', (tester) async {
      await renderReview(
        tester,
        surface: 'voice-dm-call-pane',
        state: 'declined',
        viewport: viewport,
        route: '/channels/$dmChannelId',
        settleJoinTransition: true,
        overrides: [
          dmCallOpenProvider.overrideWith((ref) => dmChannelId),
          voiceControllerProvider.overrideWith(
            (ref) => AttemptedJoinVoiceController(
              ref,
              const VoiceState(channelId: dmChannelId),
            ),
          ),
        ],
      );
    });

    testWidgets('dm call pane, no answer, at $viewport', (tester) async {
      await renderReview(
        tester,
        surface: 'voice-dm-call-pane',
        state: 'no-answer',
        viewport: viewport,
        route: '/channels/$dmChannelId',
        messages: _records,
        overrides: [reviewVoice(const VoiceState())],
      );
    });
  }
}
