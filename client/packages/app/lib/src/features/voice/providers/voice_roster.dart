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

import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../providers/app_lifecycle.dart';
import '../../../providers/live_events.dart';
import '../../../providers/providers.dart';
import '../../../providers/sync_controller.dart';

/// How often an unjoined voice channel's roster is re-fetched. A real round
/// trip to the server's SFU, not a cheap read, so this stays well clear of a
/// per-frame or per-rebuild cost.
const voiceRosterPollInterval = Duration(seconds: 15);

/// The poll interval while the socket is live: events already nudge a refetch,
/// so the poll is only a backstop.
const voiceRosterLiveInterval = Duration(seconds: 60);

/// The longest a failing poll backs off to.
const voiceRosterMaxBackoff = Duration(minutes: 2);

/// Whether the live socket is up, so events can be trusted to nudge the roster.
final voiceRosterSocketLiveProvider = Provider<bool>(
  (ref) => ref.watch(syncControllerProvider) == SyncStatus.live,
);

/// The wait before the next poll after [failures] unbroken failures.
Duration voiceRosterDelay({required bool live, required int failures}) {
  if (failures > 0) {
    final factor = 1 << (failures - 1).clamp(0, 10);
    final backoff = voiceRosterPollInterval * factor;
    return backoff > voiceRosterMaxBackoff ? voiceRosterMaxBackoff : backoff;
  }
  return live ? voiceRosterLiveInterval : voiceRosterPollInterval;
}

/// Consecutive non-`NotConfigured` failures before this stops treating the
/// SFU as merely having a bad tick and surfaces it as an [AsyncValue] error
/// instead - the [AsyncValue.hasError] a caller can check to tell "have not
/// heard back yet" apart from "have been asking and it keeps failing", per
/// `docs/reports/screen-review/voice.md`'s own request for a distinct state
/// here rather than staying silent forever. One flaky tick is not this; a
/// short unbroken run of them is.
const persistentRosterFailureThreshold = 3;

/// When [channelId]'s call started by the server's clock, as of the last
/// roster poll; null for an empty room or a server that does not say.
final voiceRosterStartProvider = StateProvider.family<DateTime?, String>(
  (ref, channelId) => null,
);

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
      final poller = _RosterPoller(
        client,
        channelId,
        controller,
        isLive: () => ref.read(voiceRosterSocketLiveProvider),
        isVisible: () => isWindowVisible(ref.read(appLifecycleProvider)),
        onCallStart: (start) =>
            ref.read(voiceRosterStartProvider(channelId).notifier).state =
                start,
      );
      unawaited(poller.tick());

      ref.listen<AppLifecycleState>(appLifecycleProvider, (was, now) {
        final visible = isWindowVisible(now);
        if (was != null && isWindowVisible(was) == visible) return;
        if (visible) {
          unawaited(poller.tick());
        } else {
          poller.pause();
        }
      });

      final liveSub = ref.read(liveEventsProvider).listen((event) {
        if (_eventChannelId(event) == channelId && poller.isVisible()) {
          unawaited(poller.tick());
        }
      });

      ref.onDispose(() {
        poller.dispose();
        unawaited(liveSub.cancel());
        unawaited(controller.close());
      });

      return controller.stream;
    });

String? _eventChannelId(api.ServerEvent event) => switch (event) {
  api.VoiceActivityChanged(:final channelId) => channelId,
  api.VoiceParticipantJoined(:final channelId) => channelId,
  api.VoiceParticipantLeft(:final channelId) => channelId,
  api.VoiceScreenShareChanged(:final channelId) => channelId,
  _ => null,
};

class _RosterPoller {
  _RosterPoller(
    this._client,
    this._channelId,
    this._controller, {
    required this.isLive,
    required this.isVisible,
    required this.onCallStart,
  });

  final api.SlimmApi _client;
  final String _channelId;
  final StreamController<List<api.VoiceRosterParticipant>> _controller;
  final bool Function() isLive;
  final bool Function() isVisible;
  final void Function(DateTime? start) onCallStart;
  Timer? _timer;
  bool _stopped = false;
  int _consecutiveFailures = 0;
  bool _inFlight = false;
  bool _askedAgain = false;

  Future<void> _poll() async {
    try {
      final snapshot = await _client.voiceRosterSnapshot(_channelId);
      final roster = snapshot.participants;
      _consecutiveFailures = 0;
      final selfId = _client.session.tokens?.userId;
      final visible = selfId == null
          ? roster
          : roster.where((p) => p.userId != selfId).toList(growable: false);
      if (_controller.isClosed) return;
      final age = snapshot.callAge;
      onCallStart(
        age == null || roster.isEmpty ? null : DateTime.now().subtract(age),
      );
      _controller.add(visible);
    } on api.NotConfiguredException catch (error, stack) {
      api.AppLog.swallowed(
        api.LogTag.voice,
        'Could not refresh who is in the call; will try again',
        error,
        stack,
      );
      dispose();
      unawaited(_controller.close());
    } on api.ApiException catch (e) {
      // Unavailable, forbidden, rate-limited: try again, unless this has gone on long enough to say so.
      _consecutiveFailures++;
      if (_consecutiveFailures >= persistentRosterFailureThreshold &&
          !_controller.isClosed) {
        _controller.addError(e);
      }
    }
  }

  // Single-flight: a nudge mid-poll re-asks once after it, so answers cannot reorder.
  Future<void> tick() async {
    _timer?.cancel();
    if (_inFlight) {
      _askedAgain = true;
      return;
    }
    _inFlight = true;
    try {
      await _poll();
    } finally {
      _inFlight = false;
    }
    if (_askedAgain && !_controller.isClosed) {
      _askedAgain = false;
      await tick();
      return;
    }
    _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    if (_stopped || !isVisible() || _controller.isClosed) return;
    final delay = voiceRosterDelay(
      live: isLive(),
      failures: _consecutiveFailures,
    );
    _timer = Timer(delay, () => unawaited(tick()));
  }

  /// Stops asking while nothing is in front of the user; focus resumes with a tick.
  void pause() => _timer?.cancel();

  void dispose() {
    _stopped = true;
    _timer?.cancel();
  }
}
