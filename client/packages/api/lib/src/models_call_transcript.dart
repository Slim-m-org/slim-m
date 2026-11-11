// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Call transcripts kept by the server (decision 0113).
library;

/// What the Space does about transcribing calls.
enum CallTranscriptionMode {
  /// Nothing is transcribed by the server. The default.
  off,

  /// Someone in the call asks, and everyone has to agree.
  onRequest,

  /// Every call, from its first join, with no prompt.
  always;

  String get wire => switch (this) {
        off => 'off',
        onRequest => 'on_request',
        always => 'always',
      };

  /// An unknown mode reads as [off], so a newer server never reads as
  /// recording to a client that has not heard of it.
  static CallTranscriptionMode parse(String? value) => switch (value) {
        'on_request' => onRequest,
        'always' => always,
        _ => off,
      };
}

/// One transcribed line: who said it, when, and what.
class TranscriptLine {
  const TranscriptLine({
    required this.seq,
    required this.speakerId,
    required this.at,
    required this.text,
  });

  /// Order within the transcript.
  final int seq;
  final String speakerId;

  /// When the segment started, in epoch milliseconds.
  final int at;
  final String text;

  factory TranscriptLine.fromJson(Map<String, dynamic> json) => TranscriptLine(
        seq: json['seq'] as int,
        speakerId: json['speaker_id'] as String,
        at: json['at'] as int,
        text: json['text'] as String,
      );
}

/// One page of a call's transcript.
class CallTranscript {
  const CallTranscript({
    required this.id,
    required this.channelId,
    required this.startedAt,
    required this.endedAt,
    required this.mode,
    required this.lines,
    required this.nextAfterSeq,
  });

  final String id;
  final String channelId;
  final int startedAt;

  /// Null while it is still being written.
  final int? endedAt;

  /// `on_request` or `always`.
  final String mode;
  final List<TranscriptLine> lines;

  /// Pass back as `after_seq` for the next page; null on the last one.
  final int? nextAfterSeq;

  bool get ongoing => endedAt == null;

  factory CallTranscript.fromJson(Map<String, dynamic> json) => CallTranscript(
        id: json['id'] as String,
        channelId: json['channel_id'] as String,
        startedAt: json['started_at'] as int,
        endedAt: json['ended_at'] as int?,
        mode: json['mode'] as String,
        lines: [
          for (final raw in json['lines'] as List<dynamic>)
            TranscriptLine.fromJson(raw as Map<String, dynamic>),
        ],
        nextAfterSeq: json['next_after_seq'] as int?,
      );
}

/// A transcript line found by search, with where it sits.
class TranscriptHit {
  const TranscriptHit({
    required this.transcriptId,
    required this.channelId,
    required this.seq,
    required this.speakerId,
    required this.at,
    required this.text,
    required this.highlight,
  });

  final String transcriptId;
  final String channelId;
  final int seq;
  final String speakerId;
  final int at;
  final String text;

  /// The matched text with the match marked, as message search does.
  final String highlight;

  factory TranscriptHit.fromJson(Map<String, dynamic> json) => TranscriptHit(
        transcriptId: json['transcript_id'] as String,
        channelId: json['channel_id'] as String,
        seq: json['seq'] as int,
        speakerId: json['speaker_id'] as String,
        at: json['at'] as int,
        text: json['text'] as String,
        highlight: json['highlight'] as String? ?? json['text'] as String,
      );
}

/// Whether the caller still owes the one-time `always` notice before joining.
class TranscriptionNotice {
  const TranscriptionNotice({required this.mode, required this.acknowledged});

  final CallTranscriptionMode mode;
  final bool acknowledged;

  /// Shown once: the Space transcribes every call and this member never agreed.
  bool get due => mode == CallTranscriptionMode.always && !acknowledged;

  factory TranscriptionNotice.fromJson(Map<String, dynamic> json) =>
      TranscriptionNotice(
        mode: CallTranscriptionMode.parse(json['mode'] as String?),
        acknowledged: json['acknowledged'] as bool? ?? false,
      );
}
