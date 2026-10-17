// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The controls that choose which screen shares a viewer watches: the stage
/// tile's icon buttons, its long-press menu rows, and the opt-back-in chip.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

/// Window width from which a share tile shows icon buttons; below it the
/// same verbs live in the tile's long-press menu (decision: width, not platform).
const double shareStageIconsMinWidth = 600;

/// A round overlay button on a share tile, with a tooltip for pointers.
class ShareStageButton extends StatelessWidget {
  const ShareStageButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: label,
    excludeFromSemantics: true,
    child: Semantics(
      button: true,
      label: label,
      onTap: onTap,
      child: GestureDetector(
        excludeFromSemantics: true,
        onTap: onTap,
        child: Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: 14, color: Colors.white),
        ),
      ),
    ),
  );
}

/// The long-press menu rows for a share tile; a null callback drops its row.
List<Widget> shareStageMenuItems(
  VoidCallback close, {
  required String sharerName,
  VoidCallback? onStopWatching,
  VoidCallback? onFocus,
  bool focused = false,
}) => [
  if (onFocus != null)
    AppMenuItem(
      label: focused ? 'Show all shares' : 'Focus $sharerName\'s screen',
      leading: focused ? AppIcons.collapse : AppIcons.shareFocus,
      onTap: () {
        close();
        onFocus();
      },
    ),
  if (onStopWatching != null)
    AppMenuItem(
      label: 'Stop watching',
      leading: AppIcons.tileHide,
      onTap: () {
        close();
        onStopWatching();
      },
    ),
];

/// "Name is sharing" with a Watch action, for a share the viewer stopped.
class ShareWatchChip extends StatelessWidget {
  const ShareWatchChip({
    super.key,
    required this.sharerName,
    required this.onWatch,
  });

  final String sharerName;
  final VoidCallback onWatch;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Container(
      padding: const EdgeInsets.only(left: AppSpacing.s12),
      decoration: BoxDecoration(
        color: tokens.surfaceRaised,
        borderRadius: BorderRadius.circular(AppRadii.full),
        border: Border.all(color: tokens.borderSubtle),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(AppIcons.screenShare, size: 14, color: tokens.accent),
          const SizedBox(width: AppSpacing.s8),
          Flexible(
            child: Text(
              '$sharerName is sharing',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.caption.copyWith(color: tokens.textPrimary),
            ),
          ),
          TextButton(onPressed: onWatch, child: const Text('Watch')),
        ],
      ),
    );
  }
}
