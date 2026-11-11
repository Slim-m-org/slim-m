// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How the server transcribes calls and how long it keeps the text
/// (decision 0113), on the Space's Voice pane.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../../preset_options.dart';
import '../../../../widgets/confirm_dialog.dart';
import '../../../../widgets/optimistic_setting_state.dart';
import '../../../../widgets/run_guarded.dart';
import '../../providers/settings_actions.dart';
import '../../providers/space_settings.dart';
import '../../widgets/settings_save_feedback.dart';
import '../../widgets/settings_section_header.dart';
import '../../widgets/settings_segmented_block.dart';
import 'retention_section.dart' show retentionDeletesHistory;

const _modes = <(String, CallTranscriptionMode)>[
  ('Off', CallTranscriptionMode.off),
  ('When someone asks', CallTranscriptionMode.onRequest),
  ('Always', CallTranscriptionMode.always),
];

const _retentionOptions = <(String, int)>[
  ('Forever', 0),
  ('7 days', 7),
  ('30 days', 30),
  ('90 days', 90),
];

String _modeConsequence(CallTranscriptionMode mode) => switch (mode) {
  CallTranscriptionMode.off => 'Calls are not transcribed.',
  CallTranscriptionMode.onRequest =>
    'Anyone in a call can start it; it runs only while everyone agrees.',
  CallTranscriptionMode.always =>
    'Every call is transcribed from the first join, and everyone sees it.',
};

/// The mode and the retention window, one card each.
class CallTranscriptsSection extends StatelessWidget {
  const CallTranscriptsSection({super.key});

  @override
  Widget build(BuildContext context) => const Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [_ModeCard(), _RetentionCard()],
  );
}

class _ModeCard extends ConsumerStatefulWidget {
  const _ModeCard();

  @override
  ConsumerState<_ModeCard> createState() => _ModeCardState();
}

class _ModeCardState extends ConsumerState<_ModeCard>
    with
        GuardedActionState<_ModeCard>,
        OptimisticSettingState<_ModeCard, CallTranscriptionMode> {
  Future<void> _set(CallTranscriptionMode mode) => saveOptimistic(
    mode,
    whatFailed: 'change call transcripts',
    action: () => ref
        .read(settingsActionsProvider)
        .setSpaceSettings(SpaceSettingsUpdate(callTranscription: mode)),
    refresh: spaceSettingsProvider,
  );

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(spaceSettingsProvider);
    ref.listen(spaceSettingsProvider, (_, next) => retireOptimistic(next));
    final loaded = settings.valueOrNull;
    final current = optimistic ?? loaded?.callTranscription;
    final available = loaded?.callTranscriptionAvailable ?? true;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSectionCard(
          title: 'Call transcripts',
          description: 'Kept with the call, for members who may view them.',
          children: [
            SettingsSegmentedBlock(
              semanticLabel: 'Call transcription mode',
              labels: [for (final mode in _modes) mode.$1],
              selectedIndex: _modes.indexWhere((m) => m.$2 == current),
              disabled: saving || current == null || !available,
              onSelected: (i) => _set(_modes[i].$2),
            ),
            if (!available)
              const SettingsSubRow(
                label:
                    'Needs the call listener, which this server is not '
                    'running.',
              )
            else if (current != null)
              SettingsSubRow(label: _modeConsequence(current)),
            if (settings.hasError && current == null)
              SettingsCardBlock(
                children: [
                  AppErrorState(
                    message: 'Could not load this setting.',
                    onRetry: () => ref.invalidate(spaceSettingsProvider),
                  ),
                ],
              ),
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
}

class _RetentionCard extends ConsumerStatefulWidget {
  const _RetentionCard();

  @override
  ConsumerState<_RetentionCard> createState() => _RetentionCardState();
}

class _RetentionCardState extends ConsumerState<_RetentionCard>
    with
        GuardedActionState<_RetentionCard>,
        OptimisticSettingState<_RetentionCard, int> {
  Future<void> _set(int days, {required int current}) async {
    if (retentionDeletesHistory(from: current, to: days)) {
      final confirmed = await confirmDangerousAction(
        context,
        title: 'Delete transcripts older than $days days?',
        message:
            'They are deleted within the next few hours, for everyone. '
            'This cannot be undone.',
        confirmLabel: 'Delete old transcripts',
      );
      if (!confirmed || !mounted) return;
    }
    await saveOptimistic(
      days,
      whatFailed: 'change transcript retention',
      action: () => ref
          .read(settingsActionsProvider)
          .setSpaceSettings(
            SpaceSettingsUpdate(callTranscriptRetentionDays: days),
          ),
      refresh: spaceSettingsProvider,
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(spaceSettingsProvider);
    ref.listen(spaceSettingsProvider, (_, next) => retireOptimistic(next));
    final loaded = settings.valueOrNull;
    final served = loaded == null
        ? null
        : loaded.callTranscriptRetentionDays ?? 0;
    final current = optimistic ?? served;
    final options = current == null
        ? _retentionOptions
        : presetsIncluding(_retentionOptions, current, (d) => '$d days');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSectionCard(
          title: 'Transcript retention',
          description: 'Older transcripts are deleted.',
          children: [
            SettingsSegmentedBlock(
              semanticLabel: 'Transcript retention window',
              labels: [for (final option in options) option.$1],
              selectedIndex: options.indexWhere((o) => o.$2 == current),
              disabled: saving || current == null,
              onSelected: (i) => _set(options[i].$2, current: current!),
            ),
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
}
