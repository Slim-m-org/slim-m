// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The first-audio watch polls only while a join is open.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/rtc.dart';

void main() {
  test('a timings object is open from begin to finish', () {
    final timings = JoinTimings();
    expect(timings.isOpen, isFalse);
    timings.begin();
    expect(timings.isOpen, isTrue);
    timings.mark(JoinStage.firstRemoteAudio);
    expect(timings.isOpen, isFalse);
  });

  test('with no join open it never asks for stats', () async {
    var polls = 0;
    var marked = 0;
    await watchFirstAudio(
      joinOpen: () => false,
      packetsReceived: () async {
        polls++;
        return 5;
      },
      onAudio: () => marked++,
      every: Duration.zero,
    );

    expect(polls, 0);
    expect(marked, 0);
  });

  test('it stops polling once the join has ended', () async {
    var polls = 0;
    await watchFirstAudio(
      joinOpen: () => polls < 3,
      packetsReceived: () async {
        polls++;
        return 0;
      },
      onAudio: () {},
      every: Duration.zero,
    );

    expect(polls, 3);
  });

  test('it marks the first packet once and stops', () async {
    var polls = 0;
    var marked = 0;
    await watchFirstAudio(
      joinOpen: () => true,
      packetsReceived: () async => ++polls < 3 ? 0 : 7,
      onAudio: () => marked++,
      every: Duration.zero,
    );

    expect(polls, 3);
    expect(marked, 1);
  });

  test('a stats call that throws does not escape the watch', () async {
    var polls = 0;
    await watchFirstAudio(
      joinOpen: () => polls < 2,
      packetsReceived: () async {
        polls++;
        throw StateError('track gone');
      },
      onAudio: () {},
      every: Duration.zero,
    );

    expect(polls, 2);
  });
}
