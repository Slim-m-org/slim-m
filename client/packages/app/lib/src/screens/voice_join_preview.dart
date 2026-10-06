// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The non-connected states of a voice screen: connecting, needing to
/// confirm a switch between two calls, and needing an explicit rejoin.
///
/// Split out of `voice_screen.dart` to keep that file under the review
/// budget; these widgets share no state with the in-call surface that
/// stayed behind. This file used to hold the join lobby (a mic/camera
/// pre-toggle behind an explicit Join button) that `voice_screen.dart`'s own
/// doc now explains was removed: clicking a voice channel joins directly,
/// and these are what a screen shows when direct joining is not the answer.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../providers/call_recap.dart';
import '../providers/channel_by_id_provider.dart';
import '../providers/dm_call.dart';
import '../providers/voice_roster.dart';
import '../routing/routes.dart';
import '../widgets/call_recap_card.dart';
import '../widgets/join_muted_note.dart';
import '../widgets/user_avatar.dart';

/// Leaves the ended call for wherever this channel's own conversation
/// already is.
///
/// A DM's call is only ever a mode of that channel's own pane
/// ([dmCallOpenProvider]); closing it is the identical action
/// `_DmCallBar`'s own dismiss button already takes, so a DM's messages are
/// straight back where this same screen sits. A real voice channel has no
/// separate text view to return to - `ConversationPane` shows this same
/// screen for as long as the channel's kind says voice - so there is
/// nowhere "back" to go but away from it, the same fallback
/// `CompactChannelAppBar`'s own back arrow and a deleted channel's own
/// redirect already land on. Either way this only leaves the call's screen;
/// a call already joined keeps running regardless (see `dm_call_pane.dart`'s
/// own doc comment).
void leaveRecapScreen(
  BuildContext context,
  WidgetRef ref, {
  required bool isDm,
}) {
  if (isDm) {
    ref.read(dmCallOpenProvider.notifier).state = null;
    return;
  }
  context.go(Routes.channels);
}

class VoiceConnecting extends StatelessWidget {
  const VoiceConnecting({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const AppBreathingHalo(
            size: 56,
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
          const SizedBox(height: AppSpacing.s16),
          Text('Connecting', style: TextStyle(color: tokens.textSecondary)),
          const SizedBox(height: AppSpacing.s24),
          _EmptySeats(tokens: tokens),
        ],
      ),
    );
  }
}

/// Faint outlined seats standing in for the roster that has not arrived yet
/// - the same circle a participant tile's own avatar takes, so the room
/// this spinner is about to fill reads as a room waiting to seat people
/// rather than an empty pane.
class _EmptySeats extends StatelessWidget {
  const _EmptySeats({required this.tokens});

  final AppTokens tokens;

  static const int _seats = 3;
  static const double _diameter = 40;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (var i = 0; i < _seats; i++)
        Padding(
          padding: EdgeInsets.only(left: i == 0 ? 0 : AppSpacing.s8),
          child: Container(
            width: _diameter,
            height: _diameter,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: tokens.borderSubtle),
            ),
          ),
        ),
    ],
  );
}

/// Shown instead of an automatic join when the caller is already connected
/// (or connecting) somewhere else: switching has to leave that call, so it
/// asks first rather than silently moving them, the one place a voice
/// channel arrival still needs an explicit decision.
class VoiceSwitchPrompt extends StatelessWidget {
  const VoiceSwitchPrompt({super.key, required this.onSwitch});

