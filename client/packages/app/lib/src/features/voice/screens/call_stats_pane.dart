// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// "Call stats" in personal settings: the caller's own talk time, pace, filler
/// words and languages, worked out by the server from their own transcript
/// lines and shown to no one else (decision 0113).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../routing/routes.dart';
import '../../../widgets/analytics_bar_chart.dart';
import '../../settings/providers/settings_index.dart' show aboutPane;
import '../../settings/widgets/settings_empty.dart';
import '../../settings/widgets/settings_meter_row.dart';
import '../../settings/widgets/settings_section_header.dart';
import '../providers/call_stats.dart';
import '../widgets/call_stats_format.dart';
import '../widgets/call_stats_ghost.dart';

const _windows = <({String label, int? days})>[
  (label: '7 days', days: 7),
  (label: '30 days', days: 30),
  (label: '90 days', days: 90),
  (label: 'All kept', days: null),
];

class CallStatsPane extends ConsumerStatefulWidget {
  const CallStatsPane({super.key});

  @override
  ConsumerState<CallStatsPane> createState() => _CallStatsPaneState();
}

class _CallStatsPaneState extends ConsumerState<CallStatsPane> {
  int _window = 1;

  @override
  Widget build(BuildContext context) {
    final days = _windows[_window].days;
    final stats = ref.watch(myCallStatsProvider(days));
    final selector = SettingsCardBlock(
      children: [
        AppSegmentedControl.fill(
          semanticLabel: 'Time window',
          options: [
            for (final w in _windows) AppSegmentedOption(label: w.label),
          ],
          selectedIndex: _window,
          onSegmentSelected: (index) => setState(() => _window = index),
        ),
      ],
    );
    return stats.when(
      loading: () => CallStatsGhost(selector: selector),
      error: (_, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingsSectionCard(
            title: 'Talk time',
            description: _private,
            children: [selector],
          ),
          AppErrorState(
            message: 'Could not load your call stats.',
            onRetry: () => ref.invalidate(myCallStatsProvider(days)),
          ),
        ],
      ),
      data: (data) => _StatsView(stats: data, selector: selector),
    );
  }
}

const _private = 'Only you can see these.';

class _StatsView extends StatelessWidget {
  const _StatsView({required this.stats, required this.selector});

  final api.CallStats stats;
  final Widget selector;

  @override
  Widget build(BuildContext context) {
    final pace = stats.wordsPerMinute;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSectionCard(
          title: 'Talk time',
          description: _private,
          children: [
            selector,
            if (stats.isEmpty)
              const SettingsEmptyState(
                icon: AppIcons.voice,
                title: 'No transcribed calls yet',
                detail:
                    'Talk in a transcribed call and your numbers show up here.',
              )
            else ...[
              SettingsMeterRow(
                label: 'Time talking',
                value: formatTalkTime(stats.talkMs),
              ),
              SettingsMeterRow(
                label: 'Calls you spoke in',
                value: '${stats.calls}',
              ),
              SettingsMeterRow(
                label: 'Words a minute',
                value: pace == null ? 'Not enough yet' : formatPace(pace),
              ),
            ],
          ],
        ),
        if (stats.fillers case final fillers?) _FillerCard(fillers: fillers),
        if (stats.languages.isNotEmpty)
          _LanguageCard(languages: stats.languages),
        if (stats.buckets.isNotEmpty) _ByDayCard(stats: stats),
        _Footer(retentionDays: stats.retentionDays),
      ],
    );
  }
}

class _FillerCard extends StatelessWidget {
  const _FillerCard({required this.fillers});

  final api.CallStatsFillers fillers;

  @override
  Widget build(BuildContext context) => SettingsSectionCard(
    title: 'Filler words',
    description:
        'English only, as the transcriber leaves out most ums and uhs.',
    children: [
      SettingsMeterRow(
        label: 'Per 100 words',
        value: formatPace(fillers.per100Words),
      ),
      for (final phrase in fillers.phrases)
        SettingsMeterRow(label: phrase.phrase, value: '${phrase.count}'),
    ],
  );
}

class _LanguageCard extends StatelessWidget {
  const _LanguageCard({required this.languages});

  final List<api.CallStatsLanguage> languages;

  @override
  Widget build(BuildContext context) => SettingsSectionCard(
    title: 'Languages',
    children: [
      for (final language in languages)
        SettingsMeterRow(
          label: callStatsLanguageName(language.code),
          value: '${(language.share * 100).round()}%',
          of: _pace(language),
          fraction: language.share,
        ),
    ],
  );

  String? _pace(api.CallStatsLanguage language) {
    final pace = language.pace;
    if (pace == null) return null;
    final unit = language.characters ? 'chars' : 'words';
    return '${formatPace(pace)} $unit/min';
  }
}

class _ByDayCard extends StatelessWidget {
  const _ByDayCard({required this.stats});

  final api.CallStats stats;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final unit = stats.weekly ? 'week' : 'day';
    final buckets = stats.buckets;
    final busiest = buckets.reduce((a, b) => b.talkMs > a.talkMs ? b : a);
    final label = buckets
        .map((b) => '${b.date}: ${formatTalkTime(b.talkMs)}')
        .join(', ');
    return SettingsSectionCard(
      title: 'Talk time by $unit',
      children: [
        SettingsCardBlock(
          gap: AppSpacing.s8,
          children: [
            AnalyticsBarChart(
              values: [for (final b in buckets) b.talkMs / 60000],
              semanticsLabel: 'Talk time per $unit: $label',
              ticks: _ticks(buckets),
              maxLabel: formatTalkTime(busiest.talkMs),
            ),
            Text(
              'Busiest $unit: ${busiest.date} (${formatTalkTime(busiest.talkMs)})',
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
          ],
        ),
      ],
    );
  }

  Map<int, String> _ticks(List<api.CallStatsBucket> buckets) => {
    0: _short(buckets.first.date),
    if (buckets.length > 2)
      buckets.length ~/ 2: _short(buckets[buckets.length ~/ 2].date),
    if (buckets.length > 1) buckets.length - 1: _short(buckets.last.date),
  };

  String _short(String isoDate) =>
      isoDate.length >= 10 ? isoDate.substring(5) : isoDate;
}

class _Footer extends StatelessWidget {
  const _Footer({required this.retentionDays});

  final int? retentionDays;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.s16),
      child: Row(
        spacing: AppSpacing.s8,
        children: [
          Expanded(
            child: Text(
              retentionDays == null
                  ? 'These come from the transcripts the Space keeps.'
                  : 'Transcripts are kept for $retentionDays days.',
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
          ),
          AppButton(
            label: 'Export your data',
            size: AppButtonSize.sm,
            variant: AppButtonVariant.ghost,
            onPressed: () => context.go(Routes.personalSettingsPane(aboutPane)),
          ),
        ],
      ),
    );
  }
}
