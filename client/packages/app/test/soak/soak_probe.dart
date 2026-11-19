// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Takes one [SoakSample]: puts the app at rest on the same screen, reads
/// every counter, and times two fixed pieces of work.
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/providers/message_extras.dart';
import 'package:slimm_app/src/providers/providers.dart';

import 'soak_app.dart';
import 'soak_census.dart';
import 'soak_driver.dart';
import 'soak_report.dart';
import 'soak_vm.dart';

class SoakProbe {
  SoakProbe(
    this.tester,
    this.app,
    this.driver,
    this.timers, {
    Set<String> traced = const {},
    this.benchMessages = 30,
  }) : objects = ObjectCensus(traced: traced);

  /// How many messages each bench delivers; fewer keeps a smoke run short.
  final int benchMessages;

  final WidgetTester tester;
  final SoakApp app;
  final SoakDriver driver;
  final TimerCensus timers;
  final ObjectCensus objects;
  final rebuilds = RebuildCensus();
  VmProbe? vm;

  Future<void> start() async {
    objects.start();
    rebuilds.start();
    vm = await tester.runAsync<VmProbe?>(VmProbe.connect);
  }

  Future<void> stop() async {
    objects.stop();
    rebuilds.stop();
    await tester.runAsync(() async => vm?.close());
  }

  Future<SoakSample> sample(double hours, {required int wallMs}) async {
    final sinceLast = rebuilds.take();
    await driver.rest();
    // Image decodes are engine work the fake clock never finishes.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(seconds: 1));
    rebuilds
      ..take()
      ..takeRoots();
    await driver.benchIdle(benchMessages);
    final idleRebuilds = rebuilds.take();
    rebuilds.takeRoots();
    final message = await driver.benchOpenChannel(benchMessages);
    final messageRebuilds = rebuilds.take();
    final messageRoots = rebuilds.takeRoots();
    // A debounced read marker or a typing row lands late; it belongs to the bench that caused it.
    await tester.pump(const Duration(seconds: 8));
    rebuilds.take();
    final background = await driver.benchBackground(benchMessages);
    final backgroundRebuilds = rebuilds.take();
    final backgroundRoots = rebuilds.takeRoots();
    final switching = await driver.benchChannelSwitch();
    await driver.rest();
    rebuilds
      ..take()
      ..takeRoots();

    var rows = 0;
    var fullest = 0;
    var extras = 0;
    final providers = <String, int>{};
    for (final runtime in app.host.accounts) {
      final container = runtime.container;
      final db = await container.read(databaseProvider.future);
      final count = await db
          .customSelect('SELECT count(*) AS c FROM messages')
          .getSingle();
      rows += count.read<int>('c');
      final busiest = await db
          .customSelect(
            'SELECT max(n) AS c FROM '
            '(SELECT count(*) AS n FROM messages GROUP BY channel_id)',
          )
          .getSingle();
      fullest = math.max(fullest, busiest.read<int?>('c') ?? 0);
      extras += container.read(messageExtrasProvider).length;
      app.labels
          .count(container)
          .forEach(
            (label, n) => providers[label] = (providers[label] ?? 0) + n,
          );
    }
    final heap = await tester.runAsync(() async => vm?.sample());
    final cache = PaintingBinding.instance.imageCache;
    return SoakSample(
      hours: hours,
      gauges: {
        'timers.pending': timers.pending.count,
        'live.listeners': app.liveListeners.count,
        'objects.undisposed': objects.total,
        'providers.live': providers.values.fold<int>(0, (a, b) => a + b),
        'tree.elements': tester.allElements.length,
        'images.cached': cache.currentSize,
        'images.live': cache.liveImageCount,
        'images.cached_kb': cache.currentSizeBytes ~/ 1024,
        'db.messages': rows,
        'db.fullest_channel': fullest,
        'extras.entries': extras,
        'bench.idle_rebuilds': _total(idleRebuilds) / benchMessages,
        'bench.rebuilds_per_message': _total(messageRebuilds) / benchMessages,
        'bench.background_rebuilds': _total(backgroundRebuilds) / benchMessages,
        'bench.message_us': message,
        'bench.background_message_us': background,
        'bench.channel_switch_ms': switching,
        'since_last.rebuilds': _total(sinceLast),
        'since_last.wall_ms': wallMs,
        'heap.kb': (heap?.heapBytes ?? 0) ~/ 1024,
        'rss.mb': (heap?.rssBytes ?? 0) ~/ (1024 * 1024),
      },
      breakdowns: {
        'undisposed objects': Map.of(objects.alive),
        'traced objects': Map.of(objects.tracedAlive),
        'rebuilds for the open-channel bench': messageRebuilds,
        'widgets that asked to rebuild in the open-channel bench': messageRoots,
        'rebuilds for the background bench': backgroundRebuilds,
        'widgets that asked to rebuild in the background bench':
            backgroundRoots,
        'live providers': providers,
        'pending timers': timers.pending.byOrigin(),
        'live-event listeners': app.liveListeners.byOrigin(),
        'rebuilds since the last sample': sinceLast,
      },
      heap: heap,
    );
  }

  static int _total(Map<String, int> counts) =>
      counts.values.fold(0, (a, b) => a + b);
}
