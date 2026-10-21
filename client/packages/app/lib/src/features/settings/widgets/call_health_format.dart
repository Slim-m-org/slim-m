// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The words for the last call's audio numbers.
library;

import 'package:slimm_rtc/rtc.dart';

const _noData = 'no data';

String _pct(double? v) =>
    v == null ? _noData : '${(v * 100).toStringAsFixed(1)}%';
String _ms(double? v) => v == null ? _noData : '${v.round()} ms';

String _pair(double? p50, double? p95, String Function(double?) f) =>
    p50 == null ? _noData : '${f(p50)} median, ${f(p95)} worst';

/// One line per measure, for what others sounded like.
List<String> describeCallHealth(HealthStats remote) => [
  'Breaking up: ${_pair(remote.concealP50, remote.concealP95, _pct)}',
  'Delay buffer: ${_pair(remote.bufferP50, remote.bufferP95, _ms)}',
  'Jitter: ${_pair(remote.jitterP50, remote.jitterP95, _ms)}',
  'Packets lost: ${_pair(remote.lossP50, remote.lossP95, _pct)}',
  'Round trip: ${_pair(remote.rttP50, remote.rttP95, _ms)}',
];
