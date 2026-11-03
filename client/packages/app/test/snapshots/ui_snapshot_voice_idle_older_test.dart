// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An older call opened from "Earlier in #channel": a long call with a late
/// joiner, a screen share and canvas work, at desktop and phone width in both
/// themes. PNGs are written only under SLIMM_UI_SNAPSHOTS=1.
library;

import 'package:flutter/painting.dart' show Size;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;

import '../support/voice_idle_scene.dart';
import '../ui_snapshot_support.dart';

final _older = DateTime(2026, 10, 12, 18, 5).millisecondsSinceEpoch;
const _min = 60000;

api.VoiceCallEvent _ev(int minute, String who, api.VoiceCallEventKind kind) =>
    api.VoiceCallEvent(at: _older + minute * _min, userId: who, kind: kind);

api.VoiceCallHistory _history() {
  final base = idleHistory();
  final long = api.VoiceCall(
    startedAt: _older,
    endedAt: _older + 305 * _min,
    events: [
      _ev(0, 'nick', api.VoiceCallEventKind.joined),
      _ev(3, 'kiki', api.VoiceCallEventKind.joined),
      _ev(190, 'jelly', api.VoiceCallEventKind.joined),
      _ev(200, 'jelly', api.VoiceCallEventKind.shareStarted),
      _ev(260, 'jelly', api.VoiceCallEventKind.shareStopped),
      _ev(280, 'kiki', api.VoiceCallEventKind.left),
      _ev(300, 'jelly', api.VoiceCallEventKind.left),
      _ev(305, 'nick', api.VoiceCallEventKind.left),
    ],
    canvas: [
      api.VoiceCallCanvasActivity(
        userId: 'kiki',
        kind: 'image',
        firstAt: _older + 40 * _min,
        count: 3,
      ),
      api.VoiceCallCanvasActivity(
        userId: 'nick',
        kind: 'stroke',
        firstAt: _older + 120 * _min,
        count: 48,
      ),
    ],
  );
  return api.VoiceCallHistory(
    retentionDays: base.retentionDays,
    canvasObjectCount: base.canvasObjectCount,
    calls: [base.calls.first, long, ...base.calls.skip(1)],
  );
}

void main() {
  setUpAll(loadRealFonts);

  const sizes = {'desktop': Size(1100, 1200), 'phone': Size(390, 1300)};
  for (final theme in const ['dark', 'light']) {
    for (final entry in sizes.entries) {
      testWidgets('older call at ${entry.key} ($theme)', (tester) async {
        await pumpIdle(
          tester,
          size: entry.value,
          dark: theme == 'dark',
          history: _history(),
        );
        await tester.pumpAndSettle();
        final row = find.byKey(ValueKey('call-history-row-$_older'));
        await tester.scrollUntilVisible(row, 200);
        await tester.tap(row);
        await tester.pumpAndSettle();
        await tester.drag(find.byKey(snapshotBoundary), const Offset(0, 5000));
        await tester.pumpAndSettle();
        await writeSnapshot(tester, 'voice-idle-older-${entry.key}-$theme');
        expect(tester.takeException(), isNull);
      });
    }
  }
}
