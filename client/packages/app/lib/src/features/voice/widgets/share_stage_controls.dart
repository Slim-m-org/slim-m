// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The controls that choose which screen shares a viewer watches: the stage
/// the shared context-menu rows, and the opt-back-in chip.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

/// The context-menu rows for one stream, shared by the share tile and the
/// participant menus; a null callback drops its row.
List<Widget> shareStageMenuItems(
  VoidCallback close, {
  required String sharerName,
  VoidCallback? onPopOut,
  VoidCallback? onStreamVolume,
  VoidCallback? onFocus,
  bool focused = false,
  VoidCallback? onStopWatching,
  VoidCallback? onFullscreen,
}) {
  Widget row(String label, IconData icon, VoidCallback act) => AppMenuItem(
    label: label,
    leading: icon,
    onTap: () {
      close();
      act();
    },
  );
  return [
    if (onPopOut != null) row('Pop out stream', AppIcons.popOut, onPopOut),
    if (onStreamVolume != null)
      row('Stream volume', AppIcons.speaker, onStreamVolume),
    if (onFocus != null)
      row(
        focused ? 'Show all shares' : "Focus $sharerName's screen",
        focused ? AppIcons.collapse : AppIcons.shareFocus,
        onFocus,
      ),
    if (onStopWatching != null)
      row('Hide stream', AppIcons.tileHide, onStopWatching),
    if (onFullscreen != null) row('Full screen', AppIcons.expand, onFullscreen),
  ];
}

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
