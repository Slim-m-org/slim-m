// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The question put to everyone else in a call when a module is asked to hear
/// it (decision 0105): a full-focus overlay above the routed tree, because it
/// is an unsolicited, time-limited prompt that needs a decision
/// (desktop-vs-mobile.md rule 7), shaped like the incoming-call overlay it is
/// modelled on. Below `kCompactWidth` it takes the whole screen; at or above
/// it is a floating card.
///
/// Escape resolves it to the less intrusive state, the way every overlay here
/// does: the person stays left out, and the banner keeps offering Allow. It
/// never counts as a no, because a no stops the session for everyone.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../providers/providers.dart';
import '../../members/providers/presence_controller.dart';
import '../../members/providers/user_profiles.dart';
import '../providers/call_audio.dart';
import '../providers/voice_flags.dart';

/// The session whose prompt the person closed with Escape, so it stays closed; only one call asks at a time.
final callAudioDismissedProvider = StateProvider<String?>((ref) => null);

String _sessionKey(String channelId, api.CallAudioState session) =>
    '$channelId/${session.moduleId}/${session.expiresAtMs}';

class CallAudioPrompt extends ConsumerWidget {
  const CallAudioPrompt({super.key});

  static const cardKey = Key('call-audio-prompt');
  static const allowKey = Key('call-audio-allow');
  static const notNowKey = Key('call-audio-not-now');
  static const hiddenNoteKey = Key('call-audio-hidden-note');
  static const countdownKey = Key('call-audio-countdown');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (_pendingAsk(ref) == null) return const SizedBox.shrink();
    return Material(
      type: MaterialType.transparency,
      child: Overlay(
        initialEntries: [
          // The entry's builder runs once, so the surface watches for itself.
          OverlayEntry(builder: (context) => const _PromptSurface()),
        ],
      ),
    );
  }
}

typedef _Ask = ({String channelId, api.CallAudioState session, String key});

/// The question this person has yet to answer and not closed, if any.
_Ask? _pendingAsk(WidgetRef ref) {
  final channelId = ref.watch(voiceFlagsProvider.select((f) => f.channelId));
  final me = ref.watch(sessionProvider.select((s) => s.tokens?.userId));
  if (channelId == null || me == null) return null;
  final session = ref.watch(
    callAudioProvider(channelId).select((m) => m.session),
  );
  if (session == null || !session.isAsking(me)) return null;
  final key = _sessionKey(channelId, session);
  if (ref.watch(callAudioDismissedProvider) == key) return null;
  return (channelId: channelId, session: session, key: key);
}

class _PromptSurface extends ConsumerWidget {
  const _PromptSurface();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ask = _pendingAsk(ref);
    if (ask == null) return const SizedBox.shrink();
    final compact = MediaQuery.sizeOf(context).width < kCompactWidth;
    final body = _PromptBody(
      channelId: ask.channelId,
      session: ask.session,
      compact: compact,
      onClose: () =>
          ref.read(callAudioDismissedProvider.notifier).state = ask.key,
    );
    final content = compact
        ? Material(
            color: Theme.of(context).extension<AppTokens>()!.surfaceBase,
            child: SafeArea(child: body),
          )
        : Align(
            alignment: Alignment.topCenter,
            child: SafeArea(
              minimum: const EdgeInsets.only(top: AppSpacing.s12),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: _Card(child: body),
              ),
            ),
          );
    return AppFadeIn(key: ValueKey('call-audio-${ask.key}'), child: content);
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.surfaceRaised,
        borderRadius: BorderRadius.circular(AppRadii.card),
        border: Border.all(color: tokens.borderSubtle),
        boxShadow: AppShadows.canvasTile,
      ),
      child: child,
    );
  }
}

class _PromptBody extends ConsumerWidget {
  const _PromptBody({
    required this.channelId,
    required this.session,
    required this.compact,
    required this.onClose,
  });

  final String channelId;
  final api.CallAudioState session;

