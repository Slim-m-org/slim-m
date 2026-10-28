// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Plain-language guidance from the server's capacity report: what the
/// machine is, what it can carry, and which settings its hardware argues for.
/// The numbers come from the server; the assumptions are in
/// docs/capacity-guidance.md.
library;

import 'package:slimm_api/api.dart' as api;

/// Where the capacity guidance is documented, linked from every place it shows.
const capacityGuidanceUrl =
    'https://github.com/Slim-m-org/slim-m/blob/main/docs/capacity-guidance.md';

const _gib = 1024 * 1024 * 1024;

/// Below this much free disk, uploads are worth bounding.
const lowDiskBytes = 20 * _gib;

/// A volume with less than this share free is low however large it is.
const lowDiskShare = 0.1;

/// At or under this many cores, a screen share competes with chat for the processor.
const fewCores = 2;

/// Which setup step a tip belongs to.
enum SetupTipTarget {
  media('Uploads'),
  retention('Retention'),
  voice('Voice');

  const SetupTipTarget(this.label);

  final String label;
}

class SetupTip {
  const SetupTip(this.target, this.text);

  final SetupTipTarget target;
  final String text;
}

/// `8 GB`, or `7.5 GB` when it is not whole; terabytes past 1024 GB.
String formatCapacityBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final whole = value >= 10 || value == value.roundToDouble();
  return '${value.toStringAsFixed(whole ? 0 : 1)} ${units[unit]}';
}

String _plural(int count, String one, String many) =>
    '$count ${count == 1 ? one : many}';

/// `4 cores, 8 GB memory, 120 GB free of 500 GB disk`.
String machineSummary(api.SpaceCapacity capacity) {
  final parts = [_plural(capacity.cores, 'core', 'cores')];
  final memory = capacity.usableMemoryBytes;
  if (memory != null) {
    final limited =
        capacity.memoryLimitBytes != null &&
        capacity.memoryLimitBytes! < (capacity.memoryTotalBytes ?? memory + 1);
    parts.add(
      '${formatCapacityBytes(memory)} memory${limited ? ' (container limit)' : ''}',
    );
  }
  final free = capacity.diskFreeBytes;
  final total = capacity.diskTotalBytes;
  if (free != null) {
    parts.add(
      total == null
          ? '${formatCapacityBytes(free)} free disk'
          : '${formatCapacityBytes(free)} free of ${formatCapacityBytes(total)} disk',
    );
  }
  return parts.join(', ');
}

String membersSummary(api.SpaceCapacityEstimate estimate) {
  final range = estimate.membersMin == estimate.membersMax
      ? 'about ${estimate.membersMax}'
      : 'about ${estimate.membersMin} to ${estimate.membersMax}';
  return 'Comfortable for $range people connected at once.';
}

/// Why the range stops where it does, and so whether more hardware moves it.
String limitSummary(api.SpaceCapacityEstimate estimate) =>
    switch (estimate.binding) {
      'memory' => 'Memory is the limit here. More memory raises it.',
      'processor' => 'Processor is the limit here. More cores raise it.',
      _ =>
        'The server holds at most ${estimate.connectionLimit} connections, '
            'so more cores or memory will not raise this.',
    };

/// Voice depends on LiveKit, which may run elsewhere, so this never states a
/// figure as if it were this machine's.
String voiceSummary(api.SpaceCapacity capacity) {
  final low = capacity.estimate.voiceMin;
  final high = capacity.estimate.voiceMax;
  if (!capacity.voiceConfigured || low == null || high == null) {
    return 'Voice is not set up on this server.';
  }
  final range = low == high ? 'about $high' : 'about $low to $high';
  return 'Voice runs through LiveKit, which may be on another machine. '
      'If it shares this one, $range people in one call. Otherwise it '
      "depends on that machine's memory, roughly 60 people per 512 MB.";
}

bool _diskIsLow(api.SpaceCapacity capacity) {
  final free = capacity.diskFreeBytes;
  if (free == null) return false;
  final total = capacity.diskTotalBytes;
  return free < lowDiskBytes ||
      (total != null && total > 0 && free < total * lowDiskShare);
}

/// The settings this hardware argues for, each tied to the step that sets it.
List<SetupTip> setupTips(api.SpaceCapacity capacity) {
  final tips = <SetupTip>[];
  if (_diskIsLow(capacity)) {
    final free = formatCapacityBytes(capacity.diskFreeBytes!);
    tips.add(
      SetupTip(
        SetupTipTarget.media,
        'Disk is low ($free free). Photo compression keeps uploads small.',
      ),
    );
    tips.add(
      SetupTip(
        SetupTipTarget.retention,
        'Disk is low ($free free). A retention window deletes old messages '
        'and their attachments.',
      ),
    );
  }
  if (capacity.cores <= fewCores) {
    tips.add(
      SetupTip(
        SetupTipTarget.voice,
        'This server has ${_plural(capacity.cores, 'core', 'cores')}. A '
        'lower screen share limit leaves more of it for chat.',
      ),
    );
  }
  return tips;
}

List<SetupTip> tipsFor(SetupTipTarget target, api.SpaceCapacity capacity) => [
  for (final tip in setupTips(capacity))
    if (tip.target == target) tip,
];
