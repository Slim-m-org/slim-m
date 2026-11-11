// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The control that asks everyone in a call to let a module hear it
/// (decision 0105). It exists only while the caller may start one here: a
/// module armed for this channel, the listener up, nothing already on.
///
/// Pressing it confirms in `showAppSheet` (desktop-vs-mobile.md rule 4): the
/// sheet shows the module's own words, because that is what everyone else
/// will be shown next to the same question.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../providers/call_audio.dart';
import 'call_dock_button.dart';

/// The dock row holding the control, or null when there is nothing to start.
Widget? callAudioStartRow(WidgetRef ref, String? channelId) {
  if (channelId == null) return null;
  final model = ref.watch(callAudioProvider(channelId));
  final status = model.status;
  if (model.session != null) return null;
  if (status.startable.isEmpty && !status.transcribable) return null;
  return CallAudioStartControl(channelId: channelId);
}

class CallAudioStartControl extends ConsumerWidget {
  const CallAudioStartControl({super.key, required this.channelId});

  final String channelId;

  static const buttonKey = Key('call-audio-start');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final model = ref.watch(callAudioProvider(channelId));
    final startable = model.status.startable;
    final transcribable = model.status.transcribable;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        CallDockButton(
          key: buttonKey,
          icon: AppIcons.callAudio,
          tooltip: switch ((transcribable, startable.length)) {
            (true, 0) => 'Transcribe this call',
            (false, 1) => 'Turn on ${startable.single.moduleName}',
            _ => 'Let a module hear this call',
          },
          active: false,
          pending: model.busy,
          onPressed: () => _choose(context, ref, startable, transcribable),
        ),
        if (model.error case final message?)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.s8),
            child: AppErrorState(message: message),
          ),
      ],
    );
  }

  Future<void> _choose(
    BuildContext context,
    WidgetRef ref,
    List<api.CallAudioModule> startable,
    bool transcribable,
  ) async {
    final picked = await showAppSheet<_Pick>(
      context,
      scrolls: true,
      builder: (context) =>
          _ConfirmSheet(modules: startable, transcribable: transcribable),
    );
    final controller = ref.read(callAudioProvider(channelId).notifier);
    switch (picked) {
      case null:
        return;
      case _Transcript():
        await controller.requestTranscript();
      case _Module(:final module):
        await controller.request(module.moduleId);
    }
  }
}

sealed class _Pick {
  const _Pick();
}

class _Transcript extends _Pick {
  const _Transcript();
}

class _Module extends _Pick {
  const _Module(this.module);

  final api.CallAudioModule module;
}

class _ConfirmSheet extends StatelessWidget {
  const _ConfirmSheet({required this.modules, required this.transcribable});

  final List<api.CallAudioModule> modules;
  final bool transcribable;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s16,
        0,
        AppSpacing.s16,
        AppSpacing.s16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            modules.isEmpty
                ? 'Transcribe this call?'
                : 'Let this call be heard?',
            style: AppText.body.copyWith(
              color: tokens.textPrimary,
              fontWeight: AppWeights.semi,
            ),
          ),
          const SizedBox(height: AppSpacing.s4),
          Text(
            'Everyone is asked first. It starts only if all say yes.',
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
          if (transcribable) ...[
            const SizedBox(height: AppSpacing.s16),
            Text(
              'The transcript is kept with the call, where people who can '
              'read transcripts here can find it.',
              style: AppText.body.copyWith(color: tokens.textSecondary),
            ),
            const SizedBox(height: AppSpacing.s12),
            AppButton(
              key: const ValueKey('call-audio-ask-transcript'),
              label: 'Ask everyone to transcribe',
              icon: AppIcons.callAudio,
              variant: AppButtonVariant.primary,
              full: true,
              onPressed: () => Navigator.of(context).pop(const _Transcript()),
            ),
          ],
          for (final module in modules) ...[
            const SizedBox(height: AppSpacing.s16),
            Text(
              module.moduleName,
              style: AppText.body.copyWith(
                color: tokens.textPrimary,
                fontWeight: AppWeights.semi,
              ),
            ),
            const SizedBox(height: AppSpacing.s4),
            Text(
              module.purpose,
              style: AppText.body.copyWith(color: tokens.textPrimary),
            ),
            const SizedBox(height: AppSpacing.s4),
            Text(
              'It keeps: ${module.keeps}',
              style: AppText.body.copyWith(color: tokens.textSecondary),
            ),
            const SizedBox(height: AppSpacing.s12),
            AppButton(
              key: ValueKey('call-audio-ask-${module.moduleId}'),
              label: 'Ask everyone to turn on ${module.moduleName}',
              icon: AppIcons.callAudio,
              variant: AppButtonVariant.primary,
              full: true,
              onPressed: () => Navigator.of(context).pop(_Module(module)),
            ),
          ],
          const SizedBox(height: AppSpacing.s8),
          AppButton(
            label: 'Cancel',
            variant: AppButtonVariant.ghost,
            full: true,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}