  /// A full-screen takeover: the words centred, the answer at the bottom.
  final bool compact;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final asker = ref.watch(userProfileProvider(session.askedBy)).valueOrNull;
    final hidden =
        ref.watch(ownVisibilityProvider) == api.PresenceVisibility.hidden;
    final controller = ref.read(callAudioProvider(channelId).notifier);
    final model = ref.watch(callAudioProvider(channelId));
    final buttonSize = compact ? AppButtonSize.lg : AppButtonSize.md;
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): onClose},
      child: Focus(
        autofocus: true,
        child: Padding(
          key: CallAudioPrompt.cardKey,
          padding: EdgeInsets.all(compact ? AppSpacing.s24 : AppSpacing.s16),
          child: Column(
            mainAxisSize: compact ? MainAxisSize.max : MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (compact) const Spacer(),
              Row(
                children: [
                  Icon(AppIcons.callAudio, color: tokens.accent),
                  const SizedBox(width: AppSpacing.s8),
                  Expanded(
                    child: Text(
                      session.isServerTranscript
                          ? 'Transcribe this call?'
                          : 'Let ${session.moduleName} hear this call?',
                      style: AppText.body.copyWith(
                        color: tokens.textPrimary,
                        fontWeight: AppWeights.semi,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.s8),
              Text(
                '${asker?.displayName ?? 'Someone'} asked. '
                '${session.isServerTranscript ? 'The server writes it down.' : 'These are the module\'s own words.'}',
                style: AppText.caption.copyWith(color: tokens.textSecondary),
              ),
              const SizedBox(height: AppSpacing.s8),
              Text(
                session.purpose,
                style: AppText.body.copyWith(color: tokens.textPrimary),
              ),
              const SizedBox(height: AppSpacing.s4),
              Text(
                'It keeps: ${session.keeps}',
                style: AppText.body.copyWith(color: tokens.textSecondary),
              ),
              if (hidden) ...[
                const SizedBox(height: AppSpacing.s8),
                Text(
                  session.isServerTranscript
                      ? 'Your presence is hidden. You are still named in the '
                            'transcript.'
                      : 'Your presence is hidden. The module will see that you '
                            'were in this call.',
                  key: CallAudioPrompt.hiddenNoteKey,
                  style: AppText.body.copyWith(color: tokens.warnText),
                ),
              ],
              if (!session.isOn) ...[
                const SizedBox(height: AppSpacing.s8),
                _Countdown(expiresAtMs: session.expiresAtMs),
              ],
              if (model.error case final error?) ...[
                const SizedBox(height: AppSpacing.s8),
                AppErrorState(message: error),
              ],
              if (compact)
                const Spacer()
              else
                const SizedBox(height: AppSpacing.s16),
              Row(
                children: [
                  Expanded(
                    child: AppButton(
                      key: CallAudioPrompt.notNowKey,
                      label: 'Not now',
                      size: buttonSize,
                      variant: AppButtonVariant.ghost,
                      full: true,
                      disabled: model.busy,
                      onPressed: () => controller.answer(allow: false),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.s8),
                  Expanded(
                    child: AppButton(
                      key: CallAudioPrompt.allowKey,
                      label: 'Allow',
                      size: buttonSize,
                      variant: AppButtonVariant.primary,
                      full: true,
                      disabled: model.busy,
                      onPressed: () => controller.answer(allow: true),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Counts the seconds left to answer, from the moment it is shown.
class _Countdown extends StatefulWidget {
  const _Countdown({required this.expiresAtMs});

  final int expiresAtMs;

  @override
  State<_Countdown> createState() => _CountdownState();
}

class _CountdownState extends State<_Countdown> {
  late int _left = _initial();
  Timer? _timer;

  int _initial() {
    final ms = widget.expiresAtMs - DateTime.now().millisecondsSinceEpoch;
    return (ms / 1000).ceil().clamp(0, 60);
  }

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_left > 0) setState(() => _left -= 1);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Text(
      '$_left seconds to answer',
      key: CallAudioPrompt.countdownKey,
      style: AppText.caption.copyWith(color: tokens.textSecondary),
    );
  }
}