  final VoidCallback onSwitch;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.s24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppBreathingHalo(
                child: Icon(
                  AppIcons.voice,
                  size: AppSizes.icon32,
                  color: tokens.textSecondary,
                ),
              ),
              const SizedBox(height: AppSpacing.s16),
              Text(
                'Already in a call',
                textAlign: TextAlign.center,
                style: AppText.heading.copyWith(
                  color: tokens.textPrimary,
                  fontWeight: AppWeights.semi,
                ),
              ),
              const SizedBox(height: AppSpacing.s8),
              Text(
                "You're in a call somewhere else. Switching leaves it and "
                'joins this one instead.',
                textAlign: TextAlign.center,
                style: AppText.caption.copyWith(color: tokens.textSecondary),
              ),
              const SizedBox(height: AppSpacing.s16),
              FilledButton(
                onPressed: onSwitch,
                style: FilledButton.styleFrom(
                  backgroundColor: tokens.accentFill,
                  foregroundColor: tokens.accentOn,
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.s16),
                ),
                child: const Text('Switch to this call'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shown after a hang-up (no error, just left) or a failed automatic join
/// (an error the caller can read and, if [canRetry], act on). Rejoining is
/// the one manual step that remains once a call ends; leaving the screen
/// entirely is the other, via [leaveRecapScreen]. It is also the join
/// affordance for a member who arrived to read the chat ([wasInCall] false).
class VoiceRejoinScreen extends ConsumerWidget {
  const VoiceRejoinScreen({
    super.key,
    required this.channelId,
    required this.isDm,
    required this.canRetry,
    required this.onRetry,
    this.errorMessage,
    this.recap,
    this.wasInCall = true,
  });

  final String channelId;
  final bool isDm;
  final bool canRetry;
  final VoidCallback onRetry;
  final String? errorMessage;

  /// False for a member who came to read, not to talk (`VoiceScreen.openChat`)
  /// and has not been in this call: no "you left" notice, and the button
  /// offers a first join rather than a rejoin.
  final bool wasInCall;

  /// The call that just ended here, already checked against this channel by
  /// the caller. Rendered only when [errorMessage] is null and
  /// [CallRecap.isWorthShowing] - a failed rejoin attempt keeps the error
  /// as the one thing on screen, and a bare mis-click gets nothing, not a
  /// summary of noise.
  final CallRecap? recap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    // Whether the plain "You left this call." fallback, not the error or CallRecapCard, is next.
    final showsPlainLeftNotice =
        wasInCall &&
        errorMessage == null &&
        (recap == null || !recap!.isWorthShowing);
    final joinsMuted =
        !isDm &&
        ref.watch(
          channelByIdProvider(
            channelId,
          ).select((c) => c.valueOrNull?.joinMuted ?? false),
        );
    final rosterAsync = ref.watch(voiceRosterProvider(channelId));
    final rosterConfirmedEmpty = rosterAsync.valueOrNull?.isEmpty ?? false;
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.s24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AppBreathingHalo(
                      child: Icon(
                        isDm ? AppIcons.startCall : AppIcons.voice,
                        size: AppSizes.icon32,
                        color: tokens.textSecondary,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.s16),
                    Text(
                      isDm ? 'Call' : 'Voice channel',
                      textAlign: TextAlign.center,
                      style: AppText.heading.copyWith(
                        color: tokens.textPrimary,
                        fontWeight: AppWeights.semi,
                      ),
                    ),
                    if (joinsMuted) ...[
                      const SizedBox(height: AppSpacing.s8),
                      const JoinMutedNote(),
                    ],
                    const SizedBox(height: AppSpacing.s16),
                    _WhoIsHere(
                      rosterAsync: rosterAsync,
                      mergeLeftNotice: showsPlainLeftNotice,
                    ),
                    const SizedBox(height: AppSpacing.s16),
                    if (errorMessage != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.s12),
                        child: AppErrorState(message: errorMessage!),
                      )
                    else if (recap case final recap? when recap.isWorthShowing)
                      Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.s12),
                        child: CallRecapCard(recap: recap),
                      )
                    else if (wasInCall && !rosterConfirmedEmpty)
                      // An empty roster already folded this into _WhoIsHere above.
                      Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.s12),
                        child: Text(
                          'You left this call.',
                          textAlign: TextAlign.center,
                          style: AppText.caption.copyWith(
                            color: tokens.textSecondary,
                          ),
                        ),
                      ),
                    // No button for a failure a retry cannot fix.
                    if (canRetry) ...[
                      FilledButton(
                        onPressed: onRetry,
                        style: FilledButton.styleFrom(
                          backgroundColor: tokens.accentFill,
                          foregroundColor: tokens.accentOn,
                          padding: const EdgeInsets.symmetric(
                            vertical: AppSpacing.s16,
                          ),
                        ),
                        child: Text(
                          errorMessage != null
                              ? 'Try again'
                              : wasInCall
                              ? 'Rejoin call'
                              : 'Join call',
                        ),
                      ),
                      const SizedBox(height: AppSpacing.s8),
                    ],
                    AppButton(
                      label: isDm ? 'Back to messages' : 'Back to channel',
                      // Distinct from `_DmCallBar`'s own "Back to messages" dismiss, on screen at once.
                      semanticLabel: isDm
                          ? 'Back to messages from this call'
                          : 'Back to channel',
                      variant: AppButtonVariant.ghost,
                      onPressed: () =>
                          leaveRecapScreen(context, ref, isDm: isDm),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Who is already in the call, above the rejoin button.
///
/// The answers the roster can give are rendered as different things,
/// because collapsing them lies. Not known yet gets its own honest sentence
/// rather than an empty room ("nobody is here" would be a claim this client
/// never checked) and rather than nothing at all, which read as a stalled
/// load or a missing widget and was indistinguishable from either. A poll
/// that has been failing for a while (`voiceRosterProvider`'s own
/// [persistentRosterFailureThreshold]) gets a third, distinct sentence
/// rather than staying indistinguishable from a poll that simply has not
/// answered yet.
///
/// [mergeLeftNotice] is true when the plain "You left this call." fallback
/// would otherwise render directly below this: an empty roster then folds
/// into one sentence with it, rather than sitting as two independently-true
/// but contradictory-sounding lines (nobody is here / you just were here).
class _WhoIsHere extends StatelessWidget {
  const _WhoIsHere({required this.rosterAsync, required this.mergeLeftNotice});

  final AsyncValue<List<api.VoiceRosterParticipant>> rosterAsync;
  final bool mergeLeftNotice;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final roster = rosterAsync.valueOrNull;
    if (roster == null) {
      return Text(
        rosterAsync.hasError
            ? 'Could not check who is here.'
            : "Can't tell who else is here right now.",
        textAlign: TextAlign.center,
        style: AppText.caption.copyWith(color: tokens.textSecondary),
      );
    }

    if (roster.isEmpty) {
      if (mergeLeftNotice) {
        return Text(
          'You left this call. Nobody else is here.',
          textAlign: TextAlign.center,
          style: AppText.caption.copyWith(color: tokens.textSecondary),
        );
      }
      return Text(
        'Nobody is in this call yet.',
        textAlign: TextAlign.center,
        style: AppText.caption.copyWith(color: tokens.textSecondary),
      );
    }

    final names = roster.map((p) => p.displayName).join(', ');
    return Column(
      children: [
        Wrap(
          alignment: WrapAlignment.center,
          spacing: AppSpacing.s4,
          children: [
            for (final participant in roster.take(8))
              UserAvatar(
                name: participant.displayName,
                userId: participant.userId,
                size: AppAvatarSize.s28,
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.s8),
        Text(
          roster.length == 1 ? '$names is here' : '$names are here',
          textAlign: TextAlign.center,
          style: AppText.caption.copyWith(color: tokens.textSecondary),
          semanticsLabel: roster.length == 1
              ? '$names is in this call'
              : '${roster.length} people in this call: $names',
        ),
      ],
    );
  }
}
