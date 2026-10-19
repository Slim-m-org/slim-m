// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Troubleshooting row that shows how the last call's audio held up.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../voice/providers/voice_health.dart';
import 'call_health_format.dart';
import 'settings_detail_row.dart';
import 'settings_result_inset.dart';

class CallHealthRow extends ConsumerWidget {
  const CallHealthRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = ref.watch(lastCallHealthProvider);
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsDetailRow(
          icon: AppIcons.requestLatency,
          title: 'Last call audio',
          detail: summary == null
              ? 'Numbers appear here after a call.'
              : 'How the audio held up.',
        ),
        if (summary != null)
          SettingsResultInset(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final line in describeCallHealth(summary.remote))
                  Text(
                    line,
                    style: AppText.caption.copyWith(
                      color: tokens.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
