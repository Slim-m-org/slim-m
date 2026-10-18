// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Troubleshooting row that measures latency and speed to the server.
///
/// Nothing runs until the button is pressed: the test moves real data.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/connection_test_controller.dart';
import 'connection_test_format.dart';
import 'settings_detail_row.dart';

class ConnectionTestRow extends ConsumerWidget {
  const ConnectionTestRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final test = ref.watch(connectionTestProvider);
    final controller = ref.read(connectionTestProvider.notifier);
    final results = test.results;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsDetailRow(
          icon: AppIcons.requestLatency,
          title: 'Connection test',
          detail: 'Latency and speed to the server.',
          error: test.failed ? 'The test stopped. Try again.' : null,
          trailing: AppButton(
            size: AppButtonSize.sm,
            label: test.running
                ? 'Stop'
                : results == null
                ? 'Run'
                : 'Run again',
            onPressed: test.running ? controller.stop : controller.run,
          ),
        ),
        if (test.running) _Progress(test.progress),
        if (results != null && !test.running)
          for (final result in results)
            _ResultLine(result: result, inUse: result.route == test.inUse),
      ],
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress(this.progress);

  final ConnectionTestProgress? progress;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final p = progress;
    final route = p == null
        ? ''
        : ' (${p.route == ConnectionRoute.lan ? 'LAN' : 'Internet'})';
    return _Inset(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: AppSpacing.s4,
        children: [
          Text(
            '${p?.step ?? 'Starting'}$route',
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
          LinearProgressIndicator(
            value: p?.fraction,
            minHeight: 3,
            semanticsLabel: 'Connection test',
          ),
        ],
      ),
    );
  }
}

class _ResultLine extends StatelessWidget {
  const _ResultLine({required this.result, required this.inUse});

  final RouteMeasurement result;
  final bool inUse;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final failed = result.failure != null;
    final style = AppText.caption.copyWith(
      color: failed ? tokens.dangerText : tokens.textSecondary,
    );
    return _Inset(
      child: Text.rich(
        TextSpan(
          style: style,
          children: [
            TextSpan(
              text: routeLabel(result),
              style: style.copyWith(
                color: tokens.textPrimary,
                fontWeight: AppWeights.medium,
              ),
            ),
            if (inUse) const TextSpan(text: ' (in use)'),
            TextSpan(text: ': ${describeMeasurement(result)}'),
          ],
        ),
      ),
    );
  }
}

/// Lines up under a row's text, past its icon tile.
class _Inset extends StatelessWidget {
  const _Inset({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Container(
      padding: const EdgeInsets.fromLTRB(62, 6, AppSpacing.s16, 6),
      color: Color.lerp(tokens.surfaceBase, tokens.surfaceRaised, 0.5),
      child: child,
    );
  }
}
