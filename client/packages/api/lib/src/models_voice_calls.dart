// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A voice channel's call history (decision 0066), as
/// [SlimmApiVoiceCalls.listVoiceCalls] returns it.
library;

enum VoiceCallEventKind {
  joined,
  left,
  shareStarted,
  shareStopped;

  static VoiceCallEventKind? parse(String raw) => switch (raw) {
        'joined' => joined,
        'left' => left,
        'share_started' => shareStarted,
        'share_stopped' => shareStopped,
        _ => null,
      };
}

class VoiceCallEvent {
  const VoiceCallEvent({
    required this.at,
    required this.userId,
    required this.kind,
  });

  final int at;
  final String userId;
  final VoiceCallEventKind kind;
}

/// What one person placed on the canvas during a call, of one kind.
class VoiceCallCanvasActivity {
  const VoiceCallCanvasActivity({
    required this.userId,
    required this.kind,
    required this.firstAt,
    required this.count,
  });

  final String userId;

  /// The canvas object kind: stroke, image, gif or window.
  final String kind;
  final int firstAt;
  final int count;

  factory VoiceCallCanvasActivity.fromJson(Map<String, dynamic> json) =>
      VoiceCallCanvasActivity(
        userId: json['user_id'] as String,
        kind: json['kind'] as String,
        firstAt: json['first_at'] as int,
        count: json['count'] as int,
      );
}

class VoiceCall {
  const VoiceCall({
    required this.startedAt,
    required this.endedAt,
    required this.events,
    required this.canvas,
  });

  final int startedAt;

  /// Null while the call is still going.
  final int? endedAt;

  /// Only the events that changed something, oldest first.
  final List<VoiceCallEvent> events;
  final List<VoiceCallCanvasActivity> canvas;

  bool get ongoing => endedAt == null;

  factory VoiceCall.fromJson(Map<String, dynamic> json) => VoiceCall(
        startedAt: json['started_at'] as int,
        endedAt: json['ended_at'] as int?,
        events: [
          for (final raw in json['events'] as List<dynamic>)
            if (VoiceCallEventKind.parse(
              (raw as Map<String, dynamic>)['kind'] as String,
            )
                case final kind?)
              VoiceCallEvent(
                at: raw['at'] as int,
                userId: raw['user_id'] as String,
                kind: kind,
              ),
        ],
        canvas: [
          for (final raw in json['canvas'] as List<dynamic>)
            VoiceCallCanvasActivity.fromJson(raw as Map<String, dynamic>),
        ],
      );
}

class VoiceCallHistory {
  const VoiceCallHistory({
    required this.retentionDays,
    required this.canvasObjectCount,
    required this.calls,
  });

  final int retentionDays;

  /// Live objects on the channel's canvas now.
  final int canvasObjectCount;

  /// Newest first.
  final List<VoiceCall> calls;

  factory VoiceCallHistory.fromJson(Map<String, dynamic> json) =>
      VoiceCallHistory(
        retentionDays: json['retention_days'] as int,
        canvasObjectCount: json['canvas_object_count'] as int,
        calls: [
          for (final raw in json['calls'] as List<dynamic>)
            VoiceCall.fromJson(raw as Map<String, dynamic>),
        ],
      );
}
