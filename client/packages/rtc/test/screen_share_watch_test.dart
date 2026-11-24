// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A recovery restart that a stop overtook must not put the share back up.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_rtc/src/screen_share_local.dart';
import 'package:slimm_rtc/src/screen_share_watch.dart';

const _request =
    ShareRequest(ScreenShareQuality.standard, 'win-1', false, null);

void main() {
  late List<bool> applied;
  late Completer<void> stopping;
  late ScreenShareWatch watch;

  setUp(() {
    applied = [];
    stopping = Completer<void>();
    watch = ScreenShareWatch(
      participant: () => null,
      isWindows: () => true,
      apply: (enabled, request) async {
        applied.add(enabled);
        if (!enabled) await stopping.future;
        return ScreenShareOutcome.started;
      },
    );
    watch.watch(_request, ScreenShareOutcome.started);
  });

  tearDown(() => watch.stop());

  test('a stop during the restart leaves the share stopped', () async {
    final restart = watch.restart();
    await pumpEventQueue();
    watch.stop();
    stopping.complete();
    await restart;

    expect(applied, [false]);
  });

  test('a restart nothing interrupted stops then starts the share', () async {
    stopping.complete();
    await watch.restart();

    expect(applied, [false, true]);
  });
}
