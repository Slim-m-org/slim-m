// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Call stats pane with numbers, with none and while loading, and the
/// in-call stats screen with no call, at a phone width and a desktop width in
/// both themes. The PNGs are written only under
/// SLIMM_UI_SNAPSHOTS=1; otherwise this asserts the page lays out.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/providers/settings_index_call_stats.dart';
import 'package:slimm_app/src/features/voice/providers/call_stats.dart';
import 'package:slimm_app/src/routing/routes.dart';

import '../ui_snapshot_support.dart';

api.CallStats _populated() => const api.CallStats(
  since: 1760000000000,
  calls: 14,
  talkMs: 5400000,
  words: 9800,
  characters: 0,
  wordsPerMinute: 118,
  fillers: api.CallStatsFillers(
    total: 212,
    per100Words: 2.2,
    phrases: [
      api.CallStatsPhrase(phrase: 'um', count: 96),
      api.CallStatsPhrase(phrase: 'you know', count: 71),
      api.CallStatsPhrase(phrase: 'like', count: 45),
    ],
  ),
  languages: [
    api.CallStatsLanguage(
      code: 'en',
      talkMs: 4800000,
      share: 0.89,
      pace: 121,
      characters: false,
    ),
    api.CallStatsLanguage(
      code: 'de',
      talkMs: 600000,
      share: 0.11,
      pace: 96,
      characters: false,
    ),
  ],
  weekly: false,
  buckets: [
    api.CallStatsBucket(date: '2026-11-17', talkMs: 600000, words: 1100),
    api.CallStatsBucket(date: '2026-11-18', talkMs: 1200000, words: 2300),
    api.CallStatsBucket(date: '2026-11-19', talkMs: 300000, words: 540),
    api.CallStatsBucket(date: '2026-11-21', talkMs: 2100000, words: 3900),
    api.CallStatsBucket(date: '2026-11-22', talkMs: 1200000, words: 1960),
  ],
  retentionDays: 90,
);

api.CallStats _empty() => const api.CallStats(
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
  retentionDays: 90,
);

void main() {
  setUpAll(loadRealFonts);

  final cases = <String, Future<api.CallStats> Function()>{
    'populated': () async => _populated(),
    'empty': () async => _empty(),
    'loading': () => Completer<api.CallStats>().future,
  };
  for (final c in cases.entries) {
    for (final viewport in const ['phone-portrait', 'desktop']) {
      testWidgets('call stats pane ${c.key} at $viewport (dark+light)', (
        tester,
      ) async {
        await renderSurface(
          tester,
          Routes.personalSettingsPane(callStatsPane),
          viewport,
          darkAndLight,
          'call-stats-pane-${c.key}-$viewport-$darkAndLight',
          knownTransient: c.key == 'loading',
          overrides: [
            callTranscriptionModeProvider.overrideWith(
              (ref) async => api.CallTranscriptionMode.onRequest,
            ),
            myCallStatsProvider.overrideWith((ref, days) => c.value()),
          ],
        );
      });
    }
  }
  for (final viewport in const ['phone-portrait', 'desktop']) {
    testWidgets('call stats screen with no call at $viewport (dark+light)', (
      tester,
    ) async {
      await renderSurface(
        tester,
        Routes.callStats,
        viewport,
        darkAndLight,
        'call-stats-screen-$viewport-$darkAndLight',
      );
    });
  }
}
