// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Who is in a voice channel the caller has not joined, kept current by
/// polling, now nudged promptly by a live event rather than waiting out the
/// interval.
///
/// `autoDispose` and keyed per channel, so this only ever polls a channel a
/// rail row is actually rendering right now; scrolling one away or switching
/// servers cancels its timer with it. Ordinary rebuilds of that row do not
/// restart the poll: Riverpod caches the stream by channel id, so only the
/// interval below governs the network's steady-state cost.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import 'live_events.dart';
import 'providers.dart';

/// How often an unjoined voice channel's roster is re-fetched. A real round
/// trip to the server's SFU, not a cheap read, so this stays well clear of a
/// per-frame or per-rebuild cost.
const voiceRosterPollInterval = Duration(seconds: 15);

/// Consecutive non-`NotConfigured` failures before this stops treating the
/// SFU as merely having a bad tick and surfaces it as an [AsyncValue] error
/// instead - the [AsyncValue.hasError] a caller can check to tell "have not
/// heard back yet" apart from "have been asking and it keeps failing", per
/// `docs/reports/screen-review/voice.md`'s own request for a distinct state
/// here rather than staying silent forever. One flaky tick is not this; a
/// short unbroken run of them is.
const persistentRosterFailureThreshold = 3;

/// Who the server reports as connected to [channelId]'s voice room.
///
/// A hidden participant is never in this list for any viewer but themselves;
/// the server enforces that, not this provider. An empty, present list means
/// a checked, genuinely empty room; [AsyncLoading] means not known yet, and
/// those two must not be rendered the same way.
///
/// This client's own identity is dropped from every answer, always. Whether
/// this client is in the call is `voiceControllerProvider`'s job, driven by
/// the live session, never this roster's: the SFU only reaps a dead
/// connection on its own schedule, and the heartbeat sweep (see
/// `crates/slimm-server/src/voice/heartbeat.rs`) is a bounded backstop for
/// that, not an instant one, so a client relaunched moments after being
/// killed can poll this and still see the identity it just lost. Rendering
/// that back as "you are in this call" is exactly the bug filtering it out
/// here fixes; see `voice_roster_test.dart` and
/// `channel_rail_voice_roster_test.dart`.
///
/// A channel with no voice configured closes the stream on its first answer
/// rather than polling a server that will only ever say the same thing
/// again, which is why [AsyncLoading] is also what a text-only deployment
/// settles on forever. A single transient failure - unreachable SFU, a blip
/// in authentication - adds nothing this tick and simply waits for the next
/// one, so the last roster this client actually saw stays on screen instead
/// of being cleared to looking empty. [persistentRosterFailureThreshold]
/// unbroken failures in a row is no longer "this tick's bad luck" though,
/// and surfaces as [AsyncValue.hasError] - a caller can check that
/// alongside [AsyncValue.valueOrNull] (which the error keeps, if there was
/// one) to tell a genuinely broken poll apart from one that just has not
/// answered yet.
///
/// `voice.activity` (`api.VoiceActivityChanged`) refreshes this promptly
/// rather than leaving a join or hangup to surface on the next poll tick, up
/// to [voiceRosterPollInterval] later. It names no participant - see the
/// event's own doc comment - so this is a nudge to re-ask, exactly what a
/// stray or duplicate frame already costs nothing extra to trigger.
///
/// `voice.participant_joined`/`_left`/`screen_share_changed` nudge the same
/// way, on deployments with LiveKit's webhook configured (see
/// docs/decisions/0032-voice-participant-webhooks.md); a re-poll rather than
/// a targeted merge, since it is the one code path that already has to
/// handle the appear-offline filter and the persistent-failure state above.
final voiceRosterProvider = StreamProvider.autoDispose
    .family<List<api.VoiceRosterParticipant>, String>((ref, channelId) {
      final client = ref.watch(apiProvider);
      final controller = StreamController<List<api.VoiceRosterParticipant>>();
      var consecutiveFailures = 0;

      Future<void> poll(Timer? self) async {
        try {
          final roster = await client.voiceRoster(channelId);
          consecutiveFailures = 0;
          final selfId = client.session.tokens?.userId;
          final visible = selfId == null
              ? roster
              : roster.where((p) => p.userId != selfId).toList(growable: false);
          if (!controller.isClosed) controller.add(visible);
        } on api.NotConfiguredException {
          self?.cancel();
          unawaited(controller.close());
        } on api.ApiException catch (e) {
          // Unavailable, forbidden, rate-limited: try again, unless this has gone on long enough to say so.
          consecutiveFailures++;
          if (consecutiveFailures >= persistentRosterFailureThreshold &&
              !controller.isClosed) {
            controller.addError(e);
          }
        }
      }

      var inFlight = false;
      var askedAgain = false;

      // Single-flight: a nudge mid-poll re-asks once after it, so answers cannot reorder.
      Future<void> tick(Timer? self) async {
        if (inFlight) {
          askedAgain = true;
          return;
        }
        inFlight = true;
        try {
          await poll(self);
        } finally {
          inFlight = false;
        }
        if (askedAgain && !controller.isClosed) {
          askedAgain = false;
          await tick(self);
        }
      }

      late final Timer timer;
      timer = Timer.periodic(voiceRosterPollInterval, (_) => tick(timer));
      unawaited(tick(timer));

      final liveSub = ref.read(liveEventsProvider).listen((event) {
        final eventChannelId = switch (event) {
          api.VoiceActivityChanged(:final channelId) => channelId,
          api.VoiceParticipantJoined(:final channelId) => channelId,
          api.VoiceParticipantLeft(:final channelId) => channelId,
          api.VoiceScreenShareChanged(:final channelId) => channelId,
          _ => null,
        };
        if (eventChannelId == channelId) {
          unawaited(tick(timer));
        }
      });

      ref.onDispose(() {
        timer.cancel();
        unawaited(liveSub.cancel());
        unawaited(controller.close());
      });

      return controller.stream;
    });
