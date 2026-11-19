// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a soak run measured, and the judgement of what grew.
library;

import 'dart:convert';
import 'dart:io';

import 'soak_vm.dart';

/// One reading of everything, taken with the app at rest on the same screen.
class SoakSample {
  SoakSample({
    required this.hours,
    required this.gauges,
    required this.breakdowns,
    this.heap,
  });

  final double hours;

  /// Single numbers, by name.
  final Map<String, num> gauges;

  /// The same things, split by class or by where they were opened.
  final Map<String, Map<String, int>> breakdowns;
  final HeapSample? heap;

  /// The gauges alone. Only the two samples a report compares keep their
  /// breakdowns, or a long run's own samples would be what grows on the heap.
  SoakSample slim() => SoakSample(
    hours: hours,
    gauges: gauges,
    breakdowns: const {},
    heap: heap == null
        ? null
        : HeapSample(const {}, heap!.heapBytes, heap!.rssBytes),
  );

  Map<String, Object?> toJson() => {
    'hours': hours,
    'gauges': gauges,
    'breakdowns': breakdowns,
    if (heap != null)
      'heap': {
        'heap_bytes': heap!.heapBytes,
        'rss_bytes': heap!.rssBytes,
        'classes': {
          for (final e in heap!.classes.entries)
            e.key: [e.value.instances, e.value.bytes],
        },
      },
  };
}

/// A gauge that must stay level, and how much wobble is not growth.
class Level {
  const Level(this.gauge, {this.ratio = 1.15, this.slack = 0, this.ceiling});

  final String gauge;
  final double ratio;
  final num slack;

  /// For a gauge that is allowed to climb to a known bound: it is judged against the bound instead.
  final num? ceiling;
}

/// What every run must hold level, however short.
const strictLevels = [
  Level('timers.pending', ratio: 1, slack: 4),
  // A voice channel joined for the first time adds two that are kept for a while.
  Level('live.listeners', ratio: 1, slack: 6),
  Level('bench.background_rebuilds', slack: 8),
];

/// What a run of hours must also hold level, once its caches have filled.
///
/// Wall-clock costs are reported but not judged: a shared machine moves them
/// more than a leak would. The whole store is not judged either, since it is
/// allowed a thousand rows for every channel there is; its fullest channel is.
const longLevels = [
  ...strictLevels,
  Level('objects.undisposed', slack: 400),
  Level('providers.live', slack: 80),
  Level('tree.elements', slack: 400),
  // Flutter's own cap on decoded images.
  Level('images.cached', ceiling: 1000),
  Level('extras.entries', ceiling: 3600),
  // The ceiling of a channel's rows, and the ten minutes of traffic between two sweeps.
  Level('db.fullest_channel', ceiling: 1200),
  Level('bench.rebuilds_per_message', slack: 3),
];

num _median(List<num> values) {
  final sorted = [...values]..sort();
  return sorted[sorted.length ~/ 2];
}

class SoakReport {
  SoakReport(this.samples, {required this.levels, this.warmup = 1});

  final List<SoakSample> samples;
  final List<Level> levels;

  /// Leading samples left out of the judgement: caches are still filling.
  final int warmup;

  List<SoakSample> get _judged => samples.sublist(warmup);

  /// Each level gauge that grew, as a sentence; empty when the run held level.
  ///
  /// Compares the median of the first third of the judged samples with the
  /// median of the last third, so one noisy reading neither hides nor fakes a trend.
  List<String> growth() {
    final judged = _judged;
    if (judged.length < 3) return const [];
    final third = (judged.length / 3).ceil();
    final found = <String>[];
    for (final level in levels) {
      final series = [for (final s in judged) s.gauges[level.gauge] ?? 0];
      final early = _median(series.sublist(0, third));
      final late = _median(series.sublist(series.length - third));
      final ceiling = level.ceiling;
      if (ceiling != null) {
        if (late > ceiling) found.add('${level.gauge} is $late, over $ceiling');
      } else if (late > early * level.ratio + level.slack) {
        found.add('${level.gauge} grew from $early to $late');
      }
    }
    return found;
  }

  /// The entries of [breakdown] that gained most between the first judged sample and the last.
  List<MapEntry<String, int>> gained(String breakdown, {int top = 12}) {
    final first = _judged.first.breakdowns[breakdown] ?? const {};
    final last = _judged.last.breakdowns[breakdown] ?? const {};
    final deltas = [
      for (final e in last.entries)
        if (e.value - (first[e.key] ?? 0) > 0)
          MapEntry(
            '${e.key} (${first[e.key] ?? 0} -> ${e.value})',
            e.value - (first[e.key] ?? 0),
          ),
    ]..sort((a, b) => b.value.compareTo(a.value));
    return deltas.take(top).toList();
  }

  /// Heap classes that gained instances between the first judged sample and the last.
  List<String> heapGained({int top = 25}) {
    final first = _judged.first.heap;
    final last = _judged.last.heap;
    if (first == null || last == null) return const [];
    final deltas = <(String, int, int, int)>[];
    for (final e in last.classes.entries) {
      final before = first.classes[e.key];
      final instances = e.value.instances - (before?.instances ?? 0);
      final bytes = e.value.bytes - (before?.bytes ?? 0);
      if (bytes > 0) deltas.add((e.key, instances, bytes, e.value.instances));
    }
    deltas.sort((a, b) => b.$3.compareTo(a.$3));
    return [
      for (final (name, instances, bytes, now) in deltas.take(top))
        '${(bytes / 1024).toStringAsFixed(0).padLeft(8)} KB  '
            '${instances.toString().padLeft(8)} more ($now now)  $name',
    ];
  }

  String render() {
    final out = StringBuffer();
    final names = samples.first.gauges.keys.toList();
    out.writeln(
      'gauge'.padRight(32) +
          [for (final s in samples) '${s.hours.toStringAsFixed(1)}h'.padLeft(9)]
              .join(),
    );
    for (final name in names) {
      out.writeln(
        name.padRight(32) +
            [
              for (final s in samples) _cell(s.gauges[name] ?? 0).padLeft(9),
            ].join(),
      );
    }
    for (final breakdown in samples.last.breakdowns.keys) {
      final top = gained(breakdown);
      if (top.isEmpty) continue;
      out.writeln('\n$breakdown that gained after warm-up:');
      for (final e in top) {
        out.writeln('  +${e.value}  ${e.key}');
      }
    }
    final heap = heapGained();
    if (heap.isNotEmpty) {
      out.writeln(
        '\nheap classes that gained after warm-up (after a collection):',
      );
      heap.forEach(out.writeln);
    }
    final grew = growth();
    out.writeln(grew.isEmpty ? '\nheld level.' : '\nGREW:');
    grew.forEach(out.writeln);
    return out.toString();
  }

  static String _cell(num value) =>
      value is int || value == value.roundToDouble()
      ? '${value.round()}'
      : value.toStringAsFixed(1);

  void write(String label) {
    final dir = Directory('build/soak')..createSync(recursive: true);
    File('${dir.path}/soak-$label.json').writeAsStringSync(
      jsonEncode({
        'samples': [for (final s in samples) s.toJson()],
        'growth': growth(),
      }),
    );
    File('${dir.path}/soak-$label.txt').writeAsStringSync(render());
  }
}
