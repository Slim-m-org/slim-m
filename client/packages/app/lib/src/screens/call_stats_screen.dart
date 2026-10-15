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
import '../routing/routes.dart';
import '../widgets/call_stats_lines.dart';
import '../widgets/settings_empty.dart';
import '../widgets/settings_section_header.dart';
import '../widgets/settings_toggle_row.dart';
import 'settings_screen_scaffold.dart';

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
          : const SettingsEmpty('Join a call to see its video stats.'),
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
              return const SettingsEmpty('Waiting for the first sample.');
            }
            if (samples.isEmpty) {
              return const SettingsEmpty('Nobody is sending video yet.');
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

class _SampleCard extends StatelessWidget {
  const _SampleCard({required this.sample});

  final VideoStatsSample sample;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final transport = callStatsTransportLine(sample.transport);
    final figures = AppText.caption.copyWith(
      color: tokens.textSecondary,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return SettingsSectionCard(
      title: callStatsTitle(sample),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final stream in sample.streams) ...[
          for (final (i, line) in callStatsStreamLines(
            stream,
            local: sample.local,
          ).indexed)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s8),
              child: Text(
                line,
                style: i == 0
                    ? AppText.ui.copyWith(
                        color: tokens.textPrimary,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      )
                    : figures,
              ),
            ),
          const SizedBox(height: AppSpacing.s8),
        ],
        if (sample.streams.isEmpty)
          const SettingsEmptyLine('No video stream reported yet.'),
        if (transport != null && transport.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s8),
            child: Text(transport, style: figures),
          ),
      ],
    );
  }
}
