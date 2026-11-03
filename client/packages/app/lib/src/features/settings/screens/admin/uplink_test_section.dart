// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Space voice settings' uplink test: measure what the server can send and
/// read it as screen-share advice.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../../format.dart';
import '../../../../providers/providers.dart';
import '../../../../widgets/run_guarded.dart';
import '../../providers/display_preferences.dart';
import '../../providers/uplink_recommendation.dart';
import '../../providers/uplink_test_providers.dart';
import '../../widgets/settings_detail_row.dart';
import '../../widgets/settings_result_inset.dart';
import '../../widgets/settings_save_feedback.dart';
import '../../widgets/settings_section_header.dart';

class UplinkTestSection extends ConsumerStatefulWidget {
  const UplinkTestSection({super.key});

  @override
  ConsumerState<UplinkTestSection> createState() => _UplinkTestSectionState();
}

class _UplinkTestSectionState extends ConsumerState<UplinkTestSection>
    with GuardedActionState<UplinkTestSection> {
  bool _running = false;

  Future<void> _run() async {
    setState(() => _running = true);
    await guard(
      whatFailed: 'measure the uplink',
      action: () => ref.read(apiProvider).runUplinkTest(),
    );
    if (!mounted) return;
    ref.invalidate(uplinkTestsProvider);
    setState(() => _running = false);
  }

  @override
  Widget build(BuildContext context) {
    final tests = ref.watch(uplinkTestsProvider);
    final results = tests.valueOrNull ?? const <api.UplinkTest>[];
    final use24Hour = watchUse24Hour(ref, context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSectionCard(
          title: 'Uplink test',
          description: 'Measure what this server can send.',
          children: [
            SettingsDetailRow(
              icon: AppIcons.requestLatency,
              title: 'Test uplink',
              detail: 'Uploads about 40 MB. Not while a call is live.',
              trailing: AppButton(
                key: const Key('uplink-test-run'),
                size: AppButtonSize.sm,
                label: _running
                    ? 'Testing'
                    : results.isEmpty
                    ? 'Run'
                    : 'Run again',
                onPressed: _running ? null : _run,
              ),
            ),
            if (tests.hasError && results.isEmpty)
              AppErrorState(
                message: 'Could not load the results.',
                onRetry: () => ref.invalidate(uplinkTestsProvider),
              ),
            if (results.isNotEmpty) ..._advice(results.first, use24Hour),
            if (results.length > 1) _History(results, use24Hour),
          ],
        ),
        SettingsSaveFeedback(
          tick: successTick,
          error: actionError,
          onDismissError: clearActionError,
        ),
      ],
    );
  }

  List<Widget> _advice(api.UplinkTest latest, bool use24Hour) {
    final rate = latest.mbitPerSecond;
    final when = formatDateTime(
      latest.measuredAt.millisecondsSinceEpoch,
      use24Hour: use24Hour,
    );
    return [
      _Lines([
        'Measured $when, ${formatMbit(rate)}.',
        'Suggested ceiling: ${suggestedCeiling(rate).label}.',
      ]),
      _Lines([
        for (final tier in uplinkAdviceTiers)
          '${tier.id}: ${formatBitrate(tier.maxBitrate)} each, '
              '${sharesThatFit(rate, tier)} at once',
        'One viewer per share.',
      ]),
    ];
  }
}

class _History extends StatelessWidget {
  const _History(this.results, this.use24Hour);

  final List<api.UplinkTest> results;
  final bool use24Hour;

  @override
  Widget build(BuildContext context) => _Lines([
    'Earlier',
    for (final test in results.skip(1))
      '${formatDateTime(test.measuredAt.millisecondsSinceEpoch, use24Hour: use24Hour)}: '
          '${formatMbit(test.mbitPerSecond)}',
  ]);
}

class _Lines extends StatelessWidget {
  const _Lines(this.lines);

  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return SettingsResultInset(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: AppSpacing.s4,
        children: [
          for (final line in lines)
            Text(
              line,
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
        ],
      ),
    );
  }
}
