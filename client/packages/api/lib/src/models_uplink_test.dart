// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The admin uplink test's measurements.
library;

/// One measurement of how fast the server host can send.
class UplinkTest {
  const UplinkTest({
    required this.id,
    required this.measuredAt,
    required this.mbitPerSecond,
    required this.bytes,
    required this.durationMs,
  });

  final int id;
  final DateTime measuredAt;
  final double mbitPerSecond;
  final int bytes;
  final int durationMs;

  factory UplinkTest.fromJson(Map<String, dynamic> json) => UplinkTest(
        id: json['id'] as int,
        measuredAt:
            DateTime.fromMillisecondsSinceEpoch(json['measured_at'] as int),
        mbitPerSecond: (json['mbit_per_s'] as num).toDouble(),
        bytes: json['bytes'] as int,
        durationMs: json['duration_ms'] as int,
      );
}
