// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where the server's list of who is in this call disagrees with what this device's call delivered.
///
/// The stage lists only who the call's own signalling socket reported. That
/// socket crosses Cloudflare, and on 2026-11-18 it stalled for minutes while
/// the API kept working, so one side saw an empty call that the server knew
/// was not. The server's list is read over the API and compared here.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_rtc/rtc.dart';

import '../../../providers/live_events.dart';
import '../../../providers/providers.dart';
import '../../../providers/sync_controller.dart';
import 'voice_flags.dart';

/// How long a disagreement must last, across two readings, before it shows.
///
/// Clear of LiveKit's 3 s batching of a joiner who publishes nothing and of
/// the 5 s leave hold, so an ordinary join or leave never flashes it.
const kRosterGapConfirm = Duration(seconds: 8);

/// How often the server's list is read while in a call, beside the nudges its events give.
const kRosterGapPoll = Duration(seconds: 10);

/// How long a shown gap may stand on the last good reading while reads fail.
///
/// A failed read is no evidence either way, so past this the gap is dropped
/// rather than left naming someone who may have left.
const kRosterGapStale = Duration(seconds: 15);

/// Someone the server lists in the call whom this device's call has not delivered.
typedef PendingPeer = ({String id, String name});

class CallRosterGap {
  const CallRosterGap({this.connecting = const [], this.selfMissing = false});

  static const none = CallRosterGap();

  /// The server lists them, this device's call does not.
  final List<PendingPeer> connecting;

  /// The server does not list this device in the call it is in.
  final bool selfMissing;

  @override
  bool operator ==(Object other) =>
      other is CallRosterGap &&
      other.selfMissing == selfMissing &&
      listEquals(other.connecting, connecting);

  @override
  int get hashCode => Object.hash(selfMissing, Object.hashAll(connecting));
}

/// Turns readings of the server's list into a gap that only shows once it holds.
class RosterGapTracker {
  final _since = <String, DateTime>{};
  DateTime? _selfMissingSince;

  /// [shown] is everyone else the stage lists; [selfId] is this account.
  CallRosterGap observe({
    required List<api.VoiceRosterParticipant> server,
    required Set<String> shown,
    required String? selfId,
    required DateTime now,
  }) {
    final missing = [
      for (final p in server)
        if (p.userId != selfId && !shown.contains(p.userId)) p,
    ];
    final ids = {for (final p in missing) p.userId};
    _since.removeWhere((id, _) => !ids.contains(id));
    for (final id in ids) {
      _since.putIfAbsent(id, () => now);
    }
    final listed = server.any((p) => p.userId == selfId && p.thisDevice);
    if (selfId == null || listed) {
      _selfMissingSince = null;
    } else {
      _selfMissingSince ??= now;
    }
    bool held(DateTime since) => now.difference(since) >= kRosterGapConfirm;
    return CallRosterGap(
      connecting: [
        for (final p in missing)
          if (held(_since[p.userId]!)) (id: p.userId, name: p.displayName),
      ],
      selfMissing: _selfMissingSince != null && held(_selfMissingSince!),
    );
  }

  /// Forgets every reading, so the next one starts its confirmation afresh.
  void reset() {
    _since.clear();
    _selfMissingSince = null;
  }

  /// Drops a reading that no longer applies, so the stage stops waiting on the next poll.
  CallRosterGap forget(CallRosterGap gap, Set<String> shown) => CallRosterGap(
    connecting: [
      for (final p in gap.connecting)
        if (!shown.contains(p.id)) p,
    ],
    selfMissing: gap.selfMissing,
  );
}

/// The clock the gap is measured on; a test moves it by hand.
final rosterGapClockProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);

/// The live gap for the call this device is in; [CallRosterGap.none] outside one.
final callRosterGapProvider =
    NotifierProvider.autoDispose<CallRosterGapNotifier, CallRosterGap>(
      CallRosterGapNotifier.new,
    );

class CallRosterGapNotifier extends AutoDisposeNotifier<CallRosterGap> {
  // Every roster change re-derives the gap; only a different one may rebuild the stage.
  @override
  bool updateShouldNotify(CallRosterGap previous, CallRosterGap next) =>
      previous != next;

  @override
  CallRosterGap build() {
    final channelId = ref.watch(
      voiceFlagsProvider.select(
        (v) => v.state == VoiceSessionState.connected ? v.channelId : null,
      ),
    );
    if (channelId == null) return CallRosterGap.none;
    final client = ref.watch(apiProvider);
    final clock = ref.watch(rosterGapClockProvider);
    // Per connected stretch: a rejoin must confirm afresh, not inherit the old clock.
    final tracker = RosterGapTracker();
    Timer? timer;
    Timer? stale;
    var gone = false;
    var inFlight = false;

    Set<String> shown() => {
      for (final p in ref.read(voiceParticipantsProvider))
        if (!p.isLocal) p.identity,
    };

    void dropStale() {
      if (gone) return;
      tracker.reset();
      state = CallRosterGap.none;
    }

    void observe(List<api.VoiceRosterParticipant> server) {
      stale?.cancel();
      stale = Timer(kRosterGapStale, dropStale);
      state = tracker.observe(
        server: server,
        shown: shown(),
        selfId: client.session.tokens?.userId,
        now: clock(),
      );
    }

    Future<void> poll() async {
      if (inFlight || gone) return;
      timer?.cancel();
      inFlight = true;
      try {
        final server = (await client.voiceRosterSnapshot(
          channelId,
        )).participants;
        if (!gone) observe(server);
      } on Object catch (error, stack) {
        // No reading at all: the last one ages until [kRosterGapStale] drops it.
        api.AppLog.swallowed(
          api.LogTag.voice,
          'Could not compare the call with the server',
          error,
          stack,
        );
      } finally {
        inFlight = false;
      }
      if (!gone) timer = Timer(kRosterGapPoll, () => unawaited(poll()));
    }

    ref.listen(voiceParticipantsProvider, (_, _) {
      if (!gone) state = tracker.forget(state, shown());
    });

    // Only an events feed already running; starting the sync machinery is not this check's job.
    final events = ref.exists(syncControllerProvider)
        ? ref.read(liveEventsProvider).listen((event) {
            if (_channelOf(event) == channelId) unawaited(poll());
          })
        : null;
    // Stops at once when the stage goes, not a frame later when autoDispose gets to it.
    ref.onCancel(() => timer?.cancel());
    ref.onResume(() => unawaited(poll()));
    ref.onDispose(() {
      gone = true;
      timer?.cancel();
      stale?.cancel();
      unawaited(events?.cancel());
    });
    unawaited(poll());
    return CallRosterGap.none;
  }
}

String? _channelOf(api.ServerEvent event) => switch (event) {
  api.VoiceParticipantJoined(:final channelId) => channelId,
  api.VoiceParticipantLeft(:final channelId) => channelId,
  api.VoiceActivityChanged(:final channelId) => channelId,
  _ => null,
};
