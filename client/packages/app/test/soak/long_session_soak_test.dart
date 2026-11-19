// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Hours of a signed-in desktop session in a few minutes of real time, and a
/// check that nothing it holds keeps growing. See docs/soak-harness.md.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'soak_app.dart';
import 'soak_census.dart';
import 'soak_driver.dart';
import 'soak_probe.dart';
import 'soak_report.dart';

int _env(String name, int fallback) =>
    int.tryParse(Platform.environment[name] ?? '') ?? fallback;

void main() {
  // Unset, a smoke run short enough for every test run; set, that many simulated hours.
  final hours = _env('SLIMM_SOAK_HOURS', 0);
  final smoke = hours == 0;
  final accounts = _env('SLIMM_SOAK_ACCOUNTS', smoke ? 2 : 3);
  final members = _env('SLIMM_SOAK_MEMBERS', smoke ? 120 : 500);
  final label = Platform.environment['SLIMM_SOAK_LABEL'] ?? 'latest';
  final judged = Platform.environment['SLIMM_SOAK_REPORT_ONLY'] != '1';
  final traced = {...?Platform.environment['SLIMM_SOAK_TRACE']?.split(',')};
  final retained = [
    ...?Platform.environment['SLIMM_SOAK_RETAINERS']?.split(','),
  ];
  const epochsPerHour = 6;
  // About a dozen samples however long the run is; a smoke run takes four across one epoch.
  final sampleCount = smoke ? 4 : math.min(12, hours * epochsPerHour);
  final stepsPerSample = smoke
      ? stepsPerEpoch ~/ 4
      : hours * epochsPerHour * stepsPerEpoch ~/ sampleCount;
  // Leading samples left out of the judgement, while caches fill.
  final warmup = smoke ? 1 : sampleCount ~/ 4;
  final simulated = smoke ? 'a smoke run' : '$hours hours';

  testWidgets(
    '$simulated of traffic, calls, channel and account switches holds level',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final timers = TimerCensus();
      await timers.run(() async {
        final app = SoakApp(accounts: accounts, seed: 36, members: members);
        final driver = SoakDriver(tester, app, seed: 36);
        final probe = SoakProbe(
          tester,
          app,
          driver,
          timers,
          traced: traced,
          benchMessages: smoke ? 8 : 30,
        );
        await probe.start();
        await app.boot(tester);
        await driver.open();

        final samples = <SoakSample>[];
        final wall = Stopwatch()..start();
        for (var sample = 1; sample <= sampleCount; sample++) {
          await driver.steps(stepsPerSample);
          expect(tester.takeException(), isNull);
          // The test binding keeps every text input call it is sent.
          tester.testTextInput.log.clear();
          samples.add(
            await probe.sample(
              sample * stepsPerSample / (stepsPerEpoch * epochsPerHour),
              wallMs: wall.elapsedMilliseconds,
            ),
          );
          wall.reset();
          final previous = samples.length - 2;
          if (previous > warmup) samples[previous] = samples[previous].slim();
        }

        for (final name in retained) {
          final paths = await tester.runAsync(
            () async => probe.vm?.retainers(name),
          );
          // ignore: avoid_print
          print('what holds $name:\n  ${paths?.join('\n  ')}');
        }
        final report = SoakReport(
          samples,
          levels: smoke ? strictLevels : longLevels,
          warmup: warmup,
        );
        report.write(label);
        // ignore: avoid_print
        print(report.render());
        // ignore: avoid_print
        print('frames delivered: ${driver.delivered}');
        await probe.stop();
        await app.dispose(tester);
        if (judged) expect(report.growth(), isEmpty);
      });
    },
    timeout: const Timeout(Duration(hours: 3)),
  );
}
