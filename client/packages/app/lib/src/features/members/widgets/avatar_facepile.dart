// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Overlapping avatars with a "+n" after them: the one facepile of the canvas bar and the channel rail.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

/// [avatars] drawn at [size] overlapping by [AppSpacing.s4], then "+[more]" when [more] is above zero.
class AvatarFacepile extends StatelessWidget {
  const AvatarFacepile({
    super.key,
    required this.avatars,
    this.more = 0,
    this.size = AppAvatarSize.s20,
  });

  /// Each already built at [size].
  final List<Widget> avatars;
  final int more;
  final double size;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final step = size - AppSpacing.s4;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: avatars.isEmpty ? 0 : size + step * (avatars.length - 1),
          height: size,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              for (var i = 0; i < avatars.length; i++)
                Positioned(left: i * step, child: avatars[i]),
            ],
          ),
        ),
        if (more > 0) ...[
          const SizedBox(width: AppSpacing.s4),
          Text(
            '+$more',
            maxLines: 1,
            softWrap: false,
            style: AppText.caption.copyWith(
              color: tokens.textSecondary,
              fontWeight: AppWeights.medium,
            ),
          ),
        ],
      ],
    );
  }
}
