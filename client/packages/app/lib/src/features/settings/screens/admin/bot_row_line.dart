// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The single line a bot takes in the Bots pane: avatar, name, connection dot and handle.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../../format.dart';
import '../../../members/widgets/bot_avatar_placeholder.dart';
import '../../../members/widgets/presence_indicator.dart';
import '../../../members/widgets/user_avatar.dart';
import '../../widgets/settings_section_header.dart';

/// The avatar, then the name, the connection dot and the dimmer handle on one line.
class BotRowLine extends StatelessWidget {
  const BotRowLine({super.key, required this.bot, required this.kebab});

  final api.Bot bot;
  final Widget kebab;

  @override
  Widget build(BuildContext context) {
    final metrics = SettingsRowMetrics.of(context);
    return Semantics(
      container: true,
      // The kebab stays its own stop rather than merging into the row's label.
      explicitChildNodes: true,
      label: [
        bot.displayName,
        '@${bot.username}',
        ?_state(bot),
        ?_note(bot),
      ].join(', '),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: metrics.minHeight),
        // No end inset: the kebab pads its own hit area, which puts its glyph near the card's inset.
        child: Padding(
          padding: EdgeInsetsDirectional.only(start: metrics.inset),
          child: Row(
            spacing: AppSpacing.s12,
            children: [
              ExcludeSemantics(
                child: Opacity(
                  opacity: bot.isRevoked ? 0.6 : 1,
                  child: UserAvatar(
                    name: bot.displayName,
                    userId: bot.userId,
                    size: AppAvatarSize.s32,
                    shape: AppAvatarShape.square,
                    placeholder: botAvatarPlaceholder(context, bot.displayName),
                  ),
                ),
              ),
              Expanded(
                child: ExcludeSemantics(child: _BotName(bot: bot)),
              ),
              kebab,
            ],
          ),
        ),
      ),
    );
  }
}

/// The name keeps what it needs and the dot always shows; the handle, then the last-seen note, ellipsize first.
class _BotName extends StatelessWidget {
  const _BotName({required this.bot});

  final api.Bot bot;

  static const double _dot = 8;

  /// Narrower than this the handle would read as a fragment, so it is left out.
  static const double _minHandle = 48;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final revoked = bot.isRevoked;
    final nameStyle = AppText.ui.copyWith(
      color: revoked ? tokens.textSecondary : tokens.textPrimary,
    );
    final handle = ['@${bot.username}', ?_note(bot)].join('  ');
    final measured = _width(context, bot.displayName, nameStyle);
    return LayoutBuilder(
      builder: (context, box) {
        final dotWidth = revoked ? 0.0 : AppSpacing.s8 + _dot;
        final nameMax = math.max(0.0, box.maxWidth - dotWidth);
        final handleMax =
            box.maxWidth -
            math.min(measured, nameMax) -
            dotWidth -
            AppSpacing.s8 -
            1;
        return Row(
          spacing: AppSpacing.s8,
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: nameMax),
              child: Text(
                bot.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: nameStyle,
              ),
            ),
            if (!revoked)
              PresenceIndicator(
                key: ValueKey('bot-presence-${bot.userId}'),
                presence: bot.online ? AppPresence.online : AppPresence.offline,
                size: _dot,
                backgroundColor: tokens.surfaceRaised,
              ),
            if (handleMax >= _minHandle)
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: handleMax),
                child: Text(
                  handle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.caption.copyWith(color: tokens.textSecondary),
                ),
              ),
          ],
        );
      },
    );
  }

  /// The width [text] takes on one line, so the handle can be given exactly what the name leaves.
  static double _width(BuildContext context, String text, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: DefaultTextStyle.of(context).style.merge(style),
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width.ceilToDouble();
    painter.dispose();
    return width;
  }
}

/// The dot in words, so colour and shape are not the only cue.
String? _state(api.Bot bot) => bot.isRevoked
    ? null
    : bot.online
    ? 'Online'
    : 'Offline';

/// What the dot alone cannot say; null for a connected bot.
String? _note(api.Bot bot) {
  if (bot.isRevoked) return 'Revoked';
  if (bot.online) return null;
  final lastUsed = bot.tokenLastUsedAt;
  return lastUsed == null
      ? 'Never connected'
      : 'Last seen ${formatRelativeAgeMs(lastUsed)}';
}
