// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/rtc.dart';

void main() {
  late Duration now;
  late List<JoinSummary> finished;
  late JoinTimings timings;

  setUp(() {
    now = Duration.zero;
    finished = [];
    timings = JoinTimings(clock: () => now, onFinished: finished.add);
  });

  void at(int ms, JoinStage stage) {
    now = Duration(milliseconds: ms);
    timings.mark(stage);
  }

  test('marks are reported in milliseconds from the click, in stage order', () {
    now = const Duration(milliseconds: 1000);
    timings.begin();
    at(1002, JoinStage.tokenRequested);
    at(1050, JoinStage.tokenReceived);
    at(1051, JoinStage.connectStarted);
    at(1400, JoinStage.connected);
    at(1450, JoinStage.micPublished);
    at(1900, JoinStage.firstRemoteAudio);

    expect(finished, hasLength(1));
    expect(
      finished.single.line,
      'Join timings in ms from the click: click=0 tokenRequested=2 '
      'tokenReceived=50 connectStarted=51 connected=400 micPublished=450 firstRemoteAudio=900',
    );
    expect(finished.single.complete, isTrue);
  });

  test('a join that ends before anyone is heard says so', () {
    timings.begin();
    at(40, JoinStage.tokenReceived);
    timings.finish();

    expect(finished.single.complete, isFalse);
    expect(finished.single.line, endsWith('(ended before remote audio)'));
  });

  test('a stage is stamped once and marks outside a join are ignored', () {
    at(5, JoinStage.connected);
    expect(finished, isEmpty);

    now = Duration.zero;
    timings.begin();
    at(10, JoinStage.connected);
    at(99, JoinStage.connected);
    timings.finish();
    timings.finish();

    expect(finished, hasLength(1));
    expect(finished.single.millis[JoinStage.connected], 10);
  });

  test('beginning a join closes the one that never ended', () {
    timings.begin();
    timings.begin();

    expect(finished, hasLength(1));
    expect(timings.last, same(finished.single));
  });
}
