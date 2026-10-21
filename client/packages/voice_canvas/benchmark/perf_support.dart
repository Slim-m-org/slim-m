// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Sampling, summary statistics and result output shared by the canvas
/// interaction benchmarks.
///
/// Where `harness.dart` times a pure-Dart body in a tight batch, these
/// benchmarks time whole pointer-move-plus-frame iterations, so each sample
/// is kept and summarised as a distribution: a median alone hides the
/// dropped-frame tail that decides whether drawing feels smooth.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

/// One frame at 60 Hz and at 120 Hz, in microseconds.
const double budget60Us = 16667;
const double budget120Us = 8333;

/// A sorted sample set, in microseconds.
class Dist {
  Dist(Iterable<double> samples) : sorted = (List<double>.of(samples)..sort());

  final List<double> sorted;

  int get count => sorted.length;

  double _at(double q) {
    if (sorted.isEmpty) return 0;
    final i = math.min(sorted.length - 1, (q * sorted.length).floor());
    return sorted[i];
  }

  double get median => _at(0.5);
  double get p95 => _at(0.95);
  double get p99 => _at(0.99);
  double get max => sorted.isEmpty ? 0 : sorted.last;
  double get mean =>
      sorted.isEmpty ? 0 : sorted.reduce((a, b) => a + b) / sorted.length;

  /// Fraction of samples over [limitUs].
  double over(double limitUs) => sorted.isEmpty
      ? 0
      : sorted.where((s) => s > limitUs).length / sorted.length;

  Map<String, Object> toJson() => <String, Object>{
        'n': count,
        'median_us': _r(median),
        'p95_us': _r(p95),
        'p99_us': _r(p99),
        'max_us': _r(max),
        'mean_us': _r(mean),
        'over_16_7ms': double.parse(over(budget60Us).toStringAsFixed(4)),
        'over_8_3ms': double.parse(over(budget120Us).toStringAsFixed(4)),
      };

  static double _r(double v) => double.parse(v.toStringAsFixed(1));
}

/// Collects named rows, prints them, and writes them as JSON.
class PerfLog {
  PerfLog(this.suite);

  final String suite;
  final List<Map<String, Object>> rows = <Map<String, Object>>[];
  final Map<String, Object> meta = <String, Object>{};

  void add(String name, Dist dist, {Map<String, Object> extra = const {}}) {
    final json = <String, Object>{'name': name, ...dist.toJson(), ...extra};
    rows.add(json);
    // ignore: avoid_print
    print(
      '${name.padRight(58)} med ${_ms(dist.median)}  p95 ${_ms(dist.p95)}  '
      'p99 ${_ms(dist.p99)}  max ${_ms(dist.max)}  '
      '>16.7ms ${(dist.over(budget60Us) * 100).toStringAsFixed(1)}%',
    );
  }

  /// A scalar row, such as a count or a byte size.
  void value(String name, num value, {String unit = ''}) {
    rows.add(<String, Object>{'name': name, 'value': value, 'unit': unit});
    // ignore: avoid_print
    print('${name.padRight(58)} $value $unit');
  }

  static String _ms(double us) => (us / 1000).toStringAsFixed(3).padLeft(8);

  /// Writes to `$CANVAS_PERF_OUT/<suite>.json` when that directory is set.
  void flush() {
    final dir = Platform.environment['CANVAS_PERF_OUT'];
    if (dir == null || dir.isEmpty) return;
    Directory(dir).createSync(recursive: true);
    File('$dir/$suite.json').writeAsStringSync(
      const JsonEncoder.withIndent(' ').convert(<String, Object>{
        'suite': suite,
        'meta': meta,
        'rows': rows,
      }),
    );
  }
}

/// Resident set size in kilobytes, from /proc, or 0 where it is unavailable.
int rssKb() {
  try {
    for (final line in File('/proc/self/status').readAsLinesSync()) {
      if (line.startsWith('VmRSS:')) {
        return int.parse(line.split(RegExp(r'\s+'))[1]);
      }
    }
  } on Object {
    return 0;
  }
  return 0;
}
