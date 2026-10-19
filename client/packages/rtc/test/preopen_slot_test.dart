// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A capture opened ahead of the connect is published only when it is the one
/// being asked for; anything else is handed back to be closed.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/rtc.dart';

void main() {
  const chosen = lk.AudioCaptureOptions(deviceId: 'mic-2');
  late PreopenSlot<String> slot;

  setUp(() => slot = PreopenSlot<String>());

  test('the same options claim the capture they opened', () async {
    slot.hold(chosen, Future.value('track'));

    final claimed = slot.claim(chosen.copyWith(), usable: true);

    expect(await claimed.match, 'track');
    expect(claimed.stale, isNull);
  });

  test('a changed device hands the capture back to be closed', () async {
    slot.hold(chosen, Future.value('track'));

    final claimed = slot.claim(
      chosen.copyWith(deviceId: 'mic-1'),
      usable: true,
    );

    expect(claimed.match, isNull);
    expect(await claimed.stale, 'track');
  });

  test('changed processing hands the capture back too', () async {
    slot.hold(chosen, Future.value('track'));

    final claimed = slot.claim(
      chosen.copyWith(noiseSuppression: false),
      usable: true,
    );

    expect(claimed.match, isNull);
    expect(await claimed.stale, 'track');
  });

  test('a capture with nowhere to publish is handed back', () async {
    slot.hold(chosen, Future.value('track'));

    final claimed = slot.claim(chosen, usable: false);

    expect(claimed.match, isNull);
    expect(await claimed.stale, 'track');
  });

  test('a claim empties the slot', () async {
    slot.hold(chosen, Future.value('track'));
    slot.claim(chosen, usable: true);

    final again = slot.claim(chosen, usable: true);

    expect(again.match, isNull);
    expect(again.stale, isNull);
  });

  test('holding a second capture returns the first to be closed', () async {
    slot.hold(chosen, Future.value('first'));
    final first = slot.hold(chosen, Future.value('second'));

    expect(await first, 'first');
    expect(await slot.claim(chosen, usable: true).match, 'second');
  });
}
