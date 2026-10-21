// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The card a video tile shows in place of a picture it cannot draw: whose
/// video it is, why it is not playing, and sometimes one action.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart'
    show BlurredLastFrame, ScreenShareStatus, videoSubscriptionKey;

import '../../members/widgets/user_avatar.dart';

class VideoStateCard extends StatelessWidget {
  const VideoStateCard({
    super.key,
    this.icon,
    required this.title,
    this.subtitle,
    required this.identity,
    required this.name,
    this.actionLabel,
    this.onAction,
    this.dimsVideoBehind = false,
    this.blurredFrameOf,
  });

  final IconData? icon;
  final String title;
  final String? subtitle;
  final String identity;
  final String name;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// Translucent, so the last good frame shows dimmed instead of a flat surface.
  final bool dimsVideoBehind;

  /// The tile key whose remembered last frame shows blurred behind the card, in place of a flat surface.
  final String? blurredFrameOf;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Semantics(
      container: true,
      label: subtitle == null ? title : '$title. $subtitle',
      child: _Backdrop(
        tileKey: blurredFrameOf,
        color: dimsVideoBehind
            ? tokens.surfaceRaised.withValues(alpha: 0.78)
            : tokens.surfaceRaised,
        dim: tokens.surfaceRaised.withValues(alpha: 0.55),
        child: Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.s12),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 260),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ExcludeSemantics(
                      child: UserAvatar(
                        name: name,
                        userId: identity,
                        size: AppAvatarSize.s36,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.s8),
                    ExcludeSemantics(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (icon != null) ...[
                            Icon(icon, size: 14, color: tokens.textSecondary),
                            const SizedBox(width: AppSpacing.s4),
                          ],
                          Flexible(
                            child: Text(
                              title,
                              textAlign: TextAlign.center,
                              style: AppText.label.copyWith(
                                color: tokens.textPrimary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: AppSpacing.s4),
                      ExcludeSemantics(
                        child: Text(
                          subtitle!,
                          textAlign: TextAlign.center,
                          style: AppText.caption.copyWith(
                            color: tokens.textSecondary,
                          ),
                        ),
                      ),
                    ],
                    if (onAction != null) ...[
                      const SizedBox(height: AppSpacing.s8),
                      AppButton(
                        label: actionLabel!,
                        size: AppButtonSize.sm,
                        onPressed: onAction,
                      ),
                    ],
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

/// [color] flat, or [dim] over [tileKey]'s blurred last frame when one has been remembered.
class _Backdrop extends StatelessWidget {
  const _Backdrop({
    required this.tileKey,
    required this.color,
    required this.dim,
    required this.child,
  });

  final String? tileKey;
  final Color color;
  final Color dim;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final key = tileKey;
    if (key == null) return ColoredBox(color: color, child: child);
    return Stack(
      fit: StackFit.expand,
      children: [
        BlurredLastFrame(
          tileKey: key,
          fallback: ColoredBox(color: color),
        ),
        ColoredBox(color: dim, child: child),
      ],
    );
  }
}

/// What a remote screen share shows while it has no picture, by [ScreenShareStatus].
Widget screenShareStatusCard({
  required BuildContext context,
  required ScreenShareStatus status,
  required String identity,
  required String name,
}) {
  final (icon, title, subtitle) = switch (status) {
    ScreenShareStatus.loading => (
      AppIcons.screenShare,
      'Loading screen share',
      "Waiting for $name's first frame",
    ),
    ScreenShareStatus.paused => (
      AppIcons.pause,
      'Share paused',
      '$name paused their screen share',
    ),
    ScreenShareStatus.ended => (
      AppIcons.screenShareStop,
      'Share ended',
      "$name stopped sharing",
    ),
  };
  return VideoStateCard(
    icon: icon,
    title: title,
    subtitle: subtitle,
    identity: identity,
    name: name,
    blurredFrameOf: status == ScreenShareStatus.ended
        ? null
        : videoSubscriptionKey(identity: identity, screenShare: true),
  );
}
