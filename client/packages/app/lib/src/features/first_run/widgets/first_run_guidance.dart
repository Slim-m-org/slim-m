// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the empty pane tells a member who has not chosen a channel yet.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/first_run_controller.dart';

const _lines = <(IconData, String)>[
  (AppIcons.thread, 'Pick a channel from the list to read and write.'),
  (AppIcons.voice, 'Open a voice channel to talk with others.'),
  (AppIcons.members, 'Set your picture and notifications in a minute.'),
];

class FirstRunGuidance extends ConsumerWidget {
  const FirstRunGuidance({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (icon, text) in _lines)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.s8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: AppSpacing.s12,
                children: [
                  Icon(icon, size: 20, color: tokens.textSecondary),
                  Expanded(
                    child: Text(
                      text,
                      style: AppText.body.copyWith(color: tokens.textSecondary),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: AppSpacing.s8),
          Align(
            alignment: Alignment.centerLeft,
            child: AppButton(
              label: 'Run setup',
              variant: AppButtonVariant.soft,
              onPressed: () =>
                  ref.read(firstRunControllerProvider.notifier).replay(),
            ),
          ),
        ],
      ),
    );
  }
}
