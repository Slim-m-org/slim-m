// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The trailing marks a voice row carries for temporary rooms and limits
/// (decision 0065), beside [RailJoinMutedGlyph].
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

/// A lobby's leading icon in place of the voice glyph.
class RailLobbyIcon extends StatelessWidget {
  const RailLobbyIcon({required this.color, super.key});

  final Color color;

  static const label = 'Opens a room of your own';

  @override
  Widget build(BuildContext context) => Tooltip(
    message: label,
    child: Icon(
      AppIcons.voiceLobby,
      size: AppSizes.icon16,
      color: color,
      semanticLabel: label,
    ),
  );
}

class RailRoomLockedGlyph extends StatelessWidget {
  const RailRoomLockedGlyph({super.key});

  static const label = 'Locked: nobody new can join';

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Tooltip(
      message: label,
      child: Icon(
        AppIcons.roomLocked,
        size: AppSizes.icon16,
        color: tokens.textSecondary,
        semanticLabel: label,
      ),
    );
  }
}

/// "2/5": how full a call with a user limit is.
class RailUserLimit extends StatelessWidget {
  const RailUserLimit({required this.present, required this.limit, super.key});

  final int present;
  final int limit;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final full = present >= limit;
    return Semantics(
      label: '$present of $limit people',
      excludeSemantics: true,
      child: Text(
        '$present/$limit',
        style: AppText.code.copyWith(
          color: full ? tokens.textPrimary : tokens.textSecondary,
        ),
      ),
    );
  }
}

/// The speaker a private voice row moves to its trailing end, paired with the
/// join-muted mic-off when there is one, because its leading glyph is the
/// private-channel hash.
class RailPrivateVoiceMarks extends StatelessWidget {
  const RailPrivateVoiceMarks({required this.joinMuted, super.key});

  final bool joinMuted;

  static const label = 'Private voice channel';
  static const mutedLabel = 'Private voice channel, joins muted';

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final text = joinMuted ? mutedLabel : label;
    return Tooltip(
      message: text,
      child: Semantics(
        label: text,
        excludeSemantics: true,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: AppSpacing.s4,
          children: [
            Icon(
              AppIcons.voice,
              size: AppSizes.icon16,
              color: tokens.textSecondary,
            ),
            if (joinMuted)
              Icon(
                AppIcons.micOff,
                size: AppSizes.icon16,
                color: tokens.textSecondary,
              ),
          ],
        ),
      ),
    );
  }
}
