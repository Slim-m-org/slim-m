// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The caller's own talk statistics from their call transcript lines (decision 0113).
library;

/// One filler phrase and how often it was heard.
class CallStatsPhrase {
  const CallStatsPhrase({required this.phrase, required this.count});

  final String phrase;
  final int count;

  factory CallStatsPhrase.fromJson(Map<String, dynamic> json) =>
      CallStatsPhrase(
        phrase: json['phrase'] as String,
        count: json['count'] as int,
      );
}

/// Filler words on English lines; the wire sends null when none were spoken.
class CallStatsFillers {
  const CallStatsFillers({
    required this.total,
    required this.per100Words,
    required this.phrases,
  });

  final int total;
  final double per100Words;
  final List<CallStatsPhrase> phrases;

  factory CallStatsFillers.fromJson(Map<String, dynamic> json) =>
      CallStatsFillers(
        total: json['total'] as int,
        per100Words: (json['per_100_words'] as num).toDouble(),
        phrases: [
          for (final raw in json['phrases'] as List<dynamic>)
            CallStatsPhrase.fromJson(raw as Map<String, dynamic>),
        ],
      );
}

/// One language's share of the caller's talk time. The code `other` folds the small ones.
class CallStatsLanguage {
  const CallStatsLanguage({
    required this.code,
    required this.talkMs,
    required this.share,
    required this.pace,
    required this.characters,
  });

  final String code;
  final int talkMs;

  /// 0 to 1.
  final double share;

  /// Units a minute; null under a minute of talk time.
  final double? pace;

  /// Whether [pace] counts characters rather than words.
  final bool characters;

  factory CallStatsLanguage.fromJson(Map<String, dynamic> json) =>
      CallStatsLanguage(
        code: json['code'] as String,
        talkMs: json['talk_ms'] as int,
        share: (json['share'] as num).toDouble(),
        pace: (json['pace'] as num?)?.toDouble(),
        characters: json['unit'] == 'characters',
      );
}

/// Talk time and words on one day, or in one week.
class CallStatsBucket {
  const CallStatsBucket({
    required this.date,
    required this.talkMs,
    required this.words,
  });

  /// `YYYY-MM-DD`: the day, or the Monday of the week.
  final String date;
  final int talkMs;
  final int words;

  factory CallStatsBucket.fromJson(Map<String, dynamic> json) =>
      CallStatsBucket(
        date: json['date'] as String,
        talkMs: json['talk_ms'] as int,
        words: json['words'] as int,
      );
}

/// What the caller said on calls, as numbers only the caller can read.
class CallStats {
  const CallStats({
    required this.since,
    required this.calls,
    required this.talkMs,
    required this.words,
    required this.characters,
    required this.wordsPerMinute,
    required this.fillers,
    required this.languages,
    required this.weekly,
    required this.buckets,
    required this.retentionDays,
  });

  /// When the first counted line began, in epoch milliseconds; null with nothing counted.
  final int? since;
  final int calls;
  final int talkMs;
  final int words;
  final int characters;
  final double? wordsPerMinute;
  final CallStatsFillers? fillers;
  final List<CallStatsLanguage> languages;

  /// Whether [buckets] are weeks rather than days.
  final bool weekly;
  final List<CallStatsBucket> buckets;

  /// How long the Space keeps transcripts; null when it keeps them without limit.
  final int? retentionDays;

  bool get isEmpty => talkMs == 0 && words == 0 && characters == 0;

  factory CallStats.fromJson(Map<String, dynamic> json) {
    final buckets = json['buckets'] as Map<String, dynamic>;
    final fillers = json['fillers'];
    return CallStats(
      since: json['since'] as int?,
      calls: json['calls'] as int,
      talkMs: json['talk_ms'] as int,
      words: json['words'] as int,
      characters: json['characters'] as int,
      wordsPerMinute: (json['words_per_minute'] as num?)?.toDouble(),
      fillers: fillers is Map<String, dynamic>
          ? CallStatsFillers.fromJson(fillers)
          : null,
      languages: [
        for (final raw in json['languages'] as List<dynamic>)
          CallStatsLanguage.fromJson(raw as Map<String, dynamic>),
      ],
      weekly: buckets['size'] == 'week',
      buckets: [
        for (final raw in buckets['items'] as List<dynamic>)
          CallStatsBucket.fromJson(raw as Map<String, dynamic>),
      ],
      retentionDays: json['retention_days'] as int?,
    );
  }
}
