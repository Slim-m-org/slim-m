// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The hash/voice glyph a channel row or header leads with, with a lock badge
/// cut into its corner when `@everyone` cannot view the channel, so a private
/// voice channel still reads as voice. Shared across the rail rows and both
/// channel headers so the tooltip and accessible label are written once.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

class ChannelKindIcon extends StatelessWidget {
  const ChannelKindIcon({
    super.key,
    required this.isVoice,
    required this.restricted,
    required this.color,
    this.size = AppSizes.icon16,
  });

  final bool isVoice;

  /// See `Channel.restricted`'s own doc comment (slimm_api). False for an
  /// ordinary channel and for a server too old to say either way.
  final bool restricted;
  final Color color;
  final double size;

  static const _label = "Restricted channel: not visible to everyone";

  @override
  Widget build(BuildContext context) {
    final kind = Icon(
      isVoice ? AppIcons.voice : AppIcons.hash,
      size: size,
      color: color,
    );
    if (!restricted) return kind;
    final badge = (size * 0.56).roundToDouble();
    return Tooltip(
      message: _label,
      child: Semantics(
        label: _label,
        child: SizedBox.square(
          dimension: size,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              ClipPath(clipper: _BadgeCutout(badge), child: kind),
              Positioned(
                right: -badge * 0.2,
                bottom: -badge * 0.15,
                child: Icon(
                  AppIcons.restrictedChannel,
                  size: badge,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The kind glyph minus a disc behind the badge, so the two never overlap
/// whatever the row's background is.
class _BadgeCutout extends CustomClipper<Path> {
  const _BadgeCutout(this.badge);

  final double badge;

  @override
  Path getClip(Size size) {
    final centre = Offset(
      size.width + badge * 0.2 - badge / 2,
      size.height + badge * 0.15 - badge / 2,
    );
    return Path.combine(
      PathOperation.difference,
      Path()..addRect(Offset.zero & size),
      Path()..addOval(Rect.fromCircle(center: centre, radius: badge * 0.62)),
    );
  }

  @override
  bool shouldReclip(_BadgeCutout oldClipper) => oldClipper.badge != badge;
}
