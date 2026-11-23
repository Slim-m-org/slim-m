// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How the server transcribes calls and how long it keeps the text
/// (decision 0113), on the Space's Voice pane.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../../api_failure.dart';

import '../../../../preset_options.dart';
import '../../../../widgets/confirm_dialog.dart';
import '../../../../widgets/optimistic_setting_state.dart';
import '../../../../widgets/run_guarded.dart';
import '../../providers/settings_actions.dart';
import '../../providers/space_settings.dart';
import '../../widgets/settings_save_feedback.dart';
import '../../widgets/settings_section_header.dart';
import '../../widgets/settings_segmented_block.dart';
import '../../widgets/settings_toggle_row.dart';
import 'retention_section.dart' show retentionDeletesHistory;
import '../../../../widgets/load_error_block.dart';

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

/// The mode, spoken marks and the retention window, one card each.
class CallTranscriptsSection extends StatelessWidget {
  const CallTranscriptsSection({super.key});

  @override
  Widget build(BuildContext context) => const Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [_ModeCard(), _VoiceCommandsCard(), _RetentionCard()],
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
                indented: false,
              )
            else if (current != null)
              SettingsSubRow(label: _modeConsequence(current), indented: false),
            if (settings.hasError && current == null)
              LoadErrorBlock(
                message: 'Could not load this setting.',
                onRetry: () => ref.invalidate(spaceSettingsProvider),
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
        title: 'Delete call transcripts older than $days days?',
        message:
            'They are deleted within the next few hours, for everyone. '
            'This cannot be undone.',
        confirmLabel: 'Delete old call transcripts',
      );
      if (!confirmed || !mounted) return;
    }
    await saveOptimistic(
      days,
      whatFailed: 'change call transcript retention',
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
          title: 'Call transcript retention',
          description: 'Older call transcripts are deleted.',
          children: [
            SettingsSegmentedBlock(
              semanticLabel: 'Call transcript retention window',
              labels: [for (final option in options) option.$1],
              selectedIndex: options.indexWhere((o) => o.$2 == current),
              disabled: saving || current == null,
              onSelected: (i) => _set(options[i].$2, current: current!),
            ),
            if (settings.hasError && current == null)
              LoadErrorBlock(
                message: 'Could not load this setting.',
                onRetry: () => ref.invalidate(spaceSettingsProvider),
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

const voiceCommandsToggleLabel = 'Use voice commands';
const voicePhraseFieldKey = Key('voice-command-phrase');
const voicePhraseSaveKey = Key('voice-command-phrase-save');

/// Spoken marks: off by default, and only while calls are transcribed.
class _VoiceCommandsCard extends ConsumerStatefulWidget {
  const _VoiceCommandsCard();

  @override
  ConsumerState<_VoiceCommandsCard> createState() => _VoiceCommandsCardState();
}

class _VoiceCommandsCardState extends ConsumerState<_VoiceCommandsCard>
    with
        GuardedActionState<_VoiceCommandsCard>,
        OptimisticSettingState<_VoiceCommandsCard, bool> {
  final _phrase = TextEditingController();
  String? _phraseError;
  bool _savingPhrase = false;

  @override
  void dispose() {
    _phrase.dispose();
    super.dispose();
  }

  Future<void> _set(bool on) => saveOptimistic(
    on,
    whatFailed: 'change voice commands',
    action: () => ref
        .read(settingsActionsProvider)
        .setSpaceSettings(SpaceSettingsUpdate(voiceCommands: on)),
    refresh: spaceSettingsProvider,
  );

  Future<void> _savePhrase() async {
    setState(() {
      _savingPhrase = true;
      _phraseError = null;
    });
    try {
      await ref
          .read(settingsActionsProvider)
          .setSpaceSettings(
            SpaceSettingsUpdate(voiceCommandPhrase: _phrase.text.trim()),
          );
      ref.invalidate(spaceSettingsProvider);
    } on ApiException catch (error, stack) {
      reportFailure(LogTag.ui, 'save the wake phrase', error, stack);
      if (mounted) {
        setState(
          () =>
              _phraseError = describeApiFailure('save the wake phrase', error),
        );
      }
    } finally {
      if (mounted) setState(() => _savingPhrase = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(spaceSettingsProvider);
    ref.listen(spaceSettingsProvider, (_, next) {
      retireOptimistic(next);
      final phrase = next.valueOrNull?.voiceCommandPhrase;
      if (phrase != null && _phrase.text.isEmpty) _phrase.text = phrase;
    });
    final loaded = settings.valueOrNull;
    if (loaded == null) return const SizedBox.shrink();
    if (_phrase.text.isEmpty) _phrase.text = loaded.voiceCommandPhrase;
    final on = optimistic ?? loaded.voiceCommands;
    final possible =
        loaded.callTranscriptionAvailable &&
        loaded.callTranscription != CallTranscriptionMode.off;
    final phrase = loaded.voiceCommandPhrase;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSectionCard(
          title: 'Voice commands',
          description: 'Say "$phrase, mark that" in a call.',
          children: [
            SettingsToggleRow(
              label: voiceCommandsToggleLabel,
              semanticLabel: voiceCommandsToggleLabel,
              value: on,
              onChanged: saving || (!possible && !on) ? null : _set,
            ),
            if (!possible)
              const SettingsSubRow(label: 'Needs call transcripts turned on.'),
            if (on && possible)
              Padding(
                padding: const EdgeInsets.all(AppSpacing.s16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AppInput(
                      key: voicePhraseFieldKey,
                      controller: _phrase,
                      placeholder: 'Wake phrase',
                      semanticLabel: 'Wake phrase',
                      helperText: '2 to 4 words.',
                      errorText: _phraseError,
                      onSubmitted: (_) => _savePhrase(),
                    ),
                    const SizedBox(height: AppSpacing.s8),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: AppButton(
                        key: voicePhraseSaveKey,
                        label: 'Save phrase',
                        size: AppButtonSize.sm,
                        variant: AppButtonVariant.secondary,
                        disabled: _savingPhrase,
                        onPressed: _savePhrase,
                      ),
                    ),
                  ],
                ),
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
