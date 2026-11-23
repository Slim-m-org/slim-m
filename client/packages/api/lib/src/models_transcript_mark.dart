// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Marks and notes on a call transcript (decision 0113, amended 2026-11-22).
library;

/// A plain mark or one with a note.
enum TranscriptMarkKind {
  mark,
  note;

  String get wire => name;

  static TranscriptMarkKind parse(String? value) =>
      value == 'note' ? note : mark;
}

/// A moment someone in a call marked, optionally with a note. Readable by
/// whoever may read the transcript.
class TranscriptMark {
  const TranscriptMark({
    required this.id,
    required this.transcriptId,
    required this.authorId,
    required this.at,
    required this.kind,
    this.lineSeq,
    this.text,
    this.spoken = false,
  });

  final String id;
  final String transcriptId;
  final String authorId;

  /// When it was marked, in epoch milliseconds.
  final int at;

  /// The newest line kept when it was marked; null before the first line.
  final int? lineSeq;
  final TranscriptMarkKind kind;

  /// The note; null on a plain mark.
  final String? text;

  /// Said aloud with the wake phrase rather than made with the button or a hotkey.
  final bool spoken;

  factory TranscriptMark.fromJson(Map<String, dynamic> json) => TranscriptMark(
        id: json['id'] as String,
        transcriptId: json['transcript_id'] as String,
        authorId: json['author_id'] as String,
        at: json['at'] as int,
        lineSeq: json['line_seq'] as int?,
        kind: TranscriptMarkKind.parse(json['kind'] as String?),
        text: json['text'] as String?,
        spoken: json['source'] == 'voice',
      );
}
