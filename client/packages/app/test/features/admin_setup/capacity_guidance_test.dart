// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The plain-language guidance read off the server's capacity report.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/admin_setup/providers/capacity_guidance.dart';

const _gib = 1024 * 1024 * 1024;

api.SpaceCapacity _capacity({
  int cores = 8,
  int? free = 400 * _gib,
  int? total = 500 * _gib,
  int? limit,
  String binding = 'connections',
  bool voice = false,
}) => api.SpaceCapacity(
  cores: cores,
  voiceConfigured: voice,
  memoryTotalBytes: 16 * _gib,
  memoryLimitBytes: limit,
  diskFreeBytes: free,
  diskTotalBytes: total,
  estimate: api.SpaceCapacityEstimate(
    binding: binding,
    connectionLimit: 1024,
    membersMin: 340,
    membersMax: 770,
    voiceMin: voice ? 40 : null,
    voiceMax: voice ? 70 : null,
  ),
);

void main() {
  test('bytes read as whole or one-decimal gigabytes', () {
    expect(formatCapacityBytes(8 * _gib), '8 GB');
    expect(formatCapacityBytes((7.5 * _gib).round()), '7.5 GB');
    expect(formatCapacityBytes(2048 * _gib), '2 TB');
  });

  test('the machine line names a container limit', () {
    expect(
      machineSummary(_capacity(limit: 2 * _gib)),
      '8 cores, 2 GB memory (container limit), 400 GB free of 500 GB disk',
    );
    expect(
      machineSummary(_capacity(cores: 1, free: null)),
      startsWith('1 core,'),
    );
  });

  test('the limit line says whether more hardware helps', () {
    final memory = _capacity(binding: 'memory').estimate;
    final capped = _capacity().estimate;
    expect(limitSummary(memory), contains('More memory raises it'));
    expect(limitSummary(capped), contains('will not raise this'));
  });

  test('voice is never stated as this machine alone', () {
    expect(voiceSummary(_capacity()), 'Voice is not set up on this server.');
    final text = voiceSummary(_capacity(voice: true));
    expect(text, contains('may be on another machine'));
    expect(text, contains('about 40 to 70 people'));
  });

  test('low disk recommends compression and retention', () {
    final tips = setupTips(_capacity(free: 6 * _gib, total: 100 * _gib));
    expect(tips.map((t) => t.target), [
      SetupTipTarget.media,
      SetupTipTarget.retention,
    ]);
  });

  test('a mostly full large disk is low too', () {
    final tips = setupTips(_capacity(free: 30 * _gib, total: 500 * _gib));
    expect(tips, hasLength(2));
  });

  test('few cores recommend a lower screen share', () {
    final tips = setupTips(_capacity(cores: 2));
    expect(tips.single.target, SetupTipTarget.voice);
    expect(setupTips(_capacity(cores: 3)), isEmpty);
  });

  test('an unreadable disk recommends nothing about disk', () {
    expect(setupTips(_capacity(free: null, total: null)), isEmpty);
  });
}
