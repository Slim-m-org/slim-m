// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Live numbers for the current call: the audio of the last minute and the
/// video actually sent and received, as opposed to what the settings ask for.
///
/// Video sampling runs while this screen is open, while we publish video, or
/// while logging every sample is on.
library;

import 'dart:async';

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

/// The audio is sampled every 5 s, so a faster repaint shows nothing new.
const _audioRefresh = Duration(seconds: 5);

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
          ? _Stats(
              sampler: sampler,
              health: ref.read(voiceControllerProvider.notifier).health,
            )
          : const _StatsEmpty('Join a call to see its stats.'),
    );
  }
}

class _Stats extends StatefulWidget {
  const _Stats({required this.sampler, required this.health});

  final CallStatsSampler sampler;
  final VoiceHealth health;

  @override
  State<_Stats> createState() => _StatsState();
}

class _StatsState extends State<_Stats> {
  Timer? _audioTick;

  @override
  void initState() {
    super.initState();
    _audioTick = Timer.periodic(_audioRefresh, (_) => setState(() {}));
  }

  @override
  void dispose() {
    _audioTick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sampler = widget.sampler;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSectionCard(
          children: [
            SettingsToggleRow(
              label: 'Log every sample',
              description: 'Write each sample to the debug log.',
              value: sampler.logging,
              semanticLabel: 'Log every call stats sample to the debug log',
              onChanged: (on) => setState(() => sampler.setLogging(on)),
            ),
          ],
        ),
        _AudioCard(windows: widget.health.recentWindows()),
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

class _AudioCard extends StatelessWidget {
  const _AudioCard({required this.windows});

  final List<NamedWindow> windows;

  @override
  Widget build(BuildContext context) => SettingsSectionCard(
    title: 'Audio, last minute',
    children: [
      for (final w in windows)
        SettingsDetailRow(
          title: callStatsAudioTitle(w),
          detail: callStatsAudioLine(w),
          monoDetail: true,
        ),
      if (windows.isEmpty)
        const SettingsEmptyState(
          icon: AppIcons.mic,
          title: 'Waiting for audio numbers.',
        ),
    ],
  );
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
