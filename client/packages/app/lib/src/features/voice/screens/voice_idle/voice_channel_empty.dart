// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A voice channel with no call going and none to look back on: the channel's
/// name, who is in it now, who can join, and the ways to join, centred in the pane.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../channels/providers/channel_by_id_provider.dart';
import '../../../channels/widgets/channel_kind_icon.dart';
import '../../../channels/widgets/channel_settings_rooms_section.dart'
    show lobbyDescription;
import '../../providers/voice_roster.dart';
import '../../widgets/join_muted_note.dart';
import 'voice_join_bar.dart' show voiceRosterTitle;

class VoiceChannelEmpty extends ConsumerWidget {
  const VoiceChannelEmpty({
    super.key,
    required this.channelId,
    required this.onJoinMuted,
    this.onJoin,
    this.onRetry,
    this.rejoin = false,
    this.errorMessage,
    this.canRetry = true,
  });

  final String channelId;
  final VoidCallback onJoinMuted;

  /// Joins with the mic as the person left it; null offers only the muted join.
  final VoidCallback? onJoin;

  /// Repeats the join that failed, in the mic mode it used; null retries muted.
  final VoidCallback? onRetry;

  /// The person just left this call, so the buttons say Rejoin.
  final bool rejoin;
  final String? errorMessage;
  final bool canRetry;

  static const double _glyph = 56;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final channel = ref.watch(channelByIdProvider(channelId)).valueOrNull;
    final restricted = channel?.restricted ?? false;
    final joinsMuted = channel?.joinMuted ?? false;
    final roster = ref.watch(voiceRosterProvider(channelId));
    return LayoutBuilder(
      builder: (context, box) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: box.maxHeight),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.s24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _Glyph(restricted: restricted, size: _glyph),
                    const SizedBox(height: AppSpacing.s16),
                    Text(
                      channel?.name ?? 'Voice channel',
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.heading.copyWith(
                        color: tokens.textPrimary,
                        fontWeight: AppWeights.semi,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.s4),
                    Text(
                      voiceRosterTitle(roster),
                      textAlign: TextAlign.center,
                      style: AppText.body.copyWith(color: tokens.textSecondary),
                    ),
                    const SizedBox(height: AppSpacing.s16),
                    _WhoCanJoin(
                      restricted: restricted,
                      lobby: channel?.createsRooms ?? false,
                    ),
                    if (joinsMuted) ...[
                      const SizedBox(height: AppSpacing.s8),
                      const JoinMutedNote(),
                    ],
                    const SizedBox(height: AppSpacing.s24),
                    if (errorMessage != null) ...[
                      AppErrorState(message: errorMessage!),
                      const SizedBox(height: AppSpacing.s16),
                    ],
                    if (errorMessage == null || canRetry)
                      _actions(joinsMuted: joinsMuted),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _actions({required bool joinsMuted}) {
    final verb = rejoin ? 'Rejoin' : 'Join';
    if (errorMessage != null) {
      return AppButton(
        label: 'Try again',
        variant: AppButtonVariant.primary,
        onPressed: onRetry ?? onJoinMuted,
      );
    }
    final muted = AppButton(
      label: '$verb muted',
      semanticLabel: rejoin ? 'Rejoin the call muted' : 'Join the call muted',
      icon: AppIcons.micOff,
      variant: AppButtonVariant.primary,
      onPressed: onJoinMuted,
    );
    final withMic = joinsMuted ? null : onJoin;
    if (withMic == null) return muted;
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: AppSpacing.s8,
      runSpacing: AppSpacing.s8,
      children: [
        muted,
        AppButton(
          label: verb,
          semanticLabel: rejoin ? 'Rejoin the call' : 'Join the call',
          icon: AppIcons.voice,
          variant: AppButtonVariant.secondary,
          onPressed: withMic,
        ),
      ],
    );
  }
}

class _Glyph extends StatelessWidget {
  const _Glyph({required this.restricted, required this.size});

  final bool restricted;
  final double size;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: tokens.surfaceRaised,
          shape: BoxShape.circle,
          border: Border.all(color: tokens.borderSubtle),
        ),
        child: ChannelKindIcon(
          isVoice: true,
          restricted: restricted,
          color: tokens.textSecondary,
          size: AppSizes.icon24,
        ),
      ),
    );
  }
}

class _WhoCanJoin extends StatelessWidget {
  const _WhoCanJoin({required this.restricted, required this.lobby});

  final bool restricted;
  final bool lobby;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final (icon, text) = restricted
        ? (
            AppIcons.restrictedChannel,
            'Private: only people with access can join',
          )
        : lobby
        ? (AppIcons.voiceLobby, lobbyDescription)
        : (AppIcons.members, 'Anyone in this space can join');
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: AppSizes.icon16, color: tokens.textSecondary),
        const SizedBox(width: AppSpacing.s8),
        Flexible(
          child: Text(
            text,
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
        ),
      ],
    );
  }
}
