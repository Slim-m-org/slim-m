// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Live numbers for the video in the current call: what is actually sent and
/// received, as opposed to what the quality settings ask for.
///
/// Sampling runs only while this screen is open or console logging is on.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../providers/voice_controller.dart';
import '../../../routing/routes.dart';
import '../widgets/call_stats_lines.dart';
import '../../settings/widgets/settings_empty.dart';
import '../../settings/widgets/settings_section_header.dart';
import '../../settings/widgets/settings_detail_row.dart';
import '../../settings/widgets/settings_toggle_row.dart';
import '../../settings/screens/settings_screen_scaffold.dart';

class CallStatsScreen extends ConsumerWidget {
  const CallStatsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inCall =
        ref.watch(voiceControllerProvider).state == VoiceSessionState.connected;
    final sampler = ref.read(voiceControllerProvider.notifier).callStats;
    return SettingsScreenScaffold(
      title: 'Call stats',
      backTooltip: 'Back to settings',
      backFallback: Routes.personalSettings,
      child: inCall
          ? _Stats(sampler: sampler)
          : const _StatsEmpty('Join a call to see its video stats.'),
    );
  }
}

class _Stats extends StatefulWidget {
  const _Stats({required this.sampler});

  final CallStatsSampler sampler;

  @override
  State<_Stats> createState() => _StatsState();
}

class _StatsState extends State<_Stats> {
  @override
  Widget build(BuildContext context) {
    final sampler = widget.sampler;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSectionCard(
          children: [
            SettingsToggleRow(
              label: 'Log to console',
              description: 'Print one line per sample.',
              value: sampler.logging,
              semanticLabel: 'Log call stats to the console',
              onChanged: (on) => setState(() => sampler.setLogging(on)),
            ),
          ],
        ),
        StreamBuilder<CallStatsSnapshot>(
          stream: sampler.snapshots,
          initialData: sampler.latest.isEmpty ? null : sampler.latest,
          builder: (context, snapshot) {
            final samples = snapshot.data;
            if (samples == null) {
              return const _StatsEmpty('Waiting for the first sample.');
            }
            if (samples.isEmpty) {
              return const _StatsEmpty('Nobody is sending video yet.');
            }
            final ordered = [...samples]
              ..sort((a, b) => a.key.compareTo(b.key));
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [for (final s in ordered) _SampleCard(sample: s)],
            );
          },
        ),
      ],
    );
  }
}

class _StatsEmpty extends StatelessWidget {
  const _StatsEmpty(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => SettingsSectionCard(
    children: [SettingsEmptyState(icon: AppIcons.camera, title: message)],
  );
}

class _SampleCard extends StatelessWidget {
  const _SampleCard({required this.sample});

  final VideoStatsSample sample;

  @override
  Widget build(BuildContext context) {
    final transport = callStatsTransportLine(sample.transport);
    return SettingsSectionCard(
      title: callStatsTitle(sample),
      children: [
        for (final stream in sample.streams)
          _streamRow(callStatsStreamLines(stream, local: sample.local)),
        if (sample.streams.isEmpty)
          const SettingsEmptyState(
            icon: AppIcons.camera,
            title: 'No video stream reported yet.',
          ),
        if (transport != null && transport.isNotEmpty)
          SettingsDetailRow(
            title: 'Connection',
            detail: transport,
            monoDetail: true,
          ),
      ],
    );
  }

  Widget _streamRow(List<String> lines) => SettingsDetailRow(
    title: lines.first,
    detail: lines.length > 1 ? lines.skip(1).join('\n') : null,
    monoDetail: true,
  );
}
