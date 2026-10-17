// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One call's record shaped for the idle voice pane (decision 0066): a lane
/// per person with when they were in and when they shared, and the call's
/// moments in order. Pure, so the shaping is tested without widgets.
library;

import 'package:slimm_api/api.dart' as api;

/// A span of time inside a call, in epoch milliseconds.
typedef Span = ({int from, int to});

class CallLane {
  const CallLane({
    required this.userId,
    required this.inCall,
    required this.sharing,
    required this.leftEarlyAt,
  });

  final String userId;
  final List<Span> inCall;
  final List<Span> sharing;

  /// When they left, if that was before the call ended.
  final int? leftEarlyAt;

  int get inMs => inCall.fold(0, (sum, s) => sum + s.to - s.from);
  int get sharedMs => sharing.fold(0, (sum, s) => sum + s.to - s.from);
}

enum CallMomentKind { started, joined, shared, left, canvas, ended }

class CallMoment {
  const CallMoment({
    required this.at,
    required this.kind,
    this.userIds = const [],
    this.durationMs,
    this.canvasKind,
    this.count = 0,
  });

  final int at;
  final CallMomentKind kind;
  final List<String> userIds;

  /// How long a share lasted.
  final int? durationMs;

  /// For a canvas moment: stroke, image, gif or window.
  final String? canvasKind;
  final int count;
}

class CallTimelineModel {
  const CallTimelineModel({
    required this.startedAt,
    required this.endedAt,
    required this.lanes,
    required this.moments,
  });

  final int startedAt;
  final int endedAt;
  final List<CallLane> lanes;
  final List<CallMoment> moments;

  int get lengthMs => endedAt - startedAt;

  /// [count] evenly spaced times across the call, first and last included.
  List<int> ticks([int count = 5]) => [
    for (var i = 0; i < count; i++)
      startedAt + (lengthMs * i / (count - 1)).round(),
  ];

  /// [call] shaped into lanes and moments; an ongoing call ends at [now].
  factory CallTimelineModel.from(api.VoiceCall call, {required int now}) =>
      _TimelineBuilder(call, call.endedAt ?? now).build();
}

class _TimelineBuilder {
  _TimelineBuilder(this.call, this.end);

  final api.VoiceCall call;
  final int end;
  final order = <String>[];
  final joinedAt = <String, int>{};
  final shareFrom = <String, int>{};
  final inCall = <String, List<Span>>{};
  final sharing = <String, List<Span>>{};
  final lastLeft = <String, int>{};
  final moments = <CallMoment>[];
  final starters = <String>[];

  CallTimelineModel build() {
    call.events.forEach(_apply);
    _closeOpenSpans();
    _addSummaryMoments();
    moments.sort((a, b) => a.at.compareTo(b.at));
    return CallTimelineModel(
      startedAt: call.startedAt,
      endedAt: end,
      lanes: [for (final user in order) _laneFor(user)],
      moments: moments,
    );
  }

  void _closeShare(String user, int at) {
    final from = shareFrom.remove(user);
    if (from == null) return;
    sharing.putIfAbsent(user, () => []).add((from: from, to: at));
    moments.add(
      CallMoment(
        at: from,
        kind: CallMomentKind.shared,
        userIds: [user],
        durationMs: at - from,
      ),
    );
  }

  void _apply(api.VoiceCallEvent event) {
    final user = event.userId;
    switch (event.kind) {
      case api.VoiceCallEventKind.joined:
        _onJoined(user, event.at);
      case api.VoiceCallEventKind.left:
        _onLeft(user, event.at);
      case api.VoiceCallEventKind.shareStarted:
        shareFrom[user] = event.at;
      case api.VoiceCallEventKind.shareStopped:
        _closeShare(user, event.at);
    }
  }

  void _onJoined(String user, int at) {
    if (!order.contains(user)) order.add(user);
    joinedAt[user] = at;
    // Everyone who joined in the call's first minute started it together.
    if (at - call.startedAt <= 60000) {
      starters.add(user);
      return;
    }
    moments.add(
      CallMoment(at: at, kind: CallMomentKind.joined, userIds: [user]),
    );
  }

  void _onLeft(String user, int at) {
    _closeShare(user, at);
    final from = joinedAt.remove(user);
    if (from != null) {
      inCall.putIfAbsent(user, () => []).add((from: from, to: at));
    }
    lastLeft[user] = at;
  }

  void _closeOpenSpans() {
    for (final user in [...shareFrom.keys]) {
      _closeShare(user, end);
    }
    for (final entry in joinedAt.entries) {
      inCall.putIfAbsent(entry.key, () => []).add((from: entry.value, to: end));
    }
  }

  bool _leftEarly(String user) {
    final at = lastLeft[user];
    return at != null && at < end && !joinedAt.containsKey(user);
  }

  CallLane _laneFor(String user) => CallLane(
    userId: user,
    inCall: inCall[user] ?? const [],
    sharing: sharing[user] ?? const [],
    leftEarlyAt: _leftEarly(user) ? lastLeft[user] : null,
  );

  void _addSummaryMoments() {
    if (starters.isNotEmpty) {
      moments.add(
        CallMoment(
          at: call.startedAt,
          kind: CallMomentKind.started,
          userIds: starters,
        ),
      );
    }
    for (final entry in lastLeft.entries) {
      if (_leftEarly(entry.key)) {
        moments.add(
          CallMoment(
            at: entry.value,
            kind: CallMomentKind.left,
            userIds: [entry.key],
          ),
        );
      }
    }
    for (final activity in call.canvas) {
      moments.add(
        CallMoment(
          at: activity.firstAt,
          kind: CallMomentKind.canvas,
          userIds: [activity.userId],
          canvasKind: activity.kind,
          count: activity.count,
        ),
      );
    }
    if (call.endedAt != null) {
      moments.add(CallMoment(at: end, kind: CallMomentKind.ended));
    }
  }
}

/// "1 h 59 min", "35 min", "under a minute".
String formatSpan(int ms) {
  final minutes = ms ~/ 60000;
  if (minutes < 1) return 'under a minute';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  if (h == 0) return '$m min';
  return m == 0 ? '$h h' : '$h h $m min';
}

/// The short form a lane uses: "1 h 22", "40m".
String formatSpanShort(int ms) {
  final minutes = ms ~/ 60000;
  final h = minutes ~/ 60;
  final m = minutes % 60;
  if (h == 0) return '${m}m';
  return '$h h ${m.toString().padLeft(2, '0')}';
}
