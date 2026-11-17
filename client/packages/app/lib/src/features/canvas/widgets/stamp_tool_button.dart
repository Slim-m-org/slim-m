// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Stamp tool's button (decision 0121), wearing the armed stamp as its
/// sample the way the pen button wears its colour (0073). The same on a share
/// tile's pill and on the board.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/armed_stamp.dart';
import 'stamp_view.dart';

/// The armed sample's square in the button's corner.
const _sampleSide = AppSizes.icon16;

class StampToolButton extends ConsumerWidget {
  const StampToolButton({
    super.key,
    required this.active,
    required this.semanticLabel,
    required this.onPressed,
    this.tooltip,
    this.size = AppIconButtonSize.md,
  });

  final bool active;
  final String semanticLabel;
  final String? tooltip;
  final AppIconButtonSize size;

  /// Handed the button's own context, which a picker anchors to.
  final void Function(BuildContext anchor)? onPressed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final armed = ref.watch(armedStampProvider).content;
    final press = onPressed;
    return Builder(
      builder: (anchor) => Stack(
        clipBehavior: Clip.none,
        children: [
          AppIconButton(
            icon: AppIcons.stamp,
            semanticLabel: semanticLabel,
            tooltip: tooltip,
            size: size,
            active: active,
            onPressed: press == null ? null : () => press(anchor),
          ),
          if (armed != null)
            Positioned(
              right: 0,
              bottom: 0,
              width: _sampleSide,
              height: _sampleSide,
              child: IgnorePointer(child: StampView(content: armed)),
            ),
        ],
      ),
    );
  }
}
