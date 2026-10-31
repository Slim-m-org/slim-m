// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/src/screen_share.dart';
import 'package:slimm_rtc/src/screen_share_local.dart';
import 'package:slimm_rtc/src/screen_share_source_watch.dart';

void main() {
  late StreamController<String> errors;
  late List<ShareRequest> stopped;
  late List<String> lost;
  late ShareSourceWatch watch;
  var subscribes = 0;
  const window =
      ShareRequest(ScreenShareQuality.standard, 'window:7', false, null);

  setUp(() {
    subscribes = 0;
    errors = StreamController<String>.broadcast();
    stopped = [];
    lost = [];
    watch = ShareSourceWatch(
      captureErrors: () {
        subscribes++;
        return errors.stream;
      },
      stop: (request) async => stopped.add(request),
    );
    watch.lost.listen(lost.add);
  });

  tearDown(() async {
    watch.dispose();
    await errors.close();
  });

  test(
      'the capturer failing on the shared window stops the share and says which source went',
      () async {
    watch.running(window);
    errors.add('window:7');
    await pumpEventQueue();

    expect(stopped, [window]);
    expect(lost, ['window:7']);
  });

  test('a failure with no source id still ends the running share', () async {
    watch.running(window);
    errors.add('');
    await pumpEventQueue();

    expect(stopped, [window]);
  });

  test('another source failing leaves the share alone', () async {
    watch.running(window);
    errors.add('window:8');
    await pumpEventQueue();

    expect(stopped, isEmpty);
    expect(lost, isEmpty);
  });

  test('nothing is listened to until a share runs, nor after it stops',
      () async {
    expect(subscribes, 0);
    watch.running(window);
    expect(subscribes, 1);
    watch.running(null);
    errors.add('window:7');
    await pumpEventQueue();

    expect(stopped, isEmpty);
    expect(errors.hasListener, isFalse);
  });

  test('a second failure for the same share stops it once', () async {
    watch.running(window);
    errors
      ..add('window:7')
      ..add('window:7');
    await pumpEventQueue();

    expect(stopped, hasLength(1));
  });
}
