// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Operator-visible storage usage and sweep health: `GET /space/storage`.
/// Requires MANAGE_SERVER, the same bit `/space/settings`, Emoji, Performance
/// and Analytics all require.
///
/// Always computed, unlike `AnalyticsPane`: there is no recording toggle, so
/// this mirrors that screen's overall shape (a scaffold plus an
/// `AppAsyncView`) without its on/off gate.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../../format.dart';
import '../../../../providers/admin_providers.dart';
import '../../../../routing/routes.dart';
import '../../../../widgets/attachment_format.dart' show formatByteSize;
import '../../widgets/settings_detail_row.dart';
import '../../widgets/settings_empty.dart';
import '../../widgets/settings_meter_row.dart';
import '../../widgets/settings_refresh_button.dart';
import '../../widgets/settings_section_header.dart';
import '../settings_screen_scaffold.dart';

class StorageScreen extends StatelessWidget {
  const StorageScreen({super.key});

  @override
  Widget build(BuildContext context) => const SettingsScreenScaffold(
    title: 'Storage',
    backTooltip: 'Back to Space settings',
    backFallback: Routes.spaceSettings,
    child: StoragePane(),
  );
}

/// The storage view, embeddable as a Space settings pane as well as routed.
class StoragePane extends ConsumerWidget {
  const StoragePane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final storage = ref.watch(spaceStorageProvider);
    return AppAsyncView<api.SpaceStorage>(
      value: AppAsyncState(data: storage.valueOrNull, error: storage.error),
      center: false,
      errorMessage: 'Could not load storage usage.',
      onRetry: () => ref.invalidate(spaceStorageProvider),
      data: (context, value) => _StorageView(storage: value),
    );
  }
}

class _StorageView extends ConsumerWidget {
  const _StorageView({required this.storage});

  final api.SpaceStorage storage;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _TotalsCard(
        storage: storage,
        onRefresh: () => ref.invalidate(spaceStorageProvider),
      ),
      _TopChannelsCard(
        channels: storage.topChannels,
        totalBytes: storage.attachmentBytes,
      ),
      _SweepsCard(sweeps: storage.sweeps),
    ],
  );
}

class _TotalsCard extends StatelessWidget {
  const _TotalsCard({required this.storage, required this.onRefresh});

  final api.SpaceStorage storage;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final onDisk = storage.databaseBytes + storage.attachmentBytes;
    final total = 'of ${formatByteSize(onDisk)}';
    return SettingsSectionCard(
      title: 'On disk',
      trailing: SettingsRefreshButton(
        label: 'Refresh storage usage',
        onPressed: onRefresh,
      ),
      children: [
        SettingsMeterRow(label: 'Total', value: formatByteSize(onDisk)),
        SettingsMeterRow(
          label: 'Database',
          value: formatByteSize(storage.databaseBytes),
          of: total,
          fraction: meterFraction(storage.databaseBytes, onDisk),
        ),
        SettingsMeterRow(
          label: 'Attachments',
          value: formatByteSize(storage.attachmentBytes),
          of: total,
          fraction: meterFraction(storage.attachmentBytes, onDisk),
        ),
        SettingsMeterRow(
          label: 'Reclaimable',
          value: formatByteSize(storage.databaseReclaimableBytes),
          of: 'of ${formatByteSize(storage.databaseBytes)} database',
          fraction: meterFraction(
            storage.databaseReclaimableBytes,
            storage.databaseBytes,
          ),
        ),
      ],
    );
  }
}

/// Channels holding the most attachment bytes, heaviest first. DMs and
/// threads are excluded server-side; see `store/storage.rs`.
class _TopChannelsCard extends StatelessWidget {
  const _TopChannelsCard({required this.channels, required this.totalBytes});

  final List<api.ChannelStorage> channels;
  final int totalBytes;

  @override
  Widget build(BuildContext context) => SettingsSectionCard(
    title: 'Storage by channel',
    children: [
      if (channels.isEmpty)
        const SettingsEmptyState(
          icon: AppIcons.storage,
          title: 'No channel has any stored attachments yet.',
        ),
      for (final channel in channels)
        SettingsMeterRow(
          label: '#${channel.name}',
          value: formatByteSize(channel.attachmentBytes),
          fraction: meterFraction(channel.attachmentBytes, totalBytes),
        ),
    ],
  );
}

/// When each background sweep last ran and roughly what it reclaimed. A
/// sweep that has never run is simply absent - see `store/storage.rs`.
class _SweepsCard extends StatelessWidget {
  const _SweepsCard({required this.sweeps});

  final List<api.SweepStatus> sweeps;

  @override
  Widget build(BuildContext context) => SettingsSectionCard(
    title: 'Background sweeps',
    children: [
      if (sweeps.isEmpty)
        const SettingsEmptyState(
          icon: AppIcons.clock,
          title: 'No sweep has run yet on this deployment.',
        ),
      for (final sweep in sweeps)
        SettingsDetailRow(
          title: sweepLabel(sweep.name),
          detail: sweepSummary(sweep),
        ),
    ],
  );
}

/// A human label for a sweep's stable snake_case identifier. Falls back to
/// the raw name for one this client does not recognise yet, rather than
/// hiding it: a future sweep should still show up, just without a nice name.
String sweepLabel(String name) => switch (name) {
  'token' => 'Expired sessions',
  'attachments' => 'Orphaned attachments',
  'canvas_ops' => 'Canvas history',
  'message_retention' => 'Message retention',
  _ => name,
};

/// "2h ago, freed 12 MB" - relative time since the last run, plus whatever
/// that run reclaimed in the sweep's own unit. `lastReclaimed` is not always
/// bytes (a row count for some sweeps), so this reads as a byte size only
/// when the sweep is one of the two that count bytes-adjacent file removals;
/// every other sweep reports a plain count instead.
String sweepSummary(api.SweepStatus sweep) {
  final ago = formatRelativeAgeMs(sweep.lastRunAt);
  if (sweep.lastReclaimed <= 0) return '$ago, nothing to reclaim';
  final unit = switch (sweep.name) {
    'attachments' => 'file(s) freed',
    'token' => 'row(s) removed',
    'canvas_ops' => 'row(s) compacted',
    'message_retention' => 'message(s) pruned',
    _ => 'reclaimed',
  };
  return '$ago, ${sweep.lastReclaimed} $unit';
}
