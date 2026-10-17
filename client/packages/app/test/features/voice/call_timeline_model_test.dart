// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The idle voice pane's call record (decision 0066): lanes per person, the
/// moments in order, and the times on the axis.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/voice/screens/voice_idle/call_timeline_model.dart';

const _min = 60000;

api.VoiceCallEvent _ev(int minute, String who, api.VoiceCallEventKind kind) =>
    api.VoiceCallEvent(at: minute * _min, userId: who, kind: kind);

api.VoiceCall _call() => api.VoiceCall(
  startedAt: 0,
  endedAt: 120 * _min,
  events: [
    _ev(0, 'nick', api.VoiceCallEventKind.joined),
    _ev(0, 'kiki', api.VoiceCallEventKind.joined),
    _ev(4, 'jelly', api.VoiceCallEventKind.joined),
    _ev(30, 'jelly', api.VoiceCallEventKind.shareStarted),
    _ev(70, 'jelly', api.VoiceCallEventKind.shareStopped),
    _ev(82, 'kiki', api.VoiceCallEventKind.left),
    _ev(119, 'jelly', api.VoiceCallEventKind.left),
    _ev(120, 'nick', api.VoiceCallEventKind.left),
  ],
  canvas: const [
    api.VoiceCallCanvasActivity(
      userId: 'kiki',
      kind: 'image',
      firstAt: 46 * _min,
      count: 1,
    ),
  ],
);

void main() {
  test('a lane per person, in the order they joined', () {
    final model = CallTimelineModel.from(_call(), now: 0);
    expect(model.lanes.map((l) => l.userId), ['nick', 'kiki', 'jelly']);
    final kiki = model.lanes[1];
    expect(kiki.inMs, 82 * _min);
    expect(kiki.leftEarlyAt, 82 * _min);
    final jelly = model.lanes[2];
    expect(jelly.sharedMs, 40 * _min);
    expect(jelly.leftEarlyAt, 119 * _min);
    expect(model.lanes[0].leftEarlyAt, isNull, reason: 'the last out ended it');
  });

  test('moments say what happened, in order, ending with the call', () {
    final model = CallTimelineModel.from(_call(), now: 0);
    expect(model.moments.map((m) => m.kind), [
      CallMomentKind.started,
      CallMomentKind.joined,
      CallMomentKind.shared,
      CallMomentKind.canvas,
      CallMomentKind.left,
      CallMomentKind.left,
      CallMomentKind.ended,
    ]);
    expect(model.moments.first.userIds, ['nick', 'kiki']);
    expect(model.moments[2].durationMs, 40 * _min);
  });

  test(
    'an ongoing call runs to now, and a share still going is open-ended',
    () {
      final call = api.VoiceCall(
        startedAt: 0,
        endedAt: null,
        events: [
          _ev(0, 'nick', api.VoiceCallEventKind.joined),
          _ev(5, 'nick', api.VoiceCallEventKind.shareStarted),
        ],
        canvas: const [],
      );
      final model = CallTimelineModel.from(call, now: 10 * _min);
      expect(model.endedAt, 10 * _min);
      expect(model.lanes.single.inMs, 10 * _min);
      expect(model.lanes.single.sharedMs, 5 * _min);
      expect(
        model.moments.map((m) => m.kind),
        isNot(contains(CallMomentKind.ended)),
      );
    },
  );

  test('ticks span the call evenly, and lengths read plainly', () {
    final model = CallTimelineModel.from(_call(), now: 0);
    expect(model.ticks(), [0, 30 * _min, 60 * _min, 90 * _min, 120 * _min]);
    expect(formatSpan(119 * _min), '1 h 59 min');
    expect(formatSpan(35 * _min), '35 min');
    expect(formatSpan(20000), 'under a minute');
    expect(formatSpanShort(82 * _min), '1 h 22');
    expect(formatSpanShort(40 * _min), '40m');
  });
}
