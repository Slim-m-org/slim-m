// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The strip of controls laid over a share's stage: stream volume, the live
/// quality chip, full screen and a button for the tile's menu.
///
/// It sits beside the stage's double-click target, never inside it, so a quick
/// second press on a button is absorbed here and does not open full screen.
/// Hidden, it is not built at all: a keyboard user reaches the stage first,
/// which reveals the strip on focus, and every action also lives in the tile's
/// menu, which the menu key and a long press open.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'stream_control_pill.dart';

/// Width of the strip below which the volume slider stays in the tile menu only.
const double kStreamStripVolumeMinWidth = 400;

class StreamControlStrip extends StatelessWidget {
  const StreamControlStrip({
    super.key,
    required this.shown,
    required this.onMore,
    required this.menuGroup,
    this.volume,
    this.quality,
    this.onFullscreen,
  });

  final bool shown;

  /// Opens the tile's menu beside the button; gets the button's own context.
  final void Function(BuildContext button) onMore;

  /// The tap-region group of the menu [onMore] opens, so a second press on the button closes it.
  final Object menuGroup;
  final Widget? volume;
  final Widget? quality;
  final VoidCallback? onFullscreen;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: AppMotion.reduced(context, AppMotion.fast),
    layoutBuilder: (current, previous) =>
        Stack(fit: StackFit.passthrough, children: [...previous, ?current]),
    child: shown
        ? _strip(context)
        : const SizedBox.shrink(key: ValueKey('off')),
  );

  Widget _strip(BuildContext context) {
    return LayoutBuilder(
      key: const ValueKey('on'),
      builder: (context, constraints) => Row(
        mainAxisAlignment: MainAxisAlignment.end,
        spacing: AppSpacing.s8,
        children: [
          if (volume != null &&
              constraints.maxWidth >= kStreamStripVolumeMinWidth)
            Flexible(child: volume!),
          StreamControlPill(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ?quality,
                if (onFullscreen != null)
                  AppIconButton(
                    icon: AppIcons.expand,
                    semanticLabel: 'Full screen',
                    tooltip: 'Full screen',
                    onPressed: onFullscreen,
                  ),
                TapRegion(
                  groupId: menuGroup,
                  child: Builder(
                    builder: (button) => AppIconButton(
                      icon: AppIcons.moreHorizontal,
                      semanticLabel: 'Stream options',
                      tooltip: 'Stream options',
                      onPressed: () => onMore(button),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
