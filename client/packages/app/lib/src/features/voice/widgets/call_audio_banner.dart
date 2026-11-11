// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What everyone in a call sees while a module is hearing it, or being asked
/// to (decision 0105). A status the person did not ask for, so it pushes the
/// stage down and never overlays it (desktop-vs-mobile.md rule 6).
///
/// Three states: the module is hearing the call, with Stop; your voice is not
/// included, with Allow; and the ask is waiting for everyone. After an ask
/// that came to nothing it says which of the two happened, never who.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../providers/providers.dart';
import '../../../widgets/status_banner.dart';
import '../providers/call_audio.dart';

class CallAudioBanner extends ConsumerWidget {
  const CallAudioBanner({super.key, required this.channelId});

  final String channelId;

  static const stopKey = Key('call-audio-stop');
  static const allowKey = Key('call-audio-banner-allow');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final model = ref.watch(callAudioProvider(channelId));
    final me = ref.watch(sessionProvider.select((s) => s.tokens?.userId));
    final session = model.session;
    final controller = ref.read(callAudioProvider(channelId).notifier);
    if (session == null) return _Ended(model: model, channelId: channelId);
    final (text, actions) = _content(session, me, controller);
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.s12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Bound to the live session like a recording light, so it never times out.
          StatusBanner(
            key: ValueKey('call-audio-${session.isOn ? 'on' : 'asking'}'),
            message: text,
            icon: AppIcons.callAudio,
            sticky: true,
            action: Row(mainAxisSize: MainAxisSize.min, children: actions),
          ),
          if (model.error case final message?)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.s8),
              child: AppErrorState(message: message),
            ),
        ],
      ),
    );
  }

  (String, List<Widget>) _content(
    api.CallAudioState session,
    String? me,
    CallAudioController controller,
  ) {
    final stop = AppButton(
      key: stopKey,
      label: 'Stop',
      size: AppButtonSize.sm,
      variant: AppButtonVariant.ghost,
      onPressed: controller.stop,
    );
    if (!session.isOn) {
      return (
        'Waiting for everyone (${session.answered} of ${session.total})',
        [stop],
      );
    }
    if (me != null && session.isAsking(me)) {
      return (
        'Your voice is not included',
        [
          AppButton(
            key: allowKey,
            label: 'Allow',
            size: AppButtonSize.sm,
            variant: AppButtonVariant.primary,
            onPressed: () => controller.answer(allow: true),
          ),
          const SizedBox(width: AppSpacing.s4),
          stop,
        ],
      );
    }
    if (session.isServerTranscript) {
      return (
        'This call is being transcribed',
        session.always ? const [] : [stop],
      );
    }
    return ('${session.moduleName} is hearing this call', [stop]);
  }
}

class _Ended extends ConsumerWidget {
  const _Ended({required this.model, required this.channelId});

  final CallAudioModel model;
  final String channelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = switch (model.ended) {
      'declined' => 'Not everyone agreed, so nothing is listening.',
      'lapsed' => 'Nobody answered in time, so nothing is listening.',
      'overload' => 'The listener was too busy and stopped.',
      'listener_unavailable' => 'The listener went away and stopped.',
      'time_limit' => 'It reached its time limit and stopped.',
      _ => null,
    };
    if (text == null) return const SizedBox.shrink();
    return StatusBanner(
      key: const ValueKey('call-audio-ended'),
      message: text,
      icon: AppIcons.callAudio,
      margin: const EdgeInsets.only(top: AppSpacing.s12),
      onDismiss: () =>
          ref.read(callAudioProvider(channelId).notifier).clearEnded(),
    );
  }
}
