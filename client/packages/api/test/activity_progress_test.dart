// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:test/test.dart';
import 'package:slimm_api/api.dart';

void main() {
  const progress = ActivityProgress(
    positionMs: 10000,
    durationMs: 60000,
    sampledAtMs: 1000,
  );

  test('position extrapolates from the sample and holds at the end', () {
    expect(progress.positionAt(1000), 10000);
    expect(progress.positionAt(6000), 15000);
    expect(progress.positionAt(500), 10000);
    expect(progress.positionAt(999999), 60000);
  });

  test('an activity round-trips its progress and ignores a partial set', () {
    final activity = PresenceActivity.tryFromJson({
      'type': 'listening',
      'title': 'Song',
      'duration_ms': 60000,
      'position_ms': 10000,
      'position_at': 1000,
    })!;
    expect(activity.progress, progress);
    expect(PresenceActivity.tryFromJson(activity.toJson()), activity);
    final partial = PresenceActivity.tryFromJson({
      'type': 'listening',
      'title': 'Song',
      'duration_ms': 60000,
    })!;
    expect(partial.progress, isNull);
    final outOfRange = PresenceActivity.tryFromJson({
      'type': 'listening',
      'title': 'Song',
      'duration_ms': 60000,
      'position_ms': 60001,
      'position_at': 1,
    })!;
    expect(outOfRange.progress, isNull);
  });
}
