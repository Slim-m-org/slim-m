// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a call amounted to, built entirely from the roster a live call
/// already reports - no new server state, since a per-call roster with join
/// and leave times is a record worth having for the person who was in the
/// call and not worth turning into a durable, queryable log of who was with
/// whom for how long. See `VoiceController`'s own doc comment for how a
/// [CallRecap] is produced and cleared.
library;

import 'package:slimm_rtc/rtc.dart';

/// One other participant's presence across a call this device was in.
class CallParticipantActivity {
  const CallParticipantActivity({
    required this.identity,
    required this.name,
    required this.joinedAt,
    this.leftAt,
  });

  final String identity;
  final String name;
  final DateTime joinedAt;

  /// Null means still in the call at the moment this device hung up.
  final DateTime? leftAt;
}

/// A finished call, summarised for the screen a hang-up leaves you on.
class CallRecap {
  const CallRecap({
    required this.channelId,
    required this.startedAt,
    required this.endedAt,
    required this.others,
    required this.sharedScreen,
    required this.usedCamera,
  });

  /// Which channel this recap belongs to. `VoiceController` is one instance
  /// for the whole app, so a screen must check this against its own channel
  /// before rendering anything - the same shape CLAUDE.md already recorded
  /// once for an in-call error message leaking across channels.
  final String channelId;

  final DateTime startedAt;
  final DateTime endedAt;

  /// Every other participant seen at any point during the call, oldest join
  /// first.
  final List<CallParticipantActivity> others;
  final bool sharedScreen;
  final bool usedCamera;

  Duration get duration => endedAt.difference(startedAt);

  /// Nobody else was ever in the call with you.
  bool get wasAlone => others.isEmpty;

  /// Below this, a call is too short to be worth a summary; see [isWorthShowing].
  static const minWorthwhileDuration = Duration(seconds: 30);

  /// A short call is noise, not a summary - asked once here rather than
  /// re-derived at every render site. A solo call past the floor still
  /// counts: testing a screen share or a camera alone is a real use of the
  /// call, and its own duration and activity are worth reporting.
  bool get isWorthShowing => duration >= minWorthwhileDuration;
}

/// `Kiki`, `Kiki and Ann`, `Kiki and 2 others`; empty when nobody else was there.
String callCompanyLabel(List<CallParticipantActivity> others) =>
    switch (others.length) {
      0 => '',
      1 => others.first.name,
      2 => '${others[0].name} and ${others[1].name}',
      _ => '${others.first.name} and ${others.length - 1} others',
    };

class _Span {
  const _Span({
    required this.name,
    required this.isLocal,
    required this.joinedAt,
    this.leftAt,
  });

  final String name;
  final bool isLocal;
  final DateTime joinedAt;
  final DateTime? leftAt;

  /// Clears a recorded departure: the same identity reappeared, so this
  /// device treats them as continuously present rather than opening a
  /// second span for what a brief reconnect probably was.
  _Span rejoined() => _Span(name: name, isLocal: isLocal, joinedAt: joinedAt);

  _Span left(DateTime at) =>
      _Span(name: name, isLocal: isLocal, joinedAt: joinedAt, leftAt: at);
}

/// Accumulates [CallRecap] material from a live participant stream.
///
/// Never asks the server for anything: `VoiceController` already receives
/// every participant change it needs for its own state, so this is
/// arithmetic over what already crosses the wire, not a new record. Entirely
/// in memory and entirely client-side - it does not outlive the process, and
/// nobody but this device ever sees it.
class CallActivityTracker {
  CallActivityTracker({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final Map<String, _Span> _spans = {};
  bool _sharedScreen = false;
  bool _usedCamera = false;

  /// Called at the start of every `VoiceController.join`, so one call's
  /// activity never bleeds into the next.
  void reset() {
    _spans.clear();
    _sharedScreen = false;
    _usedCamera = false;
  }

  void observe(List<VoiceParticipant> participants) {
    final now = _now();
    final present = <String>{};
    for (final p in participants) {
      present.add(p.identity);
      _spans[p.identity] = _spanFor(p, now);
      if (p.isLocal && p.isScreenSharing) _sharedScreen = true;
      if (p.isLocal && p.isCameraOn) _usedCamera = true;
    }
    for (final entry in _spans.entries) {
      if (!present.contains(entry.key) && entry.value.leftAt == null) {
        _spans[entry.key] = entry.value.left(now);
      }
    }
  }

  _Span _spanFor(VoiceParticipant p, DateTime now) {
    final span = _spans[p.identity];
    if (span == null) {
      return _Span(name: p.name, isLocal: p.isLocal, joinedAt: now);
    }
    return span.leftAt == null ? span : span.rejoined();
  }

  CallRecap summary({
    required String channelId,
    required DateTime startedAt,
    required DateTime endedAt,
  }) {
    final others = <CallParticipantActivity>[
      for (final entry in _spans.entries)
        if (!entry.value.isLocal)
          CallParticipantActivity(
            identity: entry.key,
            name: entry.value.name,
            joinedAt: entry.value.joinedAt,
            leftAt: entry.value.leftAt,
          ),
    ]..sort((a, b) => a.joinedAt.compareTo(b.joinedAt));
    return CallRecap(
      channelId: channelId,
      startedAt: startedAt,
      endedAt: endedAt,
      others: others,
      sharedScreen: _sharedScreen,
      usedCamera: _usedCamera,
    );
  }
}
