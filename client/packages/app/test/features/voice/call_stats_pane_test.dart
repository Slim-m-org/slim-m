// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Call stats pane in personal settings (decision 0113): loading, empty,
/// error and data, on a phone and on a laptop, with its search entries.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/providers/settings_index.dart';
import 'package:slimm_app/src/features/voice/providers/call_stats.dart';
import 'package:slimm_app/src/features/voice/widgets/call_stats_format.dart';

import '../../ui_snapshot_support.dart';

const _route = '/settings?pane=call-stats';

const _empty = api.CallStats(
  since: null,
  calls: 0,
  talkMs: 0,
  words: 0,
  characters: 0,
  wordsPerMinute: null,
  fillers: null,
  languages: [],
  weekly: false,
  buckets: [],
  retentionDays: null,
);

final _full = api.CallStats(
  since: 1000,
  calls: 4,
  talkMs: 4380000,
  words: 9100,
  characters: 410,
  wordsPerMinute: 140.4,
  fillers: const api.CallStatsFillers(
    total: 31,
    per100Words: 3.4,
    phrases: [
      api.CallStatsPhrase(phrase: 'like', count: 18),
      api.CallStatsPhrase(phrase: 'you know', count: 9),
      api.CallStatsPhrase(phrase: 'um', count: 4),
    ],
  ),
  languages: const [
    api.CallStatsLanguage(
      code: 'en',
      talkMs: 3600000,
      share: 0.82,
      pace: 146,
      characters: false,
    ),
    api.CallStatsLanguage(
      code: 'ja',
      talkMs: 480000,
      share: 0.11,
      pace: 220,
      characters: true,
    ),
    api.CallStatsLanguage(
      code: 'other',
      talkMs: 300000,
      share: 0.07,
      pace: null,
      characters: false,
    ),
  ],
  weekly: false,
  buckets: [
    for (var day = 0; day < 14; day++)
      api.CallStatsBucket(
        date: '2026-11-${(day + 1).toString().padLeft(2, '0')}',
        talkMs: day.isEven ? 0 : (day + 2) * 120000,
        words: day * 100,
      ),
  ],
  retentionDays: 30,
);

List<Override> _overrides(Future<api.CallStats> Function() stats) => [
  callTranscriptionModeProvider.overrideWith(
    (ref) async => api.CallTranscriptionMode.always,
  ),
  myCallStatsProvider.overrideWith((ref, days) => stats()),
];

Future<void> _render(
  WidgetTester tester,
  String name,
  Future<api.CallStats> Function() stats,
  void Function() check,
) async {
  for (final viewport in const ['phone-portrait', 'laptop-1280']) {
    await renderSurface(
      tester,
      _route,
      viewport,
      darkAndLight,
      'call-stats-$name-$viewport-dark+light',
      overrides: _overrides(stats),
      afterSettle: (tester) async => check(),
    );
  }
}

void main() {
  setUpAll(loadRealFonts);

  testWidgets('data: the numbers, fillers, languages and chart show', (
    tester,
  ) async {
    await _render(tester, 'data', () async => _full, () {
      expect(find.text('Only you can see these.'), findsOneWidget);
      expect(find.text('1 h 13 min'), findsOneWidget);
      expect(find.text('Calls you spoke in'), findsOneWidget);
      expect(find.text('140.4'), findsOneWidget);
      expect(find.text('Filler words'), findsOneWidget);
      expect(find.text('you know'), findsOneWidget);
      expect(find.text('English'), findsOneWidget);
      expect(find.text('Japanese'), findsOneWidget);
      expect(find.text('Other languages'), findsOneWidget);
      expect(find.text('Talk time by day'), findsOneWidget);
      expect(find.text('Transcripts are kept for 30 days.'), findsOneWidget);
    });
  });

  testWidgets('empty: no transcribed calls yet', (tester) async {
    await _render(tester, 'empty', () async => _empty, () {
      expect(find.text('No transcribed calls yet'), findsOneWidget);
      expect(find.text('Filler words'), findsNothing);
      expect(find.text('Languages'), findsNothing);
    });
  });

  testWidgets('error: says so and offers a retry, never a snackbar', (
    tester,
  ) async {
    await _render(
      tester,
      'error',
      () async => throw const api.TransportException('boom'),
      () {
        expect(find.text('Could not load your call stats.'), findsOneWidget);
        expect(find.text('Retry'), findsOneWidget);
      },
    );
  });

  testWidgets(
    'loading: the window picker stays and the rows are placeholders',
    (tester) async {
      final never = Completer<api.CallStats>();
      await _render(tester, 'loading', () => never.future, () {
        expect(find.text('Only you can see these.'), findsOneWidget);
        expect(find.text('30 days'), findsOneWidget);
        expect(find.text('Calls you spoke in'), findsNothing);
      });
    },
  );

  test('talk time and language names read plainly', () {
    expect(formatTalkTime(45000), '45 s');
    expect(formatTalkTime(12 * 60000), '12 min');
    expect(formatTalkTime(65 * 60000), '1 h 05 min');
    expect(callStatsLanguageName('yue'), 'Cantonese');
    expect(callStatsLanguageName('xx'), 'xx');
  });

  test('settings search finds the pane by what people type', () {
    bool finds(String word) => callStatsSettingsIndex.any(
      (e) =>
          e.label.toLowerCase().contains(word) ||
          e.keywords.any((k) => k.contains(word)),
    );
    for (final word in const [
      'talk time',
      'words per minute',
      'filler',
      'speech',
      'stats',
    ]) {
      expect(finds(word), isTrue, reason: word);
    }
  });
}
